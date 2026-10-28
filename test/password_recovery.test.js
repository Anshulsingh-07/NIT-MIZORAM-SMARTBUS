'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const bcrypt = require('bcryptjs');
const express = require('express');
const { canAuthenticateUser } = require('../auth_credentials');
const {
    createPasswordRecoveryRouter,
    digest,
    hashOtp,
    normalizeMobile,
} = require('../password_recovery');
const { sendSms, smsProvider } = require('../sms');

const OTP_SECRET = 'unit-test-password-reset-secret-long-enough';
const GENERIC = 'If an account exists for these details, recovery instructions will be sent.';

function createMemoryStore(now, users) {
    const resets = [];
    const otps = [];
    return {
        resets,
        otps,
        cooldownChecks: 0,
        async cleanupExpired() {
            for (let index = resets.length - 1; index >= 0; index--) {
                if (resets[index].expiresAt <= now() || resets[index].usedAt) resets.splice(index, 1);
            }
            for (let index = otps.length - 1; index >= 0; index--) {
                if (otps[index].expiresAt <= now() || otps[index].usedAt) otps.splice(index, 1);
            }
        },
        async findUserByEmail(email) {
            return users.find((user) => user.email.toLowerCase() === email) || null;
        },
        async findUserByVerifiedPhone(phone) {
            return users.find((user) => user.recoveryPhone === phone && user.phoneVerified) || null;
        },
        async createEmailReset(userId, tokenHash, expiresAt) {
            for (let index = resets.length - 1; index >= 0; index--) {
                if (resets[index].userId === userId) resets.splice(index, 1);
            }
            resets.push({ userId, tokenHash, expiresAt: expiresAt.getTime(), usedAt: null });
        },
        async deleteResetToken(tokenHash) {
            const index = resets.findIndex((reset) => reset.tokenHash === tokenHash);
            if (index >= 0) resets.splice(index, 1);
        },
        async createOtpIfCooldownElapsed(userId, otpHash, expiresAt, cooldownMs) {
            this.cooldownChecks++;
            const latest = otps
                .filter((otp) => otp.userId === userId)
                .sort((left, right) => right.createdAt - left.createdAt)[0];
            if (latest && now() - latest.createdAt < cooldownMs) return false;
            for (const otp of otps) {
                if (otp.userId === userId && !otp.usedAt) otp.usedAt = now();
            }
            otps.push({
                userId,
                otpHash,
                expiresAt: expiresAt.getTime(),
                attempts: 0,
                usedAt: null,
                createdAt: now(),
            });
            return true;
        },
        async invalidateOtps(userId) {
            for (const otp of otps) {
                if (otp.userId === userId && !otp.usedAt) otp.usedAt = now();
            }
        },
        async verifyOtpAndCreateReset(userId, candidateHash, resetTokenHash, expiresAt) {
            const otp = otps
                .filter((entry) => entry.userId === userId && !entry.usedAt && entry.expiresAt > now())
                .sort((left, right) => right.createdAt - left.createdAt)[0];
            if (!otp || otp.attempts >= 5) return false;
            const stored = Buffer.from(otp.otpHash, 'hex');
            const submitted = Buffer.from(candidateHash, 'hex');
            const matches = stored.length === submitted.length && crypto.timingSafeEqual(stored, submitted);
            if (!matches) {
                otp.attempts++;
                if (otp.attempts >= 5) otp.usedAt = now();
                return false;
            }
            otp.usedAt = now();
            for (let index = resets.length - 1; index >= 0; index--) {
                if (resets[index].userId === userId) resets.splice(index, 1);
            }
            resets.push({ userId, tokenHash: resetTokenHash, expiresAt: expiresAt.getTime(), usedAt: null });
            return true;
        },
        async consumeResetTokenAndUpdatePassword(tokenHash, passwordHash) {
            const reset = resets.find(
                (entry) => entry.tokenHash === tokenHash && !entry.usedAt && entry.expiresAt > now(),
            );
            if (!reset) return null;
            reset.usedAt = now();
            const user = users.find((entry) => entry.id === reset.userId);
            if (!user) return null;
            user.passwordHash = passwordHash;
            user.mustChangePassword = false;
            for (let index = resets.length - 1; index >= 0; index--) {
                if (resets[index].userId === user.id) resets.splice(index, 1);
            }
            await this.invalidateOtps(user.id);
            return user.id;
        },
    };
}

async function waitFor(predicate) {
    const deadline = Date.now() + 2000;
    while (!predicate()) {
        if (Date.now() >= deadline) throw new Error('Timed out waiting for recovery side effect');
        await new Promise((resolve) => setTimeout(resolve, 5));
    }
}

async function createHarness(options = {}) {
    let currentTime = options.startTime ?? Date.now();
    const users = options.users || [{
        id: 'caretaker-bh1',
        role: 'caretaker',
        email: 'caretaker-bh1@nitmz.ac.in',
        recoveryEmail: 'unverified-alternate@example.com',
        recoveryPhone: '+919876543210',
        phoneVerified: true,
        passwordHash: await bcrypt.hash('Old-password-123', 4),
        mustChangePassword: true,
    }];
    const store = options.store || createMemoryStore(() => currentTime, users);
    const mails = [];
    const messages = [];
    const sessions = new Map([['existing-session', { userId: users[0].id }]]);
    const app = express();
    app.use(express.json());
    app.use('/api/auth', createPasswordRecoveryRouter({
        store,
        sessions,
        emailConfigured: () => options.emailConfigured ?? true,
        sendMail: async (message) => {
            mails.push(message);
            if (options.mailFailure) throw new Error('provider response included sensitive data');
        },
        smsConfigured: () => options.smsConfigured ?? true,
        sendSms: async (to, body) => {
            messages.push({ to, body });
            if (options.smsFailure) throw new Error('provider response included sensitive data');
        },
        otpSecret: () => OTP_SECRET,
        baseUrl: () => options.baseUrl || 'https://bus.example.test',
        production: true,
        backgroundWorkTimeoutMs: options.backgroundWorkTimeoutMs,
        clock: () => currentTime,
        logger: {
            warn: (message) => options.logs?.push(message),
            error: (message) => options.logs?.push(message),
        },
    }));
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    const address = server.address();
    return {
        users,
        store,
        mails,
        messages,
        sessions,
        setTime: (value) => { currentTime = value; },
        request: async (path, body) => {
            const response = await fetch(`http://127.0.0.1:${address.port}/api/auth/${path}`, {
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

test('normalizes Indian mobile numbers and rejects ambiguous input', () => {
    assert.equal(normalizeMobile('98765 43210'), '+919876543210');
    assert.equal(normalizeMobile('+91-98765-43210'), '+919876543210');
    assert.equal(normalizeMobile('1234567890'), null);
});

test('caretaker login accepts its bcrypt password and assigned hostel only', async () => {
    const caretaker = {
        id: 'caretaker-bh1',
        role: 'caretaker',
        hostel_id: 'BH1',
        password: await bcrypt.hash('Caretaker-test-password', 4),
    };
    const hostels = [{ id: 'BH1' }, { id: 'GH1' }];

    assert.equal(await canAuthenticateUser(caretaker, 'Caretaker-test-password', hostels), true);
    assert.equal(await canAuthenticateUser(caretaker, 'wrong-password', hostels), false);
    assert.equal(await canAuthenticateUser({ ...caretaker, hostel_id: 'UNKNOWN' }, 'Caretaker-test-password', hostels), false);
    assert.equal(await canAuthenticateUser({ ...caretaker, password: 'plaintext' }, 'plaintext', hostels), false);
});

test('email recovery gives a generic response and sends a hashed 15-minute token to the registered email', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());

    const known = await harness.request('forgot-password', {
        method: 'email',
        email: 'CARETAKER-BH1@NITMZ.AC.IN',
    });
    const unknown = await harness.request('forgot-password', {
        method: 'email',
        email: 'unknown@nitmz.ac.in',
    });
    await waitFor(() => harness.mails.length === 1);
    assert.equal(known.status, 200);
    assert.equal(known.data.message, GENERIC);
    assert.deepEqual(unknown, known);
    assert.equal(harness.mails.length, 1);
    assert.equal(harness.mails[0].to, 'caretaker-bh1@nitmz.ac.in');
    assert.match(harness.mails[0].text, /expires in 15 minutes/);

    const token = new URL(harness.mails[0].text.match(/https:\/\/\S+/)[0]).hash.slice('#token='.length);
    assert.match(token, /^[a-f0-9]{64}$/);
    assert.equal(harness.store.resets[0].tokenHash, digest(token));
    assert.equal(harness.store.resets[0].expiresAt - Date.now() < 15 * 60 * 1000, true);
    assert.equal(JSON.stringify(known.data).includes(token), false);
});

test('email reset rejects invalid, expired, and already-used tokens; success updates password and invalidates sessions', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    await harness.request('forgot-password', { method: 'email', email: 'caretaker-bh1@nitmz.ac.in' });
    await waitFor(() => harness.mails.length === 1);
    const token = new URL(harness.mails[0].text.match(/https:\/\/\S+/)[0]).hash.slice('#token='.length);

    assert.equal((await harness.request('reset-password', { token: 'bad', newPassword: 'New-password-456' })).status, 400);
    const success = await harness.request('reset-password', { token, newPassword: 'New-password-456' });
    assert.equal(success.status, 200);
    assert.match(success.data.message, /reset successfully/);
    assert.equal(await bcrypt.compare('New-password-456', harness.users[0].passwordHash), true);
    assert.equal(await bcrypt.compare('Old-password-123', harness.users[0].passwordHash), false);
    assert.equal(harness.users[0].role, 'caretaker');
    assert.equal(harness.users[0].mustChangePassword, false);
    assert.equal(harness.sessions.size, 0);
    assert.equal((await harness.request('reset-password', { token, newPassword: 'Newer-password-789' })).status, 400);

    const expiredHarness = await createHarness();
    t.after(() => expiredHarness.close());
    await expiredHarness.request('forgot-password', {
        method: 'email',
        email: 'caretaker-bh1@nitmz.ac.in',
    });
    await waitFor(() => expiredHarness.mails.length === 1);
    const expiredToken = new URL(expiredHarness.mails[0].text.match(/https:\/\/\S+/)[0]).hash.slice('#token='.length);
    expiredHarness.setTime(Date.now() + 16 * 60 * 1000);
    assert.equal((await expiredHarness.request('reset-password', {
        token: expiredToken,
        newPassword: 'New-password-456',
    })).status, 400);
});

test('mobile requests require a verified number and never return the OTP', async (t) => {
    const unverified = {
        id: 'student-1',
        role: 'student',
        email: 'student@nitmz.ac.in',
        recoveryPhone: '+919111111111',
        phoneVerified: false,
        passwordHash: await bcrypt.hash('Old-password-123', 4),
    };
    const harness = await createHarness({ users: [
        unverified,
        await createHarnessUser(),
    ] });
    t.after(() => harness.close());

    const known = await harness.request('forgot-password', { method: 'mobile', mobile: '9876543210' });
    const unknown = await harness.request('forgot-password', { method: 'mobile', mobile: '9876543211' });
    const unverifiedRequest = await harness.request('forgot-password', { method: 'mobile', mobile: '9111111111' });
    await waitFor(() => harness.messages.length === 1);
    assert.equal(known.status, 200);
    assert.equal(known.data.message, GENERIC);
    assert.deepEqual(unknown, known);
    assert.deepEqual(unverifiedRequest, known);
    assert.equal(harness.messages.length, 1);
    assert.equal(harness.messages[0].to, '+919876543210');
    assert.equal(JSON.stringify(known.data).includes(harness.messages[0].body.match(/\d{6}/)[0]), false);
    assert.match(harness.store.otps[0].otpHash, /^[a-f0-9]{64}$/);
    assert.equal(harness.store.otps[0].otpHash.includes(harness.messages[0].body.match(/\d{6}/)[0]), false);
});

async function createHarnessUser() {
    return {
        id: 'caretaker-bh1',
        role: 'caretaker',
        email: 'caretaker-bh1@nitmz.ac.in',
        recoveryPhone: '+919876543210',
        phoneVerified: true,
        passwordHash: await bcrypt.hash('Old-password-123', 4),
        mustChangePassword: true,
    };
}

test('OTP verifies once, enforces resend cooldown and supports a secure password reset grant', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const requested = await harness.request('forgot-password', { method: 'mobile', mobile: '9876543210' });
    assert.equal(requested.data.message, GENERIC);
    await waitFor(() => harness.messages.length === 1);
    const otp = harness.messages[0].body.match(/\d{6}/)[0];

    await harness.request('resend-otp', { mobile: '9876543210' });
    await waitFor(() => harness.store.cooldownChecks === 2);
    assert.equal(harness.messages.length, 1);
    harness.setTime(Date.now() + 60 * 1000);
    await harness.request('resend-otp', { mobile: '9876543210' });
    await waitFor(() => harness.messages.length === 2);
    assert.equal(harness.messages.length, 2);

    const replacementOtp = harness.messages[1].body.match(/\d{6}/)[0];
    assert.equal((await harness.request('verify-otp', { mobile: '9876543210', otp })).status, 400);
    const verified = await harness.request('verify-otp', {
        mobile: '9876543210',
        otp: replacementOtp,
    });
    assert.equal(verified.status, 200);
    assert.match(verified.data.resetToken, /^[a-f0-9]{64}$/);
    assert.equal(harness.store.resets[0].tokenHash, digest(verified.data.resetToken));
    assert.equal((await harness.request('verify-otp', {
        mobile: '9876543210',
        otp: replacementOtp,
    })).status, 400);

    const reset = await harness.request('reset-password', {
        token: verified.data.resetToken,
        newPassword: 'New-password-456',
    });
    assert.equal(reset.status, 200);
    assert.equal(await bcrypt.compare('New-password-456', harness.users[0].passwordHash), true);
    assert.equal(harness.users[0].role, 'caretaker');
});

test('OTP expires after five minutes and locks after five incorrect attempts', async (t) => {
    const expiredHarness = await createHarness();
    t.after(() => expiredHarness.close());
    await expiredHarness.request('forgot-password', { method: 'mobile', mobile: '9876543210' });
    await waitFor(() => expiredHarness.messages.length === 1);
    const expiredOtp = expiredHarness.messages[0].body.match(/\d{6}/)[0];
    expiredHarness.setTime(Date.now() + 5 * 60 * 1000 + 1);
    assert.equal((await expiredHarness.request('verify-otp', { mobile: '9876543210', otp: expiredOtp })).status, 400);

    const attemptsHarness = await createHarness();
    t.after(() => attemptsHarness.close());
    await attemptsHarness.request('forgot-password', { method: 'mobile', mobile: '9876543210' });
    await waitFor(() => attemptsHarness.messages.length === 1);
    const actualOtp = attemptsHarness.messages[0].body.match(/\d{6}/)[0];
    for (let attempt = 0; attempt < 5; attempt++) {
        assert.equal((await attemptsHarness.request('verify-otp', {
            mobile: '9876543210',
            otp: actualOtp === '000000' ? '000001' : '000000',
        })).status, 400);
    }
    assert.equal((await attemptsHarness.request('verify-otp', { mobile: '9876543210', otp: actualOtp })).status, 400);
});

test('email provider failures do not reveal account existence or log recovery material', async (t) => {
    const logs = [];
    const harness = await createHarness({ mailFailure: true, logs });
    t.after(() => harness.close());
    const known = await harness.request('forgot-password', {
        method: 'email',
        email: 'caretaker-bh1@nitmz.ac.in',
    });
    const unknown = await harness.request('forgot-password', {
        method: 'email',
        email: 'unknown@nitmz.ac.in',
    });
    await waitFor(() => logs.length === 1);
    assert.deepEqual(known, unknown);
    assert.equal(known.data.message, GENERIC);
    assert.equal(harness.store.resets.length, 0);
    assert.deepEqual(logs, ['Password recovery email delivery failed']);
});

test('recovery requests are throttled by account and source IP', async (t) => {
    const accountHarness = await createHarness();
    t.after(() => accountHarness.close());
    for (let attempt = 0; attempt < 3; attempt++) {
        assert.equal((await accountHarness.request('forgot-password', {
            method: 'email',
            email: 'caretaker-bh1@nitmz.ac.in',
        })).status, 200);
    }
    assert.equal((await accountHarness.request('forgot-password', {
        method: 'email',
        email: 'caretaker-bh1@nitmz.ac.in',
    })).status, 429);

    const ipHarness = await createHarness();
    t.after(() => ipHarness.close());
    for (let attempt = 0; attempt < 10; attempt++) {
        assert.equal((await ipHarness.request('forgot-password', {
            method: 'email',
            email: `unknown-${attempt}@nitmz.ac.in`,
        })).status, 200);
    }
    assert.equal((await ipHarness.request('forgot-password', {
        method: 'email',
        email: 'unknown-extra@nitmz.ac.in',
    })).status, 429);
});

test('database lookup timeout does not delay or hang the generic HTTP response', async (t) => {
    const logs = [];
    const store = {
        cleanupExpired: async () => {},
        findUserByEmail: () => new Promise(() => {}),
    };
    const harness = await createHarness({
        store,
        backgroundWorkTimeoutMs: 20,
        logs,
    });
    t.after(() => harness.close());
    const startedAt = Date.now();
    const response = await harness.request('forgot-password', {
        method: 'email',
        email: 'caretaker-bh1@nitmz.ac.in',
    });
    assert.equal(response.status, 200);
    assert.equal(response.data.message, GENERIC);
    assert.ok(Date.now() - startedAt < 1000);
    await waitFor(() => logs.length === 1);
    assert.deepEqual(logs, ['Password recovery request could not be processed']);
});

test('simultaneous mobile recovery requests create at most one OTP', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const responses = await Promise.all([
        harness.request('forgot-password', { method: 'mobile', mobile: '9876543210' }),
        harness.request('forgot-password', { method: 'mobile', mobile: '9876543210' }),
    ]);
    await waitFor(() => harness.store.cooldownChecks === 2);
    assert.deepEqual(responses[0], responses[1]);
    assert.equal(responses[0].data.message, GENERIC);
    assert.equal(harness.messages.length, 1);
});

test('SMS configuration and provider failures do not disclose account existence or OTP values', async (t) => {
    const unavailable = await createHarness({ smsConfigured: false });
    t.after(() => unavailable.close());
    const knownUnavailable = await unavailable.request('forgot-password', {
        method: 'mobile',
        mobile: '9876543210',
    });
    const unknownUnavailable = await unavailable.request('forgot-password', {
        method: 'mobile',
        mobile: '9876543211',
    });
    assert.deepEqual(knownUnavailable, unknownUnavailable);
    assert.equal(knownUnavailable.status, 503);

    const logs = [];
    const failedDelivery = await createHarness({ smsFailure: true, logs });
    t.after(() => failedDelivery.close());
    const known = await failedDelivery.request('forgot-password', {
        method: 'mobile',
        mobile: '9876543210',
    });
    const unknown = await failedDelivery.request('forgot-password', {
        method: 'mobile',
        mobile: '9876543211',
    });
    await waitFor(() => logs.length === 1);
    assert.deepEqual(known, unknown);
    assert.equal(known.data.message, GENERIC);
    assert.equal(failedDelivery.store.otps.length, 0);
    assert.deepEqual(logs, ['Password recovery SMS delivery failed']);
    assert.equal(JSON.stringify(logs).includes(failedDelivery.messages[0].body.match(/\d{6}/)[0]), false);
});

test('Twilio adapter requires credentials and sends SMS through an injected HTTPS client', async () => {
    const env = {
        TWILIO_ACCOUNT_SID: 'AC123',
        TWILIO_AUTH_TOKEN: 'test-secret',
        TWILIO_FROM_NUMBER: '+15005550006',
    };
    const calls = [];
    const response = await sendSms('+919876543210', 'Test code 123456', {
        env,
        fetchImpl: async (...args) => {
            calls.push(args);
            return { ok: true, status: 201 };
        },
    });
    assert.equal(response.status, 201);
    assert.equal(smsProvider(env), 'twilio');
    assert.equal(calls.length, 1);
    assert.equal(calls[0][0], 'https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json');
    assert.equal(calls[0][1].headers.authorization.startsWith('Basic '), true);
    assert.equal(new URLSearchParams(calls[0][1].body).get('To'), '+919876543210');
    assert.equal(smsProvider({}), null);
    await assert.rejects(sendSms('+919876543210', 'Test', { env: {} }), /Configure Twilio/);

    await assert.rejects(sendSms('+919876543210', 'Test', {
        env,
        timeoutMs: 5,
        fetchImpl: (_url, options) => new Promise((_, reject) => {
            options.signal.addEventListener('abort', () => {
                const error = new Error('request aborted');
                error.name = 'TimeoutError';
                reject(error);
            }, { once: true });
        }),
    }), /Twilio SMS request timed out/);
});