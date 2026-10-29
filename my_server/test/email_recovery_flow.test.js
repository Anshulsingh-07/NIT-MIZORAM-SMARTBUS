'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');
const express = require('express');
const { createEmailPasswordRecoveryRouter } = require('../email_password_recovery');

const registeredAddress = 'student@example.invalid';
const appsEnv = {
    APPS_SCRIPT_URL: 'https://script.google.com/macros/s/deploymentfixture/exec',
    APPS_SCRIPT_SECRET: 'fixture-only-secret',
    RESEND_API_KEY: 'fixture-resend-key',
    MAIL_FROM: 'noreply@example.invalid',
};

function createPool(known = true) {
    const state = { otp: null, sent: [], errors: [], queries: [], passwordHash: null, sessionsRevoked: false };
    const user = known ? { id: 'fixture-user', email: registeredAddress } : null;
    const pool = {
        state,
        async query(sql, params = []) {
            state.queries.push(sql.replace(/\s+/g, ' ').trim());
            if (sql.includes('SELECT id, email FROM users')) {
                return { rows: user && params[0] === registeredAddress ? [user] : [] };
            }
            if (sql.includes('UPDATE email_password_recovery_otps SET used = true WHERE user_id')) {
                if (state.otp) state.otp.used = true;
            }
            return { rows: [] };
        },
        async connect() {
            return {
                async query(sql, params = []) {
                    state.queries.push(sql.replace(/\s+/g, ' ').trim());
                    if (sql.startsWith('SELECT id FROM users')) return { rows: user ? [{ id: user.id }] : [] };
                    if (sql.includes('SELECT id FROM email_password_recovery_otps') && !sql.includes('otp_hash')) {
                        return { rows: [] };
                    }
                    if (sql.includes('SELECT id, otp_hash, attempts, used, expires_at')) {
                        return { rows: state.otp ? [{ ...state.otp }] : [] };
                    }
                    if (sql.startsWith('INSERT INTO email_password_recovery_otps')) {
                        state.otp = {
                            id: 1,
                            user_id: params[0],
                            otp_hash: params[1],
                            attempts: 0,
                            used: false,
                            expires_at: new Date(Date.now() + 10 * 60 * 1000),
                        };
                    }
                    if (sql.includes('SET attempts = attempts + 1')) {
                        state.otp.attempts += 1;
                        if (state.otp.attempts >= 5) state.otp.used = true;
                    }
                    if (sql.startsWith('UPDATE email_password_recovery_otps SET used = true WHERE id')) {
                        state.otp.used = true;
                    }
                    if (sql.startsWith('UPDATE email_password_recovery_otps SET used = true WHERE user_id')) {
                        if (state.otp) state.otp.used = true;
                    }
                    if (sql.startsWith('UPDATE users SET password = $1')) state.passwordHash = params[0];
                    if (sql.startsWith('DELETE FROM sessions')) state.sessionsRevoked = true;
                    return { rows: [] };
                },
                release() {},
            };
        },
    };
    return pool;
}

function okJson(payload = { ok: true }, status = 200) {
    return {
        ok: status >= 200 && status < 300,
        status,
        headers: { get: (name) => name === 'content-type' ? 'application/json' : null },
        json: async () => payload,
    };
}

async function startHarness({ known = true, env = appsEnv, fetchImpl } = {}) {
    const pool = createPool(known);
    const fetchCalls = [];
    const fakeFetch = fetchImpl || (async (url, options) => {
        fetchCalls.push({ url, options });
        pool.state.sent.push(JSON.parse(options.body));
        return okJson();
    });
    const app = express();
    app.use(express.json());
    const router = createEmailPasswordRecoveryRouter({
        getPool: () => pool,
        env,
        fetchImpl: fakeFetch,
        timeoutMs: 100,
        logger: { error: (...args) => pool.state.errors.push(args) },
    });
    app.use('/api/auth', router);
    for (const [path, internal] of [
        ['/forgot-password', '/forgot-password'],
        ['/password-recovery/request', '/password-recovery/request'],
        ['/request', '/request'],
        ['/password-recovery/verify', '/password-recovery/verify'],
        ['/verify', '/password-recovery/verify'],
    ]) {
        app.post(path, (req, res, next) => { req.url = internal; router(req, res, next); });
    }
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    return {
        pool,
        fetchCalls,
        post: async (path, body) => {
            const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify(body),
            });
            return { status: response.status, data: await response.json() };
        },
        close: () => new Promise((resolve) => server.close(resolve)),
    };
}

async function waitFor(check) {
    for (let attempt = 0; attempt < 100; attempt += 1) {
        if (check()) return;
        await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.fail('Recovery background work did not complete');
}

async function issueCode(harness, path = '/api/auth/forgot-password') {
    const response = await harness.post(path, { method: 'email', email: registeredAddress });
    assert.equal(response.status, 202);
    await waitFor(() => Boolean(harness.pool.state.otp));
    return harness.pool.state.sent[0].otp;
}

test('all request aliases use Apps Script and never call Resend', async (t) => {
    const paths = [
        '/api/auth/forgot-password',
        '/api/auth/password-recovery/request',
        '/api/auth/request',
        '/api/auth/resend-otp',
        '/forgot-password',
        '/password-recovery/request',
        '/request',
    ];
    for (const path of paths) {
        const harness = await startHarness();
        t.after(() => harness.close());
        const result = await harness.post(path, { method: 'email', email: registeredAddress });
        assert.equal(result.status, 202);
        try {
            await waitFor(() => harness.fetchCalls.length === 1);
        } catch (_) {
            assert.fail(`Recovery mail sender was not reached; logged failures: ${harness.pool.state.errors.map((entry) => entry.join(':')).join(',')}; queries: ${harness.pool.state.queries.join('|')}`);
        }
        assert.match(harness.fetchCalls[0].url, /^https:\/\/script\.google\.com\//);
        assert.equal(harness.fetchCalls[0].options.method, 'POST');
        assert.equal(harness.fetchCalls[0].options.headers.authorization, undefined);
        assert.equal(harness.pool.state.sent[0].otp.length, 6);
        assert.equal(harness.pool.state.otp.otp_hash !== harness.pool.state.sent[0].otp, true);
        assert.equal(await bcrypt.compare(harness.pool.state.sent[0].otp, harness.pool.state.otp.otp_hash), true);
    }
});

test('unknown email returns the same generic 202 and does not send mail', async (t) => {
    const knownHarness = await startHarness();
    const unknownHarness = await startHarness({ known: false });
    t.after(() => knownHarness.close());
    t.after(() => unknownHarness.close());
    const known = await knownHarness.post('/api/auth/forgot-password', { method: 'email', email: registeredAddress });
    const unknown = await unknownHarness.post('/api/auth/forgot-password', { method: 'email', email: 'unknown@example.invalid' });
    assert.equal(known.status, 202);
    assert.deepEqual(unknown, known);
    await waitFor(() => knownHarness.pool.state.sent.length === 1);
    assert.equal(unknownHarness.pool.state.sent.length, 0);
});

test('request rate limit returns 429 after three requests per account', async (t) => {
    const harness = await startHarness();
    t.after(() => harness.close());
    for (let i = 0; i < 3; i += 1) {
        const result = await harness.post('/api/auth/forgot-password', { method: 'email', email: registeredAddress });
        assert.equal(result.status, 202);
    }
    const limited = await harness.post('/api/auth/forgot-password', { method: 'email', email: registeredAddress });
    assert.equal(limited.status, 429);
});

test('wrong OTP increments attempts; the fifth wrong answer locks it and the sixth is rate-limited', async (t) => {
    const harness = await startHarness();
    t.after(() => harness.close());
    const correctOtp = await issueCode(harness);
    const wrongOtp = correctOtp.startsWith('0') ? `1${correctOtp.slice(1)}` : `0${correctOtp.slice(1)}`;
    for (let attempt = 0; attempt < 5; attempt += 1) {
        const result = await harness.post('/api/auth/password-recovery/verify', {
            email: registeredAddress,
            otp: wrongOtp,
            newPassword: 'new-password-123',
        });
        if (attempt < 4) assert.equal(result.status, 400);
        else assert.equal(result.status, 429);
    }
    assert.equal(harness.pool.state.otp.attempts, 5);
    const sixth = await harness.post('/api/auth/password-recovery/verify', {
        email: registeredAddress,
        otp: wrongOtp,
        newPassword: 'new-password-123',
    });
    assert.equal(sixth.status, 429);
    assert.equal(harness.pool.state.otp.used, true);
});

test('expired OTP is rejected and marked used', async (t) => {
    const harness = await startHarness();
    t.after(() => harness.close());
    await issueCode(harness);
    harness.pool.state.otp.expires_at = new Date(Date.now() - 1000);
    const result = await harness.post('/api/auth/password-recovery/verify', {
        email: registeredAddress,
        otp: harness.pool.state.sent[0].otp,
        newPassword: 'new-password-123',
    });
    assert.equal(result.status, 400);
    assert.equal(result.data.code, 'OTP_EXPIRED');
    assert.equal(harness.pool.state.otp.used, true);
});

test('correct OTP changes password, revokes sessions, and cannot be reused', async (t) => {
    const harness = await startHarness();
    t.after(() => harness.close());
    await issueCode(harness);
    const otp = harness.pool.state.sent[0].otp;
    const result = await harness.post('/api/auth/password-recovery/verify', {
        email: registeredAddress,
        otp,
        newPassword: 'new-password-123',
    });
    assert.equal(result.status, 200);
    assert.equal(await bcrypt.compare('new-password-123', harness.pool.state.passwordHash), true);
    assert.equal(harness.pool.state.sessionsRevoked, true);
    assert.equal(harness.pool.state.otp.used, true);
    const reused = await harness.post('/api/auth/password-recovery/verify', {
        email: registeredAddress,
        otp,
        newPassword: 'another-password-123',
    });
    assert.equal(reused.status, 400);
});

test('all email verification aliases accept the OTP created by the shared request handler', async (t) => {
    const paths = [
        '/api/auth/password-recovery/verify',
        '/api/auth/verify-email-otp',
        '/api/auth/verify-otp',
        '/password-recovery/verify',
        '/verify',
    ];
    for (const path of paths) {
        const harness = await startHarness();
        t.after(() => harness.close());
        const otp = await issueCode(harness);
        const result = await harness.post(path, {
            email: registeredAddress,
            otp,
            newPassword: 'new-password-123',
        });
        assert.equal(result.status, 200);
        assert.equal(harness.pool.state.sessionsRevoked, true);
    }
});

test('provider failure logging contains only route, provider, status, and safe error field', async (t) => {
    const harness = await startHarness({
        fetchImpl: async () => okJson({ ok: false, error: 'unauthorized' }),
    });
    t.after(() => harness.close());
    await harness.post('/api/auth/forgot-password', { method: 'email', email: registeredAddress });
    await waitFor(() => harness.pool.state.errors.length === 1);
    const fields = harness.pool.state.errors[0][1];
    assert.deepEqual(Object.keys(fields).sort(), ['error', 'provider', 'route', 'status']);
    assert.equal(fields.provider, 'apps_script');
    assert.equal(fields.error, 'unauthorized');
    assert.equal(fields.route, '/api/auth/forgot-password');
});
