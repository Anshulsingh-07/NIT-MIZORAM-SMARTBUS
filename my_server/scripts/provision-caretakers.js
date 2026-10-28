'use strict';

const crypto = require('crypto');
const path = require('path');
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');
require('dotenv').config({
    path: process.env.SMARTBUS_ENV_FILE || path.resolve(__dirname, '..', '.env.local'),
    quiet: true,
});

const ROSTER = [
    ['BH1', 'Boys\' Hostel 1'],
    ['BH2', 'Boys\' Hostel 2'],
    ['BH3', 'Boys\' Hostel 3'],
    ['BH4', 'Boys\' Hostel 4'],
    ['GH1', 'Girls\' Hostel 1'],
    ['GH2', 'Girls\' Hostel 2'],
];
const PASSWORD_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';

function parseArguments(args) {
    const options = { dryRun: false, only: null, reset: null };
    for (let index = 0; index < args.length; index += 1) {
        if (args[index] === '--dry-run') options.dryRun = true;
        else if (args[index] === '--only') options.only = args[++index];
        else if (args[index] === '--reset') options.reset = args[++index];
        else throw new Error('Usage: provision-caretakers.js [--dry-run] [--only <HOSTEL> | --reset <email>]');
    }
    if (options.only && options.reset) throw new Error('--only and --reset cannot be combined.');
    if (options.only && !ROSTER.some(([hostelId]) => hostelId === options.only.toUpperCase())) {
        throw new Error('--only must be one of BH1, BH2, BH3, BH4, GH1, or GH2.');
    }
    if (options.reset && !ROSTER.some(([hostelId]) => `caretaker-${hostelId.toLowerCase()}@nitmz.ac.in` === options.reset.toLowerCase())) {
        throw new Error('--reset must name one of the six roster caretaker emails.');
    }
    return options;
}

function createTemporaryPassword() {
    return Array.from({ length: 16 }, () => PASSWORD_ALPHABET[crypto.randomInt(PASSWORD_ALPHABET.length)]).join('');
}

function createPool() {
    const required = process.env.DATABASE_URL
        ? []
        : ['DB_HOST', 'DB_PORT', 'DB_USER', 'DB_PASSWORD', 'DB_NAME'];
    const missing = required.filter((key) => !process.env[key]);
    if (missing.length) throw new Error(`Missing database settings: ${missing.join(', ')}`);

    return new Pool({
        ...(process.env.DATABASE_URL
            ? { connectionString: process.env.DATABASE_URL }
            : {
                host: process.env.DB_HOST,
                port: Number(process.env.DB_PORT),
                user: process.env.DB_USER,
                password: process.env.DB_PASSWORD,
                database: process.env.DB_NAME,
            }),
        ...(process.env.DB_SSL === 'true' ? { ssl: { rejectUnauthorized: false } } : {}),
        max: 1,
        connectionTimeoutMillis: Number(process.env.DB_CONNECTION_TIMEOUT_MS || 5000),
        query_timeout: Number(process.env.DB_QUERY_TIMEOUT_MS || 10000),
    });
}

function rosterFor(options) {
    if (options.reset) {
        return ROSTER.filter(([hostelId]) => `caretaker-${hostelId.toLowerCase()}@nitmz.ac.in` === options.reset.toLowerCase());
    }
    if (options.only) return ROSTER.filter(([hostelId]) => hostelId === options.only.toUpperCase());
    return ROSTER;
}

async function provision(options) {
    const roster = rosterFor(options);
    if (options.dryRun) {
        console.log(`Dry run: would ${options.reset ? 'reset' : 'provision'} ${roster.length} caretaker account(s):`);
        for (const [hostelId] of roster) console.log(`- ${hostelId}: caretaker-${hostelId.toLowerCase()}@nitmz.ac.in`);
        return;
    }

    const pool = createPool();
    const credentials = [];
    let client;
    try {
        client = await pool.connect();
        await client.query('BEGIN');
        for (const [hostelId, hostelName] of roster) {
            const email = `caretaker-${hostelId.toLowerCase()}@nitmz.ac.in`;
            const password = createTemporaryPassword();
            const passwordHash = await bcrypt.hash(password, 12);
            if (options.reset) {
                const result = await client.query(
                    `UPDATE users SET password = $1, must_change_password = true
                     WHERE LOWER(email) = LOWER($2) AND role = 'caretaker' AND hostel_id = $3
                     RETURNING email`,
                    [passwordHash, email, hostelId],
                );
                if (!result.rowCount) throw new Error(`No matching caretaker account exists for ${hostelId}.`);
                credentials.push({ email, password });
                continue;
            }

            const id = `usr_${crypto.randomBytes(8).toString('hex')}`;
            const result = await client.query(
                `INSERT INTO users (id, name, email, password, role, hostel_id, must_change_password)
                 VALUES ($1, $2, $3, $4, 'caretaker', $5, true)
                 ON CONFLICT DO NOTHING
                 RETURNING email`,
                [id, `${hostelId} ${hostelName}`, email, passwordHash, hostelId],
            );
            if (result.rowCount) credentials.push({ email, password });
        }
        await client.query('COMMIT');
        if (credentials.length) {
            console.log('Temporary caretaker credentials (shown once):');
            for (const credential of credentials) console.log(`${credential.email}: ${credential.password}`);
        } else {
            console.log('No caretaker accounts were created; all roster accounts already exist.');
        }
    } catch (error) {
        await client?.query('ROLLBACK').catch(() => {});
        const code = typeof error?.code === 'string' && /^[A-Z0-9_-]{1,32}$/.test(error.code)
            ? error.code
            : 'unknown';
        console.error(`Caretaker provisioning failed (${code}); transaction rolled back.`);
        process.exitCode = 1;
    } finally {
        client?.release();
        await pool.end();
        process.env.DB_PASSWORD = '';
        process.env.DATABASE_URL = '';
        for (const credential of credentials) credential.password = '';
    }
}

async function main(args = process.argv.slice(2)) {
    const options = parseArguments(args);
    await provision(options);
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error.message);
        process.exitCode = 1;
    });
}

module.exports = { createTemporaryPassword, parseArguments, rosterFor };