const express = require('express');
const helmet = require('helmet');
const crypto = require('crypto');
const EventEmitter = require('events');
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');
const { campusDateKey, isDateOnly, matchesCampusDate } = require('./campus_time');
const { mailProvider, mailConfigurationIssue, sendMail } = require('./mailer');
const { smsProvider, sendSms } = require('./sms');
const { createRegistrationMobileRouter } = require('./registration_mobile');
const { localMockDeliveryEnabled, takeLocalMessages } = require('./local_delivery');
const {
    canAccessDuringPasswordChange,
    createLoginRateLimiter,
    createLoginHandler,
    createUserLookup,
    compareDriverPin,
} = require('./auth_credentials');
const { createLoginAttemptStore, hashLoginIdentifier } = require('./login_attempts');
const { createPasswordRecoveryRouter, digest, normalizeMobile } = require('./password_recovery');
const { createEmailPasswordRecoveryRouter } = require('./email_password_recovery');
const { createPasswordRecoveryStore } = require('./password_recovery_store');
const { fingerprintDatabaseIdentity } = require('./database_identity');
const { createTelemetryRateLimiter, findDeviceKeyAssignment, timingSafeSecretEqual } = require('./device_keys');
const {
    TELEMETRY_DIAGNOSTIC_CODES,
    diagnoseEmptyLatestTelemetry,
    hasValidDeviceFix,
    parseTelemetryBusNumber,
    telemetryErrorPayload,
} = require('./telemetry_diagnostics');
const { createSessionStore } = require('./session_store');
const { boundedString, finiteNumberInRange, positiveSafeInteger } = require('./input_validation');
const { rejectRequest } = require('./request_rejections');
const { createReportSubmissionHandler } = require('./report_submission');
const path = require('path');
require('dotenv').config({
    path: process.env.SMARTBUS_ENV_FILE || path.join(__dirname, '.env.local'),
    quiet: true,
});

if (mailConfigurationIssue(process.env) || !mailProvider(process.env)) {
    console.error('Password recovery email is disabled: mail provider configuration is incomplete.');
}

if (process.env.NODE_ENV === 'production' && process.env.ALLOW_LEGACY_API_KEY === 'true' && !process.env.API_SECRET_KEY) {
    throw new Error('API_SECRET_KEY must be configured in production');
}
if (process.env.NODE_ENV === 'production' && !process.env.DATABASE_URL) {
    const missingDatabaseSettings = ['DB_HOST', 'DB_USER', 'DB_PASSWORD', 'DB_NAME']
        .filter((key) => !process.env[key]);
    if (missingDatabaseSettings.length) {
        throw new Error(`Database environment is incomplete: ${missingDatabaseSettings.join(', ')}`);
    }
}

const app = express();
const corsOrigins = new Set((process.env.CORS_ORIGINS || '').split(',').map((origin) => origin.trim()).filter(Boolean));
if (process.env.NODE_ENV === 'production') app.set('trust proxy', 1);
const telemetryEmitter = new EventEmitter();
telemetryEmitter.setMaxListeners(0);
const port = Number(process.env.PORT || 8080);
const bindAddress = process.env.NODE_ENV === 'development'
    ? process.env.LOCAL_API_BIND_ADDRESS || '127.0.0.1'
    : '0.0.0.0';
const API_SECRET_KEY = process.env.API_SECRET_KEY || null;
const ALLOW_LEGACY_API_KEY = process.env.ALLOW_LEGACY_API_KEY === 'true';
const LEGACY_API_BUS_NUMBER = Number(process.env.LEGACY_API_BUS_NUMBER || 0);
const telemetryRateLimiter = createTelemetryRateLimiter();
const registrationRateLimiter = createLoginRateLimiter({ limit: 5, windowMs: 15 * 60 * 1000 });

const DB_HOST = process.env.DB_HOST || '127.0.0.1'; // Local development default only; Render sets DB_HOST.
const DB_PORT = Number(process.env.DB_PORT || 5432);
const DB_USER = process.env.DB_USER || 'smartbus';
const DB_PASSWORD = process.env.DB_PASSWORD || '';
const DB_NAME = process.env.DB_NAME || 'smartbus_local';

let pool;
const sessionStore = createSessionStore(() => pool);
let sessionCleanupInterval = null;

const hostelsSeed = [
    { id: 'GH1', name: 'GH1', type: 'Girls', fullName: "Girls' Hostel 1" },
    { id: 'GH2', name: 'GH2', type: 'Girls', fullName: "Girls' Hostel 2" },
    { id: 'BH1', name: 'BH1', type: 'Boys', fullName: "Boys' Hostel 1" },
    { id: 'BH2', name: 'BH2', type: 'Boys', fullName: "Boys' Hostel 2" },
    { id: 'BH3', name: 'BH3', type: 'Boys', fullName: "Boys' Hostel 3" },
    { id: 'BH4', name: 'BH4', type: 'Boys', fullName: "Boys' Hostel 4" },
];

const busesSeed = [
    [1, 'GH1', 'Pa Hlutea', '9436168711', 23.7285, 92.7180, 'idle', '8:30 AM', '1:30 PM'],
    [2, 'GH1', 'Pu Stephen', '8787778119', 23.7260, 92.7165, 'running', '9:15 AM', '4:30 PM'],
    [3, 'GH1', 'Mawizuala', '8131811729', 23.7290, 92.7200, 'idle', '8:30 AM', '5:30 PM'],
    [4, 'GH2', 'Hruaia', '6909101103', 23.7240, 92.7150, 'running', '8:15 AM', '4:30 PM'],
    [5, 'BH1', 'Chhuanga', '9862369186', 23.7275, 92.7185, 'running', '8:15 AM', '5:30 PM'],
    [6, 'BH1', 'Pa Dina', '9615408299', 23.7265, 92.7170, 'idle', '8:15 AM', '7:00 PM'],
    [7, 'BH1', 'Vk-a', '7005367693', 23.7280, 92.7195, 'running', '8:15 AM', '5:30 PM'],
    [8, 'BH1', 'Dama', '7005364878', 23.7255, 92.7160, 'idle', '6:30 AM', '12:30 PM', 'IoN Digital Centre Mualpui'],
    [9, 'BH1', 'Mala', '6009425695', 23.7295, 92.7205, 'maintenance', '1:00 PM', '4:30 PM'],
    [10, 'BH1', 'Rinkima', '7005616947', 23.7270, 92.7175, 'idle', '9:15 AM', '1:30 PM'],
    [11, 'BH1', 'Pa Dika', '6909470121', 23.7250, 92.7155, 'running', '9:15 AM', '1:30 PM'],
    [12, 'BH1', 'Ramtea', '8729985255', 23.7285, 92.7190, 'idle', '10:15 AM', '2:30 PM'],
    [13, 'BH2', 'Lalrammawia', '9862411234', 23.7260, 92.7165, 'running', '9:20 AM', '2:00 PM'],
    [14, 'BH2', 'Vanlalruata', '8014567890', 23.7245, 92.7148, 'idle', '8:20 AM', '3:20 PM'],
    [15, 'BH2', 'Zohmingliana', '7005223344', 23.7300, 92.7210, 'running', '8:20 AM', '11:15 AM'],
    [16, 'BH3', 'Lalduhawma', '9856112233', 23.7230, 92.7140, 'idle', '8:00 AM', '4:00 PM'],
    [17, 'BH3', 'Vanlalngaia', '6009334455', 23.7315, 92.7215, 'running', '9:00 AM', '5:00 PM'],
    [18, 'BH3', 'Hmingthansanga', '7005556677', 23.7240, 92.7155, 'idle', '8:30 AM', '3:30 PM'],
    [19, 'BH3', 'Lalremruata', '8259667788', 23.7305, 92.7205, 'idle', '9:30 AM', '4:30 PM'],
    [20, 'BH3', 'Thangmawia', '9612778899', 23.7235, 92.7145, 'running', '10:00 AM', '2:00 PM'],
    [21, 'BH4', 'Kaptluanga', '9862990011', 23.7320, 92.7220, 'idle', '8:45 AM', '5:00 PM'],
    [22, 'GH2', 'Saka', '9378074359', 23.7245, 92.7152, 'running', '8:25 AM', '5:30 PM'],
];

const notificationsSeed = [
    ['n1', 'Bus 5 Departure Alert', 'Bus 5 will depart from BH1 at 8:15 AM. Please be ready!', 'departure', 5, 'BH1', false],
    ['n2', 'Bus 7 Schedule Update', 'Bus 7 schedule updated. From Hostel: 8:15 PM, From MBSE: 5:30 PM', 'general', 7, 'BH1', false],
    ['n3', 'Bus 2 Arriving Soon', 'Bus 2 (GH1) is 1 km away from hostel. ETA: 5 minutes!', 'arrival', 2, 'GH1', true],
    ['n4', 'Bus 9 Maintenance', 'Bus 9 is under maintenance today. Please use alternate buses.', 'delay', 9, 'BH1', true],
];

const driverLastFixes = new Map();
const passwordRecoveryStore = createPasswordRecoveryStore(() => pool);
const loginAttemptStore = createLoginAttemptStore(() => pool);

// Schedule calendar dates belong to the campus, whose civil timezone is IST.
const today = () => campusDateKey(new Date());
const uid = (prefix) => `${prefix}${crypto.randomBytes(6).toString('hex')}`;
// Student roll IDs use the published example shape BT24CS034. The configured
// account table currently contains caretaker identities only; see SECURITY_NOTES.md.
const COLLEGE_STUDENT_EMAIL = /^bt\d{2}[a-z]{2}\d{3}@nitmz\.ac\.in$/i;

app.use(helmet({ contentSecurityPolicy: false }));
app.use((req, res, next) => {
    const startedAt = process.hrtime.bigint();
    res.on('finish', () => {
        const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
        console.info(`${req.method} ${req.path} ${res.statusCode} ${durationMs.toFixed(0)}ms`);
    });
    next();
});
app.use(express.json());
app.use((req, res, next) => {
    const origin = req.get('origin');
    if (origin && !corsOrigins.has(origin)) {
        return rejectRequest(res, req, 403, 'ORIGIN_NOT_ALLOWED', 'Origin not allowed');
    }
    if (origin) {
        res.setHeader('Access-Control-Allow-Origin', origin);
        res.vary('Origin');
    }
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization, x-api-key');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    return next();
});
app.use(async (req, res, next) => {
    const header = req.header('authorization') || '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : null;
    req.authToken = token && token.length <= 256 ? token : null;
    req.authSession = null;
    if (!req.authToken) return next();

    try {
        req.authSession = await sessionStore.findByToken(req.authToken);
        return next();
    } catch (error) {
        const errorId = crypto.randomBytes(4).toString('hex');
        console.error(`Session lookup failed (${errorId}; ${safeDatabaseErrorCode(error)})`, error);
        return res.status(503).json({ error: 'Authentication temporarily unavailable', errorId });
    }
});

async function q(sql, params = []) {
    // convert '?' placeholders to $1, $2, ... for pg
    let idx = 0;
    const text = sql.replace(/\?/g, () => `$${++idx}`);
    const res = await pool.query(text, params);
    return res.rows;
}

function safeDatabaseErrorCode(error) {
    return typeof error?.code === 'string' && /^[A-Z0-9_-]{1,32}$/.test(error.code)
        ? error.code
        : 'unknown';
}

function shouldSeedSampleData(env = process.env) {
    return env.SEED_SAMPLE_DATA === 'true';
}

function internalError(res, error, context) {
    const errorId = crypto.randomBytes(4).toString('hex');
    console.error(`Internal error ${errorId} (${context}; ${safeDatabaseErrorCode(error)})`, error);
    if (res.headersSent) return res.end();
    return res.status(500).json({ error: 'Internal server error', errorId });
}

async function checkDatabaseConnection() {
    if (!pool) return false;
    try {
        await pool.query('SELECT 1');
        return true;
    } catch (error) {
        console.error(`PostgreSQL connectivity check failed (${safeDatabaseErrorCode(error)})`);
        return false;
    }
}

function consumeSlidingWindowLimit(limits, key, limit, windowMs, now = Date.now()) {
    for (const [entryKey, timestamps] of limits) {
        const recent = timestamps.filter((timestamp) => now - timestamp < windowMs);
        if (recent.length) limits.set(entryKey, recent);
        else limits.delete(entryKey);
    }
    const timestamps = limits.get(key) || [];
    if (timestamps.length >= limit) return false;
    timestamps.push(now);
    limits.set(key, timestamps);
    return true;
}

function publicUser(row) {
    return {
        id: row.id,
        name: row.name,
        email: row.email,
        role: row.role,
        hostelId: row.hostel_id,
        mustChangePassword: Boolean(row.must_change_password),
    };
}

function mapSchedule(row) {
    if (!row.schedule_id) return null;
    return {
        _id: row.schedule_id,
        busNumber: row.bus_number,
        date: row.schedule_date,
        fromHostelTime: row.from_hostel_time,
        fromMBSETime: row.from_mbse_time,
        specialNote: row.special_note || '',
        updatedBy: row.updated_by || '',
    };
}

function mapScheduleForToday(row) {
    if (!row.schedule_id || !row.schedule_date) return null;
    const todayKey = today();
    const scheduleDate = row.schedule_date instanceof Date
        ? campusDateKey(row.schedule_date)
        : String(row.schedule_date).slice(0, 10);
    if (!matchesCampusDate(scheduleDate, todayKey)) {
        return null;
    }
    return mapSchedule(row);
}

function mapBus(row, viewerRole = 'student') {
    return {
        busNumber: row.bus_number,
        name: row.bus_name || `Bus ${row.bus_number}`,
        assignedHostel: row.assigned_hostel,
        sourcePlace: row.source_place || row.assigned_hostel,
        destinationPlace: row.destination_place || 'MBSE',
        status: row.status,
        latitude: Number(row.latitude),
        longitude: Number(row.longitude),
        speed: Number(row.speed),
        isEnabled: !!row.is_enabled,
        route: row.route || 'Hostel ↔ MBSE',
        lastUpdated: row.last_updated ? (row.last_updated.toISOString?.() ?? row.last_updated) : null,
        driver: row.driver_id
            ? {
                _id: row.driver_id,
                name: row.driver_name,
                ...(['caretaker', 'admin'].includes(viewerRole) && row.driver_phone
                    ? { phone: row.driver_phone }
                    : {}),
                busNumber: row.bus_number,
                isActive: !!row.driver_is_active,
            }
            : null,
        schedule: mapScheduleForToday(row),
    };
}

function mapLiveBus(row) {
    return {
        busNumber: row.bus_number,
        status: row.status,
        lat: row.lat != null ? Number(row.lat) : Number(row.latitude),
        lng: row.lng != null ? Number(row.lng) : Number(row.longitude),
        speed: Number(row.speed || 0),
        route: row.route || 'Hostel ↔ MBSE',
        hostel: row.assigned_hostel,
        hasFix: row.has_fix ?? (row.lat != null && row.lng != null),
        satellites: row.satellites != null ? Number(row.satellites) : null,
        hdop: row.hdop != null ? Number(row.hdop) : null,
        netType: row.net_type || 'API',
        lastUpdated: row.received_at || null,
    };
}

function normalizeTelemetry(body = {}) {
    const rawBusId = body.bus_id ?? body.bus_number ?? body.busId ?? body.busNo ?? body.bus ?? null;
    return {
        deviceId: body.device_id == null && body.deviceId == null
            ? null
            : boundedString(String(body.device_id ?? body.deviceId), 60, { required: true }),
        busId: rawBusId === null ? null : boundedString(String(rawBusId), 40, { required: true }),
        lat: finiteNumberInRange(body.lat ?? body.latitude ?? body.lat_deg, -90, 90),
        lng: finiteNumberInRange(body.lng ?? body.longitude ?? body.lng_deg ?? body.long, -180, 180),
        speed: finiteNumberInRange(body.speed ?? body.speed_kmh ?? body.spd, 0, 250, 0),
        accuracy: finiteNumberInRange(body.accuracy ?? body.hdop, 0, 1000, 1),
        hasFix: body.has_fix ?? null,
        satellites: finiteNumberInRange(body.satellites, 0, 128, 0),
        hdop: finiteNumberInRange(body.hdop ?? body.accuracy, 0, 1000, 99.9),
        netType: boundedString(body.net_type || body.netType || 'unknown', 20, { required: true }),
        timestamp: body.ts ?? body.timestamp ?? null,
        status: boundedString(body.status || 'idle', 20, { required: true }),
    };
}

function haversineKm(a, b) {
    const radians = (degrees) => degrees * Math.PI / 180;
    const dLat = radians(b.lat - a.lat);
    const dLng = radians(b.lng - a.lng);
    const value = Math.sin(dLat / 2) ** 2 + Math.cos(radians(a.lat)) * Math.cos(radians(b.lat)) * Math.sin(dLng / 2) ** 2;
    return 6371 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function bearingDegrees(a, b) {
    const radians = (degrees) => degrees * Math.PI / 180;
    const lat1 = radians(a.lat);
    const lat2 = radians(b.lat);
    const lngDelta = radians(b.lng - a.lng);
    const y = Math.sin(lngDelta) * Math.cos(lat2);
    const x = Math.cos(lat1) * Math.sin(lat2) - Math.sin(lat1) * Math.cos(lat2) * Math.cos(lngDelta);
    return (Math.atan2(y, x) * 180 / Math.PI + 360) % 360;
}

function requireAuth(req, res, allowedRoles = null, logger = console) {
    const token = req.authToken;
    const session = req.authSession;
    if (!token || !session || new Date(session.expiresAt).getTime() < Date.now()) {
        rejectRequest(res, req, 401, 'AUTHENTICATION_REQUIRED', 'Unauthorized', logger);
        return null;
    }

    if (allowedRoles && !allowedRoles.includes(session.role)) {
        rejectRequest(res, req, 403, 'ROLE_NOT_ALLOWED', 'Forbidden', logger);
        return null;
    }
    if (session.mustChangePassword && !canAccessDuringPasswordChange(req.path)) {
        rejectRequest(res, req, 403, 'PASSWORD_CHANGE_REQUIRED', 'Change your temporary password to continue', logger);
        return null;
    }

    return { token, ...session };
}

async function createToken(user) {
    const expiresAt = Date.now() + 24 * 30 * 60 * 60 * 1000;
    const token = crypto.randomBytes(32).toString('hex');
    await sessionStore.create(token, user, new Date(expiresAt));
    return token;
}

const BUS_SELECT = `
SELECT
  b.bus_number,
  b.bus_name,
  b.assigned_hostel,
  b.source_place,
  b.destination_place,
  b.status,
  b.latitude,
  b.longitude,
  b.speed,
  b.is_enabled,
  b.route,
  live.last_updated,
  d.id AS driver_id,
  d.name AS driver_name,
  d.phone AS driver_phone,
  d.is_active AS driver_is_active,
  s.id AS schedule_id,
  s.date AS schedule_date,
  s.from_hostel_time,
  s.from_mbse_time,
  s.special_note,
  s.updated_by
FROM buses b
LEFT JOIN drivers d ON d.bus_number = b.bus_number AND d.is_active = true
LEFT JOIN (
  SELECT DISTINCT ON (bus_id) bus_id, received_at AS last_updated
  FROM telemetry WHERE bus_id IS NOT NULL
  ORDER BY bus_id, received_at DESC
) live ON live.bus_id = CAST(b.bus_number AS TEXT)
LEFT JOIN (
  SELECT s1.*
  FROM schedules s1
  JOIN (
    SELECT bus_number, MAX(updated_at) AS max_updated
    FROM schedules
    GROUP BY bus_number
  ) s2 ON s1.bus_number = s2.bus_number AND s1.updated_at = s2.max_updated
) s ON s.bus_number = b.bus_number
`;

async function fetchBusByNumber(busNumber, viewerRole = 'student') {
    const rows = await q(`${BUS_SELECT} WHERE b.bus_number = ?`, [busNumber]);
    return rows.length ? mapBus(rows[0], viewerRole) : null;
}

async function assertCaretakerAccess(busNumber, auth) {
    const busRows = await q('SELECT bus_number, assigned_hostel FROM buses WHERE bus_number = ? LIMIT 1', [busNumber]);
    if (!busRows.length) {
        return { ok: false, code: 404, message: 'Bus not found' };
    }
    if (auth.role === 'caretaker' && (!auth.hostelId || busRows[0].assigned_hostel !== auth.hostelId)) {
        return { ok: false, code: 403, message: 'Caretaker can only update own hostel buses' };
    }
    return { ok: true, bus: busRows[0] };
}

async function initializeDatabase() {
    const poolConfig = {
        ...(process.env.DATABASE_URL
            ? { connectionString: process.env.DATABASE_URL }
            : {
                host: DB_HOST,
                port: DB_PORT,
                user: DB_USER,
                password: DB_PASSWORD,
                database: DB_NAME,
            }),
        ...(process.env.DB_SSL === 'true'
            ? { ssl: { rejectUnauthorized: false } }
            : {}),
        max: Number(process.env.PG_POOL_MAX || 10),
        connectionTimeoutMillis: Number(process.env.DB_CONNECTION_TIMEOUT_MS || 5000),
        query_timeout: Number(process.env.DB_QUERY_TIMEOUT_MS || 8000),
        idleTimeoutMillis: 30000,
        keepAlive: true,
    };
    pool = new Pool(poolConfig);
    pool.on('error', (error) => {
        console.error(`PostgreSQL idle pool client error (${safeDatabaseErrorCode(error)})`);
    });

    // Create tables (Postgres-compatible)
    await q(`
CREATE TABLE IF NOT EXISTS hostels (
  id VARCHAR(10) PRIMARY KEY,
  name VARCHAR(20) NOT NULL,
  type VARCHAR(20) NOT NULL,
  full_name VARCHAR(100) NOT NULL
);
`);

    await q(`
CREATE TABLE IF NOT EXISTS users (
  id VARCHAR(40) PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(120) NOT NULL UNIQUE,
  password VARCHAR(120) NOT NULL,
  role VARCHAR(20) NOT NULL,
  hostel_id VARCHAR(10) NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (hostel_id) REFERENCES hostels(id) ON DELETE SET NULL
);
`);
        await q(`
CREATE TABLE IF NOT EXISTS sessions (
    token_hash CHAR(64) PRIMARY KEY,
    user_id VARCHAR(40) NOT NULL,
    email VARCHAR(120) NULL,
    role VARCHAR(20) NOT NULL,
    hostel_id VARCHAR(10) NULL,
    phone VARCHAR(30) NULL,
    bus_number INT NULL,
    must_change_password BOOLEAN NOT NULL DEFAULT false,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
`);
        await q('CREATE INDEX IF NOT EXISTS sessions_user_id_idx ON sessions (user_id)');
        await q('CREATE INDEX IF NOT EXISTS sessions_expires_at_idx ON sessions (expires_at)');
        await q(`
CREATE TABLE IF NOT EXISTS login_attempts (
    identifier_hash CHAR(64) PRIMARY KEY,
    failed_attempts SMALLINT NOT NULL DEFAULT 0,
    blocked_until TIMESTAMPTZ NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
`);
        await q('CREATE INDEX IF NOT EXISTS login_attempts_updated_at_idx ON login_attempts (updated_at)');
    await q('ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT false');
    await q('ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_email VARCHAR(120) NULL');
    await q('ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_phone VARCHAR(20) NULL');
    await q('ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_phone_verified_at TIMESTAMPTZ NULL');
    await q(`
CREATE TABLE IF NOT EXISTS password_resets (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash CHAR(64) NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
`);
    await q(`UPDATE password_resets
        SET expires_at = LEAST(expires_at, created_at + INTERVAL '15 minutes')
        WHERE used_at IS NULL`);
    await q(`
CREATE TABLE IF NOT EXISTS password_reset_otps (
    id BIGSERIAL PRIMARY KEY,
    user_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    otp_hash CHAR(64) NOT NULL,
    attempts SMALLINT NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
`);
    await q(`CREATE TABLE IF NOT EXISTS email_password_recovery_otps (
        id BIGSERIAL PRIMARY KEY,
        user_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        otp_hash VARCHAR(100) NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        used BOOLEAN NOT NULL DEFAULT false,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )`);
    await q('CREATE INDEX IF NOT EXISTS email_password_recovery_otps_user_created_idx ON email_password_recovery_otps (user_id, created_at DESC)');
    await q(`CREATE INDEX IF NOT EXISTS password_reset_otps_user_created_idx
        ON password_reset_otps (user_id, created_at DESC)`);
    await q(`CREATE TABLE IF NOT EXISTS registration_mobile_verifications (
        id VARCHAR(40) PRIMARY KEY,
        email VARCHAR(120) NOT NULL,
        mobile VARCHAR(20) NOT NULL,
        otp_hash CHAR(64) NOT NULL,
        attempts SMALLINT NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
        verification_token_hash CHAR(64) NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        verified_at TIMESTAMPTZ NULL,
        used_at TIMESTAMPTZ NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (email, mobile)
    )`);
    await q(`CREATE INDEX IF NOT EXISTS registration_mobile_verifications_expiry_idx
        ON registration_mobile_verifications (expires_at)`);
    const duplicateEmails = await q('SELECT LOWER(email) AS email FROM users GROUP BY LOWER(email) HAVING COUNT(*) > 1');
    if (duplicateEmails.length) {
        throw new Error('Duplicate email accounts must be resolved before the server can start');
    }
    await q(`CREATE UNIQUE INDEX IF NOT EXISTS users_verified_recovery_phone_unique
        ON users (recovery_phone)
        WHERE recovery_phone IS NOT NULL AND recovery_phone_verified_at IS NOT NULL AND role = 'student'`);
    await q('CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_unique ON users (LOWER(email))');

    await q(`
CREATE TABLE IF NOT EXISTS buses (
  bus_number INT PRIMARY KEY,
  bus_name VARCHAR(80) NOT NULL DEFAULT '',
  assigned_hostel VARCHAR(10) NOT NULL,
  source_place VARCHAR(120) NOT NULL DEFAULT '',
  destination_place VARCHAR(120) NOT NULL DEFAULT '',
  status VARCHAR(20) NOT NULL DEFAULT 'idle',
  latitude NUMERIC(10,6) NOT NULL,
  longitude NUMERIC(10,6) NOT NULL,
  speed NUMERIC(8,2) NOT NULL DEFAULT 0,
  is_enabled BOOLEAN NOT NULL DEFAULT true,
  route VARCHAR(120) NOT NULL DEFAULT 'Hostel ↔ MBSE',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (assigned_hostel) REFERENCES hostels(id)
);
`);
    await q("ALTER TABLE buses ADD COLUMN IF NOT EXISTS bus_name VARCHAR(80) NOT NULL DEFAULT ''");
    await q("ALTER TABLE buses ADD COLUMN IF NOT EXISTS source_place VARCHAR(120) NOT NULL DEFAULT ''");
    await q("ALTER TABLE buses ADD COLUMN IF NOT EXISTS destination_place VARCHAR(120) NOT NULL DEFAULT ''");
    await q("UPDATE buses SET bus_name = 'Bus ' || bus_number::text WHERE bus_name = ''");
    await q("UPDATE buses SET source_place = assigned_hostel WHERE source_place = ''");
    await q("UPDATE buses SET destination_place = 'MBSE' WHERE destination_place = ''");

    await q(`
CREATE TABLE IF NOT EXISTS drivers (
  id VARCHAR(40) PRIMARY KEY,
  bus_number INT NOT NULL UNIQUE,
    name VARCHAR(120) NULL,
  phone VARCHAR(30) NULL,
  pin_hash VARCHAR(100) NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  FOREIGN KEY (bus_number) REFERENCES buses(bus_number) ON DELETE CASCADE
);
`);
    await q('ALTER TABLE drivers ADD COLUMN IF NOT EXISTS pin_hash VARCHAR(100) NULL');
    await q(`
CREATE TABLE IF NOT EXISTS schedules (
  id VARCHAR(40) PRIMARY KEY,
  bus_number INT NOT NULL REFERENCES buses(bus_number) ON DELETE CASCADE,
  date DATE NOT NULL,
  from_hostel_time VARCHAR(20) NOT NULL,
  from_mbse_time VARCHAR(20) NOT NULL,
  special_note VARCHAR(255) NULL,
  updated_by VARCHAR(120) NULL,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (bus_number, date)
);
`);
    const scheduleDateType = await q(`SELECT data_type FROM information_schema.columns
        WHERE table_schema = current_schema() AND table_name = 'schedules' AND column_name = 'date'`);
    if (scheduleDateType.length && scheduleDateType[0].data_type !== 'date') {
        // Legacy timestamp values are converted to their IST calendar date. A UTC-midnight
        // value and an IST-midnight instant therefore both retain the intended civil day.
        const dateExpression = scheduleDateType[0].data_type === 'timestamp with time zone'
            ? `(date AT TIME ZONE 'Asia/Kolkata')::date`
            : 'date::date';
        const collisions = await q(`SELECT bus_number, ${dateExpression} AS normalized_date
            FROM schedules GROUP BY bus_number, ${dateExpression} HAVING COUNT(*) > 1 LIMIT 1`);
        if (collisions.length) {
            throw new Error('Schedule date migration found multiple records for one bus and IST date; resolve these rows before converting the legacy timestamp column');
        }
        await q(`ALTER TABLE schedules ALTER COLUMN date TYPE DATE USING ${dateExpression}`);
    }
    await q(`
CREATE TABLE IF NOT EXISTS notifications (
  id VARCHAR(40) PRIMARY KEY,
  title VARCHAR(160) NOT NULL,
  message TEXT NOT NULL,
  type VARCHAR(30) NOT NULL,
  bus_number INT NULL,
  target_hostel VARCHAR(10) NULL,
  sent_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '30 days'),
  is_read BOOLEAN NOT NULL DEFAULT false,
  sent_by VARCHAR(120) NULL,
  FOREIGN KEY (target_hostel) REFERENCES hostels(id) ON DELETE SET NULL
);
`);
    await q(`
CREATE TABLE IF NOT EXISTS reports (
  id VARCHAR(40) PRIMARY KEY,
  reporter_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  hostel_id VARCHAR(10) NOT NULL REFERENCES hostels(id),
  bus_number INT NULL REFERENCES buses(bus_number) ON DELETE SET NULL,
  category VARCHAR(40) NOT NULL,
  message TEXT NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'open',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
`);
    await q('CREATE INDEX IF NOT EXISTS reports_hostel_created_idx ON reports (hostel_id, created_at DESC)');
    await q('ALTER TABLE notifications ADD COLUMN IF NOT EXISTS expires_at TIMESTAMP');
    await q("UPDATE notifications SET expires_at = sent_at + INTERVAL '30 days' WHERE expires_at IS NULL");
    await q("ALTER TABLE notifications ALTER COLUMN expires_at SET DEFAULT (CURRENT_TIMESTAMP + INTERVAL '30 days')");
    await q('ALTER TABLE notifications ALTER COLUMN expires_at SET NOT NULL');
    await q('CREATE INDEX IF NOT EXISTS notifications_expires_at_idx ON notifications (expires_at)');

    await q(`
CREATE TABLE IF NOT EXISTS telemetry (
  id SERIAL PRIMARY KEY,
  device_id VARCHAR(60) NULL,
  bus_id VARCHAR(40) NULL,
  lat NUMERIC(10,6) NOT NULL,
  lng NUMERIC(10,6) NOT NULL,
  speed NUMERIC(8,2) NOT NULL DEFAULT 0,
  accuracy NUMERIC(8,2) NOT NULL DEFAULT 1.0,
  heading NUMERIC(6,2) NOT NULL DEFAULT 0,
  ts VARCHAR(64) NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'idle',
  received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
`);
    await q('ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS has_fix BOOLEAN DEFAULT false');
    await q('ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS satellites INT DEFAULT 0');
    await q('ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS hdop NUMERIC(6,2) DEFAULT 99.9');
    await q("ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS net_type VARCHAR(20) DEFAULT 'unknown'");
    await q('ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS heading NUMERIC(6,2) NOT NULL DEFAULT 0');

        await q(`
CREATE TABLE IF NOT EXISTS device_keys (
    bus_number INT NOT NULL REFERENCES buses(bus_number) ON DELETE CASCADE,
    key_hash CHAR(64) PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ NULL
);
`);
        await q('CREATE INDEX IF NOT EXISTS device_keys_bus_active_idx ON device_keys (bus_number) WHERE revoked_at IS NULL');

    for (const hostel of hostelsSeed) {
        await q('INSERT INTO hostels (id, name, type, full_name) VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING', [
            hostel.id,
            hostel.name,
            hostel.type,
            hostel.fullName,
        ]);
    }
    if (shouldSeedSampleData()) {
        const [busCountRow] = await q('SELECT COUNT(*) AS count FROM buses');
        const busCount = busCountRow ? Number(busCountRow.count) : 0;
        if (busCount === 0) {
            for (const [busNumber, assignedHostel, driverName, phone, latitude, longitude, status, fromHostelTime, fromMBSETime, specialNote = ''] of busesSeed) {
                await q(
                    'INSERT INTO buses (bus_number, assigned_hostel, status, latitude, longitude, speed, is_enabled, route) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
                    [busNumber, assignedHostel, status, latitude, longitude, status === 'running' ? 25 : 0, true, 'Hostel ↔ MBSE']
                );
                await q('INSERT INTO drivers (id, bus_number, name, phone, is_active) VALUES ($1, $2, $3, $4, $5)', [
                    `drv${busNumber}`,
                    busNumber,
                    driverName,
                    phone,
                    true,
                ]);
                await q(
                    'INSERT INTO schedules (id, bus_number, date, from_hostel_time, from_mbse_time, special_note, updated_by) VALUES ($1, $2, $3, $4, $5, $6, $7)',
                    [`sch${busNumber}`, busNumber, today(), fromHostelTime, fromMBSETime, specialNote, 'seed']
                );
            }
        }

        const [notifCountRow] = await q('SELECT COUNT(*) AS count FROM notifications');
        const notifCount = notifCountRow ? Number(notifCountRow.count) : 0;
        if (notifCount === 0) {
            for (const [id, title, message, type, busNumber, targetHostel, isRead] of notificationsSeed) {
                await q(
                    'INSERT INTO notifications (id, title, message, type, bus_number, target_hostel, is_read, sent_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
                    [id, title, message, type, busNumber, targetHostel, !!isRead, 'seed']
                );
            }
        }
    }

}

app.get('/', (_req, res) => {
    res.json({ status: 'ok', message: 'Campus Bus Tracker API running (PostgreSQL)' });
});

app.get('/api', (_req, res) => {
    res.json({ status: 'ok', message: 'Campus Bus Tracker API running' });
});

app.get('/api/health', async (_req, res) => {
    try {
        if (!await checkDatabaseConnection()) {
            return res.status(503).json({ status: 'error', message: 'Database unavailable' });
        }
        const serverTimeZone = Intl.DateTimeFormat().resolvedOptions().timeZone || 'unknown';
        const serverTimeUtc = new Date().toISOString();
        const [[hostels], [buses], [notifications], [databaseIdentity]] = await Promise.all([
            q('SELECT COUNT(*) AS count FROM hostels'),
            q('SELECT COUNT(*) AS count FROM buses'),
            q('SELECT COUNT(*) AS count FROM notifications'),
            q(`SELECT current_database() AS database, current_schema() AS schema,
                inet_server_addr()::text AS address, inet_server_port() AS port`),
        ]);
        res.json({
            status: 'ok',
            hostels: hostels.count,
            buses: buses.count,
            notifications: notifications.count,
            serverTimeZone,
            serverTimeUtc,
            campusDate: today(),
            databaseFingerprint: fingerprintDatabaseIdentity(databaseIdentity),
            deployedCommit: process.env.RENDER_GIT_COMMIT?.slice(0, 12) || null,
        });
    } catch (error) {
        console.error(`Health database query failed (${safeDatabaseErrorCode(error)})`);
        res.status(503).json({ status: 'error', message: 'Database unavailable' });
    }
});

app.get('/api/dev/delivery-outbox', (req, res) => {
    const remoteAddress = String(req.socket.remoteAddress || req.ip || '')
        .replace(/^::ffff:/, '');
    const isLoopback = remoteAddress === '::1' || remoteAddress.startsWith('127.');
    if (!localMockDeliveryEnabled() || !isLoopback) {
        return res.status(404).json({ error: 'Not found' });
    }
    return res.json({ messages: takeLocalMessages() });
});

app.get('/api/hostels', async (_req, res) => {
    try {
        const allowedHostels = hostelsSeed.map((hostel) => hostel.id);
        const rows = await q('SELECT id, name, type, full_name AS fullName FROM hostels WHERE id = ANY(?::varchar[]) ORDER BY id', [allowedHostels]);
        res.json({ status: 'success', data: rows });
    } catch (error) {
        internalError(res, error, 'hostels query');
    }
});

app.use('/api/auth/registration-mobile', createRegistrationMobileRouter({
    store: passwordRecoveryStore,
    smsConfigured: () => Boolean(smsProvider(process.env)),
    sendSms,
    otpSecret: () => process.env.PASSWORD_RESET_OTP_SECRET || API_SECRET_KEY,
}));

app.post('/api/auth/register', registrationRateLimiter, async (req, res) => {
    const { name, email, mobile, password, confirmPassword, hostelId, mobileVerificationToken } = req.body || {};
    const normalizedName = String(name || '').trim();
    const normalizedEmail = String(email || '').trim().toLowerCase();
    const normalizedMobile = normalizeMobile(mobile);
    const selectedHostel = String(hostelId || '').trim().toUpperCase();
    const verificationToken = String(mobileVerificationToken || '');
    const clearPassword = String(password || '');
    const clearConfirmation = String(confirmPassword || '');

    if (!normalizedName || normalizedName.length > 100 ||
        !COLLEGE_STUDENT_EMAIL.test(normalizedEmail) || !normalizedMobile ||
        clearPassword.length < 9 || clearPassword.length > 128 || clearPassword !== clearConfirmation ||
        !/^[a-f0-9]{64}$/i.test(verificationToken)) {
        return res.status(400).json({ error: 'Complete all fields and verify your mobile number.' });
    }
    if (!hostelsSeed.some((hostel) => hostel.id === selectedHostel)) {
        return res.status(400).json({ error: 'Select a valid hostel.' });
    }

    let client;
    try {
        const passwordHash = await bcrypt.hash(clearPassword, 12);
        client = await pool.connect();
        await client.query('BEGIN');
        const existing = await client.query(
            'SELECT id FROM users WHERE LOWER(email) = LOWER($1) LIMIT 1 FOR UPDATE',
            [normalizedEmail],
        );
        if (existing.rows.length) {
            await client.query('ROLLBACK');
            return res.status(409).json({ error: 'This email is already registered — log in instead.' });
        }
        const consumed = await passwordRecoveryStore.consumeRegistrationMobileVerification(
            client,
            normalizedEmail,
            normalizedMobile,
            digest(verificationToken),
        );
        if (!consumed) {
            await client.query('ROLLBACK');
            return res.status(400).json({ error: 'Mobile verification expired. Verify your number again.' });
        }

        const user = {
            id: uid('usr_'),
            name: normalizedName,
            email: normalizedEmail,
            role: 'student',
            hostel_id: selectedHostel,
            must_change_password: false,
        };
        await client.query(
            `INSERT INTO users
                (id, name, email, password, role, hostel_id, recovery_phone, recovery_phone_verified_at, must_change_password)
             VALUES ($1, $2, $3, $4, 'student', $5, $6, NOW(), false)`,
            [user.id, user.name, user.email, passwordHash, user.hostel_id, normalizedMobile],
        );
        await client.query('COMMIT');
        const token = await createToken(user);
        return res.status(201).json({ token, user: publicUser(user) });
    } catch (error) {
        if (client) await client.query('ROLLBACK').catch(() => {});
        if (error.code === '23505') {
            return res.status(409).json({ error: 'This email or verified mobile is already registered.' });
        }
        console.error(`Student registration failed (${typeof error.code === 'string' ? error.code : 'database_error'}).`);
        return internalError(res, error, 'student registration');
    } finally {
        client?.release();
    }
});

app.post('/api/auth/logout', async (req, res) => {
    const auth = requireAuth(req, res); if (!auth) return;
    await sessionStore.revoke(auth.token);
    return res.json({ status: 'success' });
});

app.get('/api/buses/live', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin', 'driver']);
    if (!auth) return;

    try {
        if (auth.role === 'caretaker' && !auth.hostelId) return res.status(403).json({ error: 'Caretaker account has no assigned hostel' });
        // Student browsing is intentionally cross-hostel for missed-bus fallback.
        // Caretakers remain scoped to their assigned hostel.
        const hostel = auth.role === 'caretaker'
            ? auth.hostelId
            : (auth.role === 'driver' ? null : (req.query.hostel || null));
        if (auth.role === 'driver' && !Number.isInteger(Number(auth.busNumber))) {
            return res.status(403).json({ error: 'Driver account has no assigned bus' });
        }
        const where = auth.role === 'driver'
            ? 'WHERE b.bus_number = ?'
            : (hostel ? 'WHERE b.assigned_hostel = ?' : '');
        const params = auth.role === 'driver' ? [Number(auth.busNumber)] : (hostel ? [hostel] : []);
        const rows = await q(
            `
            SELECT
                b.bus_number,
                b.assigned_hostel,
                b.status,
                b.latitude,
                b.longitude,
                b.speed,
                b.route,
                t.lat,
                t.lng,
                t.accuracy,
                t.hdop,
                t.has_fix,
                t.satellites,
                t.net_type,
                t.status AS telemetry_status,
                t.received_at
            FROM buses b
            LEFT JOIN LATERAL (
                SELECT bus_id, lat, lng, accuracy, has_fix, satellites, hdop, net_type, status, received_at
                FROM telemetry
                WHERE regexp_replace(bus_id, '[^0-9]', '', 'g') = b.bus_number::text
                ORDER BY received_at DESC, id DESC
                LIMIT 1
            ) t ON true
            ${where}
            ORDER BY b.bus_number
            `,
            params
        );

        return res.json({
            status: 'success',
            data: rows.map((row) => ({
                ...mapLiveBus(row),
                status: row.telemetry_status || row.status,
            })),
        });
    } catch (error) {
        return internalError(res, error, 'live buses query');
    }
});

app.get('/api/buses/stream', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin', 'driver']);
    if (!auth) return;

    try {
        if (auth.role === 'caretaker' && !auth.hostelId) return res.status(403).json({ error: 'Caretaker account has no assigned hostel' });
        // Students can browse buses across hostels; caretakers remain scoped.
        const hostel = auth.role === 'caretaker' ? auth.hostelId : null;
        const driverBusNumber = auth.role === 'driver' ? Number(auth.busNumber) : null;
        if (auth.role === 'driver' && !Number.isInteger(driverBusNumber)) {
            return res.status(403).json({ error: 'Driver account has no assigned bus' });
        }
        const rows = await q(`
            SELECT b.bus_number, b.assigned_hostel, b.status, b.latitude, b.longitude, b.speed, b.route,
                   t.lat, t.lng, t.heading, t.has_fix, t.satellites, t.hdop, t.net_type, t.status AS telemetry_status, t.received_at
            FROM buses b
            LEFT JOIN LATERAL (
                SELECT bus_id, lat, lng, heading, has_fix, satellites, hdop, net_type, status, received_at
                FROM telemetry
                WHERE regexp_replace(bus_id, '[^0-9]', '', 'g') = b.bus_number::text
                ORDER BY received_at DESC, id DESC
                LIMIT 1
            ) t ON true
                        WHERE b.is_enabled = true
                            AND ($1::text IS NULL OR LOWER(b.assigned_hostel) = LOWER($1))
                            AND ($2::int IS NULL OR b.bus_number = $2)
            ORDER BY b.bus_number
                `, [hostel || null, driverBusNumber]);

        const initialData = rows.map((row) => {
            const item = {
                bus_number: row.bus_number,
                busNumber: row.bus_number,
                status: row.telemetry_status || row.status,
                lat: row.lat == null ? Number(row.latitude) : Number(row.lat),
                lng: row.lng == null ? Number(row.longitude) : Number(row.lng),
                latitude: row.lat == null ? Number(row.latitude) : Number(row.lat),
                longitude: row.lng == null ? Number(row.longitude) : Number(row.lng),
                heading: Number(row.heading || 0),
                speed: Number(row.speed || 0),
                route: row.route,
                hostel: row.assigned_hostel,
                assigned_hostel: row.assigned_hostel,
                hasFix: row.has_fix ?? (row.lat != null && row.lng != null),
                lastUpdated: row.received_at || null,
                timestamp: row.received_at || null,
            };
            if (auth.role !== 'student') {
                item.satellites = row.satellites ?? 0;
                item.hdop = Number(row.hdop ?? row.accuracy ?? 99.9);
                item.netType = row.net_type || 'unknown';
            }
            return item;
        });

        res.status(200);
        res.setHeader('Content-Type', 'text/event-stream');
        res.setHeader('Cache-Control', 'no-cache, no-transform');
        res.setHeader('Connection', 'keep-alive');
        res.flushHeaders?.();
        res.write(`data: ${JSON.stringify(initialData)}\n\n`);
        console.info('Telemetry stream connected', { role: auth.role, hostel: hostel || 'all', initialBusCount: initialData.length });

        const onUpdate = (data) => {
            if (auth.role === 'caretaker' && (!auth.hostelId || auth.hostelId.toUpperCase() !== String(data.assigned_hostel || '').toUpperCase())) return;
            if (auth.role === 'driver' && Number(auth.busNumber) !== Number(data.busNumber || data.bus_number)) return;
            const eventData = { ...data };
            if (auth.role === 'student') {
                delete eventData.satellites;
                delete eventData.hdop;
                delete eventData.net_type;
                delete eventData.netType;
            }
            if (res.writable) {
                res.write(`data: ${JSON.stringify([eventData])}\n\n`);
                console.info('Telemetry stream event delivered', { busNumber: data.busNumber || data.bus_number, role: auth.role });
            }
        };
        const heartbeat = setInterval(() => {
            if (res.writable) res.write(': keep-alive\n\n');
        }, 25000);
        const sessionCheck = setInterval(async () => {
            try {
                const currentSession = await sessionStore.findByToken(auth.token);
                if (!currentSession || currentSession.userId !== auth.userId) res.end();
            } catch (error) {
                console.error(`Stream session check failed (${safeDatabaseErrorCode(error)})`);
                res.end();
            }
        }, 30000);
        telemetryEmitter.on('live_update', onUpdate);
        req.on('close', () => {
            clearInterval(heartbeat);
            clearInterval(sessionCheck);
            telemetryEmitter.removeListener('live_update', onUpdate);
            console.info('Telemetry stream closed', { role: auth.role });
        });
    } catch (error) {
        return internalError(res, error, 'bus stream');
    }
});

app.get('/api/telemetry/diagnostics', async (req, res) => {
    const auth = requireAuth(req, res, ['caretaker', 'admin']);
    if (!auth) return;
    try {
        const limit = Math.min(Math.max(Number.parseInt(req.query.limit, 10) || 50, 1), 200);
        const values = [];
        let filter = '';
        if (req.query.bus_id) {
            const busNumber = String(req.query.bus_id).replace(/[^0-9]/g, '');
            if (!busNumber) return res.status(400).json({ error: 'bus_id must include a bus number' });
            values.push(busNumber);
            filter += ` AND regexp_replace(t.bus_id, '[^0-9]', '', 'g') = $${values.length}`;
        }
        if (auth.role === 'caretaker') {
            values.push(auth.hostelId || '');
            filter += ` AND b.assigned_hostel = $${values.length}`;
        }
        values.push(limit);
        const rows = await pool.query(`
            SELECT t.id, t.device_id, t.bus_id, t.lat, t.lng, t.speed, t.accuracy, t.has_fix,
                   t.satellites, t.hdop, t.net_type, t.ts, t.status, t.received_at
            FROM telemetry t
            LEFT JOIN buses b ON regexp_replace(t.bus_id, '[^0-9]', '', 'g') = b.bus_number::text
            WHERE true ${filter}
            ORDER BY t.received_at DESC, t.id DESC
            LIMIT $${values.length}
        `, values);
        const data = rows.rows.map((row) => ({
            id: row.id,
            deviceId: row.device_id,
            busId: row.bus_id,
            lat: Number(row.lat),
            lng: Number(row.lng),
            speed: Number(row.speed || 0),
            accuracy: Number(row.accuracy || 1),
            hasFix: row.has_fix ?? false,
            satellites: row.satellites ?? 0,
            hdop: Number(row.hdop ?? 99.9),
            netType: row.net_type || 'unknown',
            timestamp: row.ts,
            status: row.status,
            receivedAt: row.received_at,
        }));
        const average = (list, key) => list.length ? Math.round(list.reduce((sum, item) => sum + item[key], 0) / list.length * 10) / 10 : 0;
        return res.json({
            status: 'success',
            summary: {
                totalPackets: data.length,
                fixRate: data.length ? `${Math.round(data.filter((item) => item.hasFix).length / data.length * 100)}%` : '0%',
                avgSatellites: average(data, 'satellites'),
                avgHdop: data.length ? average(data, 'hdop') : 99.9,
                latestPacket: data[0] || null,
            },
            data,
        });
    } catch (error) {
        return internalError(res, error, 'telemetry diagnostics');
    }
});

app.get('/api/telemetry/history', async (req, res) => {
    const auth = requireAuth(req, res, ['caretaker', 'admin']);
    if (!auth) return;
    const busId = String(req.query.bus_id || '').replace(/[^0-9]/g, '');
    if (!busId) return res.status(400).json({ error: 'bus_id must include a bus number' });
    const end = req.query.end_time ? new Date(String(req.query.end_time)) : new Date();
    const start = req.query.start_time ? new Date(String(req.query.start_time)) : new Date(end.getTime() - 24 * 60 * 60 * 1000);
    if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime()) || start > end) {
        return res.status(400).json({ error: 'Invalid start_time or end_time' });
    }
    try {
        const values = [busId, start.toISOString(), end.toISOString()];
        let hostelFilter = '';
        if (auth.role === 'caretaker') {
            values.push(auth.hostelId || '');
            hostelFilter = ` AND b.assigned_hostel = $${values.length}`;
        }
        const rows = await pool.query(`
            SELECT t.id, t.bus_id AS "busId", t.lat, t.lng, t.speed, t.ts, t.status, t.received_at AS "receivedAt"
            FROM telemetry t
            LEFT JOIN buses b ON regexp_replace(t.bus_id, '[^0-9]', '', 'g') = b.bus_number::text
            WHERE regexp_replace(t.bus_id, '[^0-9]', '', 'g') = $1 AND t.received_at >= $2 AND t.received_at <= $3 ${hostelFilter}
            ORDER BY t.received_at ASC, t.id ASC
        `, values);
        return res.json({ status: 'success', data: rows.rows.map((row) => ({
            ...row,
            lat: Number(row.lat),
            lng: Number(row.lng),
            speed: Number(row.speed || 0),
        })) });
    } catch (error) {
        return internalError(res, error, 'telemetry history');
    }
});

app.get('/reset-password', (_req, res) => {
    res.set({
        'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'",
        'Referrer-Policy': 'no-referrer',
        'Cache-Control': 'no-store',
    });
    return res.type('html').send(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Reset password</title>
  <style>
    body { font: 16px system-ui, sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #eef3f8; color: #18212b; }
    main { width: min(420px, calc(100% - 40px)); padding: 28px; background: white; border: 1px solid #d5dde6; border-radius: 12px; box-sizing: border-box; }
    h1 { margin-top: 0; font-size: 24px; }
    label { display: block; margin: 16px 0 6px; }
    input, button { width: 100%; box-sizing: border-box; padding: 12px; font: inherit; }
    input { border: 1px solid #8a98a8; border-radius: 6px; }
    button { margin-top: 20px; color: white; background: #1769aa; border: 0; border-radius: 6px; cursor: pointer; }
    #message { min-height: 24px; }
  </style>
</head>
<body>
  <main>
    <h1>Choose a new password</h1>
    <form id="reset-form">
      <label for="password">New password</label>
      <input id="password" type="password" minlength="9" maxlength="128" autocomplete="new-password" required>
      <label for="confirm">Confirm new password</label>
      <input id="confirm" type="password" minlength="9" maxlength="128" autocomplete="new-password" required>
      <button type="submit">Update password</button>
    </form>
    <p id="message" role="status"></p>
    <a id="back-to-login" href="smartbus://login" hidden>Back to Login</a>
  </main>
  <script>
    const tokenMatch = location.hash.match(/^#token=([a-f0-9]{64})$/i);
    const token = tokenMatch ? tokenMatch[1] : '';
    history.replaceState(null, '', location.pathname + location.search);
    const form = document.getElementById('reset-form');
    const message = document.getElementById('message');
    if (!token) {
      form.hidden = true;
      message.textContent = 'This password reset link is invalid or incomplete.';
    }
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const password = document.getElementById('password').value;
      const confirmation = document.getElementById('confirm').value;
      if (password !== confirmation) {
        message.textContent = 'The passwords do not match.';
        return;
      }
      message.textContent = 'Updating password...';
      try {
        const response = await fetch('/api/auth/reset-password', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ token, newPassword: password })
        });
        const result = await response.json();
                message.textContent = result.message || result.error || 'Could not reset password.';
                if (response.ok) {
                    form.hidden = true;
                    document.getElementById('back-to-login').hidden = false;
                }
      } catch (_) {
        message.textContent = 'Could not reach the server. Try again.';
      }
    });
  </script>
</body>
</html>`);
});

app.use('/api/auth', createPasswordRecoveryRouter({
    store: passwordRecoveryStore,
    sessionStore,
    emailConfigurationIssue: () => mailConfigurationIssue(process.env),
    emailConfigured: () => Boolean(mailProvider(process.env)),
    sendMail,
    smsConfigured: () => Boolean(smsProvider(process.env)),
    sendSms,
    otpSecret: () => process.env.PASSWORD_RESET_OTP_SECRET || API_SECRET_KEY,
    // Local development fallback only; production should set PUBLIC_BASE_URL.
    baseUrl: () => process.env.PUBLIC_BASE_URL || process.env.RENDER_EXTERNAL_URL || `http://localhost:${port}`,
    production: process.env.NODE_ENV === 'production',
}));

const emailPasswordRecoveryRouter = createEmailPasswordRecoveryRouter({
    getPool: () => pool,
    env: process.env,
    sendMail,
    emailConfigured: () => Boolean(mailProvider(process.env)),
});
app.use('/api/auth', emailPasswordRecoveryRouter);
// Compatibility for older app builds still posting to the original root URL.
app.post('/request', (req, res, next) => {
    req.url = '/password-recovery/request';
    emailPasswordRecoveryRouter(req, res, next);
});

app.post('/api/auth/change-password', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin']);
    if (!auth) return;
    const currentPassword = String(req.body?.currentPassword || '');
    const newPassword = String(req.body?.newPassword || '');
    if (!currentPassword) {
        return res.status(400).json({ error: 'Enter your current password' });
    }
    if (newPassword.length < 9 || newPassword.length > 128) {
        return res.status(400).json({ error: 'Choose a password between 9 and 128 characters' });
    }
    try {
        const users = await q('SELECT password FROM users WHERE id = ? LIMIT 1', [auth.userId]);
        if (!users.length || !await bcrypt.compare(currentPassword, users[0].password)) {
            return res.status(401).json({ error: 'Current password is incorrect' });
        }
        const passwordHash = await bcrypt.hash(newPassword, 12);
        await q('UPDATE users SET password = ?, must_change_password = false WHERE id = ?', [passwordHash, auth.userId]);
        await sessionStore.updateMustChangePassword(auth.token, false);
        await sessionStore.revokeOtherUserSessions(auth.userId, auth.token);
        return res.json({ status: 'success', message: 'Password updated' });
    } catch (error) {
        return internalError(res, error, 'change password');
    }
});

app.post(
    '/api/auth/login',
    createLoginRateLimiter(),
    createLoginHandler({
        findUserByEmail: createUserLookup(q),
        hostels: hostelsSeed,
        createToken,
        publicUser,
    }),
);

 app.post('/api/auth/driver-login', async (req, res) => {
    const phone = String(req.body?.phone || '').replace(/\D/g, '').slice(-10);
    const pin = String(req.body?.pin || '');
    if (!/^[6-9]\d{9}$/.test(phone) || !/^\d{6}$/.test(pin)) {
        return res.status(400).json({ error: 'Enter a valid mobile number and 6-digit PIN' });
    }
    const ip = req.ip || req.socket?.remoteAddress || 'unknown';
    const attemptHashes = [
        hashLoginIdentifier('driver-phone', phone),
        hashLoginIdentifier('client-ip', ip),
    ];

    try {
        const blockedUntil = await loginAttemptStore.getBlockedUntil(attemptHashes);
        if (blockedUntil && new Date(blockedUntil).getTime() > Date.now()) {
            return res.status(429).json({ error: 'Too many attempts. Try again shortly.' });
        }
        const rows = await q(`
            SELECT d.id, d.name, d.phone, d.bus_number, d.pin_hash, d.is_active, b.is_enabled
            FROM drivers d JOIN buses b ON b.bus_number = d.bus_number
            WHERE RIGHT(regexp_replace(d.phone, '[^0-9]', '', 'g'), 10) = $1
            ORDER BY d.bus_number LIMIT 1
        `, [phone]);
        const driver = rows[0];
        const pinMatches = await compareDriverPin(pin, driver?.pin_hash);
        if (!driver || !driver.is_active || !driver.is_enabled || !pinMatches) {
            await loginAttemptStore.recordFailure(attemptHashes);
            return res.status(401).json({ error: 'Invalid phone or PIN' });
        }
        await loginAttemptStore.clear(attemptHashes);
        const user = { id: driver.id, name: driver.name || 'Driver', phone: driver.phone, bus_number: driver.bus_number, role: 'driver' };
        const token = await createToken(user);
        return res.json({ token, user: { id: user.id, name: user.name, phone: user.phone, busNumber: user.bus_number, role: 'driver' } });
    } catch (error) {
        return internalError(res, error, 'driver login');
    }
});

app.get('/api/auth/driver/me', async (req, res) => {
    const auth = requireAuth(req, res, ['driver']);
    if (!auth) return;
    try {
        const rows = await q(`SELECT d.id, d.name, d.phone, d.bus_number, d.is_active, b.is_enabled
            FROM drivers d JOIN buses b ON b.bus_number = d.bus_number WHERE d.id = ? LIMIT 1`, [auth.userId]);
        if (!rows.length || !rows[0].is_active || !rows[0].is_enabled) {
            await sessionStore.revoke(auth.token);
            return res.status(401).json({ error: 'Driver access has been disabled' });
        }
        const driver = rows[0];
        return res.json({ user: { id: driver.id, name: driver.name || 'Driver', phone: driver.phone, busNumber: driver.bus_number, role: 'driver' } });
    } catch (error) {
        return internalError(res, error, 'driver session lookup');
    }
});

app.get('/api/me', async (req, res) => {
    const auth = requireAuth(req, res);
    if (!auth) return;

    try {
        const rows = await q('SELECT id, name, email, role, hostel_id, must_change_password FROM users WHERE id = ? LIMIT 1', [auth.userId]);
        if (rows.length === 0) return res.status(404).json({ error: 'User not found' });
        return res.json({ status: 'success', user: publicUser(rows[0]) });
    } catch (error) {
        return internalError(res, error, 'current user lookup');
    }
});

app.get('/api/buses', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin', 'driver']);
    if (!auth) return;

    try {
        if (auth.role === 'caretaker' && !auth.hostelId) return res.status(403).json({ error: 'Caretaker account has no assigned hostel' });
        const targetHostel = auth.role === 'caretaker' ? auth.hostelId : (req.query.hostel || null);
        const isDriver = auth.role === 'driver';
        if (isDriver && !Number.isInteger(Number(auth.busNumber))) {
            return res.status(403).json({ error: 'Driver account has no assigned bus' });
        }
        const where = isDriver ? 'WHERE b.bus_number = ?' : (targetHostel ? 'WHERE b.assigned_hostel = ?' : '');
        const params = isDriver ? [Number(auth.busNumber)] : (targetHostel ? [targetHostel] : []);
        const rows = await q(`${BUS_SELECT} ${where} ORDER BY b.bus_number`, params);
        return res.json(rows.map((row) => mapBus(row, auth.role)));
    } catch (error) {
        return internalError(res, error, 'buses query');
    }
});

app.get('/api/all-buses', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin', 'driver']);
    if (!auth) return;

    try {
        if (auth.role === 'caretaker' && !auth.hostelId) return res.status(403).json({ error: 'Caretaker account has no assigned hostel' });
        const hostel = auth.role === 'caretaker' ? auth.hostelId : (req.query.hostel || null);
        const isDriver = auth.role === 'driver';
        if (isDriver && !Number.isInteger(Number(auth.busNumber))) {
            return res.status(403).json({ error: 'Driver account has no assigned bus' });
        }
        const where = isDriver ? 'WHERE b.bus_number = ?' : (hostel ? 'WHERE b.assigned_hostel = ?' : '');
        const params = isDriver ? [Number(auth.busNumber)] : (hostel ? [hostel] : []);
        const rows = await q(`${BUS_SELECT} ${where} ORDER BY b.bus_number`, params);
        return res.json({ status: 'success', data: rows.map((row) => mapBus(row, auth.role)) });
    } catch (error) {
        return internalError(res, error, 'all buses query');
    }
});

app.get('/api/today-buses', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin', 'driver']);
    if (!auth) return;
    const date = String(req.query.date || today());
    if (!isDateOnly(date)) {
        return res.status(400).json({ error: 'date must use YYYY-MM-DD format' });
    }
    try {
        const values = [date];
        let accessFilter = '';
        if (auth.role === 'caretaker') {
            if (!auth.hostelId) return res.status(403).json({ error: 'Caretaker account has no assigned hostel' });
            values.push(auth.hostelId);
            accessFilter = ` AND b.assigned_hostel = $${values.length}`;
        } else if (auth.role === 'driver') {
            if (!Number.isInteger(Number(auth.busNumber))) return res.status(403).json({ error: 'Driver account has no assigned bus' });
            values.push(Number(auth.busNumber));
            accessFilter = ` AND b.bus_number = $${values.length}`;
        }
        const rows = await q(`${BUS_SELECT}
            WHERE b.is_enabled = true
              AND b.bus_number IN (SELECT bus_number FROM schedules WHERE date = $1)
              ${accessFilter}
            ORDER BY b.assigned_hostel, b.bus_number`, values);
        let scheduleScope = '';
        const scheduleValues = [date];
        if (auth.role === 'driver') {
            scheduleValues.push(Number(auth.busNumber));
            scheduleScope = ` AND bus_number = $${scheduleValues.length}`;
        }
        const schedules = await q(`SELECT id AS schedule_id, bus_number, date AS schedule_date,
                from_hostel_time, from_mbse_time, special_note, updated_by
            FROM schedules WHERE date = $1${scheduleScope}`, scheduleValues);
        const scheduleByBus = new Map(schedules.map((schedule) => [Number(schedule.bus_number), schedule]));
        const data = rows.map((row) => ({
            ...row,
            ...(scheduleByBus.get(Number(row.bus_number)) || {}),
        }));
        return res.json(data.map((row) => mapBus(row, auth.role)));
    } catch (error) {
        return internalError(res, error, 'today buses query');
    }
});

app.get('/api/buses/:busNumber', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin']);
    if (!auth) return;

    try {
        const bus = await fetchBusByNumber(req.params.busNumber, auth.role);
        if (!bus) return res.status(404).json({ error: 'Bus not found' });
        if (auth.role === 'caretaker' && (!auth.hostelId || auth.hostelId !== bus.assignedHostel)) {
            return res.status(403).json({ error: 'Caretaker can only view own hostel buses' });
        }
        return res.json(bus);
    } catch (error) {
        return internalError(res, error, 'bus lookup');
    }
});

app.post('/api/buses', async (req, res) => {
    const auth = requireAuth(req, res, ['caretaker', 'admin']);
    if (!auth) return;

    try {
        const { busNumber, name, sourcePlace, destinationPlace, assignedHostel, driverName, driverPhone, pin, latitude, longitude, route } = req.body || {};
        const normalizedBusNumber = positiveSafeInteger(busNumber);
        const normalizedDriverName = boundedString(driverName, 120, { required: true });
        const rawDriverPhone = boundedString(driverPhone, 30, { required: true });
        const normalizedName = boundedString(name, 80, { fallback: `Bus ${normalizedBusNumber || ''}` });
        const normalizedSourcePlace = boundedString(sourcePlace, 120, { fallback: auth.hostelId || 'BH1' });
        const normalizedDestinationPlace = boundedString(destinationPlace, 120, { fallback: 'MBSE' });
        const normalizedRoute = boundedString(route, 120, { fallback: 'Hostel ↔ MBSE' });
        const normalizedLatitude = finiteNumberInRange(latitude, -90, 90, 23.7271);
        const normalizedLongitude = finiteNumberInRange(longitude, -180, 180, 92.7176);
        if (!normalizedBusNumber || !normalizedDriverName || !rawDriverPhone || typeof pin !== 'string' || !/^\d{6}$/.test(pin) ||
            !normalizedName || !normalizedSourcePlace || !normalizedDestinationPlace || !normalizedRoute ||
            normalizedLatitude === null || normalizedLongitude === null) {
            return res.status(400).json({ error: 'busNumber, driverName, driverPhone, and a 6-digit PIN are required' });
        }
        const normalizedPhone = rawDriverPhone.replace(/\D/g, '').slice(-10);
        if (!/^[6-9]\d{9}$/.test(normalizedPhone)) return res.status(400).json({ error: 'Enter a valid 10-digit Indian mobile number' });
        const duplicatePhone = await q("SELECT bus_number FROM drivers WHERE regexp_replace(phone, '[^0-9]', '', 'g') LIKE ? LIMIT 1", [`%${normalizedPhone}`]);
        if (duplicatePhone.length) return res.status(409).json({ error: 'This mobile number is already assigned to another bus' });

        const existing = await q('SELECT bus_number FROM buses WHERE bus_number = ? LIMIT 1', [normalizedBusNumber]);
        if (existing.length) {
            return res.status(409).json({ error: 'Bus number already exists' });
        }

        const targetHostel = String(auth.role === 'caretaker' ? auth.hostelId : (assignedHostel || auth.hostelId || 'BH1')).trim().toUpperCase();
        if (!hostelsSeed.some((hostel) => hostel.id === targetHostel)) {
            return res.status(400).json({ error: 'assignedHostel must name a valid hostel' });
        }

        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            await client.query(
            'INSERT INTO buses (bus_number, bus_name, assigned_hostel, source_place, destination_place, status, latitude, longitude, speed, is_enabled, route) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, true, $10)',
            [
                normalizedBusNumber,
                normalizedName,
                targetHostel,
                normalizedSourcePlace,
                normalizedDestinationPlace,
                'idle',
                normalizedLatitude,
                normalizedLongitude,
                0,
                normalizedRoute,
            ]
        );

            await client.query('INSERT INTO drivers (id,bus_number,name,phone,pin_hash,is_active) VALUES ($1,$2,$3,$4,$5,true)', [
                uid('drv_'), normalizedBusNumber, normalizedDriverName, normalizedPhone, await bcrypt.hash(pin, 10),
            ]);
            await client.query('COMMIT');
        } catch (error) {
            await client.query('ROLLBACK').catch(() => {});
            if (error.code === '23505') return res.status(409).json({ error: 'Bus number already exists' });
            throw error;
        } finally {
            client.release();
        }

        const created = await fetchBusByNumber(normalizedBusNumber, auth.role);
        return res.status(201).json({ status: 'success', data: created });
    } catch (error) {
        return internalError(res, error, 'create bus');
    }
});

app.patch('/api/buses/:busNumber/driver', async (req, res) => {
    const auth = requireAuth(req, res, ['caretaker', 'admin']);
    if (!auth) return;

    try {
        const busNumber = positiveSafeInteger(req.params.busNumber);
        if (!busNumber) return res.status(400).json({ error: 'busNumber must be a positive integer' });
        const access = await assertCaretakerAccess(busNumber, auth);
        if (!access.ok) {
            return res.status(access.code).json({ error: access.message });
        }

        const { driverName, driverPhone, pin } = req.body || {};
        const normalizedDriverName = boundedString(driverName, 120, { required: true });
        const rawDriverPhone = boundedString(driverPhone, 30, { required: true });
        if (!normalizedDriverName || !rawDriverPhone) {
            return res.status(400).json({ error: 'driverName and driverPhone are required' });
        }

        const normalizedPhone = rawDriverPhone.replace(/\D/g, '').slice(-10);
        if (!/^[6-9]\d{9}$/.test(normalizedPhone)) return res.status(400).json({ error: 'Enter a valid 10-digit Indian mobile number' });
        if (pin !== undefined && pin !== '' && (typeof pin !== 'string' || !/^\d{6}$/.test(pin))) return res.status(400).json({ error: 'PIN must contain exactly 6 digits' });
        const duplicate = await q("SELECT bus_number FROM drivers WHERE regexp_replace(phone, '[^0-9]', '', 'g') LIKE ? AND bus_number <> ? LIMIT 1", [`%${normalizedPhone}`, busNumber]);
        if (duplicate.length) return res.status(409).json({ error: 'This mobile number is already assigned to another bus' });

        const currentDriver = await q('SELECT id FROM drivers WHERE bus_number=? LIMIT 1', [busNumber]);
        if (!currentDriver.length && !pin) {
            return res.status(400).json({ error: 'A 6-digit PIN is required when adding a driver' });
        }
        const pinHash = pin ? await bcrypt.hash(String(pin), 10) : null;
        if (currentDriver.length) {
            if (pinHash) {
                await q('UPDATE drivers SET name=?, phone=?, pin_hash=?, is_active=true WHERE bus_number=?', [normalizedDriverName, normalizedPhone, pinHash, busNumber]);
            } else {
                await q('UPDATE drivers SET name=?, phone=?, is_active=true WHERE bus_number=?', [normalizedDriverName, normalizedPhone, busNumber]);
            }
        } else {
            await q('INSERT INTO drivers (id,bus_number,name,phone,pin_hash,is_active) VALUES (?,?,?,?,?,true)', [
                uid('drv_'), busNumber, normalizedDriverName, normalizedPhone, pinHash,
            ]);
        }

        const updatedBus = await fetchBusByNumber(busNumber, auth.role);
        return res.json({ status: 'success', data: updatedBus });
    } catch (error) {
        return internalError(res, error, 'update bus driver');
    }
});

app.get('/api/schedules', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin', 'driver']);
    if (!auth) return;

    try {
        if (auth.role === 'caretaker' && !auth.hostelId) return res.status(403).json({ error: 'Caretaker account has no assigned hostel' });
        const hostel = auth.role === 'caretaker' ? auth.hostelId : (req.query.hostel || null);
        const driverBusNumber = auth.role === 'driver' ? Number(auth.busNumber) : null;
        if (auth.role === 'driver' && !Number.isInteger(driverBusNumber)) {
            return res.status(403).json({ error: 'Driver account has no assigned bus' });
        }
        const date = req.query.date || null;
        if (date !== null && !isDateOnly(String(date))) {
            return res.status(400).json({ error: 'date must be a valid YYYY-MM-DD campus date' });
        }

        const rows = await q(
            `
            SELECT
                s.id AS _id,
                s.bus_number AS busNumber,
                to_char(s.date, 'YYYY-MM-DD') AS date,
                s.from_hostel_time AS fromHostelTime,
                s.from_mbse_time AS fromMBSETime,
                COALESCE(s.special_note, '') AS specialNote,
                COALESCE(s.updated_by, '') AS updatedBy
            FROM schedules s
            JOIN buses b ON b.bus_number = s.bus_number
            WHERE ($1::varchar IS NULL OR b.assigned_hostel = $1::varchar)
                AND ($2::date IS NULL OR s.date = $2::date)
                AND ($3::int IS NULL OR b.bus_number = $3)
            ORDER BY s.bus_number
      `,
                    [hostel, date, driverBusNumber]
        );

        return res.json(rows);
    } catch (error) {
        return internalError(res, error, 'schedules query');
    }
});

app.post('/api/schedules', async (req, res) => {
    const auth = requireAuth(req, res, ['caretaker', 'admin']);
    if (!auth) return;

    try {
        const { busNumber } = req.body || {};
        const normalizedBusNumber = positiveSafeInteger(busNumber);
        if (!normalizedBusNumber) {
            return res.status(400).json({ error: 'busNumber must be a positive integer' });
        }

        const access = await assertCaretakerAccess(normalizedBusNumber, auth);
        if (!access.ok) {
            return res.status(access.code).json({ error: access.message });
        }

        const scheduleDate = req.body.date === undefined ? today() : req.body.date;
        if (typeof scheduleDate !== 'string' || !isDateOnly(scheduleDate)) {
            return res.status(400).json({ error: 'date must be a valid YYYY-MM-DD campus date' });
        }
        const fromHostelTime = boundedString(req.body.fromHostelTime, 20, { fallback: '' });
        const fromMBSETime = boundedString(req.body.fromMBSETime, 20, { fallback: '' });
        const specialNote = boundedString(req.body.specialNote, 255, { fallback: '' });
        if (fromHostelTime === null || fromMBSETime === null || specialNote === null) {
            return res.status(400).json({ error: 'Schedule times must be strings up to 20 characters and note up to 255 characters' });
        }
        if (req.body.status !== undefined && !['idle', 'running', 'maintenance'].includes(String(req.body.status).toLowerCase())) {
            return res.status(400).json({ error: 'status must be idle, running, or maintenance' });
        }

        // Notifications target the hostel on the bus record, never a client-supplied recipient.
        const priorRows = await q('SELECT from_hostel_time, from_mbse_time FROM schedules WHERE bus_number = ? AND date = ? LIMIT 1', [normalizedBusNumber, scheduleDate]);
        const scheduleChanged = priorRows.length === 0 ||
            priorRows[0].from_hostel_time !== fromHostelTime ||
            priorRows[0].from_mbse_time !== fromMBSETime;

                await q(
                        `
            INSERT INTO schedules (id, bus_number, date, from_hostel_time, from_mbse_time, special_note, updated_by)
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (bus_number, date) DO UPDATE SET
                from_hostel_time = EXCLUDED.from_hostel_time,
                from_mbse_time = EXCLUDED.from_mbse_time,
                special_note = EXCLUDED.special_note,
                updated_by = EXCLUDED.updated_by,
                updated_at = CURRENT_TIMESTAMP
            `,
                        [
                                uid('sch_'),
                                normalizedBusNumber,
                                scheduleDate,
                                fromHostelTime,
                                fromMBSETime,
                                specialNote,
                                auth.email,
                        ]
                );

        if (scheduleChanged) {
            const bus = await q('SELECT assigned_hostel FROM buses WHERE bus_number = ? LIMIT 1', [normalizedBusNumber]);
            if (bus.length) {
                await q('INSERT INTO notifications (id, title, message, type, bus_number, target_hostel, is_read, sent_by) VALUES (?, ?, ?, ?, ?, ?, false, ?)', [
                    uid('n_'), `Bus ${normalizedBusNumber} Schedule Updated`,
                    `Bus ${normalizedBusNumber} ${bus[0].assigned_hostel} → MBSE schedule has changed to ${fromHostelTime || fromMBSETime}.`,
                    'schedule', normalizedBusNumber, bus[0].assigned_hostel, auth.email,
                ]);
            }
        }

        if (req.body.status !== undefined) {
            const status = String(req.body.status).toLowerCase();
            await q('UPDATE buses SET status = ?, speed = ? WHERE bus_number = ?', [
                status,
                status === 'running' ? 25 : 0,
            normalizedBusNumber,
            ]);
        }

                const rows = await q(
                        `
            SELECT
                s.id AS _id,
                s.bus_number AS busNumber,
                to_char(s.date, 'YYYY-MM-DD') AS date,
                s.from_hostel_time AS fromHostelTime,
                s.from_mbse_time AS fromMBSETime,
                COALESCE(s.special_note, '') AS specialNote,
                COALESCE(s.updated_by, '') AS updatedBy
            FROM schedules s
            WHERE s.bus_number = ? AND s.date = ?
            LIMIT 1
            `,
                        [normalizedBusNumber, scheduleDate]
                );

                const bus = await fetchBusByNumber(normalizedBusNumber, auth.role);
        return res.json({ status: 'success', data: rows[0], bus });
    } catch (error) {
        return internalError(res, error, 'save schedule');
    }
});

app.patch('/api/buses/:busNumber', async (req, res) => {
    const auth = requireAuth(req, res, ['caretaker', 'admin']);
    if (!auth) return;

    try {
        const busNumber = positiveSafeInteger(req.params.busNumber);
        if (!busNumber) return res.status(400).json({ error: 'busNumber must be a positive integer' });
        const access = await assertCaretakerAccess(busNumber, auth);
        if (!access.ok) {
            return res.status(access.code).json({ error: access.message });
        }

        const updates = [];
        const params = [];

        if (req.body.status !== undefined) {
            const status = String(req.body.status).toLowerCase();
            if (!['idle', 'running', 'maintenance'].includes(status)) {
                return res.status(400).json({ error: 'status must be idle, running, or maintenance' });
            }
            updates.push('status = ?', 'speed = ?');
            params.push(status, status === 'running' ? 25 : 0);
        }
        if (req.body.route !== undefined) {
            const route = boundedString(req.body.route, 120, { required: true });
            if (!route) {
                return res.status(400).json({ error: 'route must contain 1 to 120 characters' });
            }
            updates.push('route = ?');
            params.push(route);
        }
        for (const [field, column, maxLength] of [
            ['name', 'bus_name', 80],
            ['sourcePlace', 'source_place', 120],
            ['destinationPlace', 'destination_place', 120],
        ]) {
            if (req.body[field] === undefined) continue;
            const value = boundedString(req.body[field], maxLength, { required: true });
            if (!value) {
                return res.status(400).json({ error: `${field} must contain 1 to ${maxLength} characters` });
            }
            updates.push(`${column} = ?`);
            params.push(value);
        }
        if (req.body.latitude !== undefined) {
            const latitude = finiteNumberInRange(req.body.latitude, -90, 90);
            if (latitude === null) return res.status(400).json({ error: 'latitude must be between -90 and 90' });
            updates.push('latitude = ?');
            params.push(latitude);
        }
        if (req.body.longitude !== undefined) {
            const longitude = finiteNumberInRange(req.body.longitude, -180, 180);
            if (longitude === null) return res.status(400).json({ error: 'longitude must be between -180 and 180' });
            updates.push('longitude = ?');
            params.push(longitude);
        }
        if (req.body.isEnabled !== undefined) {
            if (typeof req.body.isEnabled !== 'boolean') return res.status(400).json({ error: 'isEnabled must be a boolean' });
            updates.push('is_enabled = ?');
            params.push(req.body.isEnabled);
        }

        if (updates.length > 0) {
            params.push(busNumber);
            await q(`UPDATE buses SET ${updates.join(', ')} WHERE bus_number = ?`, params);
        }

        const bus = await fetchBusByNumber(busNumber, auth.role);
        return res.json({ status: 'success', data: bus });
    } catch (error) {
        return internalError(res, error, 'update bus');
    }
});

app.get('/api/notifications', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin']);
    if (!auth) return;

    try {
        if (auth.role === 'caretaker' && !auth.hostelId) return res.status(403).json({ error: 'Caretaker account has no assigned hostel' });
        const hostel = ['student', 'caretaker'].includes(auth.role) ? auth.hostelId : (req.query.hostel || null);
        const rows = await q(
            `
            SELECT
                id AS _id,
                title,
                message,
                type,
                bus_number AS busNumber,
                target_hostel AS targetHostel,
                to_char(sent_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS sentAt,
                                to_char(expires_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS expiresAt,
                is_read AS isRead
            FROM notifications
                        WHERE expires_at > CURRENT_TIMESTAMP
                            AND ($1::varchar(10) IS NULL OR target_hostel = $1::varchar(10) OR target_hostel IS NULL)
            ORDER BY sent_at DESC
      `,
                        [hostel]
        );
        return res.json(rows.map((n) => ({ ...n, isRead: !!n.isRead })));
    } catch (error) {
        return internalError(res, error, 'notifications query');
    }
});

app.post('/api/reports', createReportSubmissionHandler({
    requireAuth,
    query: q,
    uid,
    internalError,
}));

app.get('/api/reports', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin']);
    if (!auth) return;
    try {
        const scope = auth.role === 'caretaker' ? 'WHERE r.hostel_id = $1'
            : auth.role === 'student' ? 'WHERE r.reporter_id = $1' : '';
        const args = auth.role === 'caretaker' ? [auth.hostelId || ''] : auth.role === 'student' ? [auth.userId] : [];
        const rows = await pool.query(`SELECT r.id, r.reporter_id AS "reporterId", r.hostel_id AS "hostelId",
            r.bus_number AS "busNumber", r.category, r.message, r.status, r.created_at AS "createdAt"
            FROM reports r ${scope} ORDER BY r.created_at DESC`, args);
        return res.json({ status: 'success', data: rows.rows });
    } catch (error) {
        return internalError(res, error, 'load reports');
    }
});

app.patch('/api/reports/:id', async (req, res) => {
    const auth = requireAuth(req, res, ['caretaker', 'admin']);
    if (!auth) return;
    const status = String(req.body?.status || '').toLowerCase();
    if (!['open', 'in_progress', 'resolved'].includes(status)) return res.status(400).json({ error: 'Invalid report status' });
    try {
        const args = [status, req.params.id];
        const scope = auth.role === 'caretaker' ? ' AND hostel_id = $3' : '';
        if (auth.role === 'caretaker') args.push(auth.hostelId || '');
        const result = await pool.query(`UPDATE reports SET status = $1 WHERE id = $2${scope} RETURNING id`, args);
        return result.rowCount ? res.json({ status: 'success' }) : res.status(404).json({ error: 'Report not found' });
    } catch (error) {
        return internalError(res, error, 'update report');
    }
});

app.post('/api/notifications/send', async (req, res) => {
    const auth = requireAuth(req, res, ['caretaker', 'admin']);
    if (!auth) return;

    try {
        const {
            title,
            message,
            type = 'general',
            busNumber = null,
            targetHostel = auth.role === 'caretaker' ? auth.hostelId : (auth.hostelId || null),
        } = req.body || {};

        const normalizedTitle = boundedString(title, 160, { required: true });
        const normalizedMessage = boundedString(message, 2000, { required: true });
        const normalizedType = boundedString(type, 30, { required: true });
        const normalizedBusNumber = busNumber == null ? null : positiveSafeInteger(busNumber);
        const normalizedTargetHostel = targetHostel == null ? null : String(targetHostel).trim().toUpperCase();
        if (!normalizedTitle || !normalizedMessage || !normalizedType ||
            (busNumber != null && !normalizedBusNumber) ||
            (normalizedTargetHostel !== null && !hostelsSeed.some((hostel) => hostel.id === normalizedTargetHostel))) {
            return res.status(400).json({ error: 'Invalid notification fields' });
        }
        if (!normalizedTitle || !normalizedMessage) {
            return res.status(400).json({ error: 'title and message are required' });
        }
        if (auth.role === 'caretaker' && (!auth.hostelId || normalizedTargetHostel !== auth.hostelId)) {
            return res.status(403).json({ error: 'Caretakers can only post to their own hostel' });
        }
        if (auth.role === 'caretaker' && normalizedBusNumber != null) {
            const access = await assertCaretakerAccess(normalizedBusNumber, auth);
            if (!access.ok) return res.status(access.code).json({ error: access.message });
        }

        const id = uid('n_');
        await q(
            'INSERT INTO notifications (id, title, message, type, bus_number, target_hostel, is_read, sent_by) VALUES (?, ?, ?, ?, ?, ?, 0, ?)',
            [id, normalizedTitle, normalizedMessage, normalizedType, normalizedBusNumber, normalizedTargetHostel, auth.email]
        );

                const rows = await q(
                        `
            SELECT
                id AS _id,
                title,
                message,
                type,
                bus_number AS busNumber,
                target_hostel AS targetHostel,
                to_char(sent_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS sentAt,
                to_char(expires_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"') AS expiresAt,
                is_read AS isRead
            FROM notifications
            WHERE id = $1
            LIMIT 1
            `,
                        [id]
                );

        const created = rows[0];
        return res.json({ ...created, isRead: !!created.isRead });
    } catch (error) {
        return internalError(res, error, 'send notification');
    }
});

app.post('/api/location', async (req, res) => {
    const auth = requireAuth(req, res, ['driver']);
    if (!auth) {
        console.warn('Driver location authentication rejected', { route: req.path });
        return;
    }
    const busNumber = positiveSafeInteger(req.body?.busNumber);
    if (!Number.isInteger(busNumber) || busNumber !== Number(auth.busNumber)) {
        console.warn('Driver location validation rejected', { busNumber, reason: 'assignment_mismatch' });
        return res.status(403).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.UNKNOWN_BUS, 'This token can update only its assigned bus'));
    }
    const lat = finiteNumberInRange(req.body?.lat, -90, 90);
    const lng = finiteNumberInRange(req.body?.lng, -180, 180);
    const clientSpeed = finiteNumberInRange(req.body?.speed, 0, 250);
    const accuracy = finiteNumberInRange(req.body?.accuracy, 0, 50);
    const timestamp = req.body?.timestamp ? new Date(req.body.timestamp) : new Date();
    const requestedStatus = req.body?.status === 'idle' ? 'idle' : null;
    if (lat === null || lng === null || clientSpeed === null || accuracy === null || Number.isNaN(timestamp.getTime()) ||
        timestamp.getTime() > Date.now() + 5 * 60 * 1000) {
        console.warn('Driver location validation rejected', { busNumber, reason: 'invalid_fix' });
        return res.status(400).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.INVALID_COORDINATES, 'Invalid GPS fix; location accuracy must be 50m or better'));
    }

    let previous = driverLastFixes.get(busNumber);
    if (!previous) {
        const previousRows = await q('SELECT lat, lng, speed, ts FROM telemetry WHERE device_id=? ORDER BY received_at DESC, id DESC LIMIT 1', [`driver:${auth.userId}`]);
        if (previousRows.length) {
            const storedAt = Date.parse(previousRows[0].ts || '');
            if (Number.isFinite(storedAt)) {
                previous = { lat: Number(previousRows[0].lat), lng: Number(previousRows[0].lng), speed: Number(previousRows[0].speed || 0), timestamp: storedAt };
                driverLastFixes.set(busNumber, previous);
            }
        }
    }
    if (previous && timestamp.getTime() <= previous.timestamp) {
        console.warn('Driver location validation rejected', { busNumber, reason: 'stale_fix', fixTime: timestamp.toISOString() });
        return res.json({ ok: true, stale: true });
    }
    const point = { lat, lng, timestamp: timestamp.getTime() };
    let speed = clientSpeed;
    let heading = Number(req.body?.heading);
    if (previous) {
        const seconds = (point.timestamp - previous.timestamp) / 1000;
        if (seconds > 0) {
            const computed = haversineKm(previous, point) / (seconds / 3600);
            if (Number.isFinite(computed) && computed <= 180 && (clientSpeed > Math.max(computed * 2, 2) || computed > Math.max(clientSpeed * 2, 2))) speed = computed;
            if (!Number.isFinite(heading) || heading < 0 || heading >= 360) heading = bearingDegrees(previous, point);
            speed = previous.speed * 0.7 + speed * 0.3;
        }
    }
    if (!Number.isFinite(heading) || heading < 0 || heading >= 360) heading = 0;
    if (requestedStatus === 'idle') speed = 0;
    const status = requestedStatus || (speed > 1.5 ? 'running' : 'idle');
    const buses = await q(`SELECT b.assigned_hostel FROM buses b JOIN drivers d ON d.bus_number=b.bus_number
        WHERE b.bus_number=? AND b.is_enabled=true AND d.id=? AND d.is_active=true`, [busNumber, auth.userId]);
    if (!buses.length) {
        console.warn('Driver location validation rejected', { busNumber, reason: 'inactive_assignment' });
        return res.status(403).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.UNKNOWN_BUS, 'Driver assignment is no longer active'));
    }

    try {
        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            await client.query('INSERT INTO telemetry (device_id, bus_id, lat, lng, speed, accuracy, heading, has_fix, ts, status) VALUES ($1, $2, $3, $4, $5, $6, $7, true, $8, $9)',
                [`driver:${auth.userId}`, String(busNumber), lat, lng, speed, accuracy, heading, timestamp.toISOString(), status]);
            await client.query('UPDATE buses SET latitude=$1, longitude=$2, speed=$3, status=$4 WHERE bus_number=$5', [lat, lng, speed, status, busNumber]);
            await client.query('COMMIT');
        } catch (error) {
            await client.query('ROLLBACK').catch(() => {});
            console.error(`Telemetry database insertion failed (${TELEMETRY_DIAGNOSTIC_CODES.DATABASE_INSERT_FAILED}; ${safeDatabaseErrorCode(error)})`);
            return res.status(500).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.DATABASE_INSERT_FAILED, 'Unable to store telemetry'));
        } finally {
            client.release();
        }
        console.info('Driver location persisted', { busNumber, deviceId: `driver:${auth.userId}`, fixTime: timestamp.toISOString() });
        const accepted = { ...point, speed };
        driverLastFixes.set(busNumber, accepted);
        const update = {
            busId: String(busNumber), busNumber, bus_number: busNumber,
            assignedHostel: buses[0].assigned_hostel, assigned_hostel: buses[0].assigned_hostel,
            lat, lng, latitude: lat, longitude: lng, speed, heading,
            accuracy, status, hasFix: true, timestamp: timestamp.toISOString(),
            lastUpdated: timestamp.toISOString(),
        };
        telemetryEmitter.emit('live_update', update);
        console.info('Telemetry stream event emitted', { busNumber, source: 'driver' });
        return res.status(200).json({ ok: true });
    } catch (error) {
        console.error('Driver location persistence failed', { busNumber, code: safeDatabaseErrorCode(error) });
        return internalError(res, error, 'store driver location');
    }
});

app.post('/api/update-location', telemetryRateLimiter, async (req, res) => {
    try {
        const telemetry = normalizeTelemetry(req.body || {});
        const { lat: latNum, lng: lngNum, speed: speedNum, accuracy: accuracyNum } = telemetry;
        if (!hasValidDeviceFix({ lat: latNum, lng: lngNum, speed: speedNum, accuracy: accuracyNum })) {
            console.warn(`Telemetry rejected: ${TELEMETRY_DIAGNOSTIC_CODES.INVALID_COORDINATES}`);
            return res.status(400).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.INVALID_COORDINATES, 'A valid latitude, longitude, speed, and accuracy are required.'));
        }

        const normalizedStatus = telemetry.status === 'active' ? 'running' : telemetry.status;
        const eventTime = telemetry.timestamp == null ? new Date() : new Date(telemetry.timestamp);
        if (Number.isNaN(eventTime.getTime()) || eventTime.getTime() > Date.now() + 5 * 60 * 1000) {
            return res.status(400).json({ error: 'timestamp must be a valid ISO date and cannot be in the future' });
        }
        const busNumber = parseTelemetryBusNumber(telemetry.busId);
        if (busNumber === null) {
            console.warn(`Telemetry rejected: ${TELEMETRY_DIAGNOSTIC_CODES.UNKNOWN_BUS}`);
            return res.status(400).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.UNKNOWN_BUS, 'A valid bus_id is required.'));
        }
        const clientKey = req.header('x-api-key') || '';
        const deviceKeys = await q(
            'SELECT bus_number, key_hash FROM device_keys WHERE revoked_at IS NULL',
        );
        const deviceKey = findDeviceKeyAssignment(clientKey, deviceKeys);
        let authorized = false;
        if (deviceKey) {
            authorized = Number(deviceKey.bus_number) === busNumber;
        }
        if (!authorized && ALLOW_LEGACY_API_KEY && API_SECRET_KEY &&
            LEGACY_API_BUS_NUMBER > 0 && LEGACY_API_BUS_NUMBER === busNumber) {
            authorized = timingSafeSecretEqual(clientKey, API_SECRET_KEY);
        }
        if (!authorized) {
            console.warn(`Telemetry rejected: ${TELEMETRY_DIAGNOSTIC_CODES.AUTHENTICATION_FAILED}`);
            return res.status(401).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.AUTHENTICATION_FAILED, 'Unauthorized'));
        }
        console.info('Telemetry request authenticated', { route: req.path, busId: String(busNumber) });

        const buses = await q('SELECT assigned_hostel FROM buses WHERE bus_number=? AND is_enabled=true', [busNumber]);
        if (!buses.length) {
            console.warn(`Telemetry rejected: ${TELEMETRY_DIAGNOSTIC_CODES.UNKNOWN_BUS}`);
            return res.status(404).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.UNKNOWN_BUS, 'Bus not registered or disabled'));
        }

        const priorFix = await q('SELECT ts FROM telemetry WHERE regexp_replace(bus_id, \'[^0-9]\', \'\', \'g\') = ? ORDER BY received_at DESC, id DESC LIMIT 1', [String(busNumber)]);
        const priorEventTime = priorFix.length ? Date.parse(priorFix[0].ts || '') : NaN;
        if (Number.isFinite(priorEventTime) && eventTime.getTime() <= priorEventTime) {
            return res.status(200).json({ message: 'Older telemetry ignored', status: 'success', stale: true });
        }

        const client = await pool.connect();
        try {
            await client.query('BEGIN');
            await client.query(
                'INSERT INTO telemetry (device_id, bus_id, lat, lng, speed, accuracy, has_fix, satellites, hdop, net_type, ts, status) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)',
                [telemetry.deviceId, String(busNumber), latNum, lngNum, speedNum, accuracyNum, telemetry.hasFix ?? true, telemetry.satellites, telemetry.hdop, telemetry.netType, eventTime.toISOString(), normalizedStatus]
            );
            await client.query('UPDATE buses SET latitude = $1, longitude = $2, speed = $3, status = $4 WHERE bus_number = $5', [latNum, lngNum, speedNum, normalizedStatus, busNumber]);
            await client.query('COMMIT');
        } catch (error) {
            await client.query('ROLLBACK');
            console.error(`Telemetry database insertion failed (${TELEMETRY_DIAGNOSTIC_CODES.DATABASE_INSERT_FAILED}; ${safeDatabaseErrorCode(error)})`);
            return res.status(500).json(telemetryErrorPayload(TELEMETRY_DIAGNOSTIC_CODES.DATABASE_INSERT_FAILED, 'Unable to store telemetry'));
        } finally {
            client.release();
        }
        console.info('Telemetry persisted', { busId: String(busNumber), receivedAt: new Date().toISOString() });
        telemetryEmitter.emit('live_update', {
            bus_number: busNumber,
            busNumber,
            assigned_hostel: buses[0].assigned_hostel,
            hostel: buses[0].assigned_hostel,
            lat: latNum,
            lng: lngNum,
            speed: speedNum,
            status: normalizedStatus,
            hasFix: telemetry.hasFix ?? true,
            satellites: telemetry.satellites,
            hdop: telemetry.hdop,
            netType: telemetry.netType,
            timestamp: eventTime.toISOString(),
        });

        return res.status(200).json({ message: 'Data received successfully', status: 'success' });
    } catch (error) {
        console.error(`Telemetry processing failed (${safeDatabaseErrorCode(error)})`);
        return internalError(res, error, 'store device telemetry');
    }
});

app.get('/api/location/latest', async (req, res) => {
    const auth = requireAuth(req, res, ['student', 'caretaker', 'admin', 'driver']);
    if (!auth) return;

    const values = [];
    let scope = '';
    if (auth.role === 'driver') {
        if (!Number.isInteger(Number(auth.busNumber))) {
            return res.status(403).json({ error: 'Driver account has no assigned bus' });
        }
        values.push(String(auth.busNumber));
        scope = `WHERE regexp_replace(t.bus_id, '[^0-9]', '', 'g') = $${values.length}`;
    } else if (auth.role === 'student' || auth.role === 'caretaker') {
        if (!auth.hostelId) {
            return res.status(403).json({ error: 'Account has no assigned hostel' });
        }
        values.push(auth.hostelId);
        scope = `WHERE b.assigned_hostel = $${values.length}`;
    }

    try {
        const rows = await pool.query(
            `
            SELECT
                t.id,
                t.device_id,
                t.bus_id,
                t.lat,
                t.lng,
                t.speed,
                t.accuracy,
                t.ts,
                t.status,
                t.received_at AT TIME ZONE 'UTC' AS received_at
            FROM telemetry t
            LEFT JOIN buses b ON regexp_replace(t.bus_id, '[^0-9]', '', 'g') = b.bus_number::text
            ${scope}
            ORDER BY t.received_at DESC, t.id DESC
            LIMIT 1
            `,
            values,
        );

        if (!rows.rows.length) {
            const reasonCode = await diagnoseEmptyLatestTelemetry((sql) => pool.query(sql));
            console.info(`Latest telemetry query completed: ${reasonCode}`);
            return res.json({ status: 'success', data: null, reasonCode });
        }

        const latest = rows.rows[0];
        const deviceTime = latest.ts ? new Date(latest.ts) : null;
        const validDeviceTime = deviceTime && !Number.isNaN(deviceTime.getTime()) && deviceTime.getTime() <= Date.now() + 5 * 60 * 1000;
        const eventTimestamp = validDeviceTime ? deviceTime.toISOString() : new Date(latest.received_at).toISOString();
        const busRaw = latest.bus_id || '5';
        const busDigits = String(busRaw).replace(/[^0-9]/g, '');
        const busId = busDigits ? `Bus ${busDigits}` : String(busRaw);
        console.info('Latest telemetry query completed', {
            found: true,
            telemetryId: latest.id,
            deviceId: latest.device_id,
            busId,
            receivedAt: latest.received_at,
            fixTime: latest.ts,
        });

        return res.json({
            status: 'success',
            data: {
                deviceId: latest.device_id || 'ESP32-Device-1',
                busId,
                lat: Number(latest.lat),
                lng: Number(latest.lng),
                speed: Number(latest.speed || 0),
                accuracy: Number(latest.accuracy || 1.0),
                // Preserve the normalized device fix time so clients can mark
                // delayed/replayed telemetry stale. Receipt time is available separately.
                timestamp: eventTimestamp,
                deviceTimestamp: latest.ts,
                receivedAt: latest.received_at,
                status: latest.status || 'idle',
            },
        });
    } catch (error) {
        console.error(`Latest location query failed (${safeDatabaseErrorCode(error)})`);
        return internalError(res, error, 'latest location query');
    }
});

app.use((req, res) => {
    res.status(404).json({ error: 'Route not found' });
});

app.use((error, _req, res, _next) => {
    if (res.headersSent) return;
    if (error.type === 'entity.parse.failed') {
        return res.status(400).json({ error: 'Invalid JSON request body' });
    }
    return internalError(res, error, 'unhandled request');
});

async function start() {
    try {
        await initializeDatabase();
        await sessionStore.cleanupExpired();
        await loginAttemptStore.cleanup();
        sessionCleanupInterval = setInterval(() => {
            sessionStore.cleanupExpired().catch((error) => {
                console.error(`Session cleanup failed (${safeDatabaseErrorCode(error)})`);
            });
            loginAttemptStore.cleanup().catch((error) => {
                console.error(`Login attempt cleanup failed (${safeDatabaseErrorCode(error)})`);
            });
        }, 5 * 60 * 1000);
        sessionCleanupInterval.unref?.();
        console.info('PostgreSQL database initialized successfully');
        app.listen(port, bindAddress, () => {
            console.log(`Server running on port ${port}`);
            console.log(`ESP32 secure endpoint: http://<YOUR_PC_IP>:${port}/api/update-location`);
            console.log(`Flutter latest endpoint: http://<YOUR_PC_IP>:${port}/api/location/latest`);
        });
    } catch (error) {
        console.error(`Failed to start server (${safeDatabaseErrorCode(error)})`);
        process.exit(1);
    }
}

async function closeDatabase() {
    if (sessionCleanupInterval) {
        clearInterval(sessionCleanupInterval);
        sessionCleanupInterval = null;
    }
    if (!pool) return;
    const activePool = pool;
    pool = null;
    await activePool.end();
}

if (require.main === module) {
    start();
}

module.exports = {
    app,
    sessionStore,
    requireAuth,
    shouldSeedSampleData,
    start,
    initializeDatabase,
    checkDatabaseConnection,
    closeDatabase,
};
