'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const path = require('node:path');
require('dotenv').config({
    path: path.resolve(__dirname, '..', '.env.local'),
    quiet: true,
});

const integrationEnabled = process.env.SMARTBUS_LOCAL_INTEGRATION === '1';

async function startLocalApi(t) {
    const { app, sessions, initializeDatabase, checkDatabaseConnection, closeDatabase } = require('../server');
    await initializeDatabase();
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    t.after(async () => {
        await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
        sessions.clear();
        await closeDatabase();
    });
    return {
        baseUrl: `http://127.0.0.1:${server.address().port}/api`,
        sessions,
        checkDatabaseConnection,
    };
}

async function requestJson(url, body) {
    const response = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(body),
    });
    return { status: response.status, data: await response.json() };
}

async function capturedSms(baseUrl) {
    const deadline = Date.now() + 3000;
    while (Date.now() < deadline) {
        const response = await fetch(`${baseUrl}/dev/delivery-outbox`);
        assert.equal(response.status, 200);
        const payload = await response.json();
        const sms = payload.messages.find((message) => message.type === 'sms');
        if (sms) return sms.message;
        await new Promise((resolve) => setTimeout(resolve, 10));
    }
    throw new Error('Timed out waiting for local mock SMS delivery.');
}

test('six seeded caretakers authenticate only for their assigned hostel', {
    skip: !integrationEnabled,
}, async (t) => {
    const host = process.env.DB_HOST || '127.0.0.1';
    const port = Number(process.env.DB_PORT || 0);
    if (process.env.NODE_ENV !== 'development' ||
        !['127.0.0.1', 'localhost', '::1'].includes(host) ||
        port !== 5433 || process.env.DB_NAME !== 'smartbus_local') {
        throw new Error('Refusing integration test outside the isolated local database.');
    }

    const passwords = JSON.parse(process.env.LOCAL_CARETAKER_PASSWORDS_JSON || '{}');
    const hostels = ['BH1', 'BH2', 'BH3', 'BH4', 'GH1', 'GH2'];
    assert.ok(hostels.every((hostel) => typeof passwords[hostel] === 'string'));

    const { baseUrl, sessions, checkDatabaseConnection } = await startLocalApi(t);
    assert.equal(await checkDatabaseConnection(), true);
    const health = await fetch(`${baseUrl}/health`);
    assert.equal(health.status, 200);
    const healthData = await health.json();
    assert.equal(healthData.status, 'ok');
    assert.equal(Object.hasOwn(healthData, 'connectionString'), false);
    for (const hostelId of hostels) {
        const email = `caretaker-${hostelId.toLowerCase()}@nitmz.ac.in`;
        const login = await fetch(`${baseUrl}/auth/login`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ email, password: passwords[hostelId] }),
        });
        assert.equal(login.status, 200, `${hostelId} login failed`);
        const payload = await login.json();
        assert.equal(payload.user.role, 'caretaker');
        assert.equal(payload.user.hostelId, hostelId);
        assert.equal(payload.user.mustChangePassword, true);
        sessions.get(payload.token).mustChangePassword = false;

        const buses = await fetch(`${baseUrl}/buses`, {
            headers: { authorization: `Bearer ${payload.token}` },
        });
        assert.equal(buses.status, 200, `${hostelId} bus query failed`);
        const assignedBuses = await buses.json();
        assert.ok(assignedBuses.every((bus) => bus.assignedHostel === hostelId));
        console.log(`Verified ${hostelId} caretaker authentication and hostel scope.`);
    }
});

test('shared caretaker mobile OTP is account-bound and one-time', {
    skip: !integrationEnabled,
}, async (t) => {
    const { baseUrl } = await startLocalApi(t);
    const phone = process.env.CARETAKER_RECOVERY_MOBILE;
    const bh1Email = 'caretaker-bh1@nitmz.ac.in';
    const bh2Email = 'caretaker-bh2@nitmz.ac.in';
    const request = await requestJson(`${baseUrl}/auth/forgot-password`, {
        method: 'mobile',
        email: bh1Email,
        mobile: phone,
    });
    assert.equal(request.status, 200);
    assert.equal(Object.hasOwn(request.data, 'otp'), false);

    const message = await capturedSms(baseUrl);
    const otp = message.match(/code is (\d{6})/)[1];
    const transferred = await requestJson(`${baseUrl}/auth/verify-otp`, {
        email: bh2Email,
        mobile: phone,
        otp,
    });
    assert.equal(transferred.status, 400);

    const verified = await requestJson(`${baseUrl}/auth/verify-otp`, {
        email: bh1Email,
        mobile: phone,
        otp,
    });
    assert.equal(verified.status, 200);
    assert.match(verified.data.resetToken, /^[a-f0-9]{64}$/);
    const reused = await requestJson(`${baseUrl}/auth/verify-otp`, {
        email: bh1Email,
        mobile: phone,
        otp,
    });
    assert.equal(reused.status, 400);
});

test('student registration requires mobile verification and matching passwords', {
    skip: !integrationEnabled,
}, async (t) => {
    const { baseUrl } = await startLocalApi(t);
    const suffix = String(crypto.randomInt(100, 1000));
    const year = String(crypto.randomInt(20, 100));
    const email = `bt${year}qa${suffix}@nitmz.ac.in`;
    const mobile = `9${crypto.randomInt(100000000, 1000000000)}`;
    const otpRequest = await requestJson(`${baseUrl}/auth/registration-mobile/request`, {
        email,
        mobile,
    });
    assert.equal(otpRequest.status, 200);
    const message = await capturedSms(baseUrl);
    const otp = message.match(/code is (\d{6})/)[1];
    const verification = await requestJson(`${baseUrl}/auth/registration-mobile/verify`, {
        email,
        mobile,
        otp,
    });
    assert.equal(verification.status, 200);

    const registration = {
        name: 'Local Integration Student',
        email,
        mobile,
        password: 'local-Test-234',
        confirmPassword: 'different-Test-234',
        hostelId: 'BH1',
        mobileVerificationToken: verification.data.verificationToken,
    };
    const mismatch = await requestJson(`${baseUrl}/auth/register`, registration);
    assert.equal(mismatch.status, 400);

    registration.confirmPassword = registration.password;
    const created = await requestJson(`${baseUrl}/auth/register`, registration);
    assert.equal(created.status, 201);
    assert.equal(created.data.user.role, 'student');
    assert.equal(created.data.user.hostelId, 'BH1');
    assert.equal(Object.hasOwn(created.data.user, 'recoveryPhone'), false);

    const login = await requestJson(`${baseUrl}/auth/login`, {
        email,
        password: registration.password,
    });
    assert.equal(login.status, 200);
    assert.equal(login.data.user.role, 'student');

    const recoveryRequest = await requestJson(`${baseUrl}/auth/forgot-password`, {
        method: 'mobile',
        email,
        mobile,
    });
    assert.equal(recoveryRequest.status, 200);
    const recoveryMessage = await capturedSms(baseUrl);
    const recoveryOtp = recoveryMessage.match(/code is (\d{6})/)[1];
    const recoveryVerification = await requestJson(`${baseUrl}/auth/verify-otp`, {
        email,
        mobile,
        otp: recoveryOtp,
    });
    assert.equal(recoveryVerification.status, 200);
    const reset = await requestJson(`${baseUrl}/auth/reset-password`, {
        token: recoveryVerification.data.resetToken,
        newPassword: 'recovered-Test-567',
    });
    assert.equal(reset.status, 200);

    const oldSession = await fetch(`${baseUrl}/me`, {
        headers: { authorization: `Bearer ${login.data.token}` },
    });
    assert.equal(oldSession.status, 401);
    const oldPassword = await requestJson(`${baseUrl}/auth/login`, {
        email,
        password: registration.password,
    });
    assert.equal(oldPassword.status, 401);
    const newPassword = await requestJson(`${baseUrl}/auth/login`, {
        email,
        password: 'recovered-Test-567',
    });
    assert.equal(newPassword.status, 200);
});
