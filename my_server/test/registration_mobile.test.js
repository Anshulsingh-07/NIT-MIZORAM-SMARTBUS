'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const bcrypt = require('bcryptjs');
const express = require('express');
const { createRegistrationMobileRouter } = require('../registration_mobile');
const {
    createStudentRegistrationRouter,
    mountStudentRegistrationRoute,
} = require('../student_registration');

const studentEmail = 'bt24zz123@nitmz.ac.in';
const registrationBody = (overrides = {}) => ({
    name: 'Test Student',
    email: studentEmail,
    password: 'Pass-word-123',
    confirmPassword: 'Pass-word-123',
    hostelId: 'BH1',
    ...overrides,
});

async function createHarness({
    duplicate = false,
    limiterStatus,
    errorAt,
    error,
    hashFailure = false,
    idFailure = false,
} = {}) {
    let insertValues = null;
    let rateLimitHits = 0;
    let poolConnectCalls = 0;
    const statements = [];
    const logs = [];
    const client = {
        async query(sql, values) {
            statements.push(sql);
            if ((errorAt === 'begin' && sql === 'BEGIN') ||
                (errorAt === 'select' && sql.startsWith('SELECT id FROM users')) ||
                (errorAt === 'insert' && sql.startsWith('INSERT INTO users')) ||
                (errorAt === 'commit' && sql === 'COMMIT')) throw error;
            if (sql.startsWith('SELECT id FROM users')) {
                return { rows: duplicate ? [{ id: 'existing-user' }] : [] };
            }
            if (sql.startsWith('INSERT INTO users')) insertValues = values;
            return { rows: [] };
        },
        release() {},
    };
    const pool = {
        connect: async () => {
            if (errorAt === 'connect') throw error;
            poolConnectCalls++;
            return client;
        },
    };
    const app = express();
    app.use(express.json());
    app.use('/api/auth/registration-mobile', createRegistrationMobileRouter());
    mountStudentRegistrationRoute(app, {
        getPool: () => pool,
        rateLimiter: (_req, res, next) => {
            rateLimitHits++;
            if (limiterStatus) return res.status(limiterStatus).json({ error: 'Rate limited' });
            next();
        },
        hostels: [{ id: 'BH1' }, { id: 'GH1' }],
        emailPattern: /^bt\d{2}[a-z]{2}\d{3}@nitmz\.ac\.in$/i,
        createToken: async () => 'test-session-token',
        makeId: (prefix) => {
            if (idFailure) throw new Error('synthetic id failure');
            return `${prefix}test123`;
        },
        hashPassword: async (password, cost) => {
            if (hashFailure) throw new Error('synthetic bcrypt failure');
            return bcrypt.hash(password, cost);
        },
        logger: { error: (...args) => logs.push(args) },
    });
    const server = app.listen(0, '127.0.0.1');
    await once(server, 'listening');
    return {
        statements,
        logs,
        get insertValues() { return insertValues; },
        get rateLimitHits() { return rateLimitHits; },
        get poolConnectCalls() { return poolConnectCalls; },
        request: async (path, body = {}) => {
            const response = await fetch(`http://127.0.0.1:${server.address().port}/api/auth${path}`, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify(body),
            });
            return { status: response.status, data: await response.json() };
        },
        close: () => new Promise((resolve, reject) => {
            server.close((error) => error ? reject(error) : resolve());
        }),
    };
}

test('registration creates an account directly without an OTP token', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody());
    assert.equal(response.status, 201);
    assert.equal(response.data.user.role, 'student');
    assert.equal(response.data.token, 'test-session-token');
    assert.equal(harness.insertValues[2], studentEmail);
    assert.equal(harness.insertValues[3].startsWith('$2'), true);
    assert.match(harness.insertValues[3], /^\$2[aby]\$12\$/);
    assert.equal(await bcrypt.compare('Pass-word-123', harness.insertValues[3]), true);
    assert.equal(harness.insertValues[5], studentEmail);
    assert.equal(harness.insertValues[6], null);
    assert.match(harness.statements.find((sql) => sql.startsWith('INSERT INTO users')), /recovery_phone_verified_at/);
    assert.match(harness.statements.find((sql) => sql.startsWith('INSERT INTO users')), /VALUES \(\$1, \$2, \$3, \$4, 'student', \$5, \$6, \$7, NULL, false\)/);
    assert.equal(harness.rateLimitHits, 1);
    assert.equal(harness.poolConnectCalls, 1);
});

test('registration router refuses to mount without a pool dependency', () => {
    assert.throws(() => createStudentRegistrationRouter({
        rateLimiter: (_req, _res, next) => next(),
        hostels: [],
        createToken: async () => 'unused',
        makeId: () => 'unused',
    }), /must be mounted with a PostgreSQL pool or getPool provider/);
});

test('registration rejects a case-insensitive duplicate email', async (t) => {
    const harness = await createHarness({ duplicate: true });
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody({ email: studentEmail.toUpperCase() }));
    assert.equal(response.status, 409);
    assert.match(harness.statements.find((sql) => sql.startsWith('SELECT id')), /LOWER\(email\) = LOWER\(\$1\)/);
    assert.equal(harness.insertValues, null);
});

test('registration rejects passwords shorter than eight characters', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody({ password: 'short7', confirmPassword: 'short7' }));
    assert.equal(response.status, 400);
    assert.equal(harness.insertValues, null);
});

test('registration rejects an invalid hostel', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody({ hostelId: 'UNKNOWN' }));
    assert.equal(response.status, 400);
    assert.equal(harness.insertValues, null);
});

test('blank mobile is stored as NULL', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody({ mobile: '  ' }));
    assert.equal(response.status, 201);
    assert.equal(harness.insertValues[6], null);
});

test('valid mobile is normalized to E.164 before insert', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody({ mobile: '98765 43210' }));
    assert.equal(response.status, 201);
    assert.equal(harness.insertValues[6], '+919876543210');
});

test('legacy registration OTP request and verify routes return 410', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const request = await harness.request('/registration-mobile/request', { email: studentEmail, mobile: '9876543210' });
    const verify = await harness.request('/registration-mobile/verify', { email: studentEmail, mobile: '9876543210', otp: '000000' });
    assert.equal(request.status, 410);
    assert.equal(verify.status, 410);
    assert.equal(request.data.code, 'REGISTRATION_MOBILE_OTP_REMOVED');
    assert.equal(verify.data.code, 'REGISTRATION_MOBILE_OTP_REMOVED');
});

test('registration remains subject to the configured rate limiter', async (t) => {
    const harness = await createHarness({ limiterStatus: 429 });
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody());
    assert.equal(response.status, 429);
    assert.equal(harness.rateLimitHits, 1);
    assert.equal(harness.insertValues, null);
});

function postgresError(code, properties = {}) {
    return Object.assign(new Error(properties.message || `synthetic database failure ${code}`), {
        code,
        ...properties,
    });
}

test('Postgres unique violation returns 409 Email already registered', async (t) => {
    const harness = await createHarness({ errorAt: 'insert', error: postgresError('23505') });
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody());
    assert.deepEqual(response, { status: 409, data: { error: 'Email already registered' } });
});

test('recovery phone check violation returns the E.164 guidance', async (t) => {
    const harness = await createHarness({
        errorAt: 'insert',
        error: postgresError('23514', { constraint: 'users_recovery_phone_format_check' }),
    });
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody({ mobile: '9876543210' }));
    assert.equal(response.status, 400);
    assert.equal(response.data.error, 'Enter the mobile number as +91XXXXXXXXXX or leave it blank');
});

test('foreign key violation returns 400 Invalid hostel', async (t) => {
    const harness = await createHarness({ errorAt: 'insert', error: postgresError('23503') });
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody());
    assert.deepEqual(response, { status: 400, data: { error: 'Invalid hostel' } });
});

test('missing column returns 500 and names the column in safe diagnostics', async (t) => {
    const harness = await createHarness({
        errorAt: 'insert',
        error: postgresError('42703', { message: 'column "recovery_email" of relation "users" does not exist' }),
    });
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody());
    assert.deepEqual(response, { status: 500, data: { error: 'Registration failed' } });
    assert.equal(harness.logs[0][1].column, 'recovery_email');
    assert.equal(harness.logs[0][1].code, '42703');
    assert.equal(harness.logs[0][1].step, 'insert');
});

test('only configured database connection errors return 503', async (t) => {
    for (const code of ['ECONNREFUSED', 'ETIMEDOUT', '57P01', '08006']) {
        const harness = await createHarness({ errorAt: 'connect', error: postgresError(code) });
        t.after(() => harness.close());
        const response = await harness.request('/register', registrationBody());
        assert.deepEqual(response, {
            status: 503,
            data: { error: 'Registration service temporarily unavailable' },
        });
        assert.equal(harness.logs[0][1].code, code);
        assert.equal(harness.logs[0][1].step, 'insert');
    }
});

test('unclassified database errors return 500 Registration failed', async (t) => {
    const harness = await createHarness({ errorAt: 'insert', error: postgresError('XX000') });
    t.after(() => harness.close());
    const response = await harness.request('/register', registrationBody());
    assert.deepEqual(response, { status: 500, data: { error: 'Registration failed' } });
});

test('JavaScript hash and ID generation errors are attributed to their handler steps', async (t) => {
    const hashHarness = await createHarness({ hashFailure: true });
    t.after(() => hashHarness.close());
    const hashResponse = await hashHarness.request('/register', registrationBody());
    assert.equal(hashResponse.status, 500);
    assert.equal(hashResponse.data.error, 'Registration failed');
    assert.equal(hashHarness.logs[0][1].step, 'hash');
    assert.equal(hashHarness.logs[0][1].name, 'Error');

    const idHarness = await createHarness({ idFailure: true });
    t.after(() => idHarness.close());
    const idResponse = await idHarness.request('/register', registrationBody());
    assert.equal(idResponse.status, 500);
    assert.equal(idHarness.logs[0][1].step, 'insert');
});

test('error diagnostics are limited to safe fields and truncate/redact message text', async (t) => {
    const longError = postgresError('XX000', {
        message: `${studentEmail} ${'x'.repeat(250)}`,
        constraint: 'users_email_key',
        column: 'email',
    });
    const harness = await createHarness({ errorAt: 'insert', error: longError });
    t.after(() => harness.close());
    await harness.request('/register', registrationBody());
    const [message, details] = harness.logs[0];
    assert.equal(message, 'Student registration failed');
    assert.deepEqual(Object.keys(details).sort(), ['code', 'column', 'constraint', 'message', 'name', 'step']);
    assert.equal(details.message.length <= 200, true);
    assert.equal(details.message.includes(studentEmail), false);
    assert.equal(details.step, 'insert');
});
