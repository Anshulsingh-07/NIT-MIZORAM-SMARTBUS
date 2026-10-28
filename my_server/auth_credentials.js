'use strict';

const bcrypt = require('bcryptjs');
const crypto = require('crypto');
const DUMMY_PASSWORD_HASH = bcrypt.hashSync('not-a-real-account-password-for-timing', 12);

const PASSWORD_CHANGE_ALLOWED_PATHS = new Set([
    '/api/me',
    '/api/auth/change-password',
    '/api/auth/logout',
]);

function canAccessDuringPasswordChange(path) {
    return PASSWORD_CHANGE_ALLOWED_PATHS.has(path);
}

function createUserLookup(query) {
    return async (email) => {
        const rows = await query(
            'SELECT id, name, email, role, hostel_id, password, must_change_password FROM users WHERE LOWER(BTRIM(email)) = LOWER(?) LIMIT 2',
            [email],
        );
        return rows.length === 1 ? rows[0] : undefined;
    };
}

async function getAuthenticationFailureReason(user, password, hostels) {
    const storedPassword = user?.password || '';
    const supportedHash = /^\$2[aby]\$/.test(storedPassword);
    let passwordMatches = false;
    try {
        passwordMatches = await bcrypt.compare(password, supportedHash ? storedPassword : DUMMY_PASSWORD_HASH);
    } catch (_) {
        return 'invalid_password_hash';
    }
    if (!user) return 'account_not_found';
    if (!supportedHash) return 'unsupported_password_hash';
    if (!passwordMatches) return 'password_mismatch';
    if (user.role === 'caretaker' && !hostels.some((hostel) => hostel.id === user.hostel_id)) {
        return 'invalid_caretaker_hostel';
    }
    return null;
}

async function compareDriverPin(pin, storedHash) {
    const dummyHash = DUMMY_DRIVER_PIN_HASH;
    try {
        return await bcrypt.compare(pin, /^\$2[aby]\$/.test(storedHash || '') ? storedHash : dummyHash);
    } catch (_) {
        return false;
    }
}

const DUMMY_DRIVER_PIN_HASH = bcrypt.hashSync('000000', 10);

async function canAuthenticateUser(user, password, hostels) {
    return (await getAuthenticationFailureReason(user, password, hostels)) === null;
}

function createLoginRateLimiter({ limit = 10, windowMs = 15 * 60 * 1000, clock = Date.now } = {}) {
    const attemptsByIp = new Map();
    return (req, res, next) => {
        const now = clock();
        for (const [ip, timestamps] of attemptsByIp) {
            const recent = timestamps.filter((timestamp) => now - timestamp < windowMs);
            if (recent.length) attemptsByIp.set(ip, recent);
            else attemptsByIp.delete(ip);
        }

        const ip = req.ip || req.socket?.remoteAddress || 'unknown';
        const attempts = attemptsByIp.get(ip) || [];
        if (attempts.length >= limit) {
            return res.status(429).json({ error: 'Too many login attempts. Try again later.' });
        }
        attempts.push(now);
        attemptsByIp.set(ip, attempts);
        return next();
    };
}

function createLoginHandler({ findUserByEmail, hostels, createToken, publicUser, logger = console }) {
    return async (req, res) => {
        try {
            const email = String(req.body?.email || '').trim().toLowerCase();
            const password = String(req.body?.password || '');
            const user = await findUserByEmail(email);
            const failureReason = await getAuthenticationFailureReason(user, password, hostels);
            if (failureReason) {
                logger.warn(`Login rejected: ${failureReason}`);
                return res.status(401).json({ error: 'Invalid credentials' });
            }

            const token = await createToken(user);
            return res.json({
                token,
                user: publicUser(user),
                mustChangePassword: Boolean(user.must_change_password),
            });
        } catch (error) {
            const errorId = crypto.randomBytes(4).toString('hex');
            logger.error(`Login processing failed (${errorId})`, error);
            return res.status(500).json({ error: 'Internal server error', errorId });
        }
    };
}

module.exports = {
    canAuthenticateUser,
    canAccessDuringPasswordChange,
    createUserLookup,
    createLoginRateLimiter,
    createLoginHandler,
    compareDriverPin,
};
