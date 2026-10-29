'use strict';

const bcrypt = require('bcryptjs');
const { Pool } = require('pg');

const CARETAKER_EMAIL = 'caretakerbh1@nitmz.ac.in';
const DRIVER_NAME = 'Seed Test Driver';
const BCRYPT_PASSWORD_COST = 12;
const BCRYPT_DRIVER_PIN_COST = 10;

function requiredEnv(name) {
    const value = process.env[name];
    if (typeof value !== 'string' || !value.trim()) throw new Error(`Missing required environment variable: ${name}`);
    return value.trim();
}

function readConfiguration() {
    const databaseUrl = requiredEnv('DATABASE_URL');
    const caretakerPassword = requiredEnv('SEED_CARETAKER_PASSWORD');
    const driverPhone = requiredEnv('SEED_DRIVER_PHONE').replace(/\D/g, '').slice(-10);
    const driverPin = requiredEnv('SEED_DRIVER_PIN');
    const driverBusNumberValue = requiredEnv('SEED_DRIVER_BUS_NUMBER');
    const driverBusNumber = Number(driverBusNumberValue);

    if (caretakerPassword.length < 12 || caretakerPassword.length > 128) {
        throw new Error('SEED_CARETAKER_PASSWORD must be 12-128 characters.');
    }
    if (!/^[6-9]\d{9}$/.test(driverPhone)) {
        throw new Error('SEED_DRIVER_PHONE must contain a valid 10-digit Indian mobile number.');
    }
    if (!/^\d{6}$/.test(driverPin)) throw new Error('SEED_DRIVER_PIN must be exactly 6 digits.');
    if (!/^\d+$/.test(driverBusNumberValue) || !Number.isSafeInteger(driverBusNumber) || driverBusNumber < 1) {
        throw new Error('SEED_DRIVER_BUS_NUMBER must be a positive whole number.');
    }

    return { databaseUrl, caretakerPassword, driverPhone, driverPin, driverBusNumber };
}

function createPool(databaseUrl) {
    return new Pool({
        connectionString: databaseUrl,
        ssl: { rejectUnauthorized: false },
        max: 1,
        connectionTimeoutMillis: 10000,
        query_timeout: 15000,
    });
}

function safeDatabaseErrorCode(error) {
    return typeof error?.code === 'string' && /^[A-Z0-9_-]{1,32}$/.test(error.code)
        ? error.code
        : 'unknown';
}

async function seedAccounts() {
    const configuration = readConfiguration();
    const pool = createPool(configuration.databaseUrl);
    let client;
    let caretakerHash;
    let driverPinHash;
    try {
        [caretakerHash, driverPinHash] = await Promise.all([
            bcrypt.hash(configuration.caretakerPassword, BCRYPT_PASSWORD_COST),
            bcrypt.hash(configuration.driverPin, BCRYPT_DRIVER_PIN_COST),
        ]);

        client = await pool.connect();
        await client.query('BEGIN');

        const hostelResult = await client.query(
            'SELECT id FROM public.hostels WHERE id = $1',
            ['BH1'],
        );
        if (!hostelResult.rowCount) throw new Error('Required hostel BH1 is missing; run the backend schema/seed first.');

        const busResult = await client.query(
            'SELECT bus_number, is_enabled FROM public.buses WHERE bus_number = $1 FOR UPDATE',
            [configuration.driverBusNumber],
        );
        if (!busResult.rowCount) throw new Error('Configured test driver bus is missing; choose an existing bus number.');
        if (!busResult.rows[0].is_enabled) throw new Error('Configured test driver bus is disabled.');

        const caretakerResult = await client.query(
            `INSERT INTO public.users
                (id, name, email, password, role, hostel_id, must_change_password)
             VALUES ($1, $2, $3, $4, 'caretaker', 'BH1', true)
             ON CONFLICT (email) DO UPDATE SET
                name = EXCLUDED.name,
                password = EXCLUDED.password,
                role = EXCLUDED.role,
                hostel_id = EXCLUDED.hostel_id,
                must_change_password = true
             RETURNING (xmax = 0) AS created`,
            ['seed_caretaker_bh1', 'BH1 Caretaker', CARETAKER_EMAIL, caretakerHash],
        );

        const driverId = `seed_test_driver_${configuration.driverBusNumber}`;
        const phoneResult = await client.query(
            `SELECT id FROM public.drivers
             WHERE RIGHT(regexp_replace(phone, '[^0-9]', '', 'g'), 10) = $1 AND id <> $2
             LIMIT 1`,
            [configuration.driverPhone, driverId],
        );
        if (phoneResult.rowCount) throw new Error('The configured test driver phone is already assigned to another driver.');

        const driverResult = await client.query(
            `INSERT INTO public.drivers (id, bus_number, name, phone, pin_hash, is_active)
             VALUES ($1, $2, $3, $4, $5, true)
             ON CONFLICT (bus_number) DO UPDATE SET
                name = EXCLUDED.name,
                phone = EXCLUDED.phone,
                pin_hash = EXCLUDED.pin_hash,
                is_active = true
             WHERE public.drivers.id = EXCLUDED.id
             RETURNING id, (xmax = 0) AS created`,
            [driverId, configuration.driverBusNumber, DRIVER_NAME, configuration.driverPhone, driverPinHash],
        );
        if (!driverResult.rowCount) {
            throw new Error('The selected bus already has a different driver; choose an unassigned test bus.');
        }

        await client.query('COMMIT');
        const caretakerAction = caretakerResult.rows[0].created ? 'created' : 'updated';
        const driverAction = driverResult.rows[0].created ? 'created' : 'updated';
        console.log(`Seed complete: ${CARETAKER_EMAIL} ${caretakerAction}; test driver for bus ${configuration.driverBusNumber} ${driverAction}.`);
    } catch (error) {
        await client?.query('ROLLBACK').catch(() => {});
        const message = error.message.startsWith('Required hostel') ||
            error.message.startsWith('Configured test driver') ||
            error.message.startsWith('The selected bus') ||
            error.message.startsWith('The configured test driver phone')
            ? error.message
            : `Account seed failed (${safeDatabaseErrorCode(error)}); transaction rolled back.`;
        console.error(message);
        process.exitCode = 1;
    } finally {
        client?.release();
        await pool.end();
        configuration.caretakerPassword = '';
        configuration.driverPin = '';
        configuration.databaseUrl = '';
        caretakerHash = '';
        driverPinHash = '';
        for (const key of ['DATABASE_URL', 'SEED_CARETAKER_PASSWORD', 'SEED_DRIVER_PHONE', 'SEED_DRIVER_PIN', 'SEED_DRIVER_BUS_NUMBER']) {
            process.env[key] = '';
        }
    }
}

if (require.main === module) {
    seedAccounts().catch((error) => {
        console.error(error.message.startsWith('Missing required environment variable:') ||
            error.message.startsWith('SEED_')
            ? error.message
            : `Account seed stopped (${safeDatabaseErrorCode(error)}).`);
        process.exitCode = 1;
    });
}

module.exports = { readConfiguration, seedAccounts };
