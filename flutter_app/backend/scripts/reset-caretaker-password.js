#!/usr/bin/env node
'use strict';

const path = require('path');
const readline = require('readline');
const bcrypt = require('bcryptjs');
const { Pool } = require('pg');

require('dotenv').config({ path: path.resolve(__dirname, '..', '.env'), quiet: true });

function usage() {
    console.log('Usage: node scripts/reset-caretaker-password.js (--email EMAIL | --username USER_ID | --mobile VERIFIED_MOBILE) --confirm');
    console.log('The new password is entered twice through a hidden terminal prompt.');
}

function parseArgs(args) {
    const result = { confirm: false };
    for (let index = 0; index < args.length; index++) {
        const argument = args[index];
        if (argument === '--confirm') {
            result.confirm = true;
        } else if (['--email', '--username', '--mobile'].includes(argument)) {
            if (result.identifierType || !args[index + 1] || args[index + 1].startsWith('--')) {
                throw new Error('Provide exactly one caretaker identifier.');
            }
            result.identifierType = argument.slice(2);
            result.identifier = args[++index].trim();
        } else if (argument === '--help' || argument === '-h') {
            result.help = true;
        } else {
            throw new Error('Unknown command-line option.');
        }
    }
    return result;
}

function normalizeVerifiedMobile(value) {
    const digits = value.replace(/\D/g, '');
    if (digits.length === 10 && /^[6-9]/.test(digits)) return `+91${digits}`;
    if (digits.length === 12 && digits.startsWith('91') && /^[6-9]/.test(digits.slice(2))) {
        return `+${digits}`;
    }
    throw new Error('Mobile identifier must be a valid 10-digit Indian number.');
}

function promptHidden(prompt) {
    if (!process.stdin.isTTY || typeof process.stdin.setRawMode !== 'function') {
        return Promise.reject(new Error('Run this command in an interactive terminal.'));
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

function createPool() {
    const common = {
        max: 1,
        connectionTimeoutMillis: Number(process.env.DB_CONNECTION_TIMEOUT_MS || 5000),
        query_timeout: Number(process.env.DB_QUERY_TIMEOUT_MS || 8000),
    };
    if (process.env.DATABASE_URL) {
        return new Pool({
            ...common,
            connectionString: process.env.DATABASE_URL,
            ssl: { rejectUnauthorized: false },
        });
    }

    const host = process.env.DB_HOST || '';
    const port = Number(process.env.DB_PORT || 5432);
    const user = process.env.DB_USER || '';
    const password = process.env.DB_PASSWORD || '';
    const database = process.env.DB_NAME || '';
    if (!host || !user || !password || !database) {
        throw new Error('Database configuration is incomplete.');
    }
    return new Pool({
        ...common,
        host,
        port,
        user,
        password,
        database,
        ssl: process.env.DB_SSL === 'true' || host.includes('supabase')
            ? { rejectUnauthorized: false }
            : false,
    });
}

function identifierQuery(identifierType, identifier) {
    if (identifierType === 'email') {
        if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(identifier)) {
            throw new Error('Provide a valid caretaker email address.');
        }
        return {
            sql: 'SELECT id, role, hostel_id FROM users WHERE LOWER(email) = LOWER($1) LIMIT 2 FOR UPDATE',
            value: identifier.toLowerCase(),
        };
    }
    if (identifierType === 'username') {
        return {
            sql: 'SELECT id, role, hostel_id FROM users WHERE id = $1 LIMIT 2 FOR UPDATE',
            value: identifier,
        };
    }
    if (identifierType === 'mobile') {
        return {
            sql: `SELECT id, role, hostel_id FROM users
                  WHERE recovery_phone = $1 AND recovery_phone_verified_at IS NOT NULL
                  LIMIT 2 FOR UPDATE`,
            value: normalizeVerifiedMobile(identifier),
        };
    }
    throw new Error('Provide exactly one caretaker identifier.');
}

async function updateCaretakerPassword(client, query, newPassword) {
    await client.query('BEGIN');
    try {
        const result = await client.query(query.sql, [query.value]);
        if (result.rows.length !== 1 || result.rows[0].role !== 'caretaker') {
            await client.query('ROLLBACK');
            return 'not_found';
        }

        const user = result.rows[0];
        const hostel = await client.query('SELECT id FROM hostels WHERE id = $1 LIMIT 1', [user.hostel_id]);
        if (!user.hostel_id || !hostel.rows.length) {
            await client.query('ROLLBACK');
            return 'invalid_hostel';
        }

        const passwordHash = await bcrypt.hash(newPassword, 12);
        await client.query(
            'UPDATE users SET password = $1, must_change_password = false WHERE id = $2 AND role = $3',
            [passwordHash, user.id, 'caretaker'],
        );
        await client.query('DELETE FROM password_resets WHERE user_id = $1', [user.id]);
        await client.query('UPDATE password_reset_otps SET used_at = NOW() WHERE user_id = $1 AND used_at IS NULL', [user.id]);
        await client.query('COMMIT');
        return 'updated';
    } catch (error) {
        await client.query('ROLLBACK').catch(() => {});
        throw error;
    }
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    if (args.help) {
        usage();
        return;
    }
    if (!args.confirm) throw new Error('Pass --confirm to authorize this database update.');

    const query = identifierQuery(args.identifierType, args.identifier);
    const newPassword = await promptHidden('New password (9-128 characters): ');
    const confirmation = await promptHidden('Confirm new password: ');
    if (newPassword.length < 9 || newPassword.length > 128) {
        throw new Error('Password must be between 9 and 128 characters.');
    }
    if (newPassword !== confirmation) throw new Error('Passwords did not match.');

    const pool = createPool();
    let client;
    try {
        client = await pool.connect();
        const result = await updateCaretakerPassword(client, query, newPassword);
        if (result === 'not_found') {
            console.log('Caretaker not found; no account was changed.');
            process.exitCode = 2;
            return;
        }
        if (result === 'invalid_hostel') {
            console.error('Caretaker has an invalid hostel assignment; no account was changed.');
            process.exitCode = 3;
            return;
        }
        console.log('Caretaker password updated successfully.');
    } catch (error) {
        console.error(`Password reset failed (${typeof error?.code === 'string' ? error.code : 'database_error'}).`);
        process.exitCode = 1;
    } finally {
        client?.release();
        await pool.end().catch(() => {});
    }
}

if (require.main === module) {
    main().catch((error) => {
        console.error(error.message);
        process.exitCode = 1;
    });
}

module.exports = {
    identifierQuery,
    normalizeVerifiedMobile,
    parseArgs,
    updateCaretakerPassword,
};
