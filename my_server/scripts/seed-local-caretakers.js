'use strict';

// LOCAL-ONLY: createLocalPool enforces NODE_ENV=development, loopback,
// smartbus_local, port 5433, and rejects DATABASE_URL or remote hosts.

const path = require('path');
const bcrypt = require('bcryptjs');
require('dotenv').config({ path: path.resolve(__dirname, '..', '.env.local'), quiet: true });
const { assertLocalDatabaseConfig, createLocalPool } = require('./local-db');

const HOSTELS = [
    ['BH1', "Boys' Hostel 1"],
    ['BH2', "Boys' Hostel 2"],
    ['BH3', "Boys' Hostel 3"],
    ['BH4', "Boys' Hostel 4"],
    ['GH1', "Girls' Hostel 1"],
    ['GH2', "Girls' Hostel 2"],
];

function normalizedRecoveryMobile(value) {
    const digits = String(value || '').replace(/\D/g, '');
    if (digits.length === 10 && /^[6-9]/.test(digits)) return `+91${digits}`;
    if (digits.length === 12 && digits.startsWith('91') && /^[6-9]/.test(digits.slice(2))) {
        return `+${digits}`;
    }
    throw new Error('CARETAKER_RECOVERY_MOBILE must be a valid Indian mobile number.');
}

function readInitialPasswords() {
    let passwords;
    try {
        passwords = JSON.parse(process.env.LOCAL_CARETAKER_PASSWORDS_JSON || '{}');
    } catch (_) {
        throw new Error('LOCAL_CARETAKER_PASSWORDS_JSON must contain a JSON object in .env.local.');
    }
    for (const [hostel] of HOSTELS) {
        const password = passwords[hostel];
        if (typeof password !== 'string' || password.length < 9 || password.length > 128) {
            throw new Error(`A 9-128 character local initial password is required for ${hostel}.`);
        }
    }
    if (new Set(Object.values(passwords)).size !== HOSTELS.length) {
        throw new Error('Local caretaker initial passwords must be unique.');
    }
    return passwords;
}

async function main() {
    assertLocalDatabaseConfig();
    const recoveryMobile = normalizedRecoveryMobile(process.env.CARETAKER_RECOVERY_MOBILE);
    const passwords = readInitialPasswords();
    const pool = createLocalPool();
    const client = await pool.connect();
    try {
        await client.query('BEGIN');
        for (const [hostelId, fullName] of HOSTELS) {
            await client.query(
                'INSERT INTO hostels (id, name, type, full_name) VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING',
                [hostelId, hostelId, hostelId.startsWith('B') ? 'Boys' : 'Girls', fullName],
            );

            const email = `caretaker-${hostelId.toLowerCase()}@nitmz.ac.in`;
            const found = await client.query(
                'SELECT id, role, hostel_id, password FROM users WHERE LOWER(email) = LOWER($1) LIMIT 1 FOR UPDATE',
                [email],
            );
            if (found.rows.length) {
                const existing = found.rows[0];
                if (existing.role !== 'caretaker' || existing.hostel_id !== hostelId) {
                    throw new Error(`Existing account conflicts with caretaker identity for ${hostelId}; no records were changed.`);
                }
                await client.query(
                    `UPDATE users SET recovery_phone = COALESCE(recovery_phone, $1::varchar),
                                         recovery_phone_verified_at = CASE
                                             WHEN recovery_phone IS NULL OR
                                                  (recovery_phone = $1::varchar AND recovery_phone_verified_at IS NULL) THEN NOW()
                                             ELSE recovery_phone_verified_at
                                         END
                     WHERE id = $2`,
                    [recoveryMobile, existing.id],
                );
                if (/^\$2[aby]\$/.test(existing.password || '') &&
                    await bcrypt.compare(passwords[hostelId], existing.password)) {
                    await client.query(
                        'UPDATE users SET must_change_password = true WHERE id = $1',
                        [existing.id],
                    );
                }
                if (!/^\$2[aby]\$/.test(existing.password || '')) {
                    console.warn(`Existing ${hostelId} caretaker has a legacy password hash and was left unchanged.`);
                }
                continue;
            }

            const passwordHash = await bcrypt.hash(passwords[hostelId], 12);
            await client.query(
                `INSERT INTO users (id, name, email, password, role, hostel_id, recovery_phone, recovery_phone_verified_at, must_change_password)
                 VALUES ($1, $2, $3, $4, 'caretaker', $5, $6, NOW(), true)`,
                [`local_caretaker_${hostelId.toLowerCase()}`, `${hostelId} Caretaker`, email, passwordHash, hostelId, recoveryMobile],
            );
        }
        await client.query('COMMIT');
        console.log('Local caretaker seed completed; existing password hashes were preserved.');
    } catch (error) {
        await client.query('ROLLBACK').catch(() => {});
        console.error(error.message);
        process.exitCode = 1;
    } finally {
        client.release();
        await pool.end();
    }
}

main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
});
