'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { recoveryEmailProvider, sendRecoveryEmail } = require('../recovery_email');

const fixtureMessage = { to: 'tester@example.invalid', otp: '348216' };
const appsEnv = {
    APPS_SCRIPT_URL: 'https://script.google.com/macros/s/deploymentfixture/exec',
    APPS_SCRIPT_SECRET: 'fixture-only-secret',
    RESEND_API_KEY: 'fixture-resend-key',
    MAIL_FROM: 'Campus Bus <noreply@example.invalid>',
};

function jsonResponse(payload, status = 200) {
    return {
        ok: status >= 200 && status < 300,
        status,
        headers: { get: (name) => name === 'content-type' ? 'application/json; charset=utf-8' : null },
        json: async () => payload,
    };
}

test('Apps Script is preferred when its URL and secret are configured', () => {
    assert.equal(recoveryEmailProvider(appsEnv), 'apps_script');
});

test('Apps Script recovery sends OTP in POST body and accepts JSON ok true after redirect', async () => {
    const calls = [];
    const responses = [
        { ok: false, status: 302, headers: { get: () => 'https://script.googleusercontent.com/macros/echo?fixture=1' } },
        jsonResponse({ ok: true }),
    ];
    const result = await sendRecoveryEmail(fixtureMessage, {
        env: appsEnv,
        fetchImpl: async (...args) => { calls.push(args); return responses.shift(); },
    });
    assert.equal(result.provider, 'apps_script');
    assert.equal(calls.length, 2);
    assert.equal(calls[0][1].method, 'POST');
    assert.equal(calls[0][1].redirect, 'manual');
    const body = JSON.parse(calls[0][1].body);
    assert.deepEqual(Object.keys(body).sort(), ['otp', 'secret', 'to']);
    assert.equal(body.secret === appsEnv.APPS_SCRIPT_SECRET, true);
    assert.equal(body.to === fixtureMessage.to, true);
    assert.equal(body.otp === fixtureMessage.otp, true);
    assert.equal(calls[1][1].method, 'GET');
    assert.equal('body' in calls[1][1], false);
    assert.equal('headers' in calls[1][1], false);
});

for (const providerError of ['unauthorized', 'send_failed']) {
    test(`Apps Script ${providerError} response is normalized`, async () => {
        await assert.rejects(
            sendRecoveryEmail(fixtureMessage, {
                env: appsEnv,
                fetchImpl: async () => jsonResponse({ ok: false, error: providerError }),
            }),
            (error) => error.provider === 'apps_script' && error.status === 200 && error.providerError === providerError,
        );
    });
}

test('Apps Script timeout is bounded and reported without request data', async () => {
    await assert.rejects(
        sendRecoveryEmail(fixtureMessage, {
            env: appsEnv,
            timeoutMs: 5,
            fetchImpl: (_url, options) => new Promise((_, reject) => {
                options.signal.addEventListener('abort', () => {
                    const error = new Error('aborted');
                    error.name = 'AbortError';
                    reject(error);
                }, { once: true });
            }),
        }),
        (error) => error.provider === 'apps_script' && error.providerError === 'timeout',
    );
});

test('Apps Script HTML or non-JSON response is rejected as send_failed', async () => {
    await assert.rejects(
        sendRecoveryEmail(fixtureMessage, {
            env: appsEnv,
            fetchImpl: async () => ({
                ok: true,
                status: 200,
                headers: { get: () => 'text/html' },
                text: async () => '<html>fixture</html>',
            }),
        }),
        (error) => error.providerError === 'send_failed',
    );
});

test('Resend is selected only when Apps Script variables are unset', async () => {
    assert.equal(recoveryEmailProvider({ RESEND_API_KEY: 'fixture-key' }), 'resend');
    let calledUrl = '';
    const result = await sendRecoveryEmail(fixtureMessage, {
        env: { RESEND_API_KEY: 'fixture-key', MAIL_FROM: 'noreply@example.invalid' },
        fetchImpl: async (url, options) => {
            calledUrl = url;
            assert.equal(options.method, 'POST');
            return { ok: true, status: 202 };
        },
    });
    assert.equal(result.provider, 'resend');
    assert.equal(calledUrl, 'https://api.resend.com/emails');
});

test('missing Apps Script and Resend configuration fails clearly', async () => {
    assert.equal(recoveryEmailProvider({}), null);
    await assert.rejects(sendRecoveryEmail(fixtureMessage, { env: {} }),
        (error) => error.provider === 'none' && error.providerError === 'send_failed');
});
