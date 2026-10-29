'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { mailProvider, mailConfigurationIssue, parseSender, parseAppsScriptUrl, sendMail } = require('../mailer');

const message = {
    to: 'user@example.com',
    subject: 'Reset password',
    text: 'Reset link',
    html: '<p>Reset link</p>',
};

function fakeFetch(response = { ok: true, status: 202 }) {
    const calls = [];
    const fetchImpl = async (...args) => {
        calls.push(args);
        return {
            ...response,
            text: async () => response.body || '',
        };
    };
    return { calls, fetchImpl };
}

test('mailProvider selects Brevo before Resend and requires MAIL_FROM', () => {
    assert.equal(mailProvider({ BREVO_API_KEY: 'brevo', RESEND_API_KEY: 'resend', MAIL_FROM: 'a@example.com' }), 'brevo');
    assert.equal(mailProvider({ RESEND_API_KEY: 'resend', MAIL_FROM: 'a@example.com' }), 'resend');
    assert.equal(mailProvider({ BREVO_API_KEY: 'brevo' }), null);
});

test('mailProvider and configuration validation support Apps Script without MAIL_FROM', () => {
    const env = {
        MAIL_PROVIDER: 'apps_script',
        APPS_SCRIPT_URL: 'https://script.google.com/macros/s/deployment123/exec',
        MAIL_SECRET: 'test-secret',
    };
    assert.equal(mailProvider(env), 'apps_script');
    assert.equal(mailConfigurationIssue(env), null);
    assert.equal(mailConfigurationIssue({ MAIL_PROVIDER: 'apps_script', MAIL_SECRET: 'test-secret' }), 'EMAIL_PROVIDER_CREDENTIALS_UNAVAILABLE');
    assert.equal(mailConfigurationIssue({ MAIL_PROVIDER: 'apps_script', APPS_SCRIPT_URL: env.APPS_SCRIPT_URL }), 'EMAIL_PROVIDER_CREDENTIALS_UNAVAILABLE');
    assert.equal(mailConfigurationIssue({ ...env, APPS_SCRIPT_URL: 'https://evil.example/exec' }), 'EMAIL_PROVIDER_CONFIGURATION_INVALID');
    assert.equal(mailProvider({ MAIL_PROVIDER: 'unknown', RESEND_API_KEY: 'key', MAIL_FROM: 'bus@example.com' }), null);
});

test('parseAppsScriptUrl accepts only HTTPS Google Apps Script deployments', () => {
    assert.equal(parseAppsScriptUrl('https://script.google.com/macros/s/deployment-123/exec').hostname, 'script.google.com');
    for (const url of [
        'http://script.google.com/macros/s/deployment/exec',
        'https://evil.example/macros/s/deployment/exec',
        'https://script.google.com/macros/s/deployment/dev',
        'https://user:pass@script.google.com/macros/s/deployment/exec',
    ]) assert.throws(() => parseAppsScriptUrl(url), /Invalid Apps Script deployment URL/);
});

test('mail configuration issues use fixed codes without exposing configuration values', () => {
    assert.equal(mailConfigurationIssue({}), 'MAIL_FROM_UNAVAILABLE');
    assert.equal(mailConfigurationIssue({ MAIL_FROM: 'not-an-address' }), 'MAIL_FROM_INVALID');
    assert.equal(mailConfigurationIssue({ MAIL_FROM: 'bus@example.test' }), 'EMAIL_PROVIDER_CREDENTIALS_UNAVAILABLE');
    assert.equal(mailConfigurationIssue({ MAIL_FROM: 'bus@example.test', BREVO_API_KEY: 'synthetic' }), null);
});

test('parseSender accepts bare addresses and display names', () => {
    assert.deepEqual(parseSender('alerts@example.com'), { name: 'alerts', email: 'alerts@example.com' });
    assert.deepEqual(parseSender('Campus Bus <alerts@example.com>'), { name: 'Campus Bus', email: 'alerts@example.com' });
    assert.throws(() => parseSender('not an address'), /MAIL_FROM/);
});

test('sendMail sends Brevo HTTPS payload and API key', async () => {
    const { calls, fetchImpl } = fakeFetch();
    await sendMail(message, {
        env: { BREVO_API_KEY: 'secret', MAIL_FROM: 'Campus Bus <bus@example.com>' },
        fetchImpl,
    });
    assert.equal(calls[0][0], 'https://api.brevo.com/v3/smtp/email');
    assert.equal(calls[0][1].headers['api-key'], 'secret');
    assert.deepEqual(JSON.parse(calls[0][1].body), {
        sender: { name: 'Campus Bus', email: 'bus@example.com' },
        to: [{ email: message.to }],
        subject: message.subject,
        textContent: message.text,
        htmlContent: message.html,
    });
});

test('sendMail sends Resend HTTPS payload and bearer token', async () => {
    const { calls, fetchImpl } = fakeFetch();
    await sendMail(message, {
        env: { RESEND_API_KEY: 'secret', MAIL_FROM: 'Campus Bus <bus@example.com>' },
        fetchImpl,
    });
    assert.equal(calls[0][0], 'https://api.resend.com/emails');
    assert.equal(calls[0][1].headers.authorization, 'Bearer secret');
    assert.deepEqual(JSON.parse(calls[0][1].body), {
        from: 'Campus Bus <bus@example.com>',
        to: [message.to],
        subject: message.subject,
        text: message.text,
        html: message.html,
    });
});

test('sendMail posts password-reset link content to Apps Script and accepts OK', async () => {
    const calls = [];
    const response = {
        ok: true,
        status: 200,
        text: async () => 'OK\n',
        headers: { get: () => null },
    };
    const result = await sendMail(message, {
        env: {
            MAIL_PROVIDER: 'apps_script',
            APPS_SCRIPT_URL: 'https://script.google.com/macros/s/deployment123/exec',
            MAIL_SECRET: 'test-shared-secret',
        },
        fetchImpl: async (...args) => { calls.push(args); return response; },
    });
    assert.equal(result, response);
    assert.equal(calls.length, 1);
    assert.equal(calls[0][0], 'https://script.google.com/macros/s/deployment123/exec');
    assert.equal(calls[0][1].method, 'POST');
    assert.equal(calls[0][1].redirect, 'manual');
    assert.deepEqual(JSON.parse(calls[0][1].body), {
        secret: 'test-shared-secret', to: message.to, subject: message.subject,
        text: message.text, html: message.html,
    });
});

test('sendMail safely follows Apps Script redirects without forwarding the secret', async () => {
    const calls = [];
    const responses = [
        { ok: false, status: 302, headers: { get: () => 'https://script.googleusercontent.com/macros/echo?result=1' } },
        { ok: true, status: 200, headers: { get: () => null }, text: async () => 'OK' },
    ];
    await sendMail(message, {
        env: { MAIL_PROVIDER: 'apps_script', APPS_SCRIPT_URL: 'https://script.google.com/macros/s/deployment123/exec', MAIL_SECRET: 'test-shared-secret' },
        fetchImpl: async (...args) => { calls.push(args); return responses.shift(); },
    });
    assert.equal(calls.length, 2);
    assert.equal(calls[1][1].method, 'GET');
    assert.equal('headers' in calls[1][1], false);
    assert.equal('body' in calls[1][1], false);
});

test('sendMail rejects untrusted redirects, HTTP errors, HTML responses, and unauthorized responses generically', async () => {
    const env = { MAIL_PROVIDER: 'apps_script', APPS_SCRIPT_URL: 'https://script.google.com/macros/s/deployment123/exec', MAIL_SECRET: 'sensitive-test-secret' };
    const redirectFetch = async () => ({ ok: false, status: 302, headers: { get: () => 'https://evil.example/collect' } });
    await assert.rejects(sendMail(message, { env, fetchImpl: redirectFetch }), /apps_script mail delivery failed/);
    for (const response of [
        { ok: false, status: 403, headers: { get: () => null }, text: async () => 'sensitive-test-secret' },
        { ok: true, status: 200, headers: { get: () => null }, text: async () => '<html>Google authorization required</html>' },
        { ok: true, status: 200, headers: { get: () => null }, text: async () => 'ERROR: unauthorized' },
    ]) {
        await assert.rejects(sendMail(message, { env, fetchImpl: async () => response }), (error) => {
            assert.equal(error.message, 'apps_script mail delivery failed');
            assert.equal(error.message.includes('sensitive-test-secret'), false);
            return true;
        });
    }
});

test('sendMail times out Apps Script requests without exposing request data', async () => {
    await assert.rejects(sendMail(message, {
        env: { MAIL_PROVIDER: 'apps_script', APPS_SCRIPT_URL: 'https://script.google.com/macros/s/deployment123/exec', MAIL_SECRET: 'sensitive-test-secret' },
        timeoutMs: 5,
        fetchImpl: (_url, options) => new Promise((_, reject) => options.signal.addEventListener('abort', () => {
            const error = new Error('aborted');
            error.name = 'AbortError';
            reject(error);
        }, { once: true })),
    }), /apps_script mail request timed out/);
});

test('sendMail rejects missing configuration and non-2xx responses', async () => {
    await assert.rejects(sendMail(message, { env: {}, fetchImpl: async () => ({ ok: true }) }), /Configure MAIL_FROM/);
    const { fetchImpl } = fakeFetch({ ok: false, status: 401, body: 'unauthorized' });
    await assert.rejects(
        sendMail(message, { env: { BREVO_API_KEY: 'secret', MAIL_FROM: 'bus@example.com' }, fetchImpl }),
        /brevo mail request failed \(401\)/
    );
});

test('sendMail aborts a provider request that exceeds its timeout', async () => {
    await assert.rejects(sendMail(message, {
        env: { RESEND_API_KEY: 'secret', MAIL_FROM: 'bus@example.com' },
        timeoutMs: 5,
        fetchImpl: (_url, options) => new Promise((_, reject) => {
            options.signal.addEventListener('abort', () => {
                const error = new Error('request aborted');
                error.name = 'TimeoutError';
                reject(error);
            }, { once: true });
        }),
    }), /resend mail request timed out/);
});
