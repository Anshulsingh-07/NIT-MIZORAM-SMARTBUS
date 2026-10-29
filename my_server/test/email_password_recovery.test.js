'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');
const express = require('express');
const { createEmailPasswordRecoveryRouter } = require('../email_password_recovery');

async function startServer({ env = {}, knownEmail = 'student@nitmz.ac.in' } = {}) {
    const state = { resets: [], sent: [] };
    const pool = {
        async query(sql, params = []) {
            if (sql.includes('SELECT id, email FROM users')) {
                return { rows: params[0] === knownEmail ? [{ id: 'user-1', email: knownEmail }] : [] };
            }
            return { rows: [] };
        },
        async connect() {
            return {
                async query(sql, params = []) {
                    if (sql.startsWith('INSERT INTO email_password_recovery_otps')) {
                        state.resets.push({ userId: params[0], otpHash: params[1] });
                    }
                    return { rows: [] };
                },
                release() {},
            };
        },
    };
    const app = express();
    app.use(express.json());
    app.use('/api/auth', createEmailPasswordRecoveryRouter({
        getPool: () => pool,
        env,
        logger: { error: (...args) => state.errors.push(args) },
        sendMail: async (message) => {
            state.sent.push(message);
        },
        emailConfigured: () => Boolean(env.MAIL_PROVIDER === 'apps_script'),
    }));
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    return {
        state,
        post: async (path, body) => {
            const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
                method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
            });
            return { status: response.status, data: await response.json() };
        },
        close: () => new Promise((resolve) => server.close(resolve)),
    };
}

async function waitFor(check) {
    for (let attempt = 0; attempt < 100; attempt++) {
        if (check()) return;
        await new Promise((resolve) => setTimeout(resolve, 5));
    }
    assert.fail('Timed out waiting for recovery mail');
}

test('email OTP request sends through configured mail adapter and returns a generic 200 response', async (t) => {
    const harness = await startServer({
        env: { MAIL_PROVIDER: 'apps_script', APPS_SCRIPT_URL: 'https://script.google.com/macros/s/test/exec', MAIL_SECRET: 'test' },
    });
    t.after(() => harness.close());
    const known = await harness.post('/api/auth/password-recovery/request', { email: ' STUDENT@NITMZ.AC.IN ' });
    const unknown = await harness.post('/api/auth/password-recovery/request', { email: 'unknown@nitmz.ac.in' });
    assert.equal(known.status, 200);
    assert.equal(known.data.message, 'If this email is registered, a code has been sent.');
    assert.deepEqual(unknown, known);
    await waitFor(() => harness.state.sent.length === 1);
    assert.equal(harness.state.sent[0].to, 'student@nitmz.ac.in');
    const otp = harness.state.sent[0].text.match(/\b\d{6}\b/)[0];
    assert.equal(await bcrypt.compare(otp, harness.state.resets[0].otpHash), true);
});

test('email OTP request returns 503 when no mail provider is configured', async (t) => {
    const harness = await startServer();
    t.after(() => harness.close());
    const response = await harness.post('/api/auth/password-recovery/request', { email: 'student@nitmz.ac.in' });
    assert.equal(response.status, 503);
});
