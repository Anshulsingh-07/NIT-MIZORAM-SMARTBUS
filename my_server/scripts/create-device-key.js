'use strict';

const crypto = require('crypto');
const path = require('path');
const { Pool } = require('pg');
require('dotenv').config({
    path: process.env.SMARTBUS_ENV_FILE || path.resolve(__dirname, '..', '.env.supabase.local'),
    quiet: true,
});

function safeDatabaseErrorCode(error) {
    return typeof error?.code === 'string' && /^[A-Z0-9_-]{1,32}$/.test(error.code)
        ? error.code
        : 'unknown';
}

async function main() {
    const busNumber = Number(process.argv[2]);
    if (!Number.isSafeInteger(busNumber) || busNumber <= 0) {
        throw new Error('Usage: node scripts/create-device-key.js <bus-number>');
    }
    for (const name of ['DB_HOST', 'DB_USER', 'DB_PASSWORD', 'DB_NAME']) {
        if (!process.env[name]) throw new Error(`Missing required database setting: ${name}`);
    }

    const pool = new Pool({
        host: process.env.DB_HOST,
        port: Number(process.env.DB_PORT || 5432),
        database: process.env.DB_NAME,
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        ssl: process.env.DB_SSL === 'true' ? { rejectUnauthorized: false } : undefined,
        max: 1,
        connectionTimeoutMillis: Number(process.env.DB_CONNECTION_TIMEOUT_MS || 5000),
    });

    try {
        const key = crypto.randomBytes(32).toString('base64url');
        const keyHash = crypto.createHash('sha256').update(key).digest('hex');
        const result = await pool.query(
            `INSERT INTO device_keys (bus_number, key_hash)
             SELECT bus_number, $2 FROM buses WHERE bus_number = $1
             RETURNING bus_number`,
            [busNumber, keyHash],
        );
        if (!result.rowCount) throw new Error('Bus not found; no device key was created.');
        console.log(`Device key for bus ${busNumber} (shown once):`);
        console.log(key);
    } catch (error) {
        console.error(`Device key creation failed (${safeDatabaseErrorCode(error)}).`);
        process.exitCode = 1;
    } finally {
        process.env.DB_PASSWORD = '';
        await pool.end();
    }
}

main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
});