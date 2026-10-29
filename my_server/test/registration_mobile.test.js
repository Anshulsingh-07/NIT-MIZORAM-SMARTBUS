'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const bcrypt = require('bcryptjs');
const express = require('express');
const { createRegistrationMobileRouter } = require('../registration_mobile');
const { createStudentRegistrationRouter } = require('../student_registration');

const studentEmail = 'bt24zz123@nitmz.ac.in';
const registrationBody = (overrides = {}) => ({
    name: 'Test Student',
    email: studentEmail,
    password: 'Pass-word-123',
    confirmPassword: 'Pass-word-123',
    hostelId: 'BH1',
    ...overrides,
});

async function createHarness({ duplicate = false, limiterStatus } = {}) {
    let insertValues = null;
    let rateLimitHits = 0;
    const statements = [];
    const client = {
        async query(sql, values) {
            statements.push(sql);
            if (sql.startsWith('SELECT id FROM users')) {
                return { rows: duplicate ? [{ id: 'existing-user' }] : [] };
            }
            if (sql.startsWith('INSERT INTO users')) insertValues = values;
            return { rows: [] };
        },
        release() {},
    };
    const pool = { connect: async () => client };
    const app = express();
    app.use(express.json());
    app.use('/api/auth/registration-mobile', createRegistrationMobileRouter());
    app.use('/api/auth', createStudentRegistrationRouter({
        pool,
        rateLimiter: (_req, res, next) => {
            rateLimitHits++;
            if (limiterStatus) return res.status(limiterStatus).json({ error: 'Rate limited' });
            next();
        },
        hostels: [{ id: 'BH1' }, { id: 'GH1' }],
        emailPattern: /^bt\d{2}[a-z]{2}\d{3}@nitmz\.ac\.in$/i,
        createToken: async () => 'test-session-token',
        makeId: (prefix) => `${prefix}test123`,
        logger: { error() {} },
    }));
    const server = app.listen(0, '127.0.0.1');
    await once(server, 'listening');
    return {
        statements,
        get insertValues() { return insertValues; },
        get rateLimitHits() { return rateLimitHits; },
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
