'use strict';

const path = require('path');
const readline = require('readline');
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');
require('dotenv').config({
    path: process.env.SMARTBUS_ENV_FILE || path.resolve(__dirname, '..', '.env.supabase.local'),
    quiet: true,
});

const EXPECTED_HOST = 'aws-0-ap-southeast-2.pooler.supabase.com';
const EXPECTED_USER = 'postgres.igzurztdhdepkodyetop';
const EXPECTED_DATABASE = 'postgres';
const RECOVERY_MOBILE = '+919140598061';
const HOSTELS = [
    ['BH1', 'caretaker-bh1@nitmz.ac.in'],
    ['BH2', 'caretaker-bh2@nitmz.ac.in'],
    ['BH3', 'caretaker-bh3@nitmz.ac.in'],
    ['BH4', 'caretaker-bh4@nitmz.ac.in'],
    ['GH1', 'caretaker-gh1@nitmz.ac.in'],
    ['GH2', 'caretaker-gh2@nitmz.ac.in'],
];

function assertTargetConfiguration() {
    if (process.env.DB_HOST !== EXPECTED_HOST ||
        process.env.DB_USER !== EXPECTED_USER ||
        process.env.DB_NAME !== EXPECTED_DATABASE ||
        Number(process.env.DB_PORT) !== 5432 ||
        process.env.DB_SSL !== 'true') {
        throw new Error('Refusing to run: configure the expected Supabase Session Pooler host, user, database, port 5432, and DB_SSL=true.');
    }
}

function promptHidden(prompt) {
    if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== 'function') {
        return Promise.reject(new Error('Run this provisioning command directly in an interactive terminal.'));
    }

    return new Promise((resolve, reject) => {
        let value = '';
        const finish = (error) => {
            process.stdin.removeListener('keypress', onKeypress);
            process.stdin.setRawMode(false);
            process.stdin.pause();
            process.stdout.write('\n');
            if (error) reject(error);
            else resolve(value);
        };
        const onKeypress = (character, key = {}) => {
            if (key.ctrl && key.name === 'c') return finish(new Error('Cancelled.'));
            if (key.name === 'return' || key.name === 'enter') return finish();
            if (key.name === 'backspace') {
                value = Array.from(value).slice(0, -1).join('');
                return;
            }
            if (character && !key.ctrl && !key.meta) value += character;
        };

        readline.emitKeypressEvents(process.stdin);
        process.stdin.setRawMode(true);
        process.stdin.resume();
        process.stdin.on('keypress', onKeypress);
        process.stdout.write(prompt);
    });
}

function promptConfirmation(prompt) {
    const terminal = readline.createInterface({ input: process.stdin, output: process.stdout });
    return new Promise((resolve) => terminal.question(prompt, (answer) => {
        terminal.close();
        resolve(answer.trim());
    }));
}

function validatePasswords(passwords) {
    for (const [hostelId] of HOSTELS) {
        const password = passwords[hostelId];
        if (typeof password !== 'string' || password.length < 16 || password.length > 128) {
            throw new Error(`A 16-128 character fresh password is required for ${hostelId}.`);
        }
    }
    if (new Set(HOSTELS.map(([hostelId]) => passwords[hostelId])).size !== HOSTELS.length) {
        throw new Error('All six caretaker passwords must be unique.');
    }
}

async function collectPasswords() {
    const passwords = {};
    for (const [hostelId, email] of HOSTELS) {
        const password = await promptHidden(`Temporary password for ${hostelId} (${email}): `);
        const confirmation = await promptHidden(`Confirm password for ${hostelId}: `);
        if (password !== confirmation) {
            throw new Error(`Password confirmation did not match for ${hostelId}.`);
        }
        passwords[hostelId] = password;
    }
    validatePasswords(passwords);
    return passwords;
}

function safeDatabaseErrorCode(error) {
    return typeof error?.code === 'string' && /^[A-Z0-9_-]{1,32}$/.test(error.code)
        ? error.code
        : 'unknown';
}

async function provision() {
    assertTargetConfiguration();
    if (!process.env.DB_PASSWORD) {
        process.env.DB_PASSWORD = await promptHidden('Supabase database password: ');
    }
    if (!process.env.DB_PASSWORD || process.env.DB_PASSWORD === '[YOUR-PASSWORD]') {
        throw new Error('A real Supabase database password is required.');
    }

    const passwords = await collectPasswords();
    const confirmation = await promptConfirmation(
        `This will create only missing caretaker accounts at ${EXPECTED_HOST}. Type PROVISION to continue: `,
    );
    if (confirmation !== 'PROVISION') throw new Error('Provisioning cancelled.');

    const pool = new Pool({
        host: process.env.DB_HOST,
        port: Number(process.env.DB_PORT),
        database: process.env.DB_NAME,
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        ssl: { rejectUnauthorized: false },
        max: 1,
        connectionTimeoutMillis: 5000,
        query_timeout: 10000,
    });
    let client;
    let created = 0;
    let preserved = 0;
    try {
        client = await pool.connect();
        await client.query('BEGIN');
        const hostelResult = await client.query(
            'SELECT id FROM public.hostels WHERE id = ANY($1::varchar[])',
            [HOSTELS.map(([hostelId]) => hostelId)],
        );
        if (hostelResult.rows.length !== HOSTELS.length) {
            throw new Error('The six required hostel rows are missing. Run the non-sensitive Supabase seed first.');
        }

        for (const [hostelId, email] of HOSTELS) {
            const found = await client.query(
                'SELECT id, role, hostel_id, password FROM public.users WHERE LOWER(email) = LOWER($1) LIMIT 1 FOR UPDATE',
                [email],
            );
            if (found.rows.length) {
                const account = found.rows[0];
                if (account.role !== 'caretaker' || account.hostel_id !== hostelId) {
                    throw new Error(`Existing account conflicts with ${hostelId}; no password was changed.`);
                }
                if (!/^\$2[aby]\$/.test(account.password || '')) {
                    throw new Error(`Existing ${hostelId} account does not contain a supported bcrypt hash; no password was changed.`);
                }
                await client.query(
                    `UPDATE public.users
                     SET recovery_phone = COALESCE(recovery_phone, $1),
                         recovery_phone_verified_at = CASE
                                                     WHEN recovery_phone IS NULL OR recovery_phone = $1
                                                         THEN COALESCE(recovery_phone_verified_at, NOW())
                           ELSE recovery_phone_verified_at
                         END
                     WHERE id = $2`,
                    [RECOVERY_MOBILE, account.id],
                );
                preserved++;
                continue;
            }

            const passwordHash = await bcrypt.hash(passwords[hostelId], 12);
            await client.query(
                `INSERT INTO public.users
                   (id, name, email, password, role, hostel_id, recovery_phone,
                    recovery_phone_verified_at, must_change_password)
                 VALUES ($1, $2, $3, $4, 'caretaker', $5, $6, NOW(), true)`,
                [`supabase_caretaker_${hostelId.toLowerCase()}`, `${hostelId} Caretaker`, email,
                    passwordHash, hostelId, RECOVERY_MOBILE],
            );
            created++;
        }
        await client.query('COMMIT');
        console.log(`Caretaker provisioning complete: ${created} created; ${preserved} existing bcrypt hashes preserved.`);
    } catch (error) {
        await client?.query('ROLLBACK').catch(() => {});
        console.error(`Caretaker provisioning failed (${safeDatabaseErrorCode(error)}); transaction rolled back.`);
        process.exitCode = 1;
    } finally {
        client?.release();
        await pool.end();
        for (const hostelId of Object.keys(passwords)) passwords[hostelId] = '';
        process.env.DB_PASSWORD = '';
    }
}

if (require.main === module) {
    provision().catch((error) => {
        console.error(`Caretaker provisioning stopped (${safeDatabaseErrorCode(error)}).`);
        process.exitCode = 1;
    });
}

module.exports = { assertTargetConfiguration, validatePasswords };
