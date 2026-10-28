'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { mailProvider, parseSender, sendMail } = require('../mailer');

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

test('sendMail rejects missing configuration and non-2xx responses', async () => {
    await assert.rejects(sendMail(message, { env: {}, fetchImpl: async () => ({ ok: true }) }), /Configure MAIL_FROM/);
    const { fetchImpl } = fakeFetch({ ok: false, status: 401, body: 'unauthorized' });
    await assert.rejects(
        sendMail(message, { env: { BREVO_API_KEY: 'secret', MAIL_FROM: 'bus@example.com' }, fetchImpl }),
        /brevo mail request failed \(401\): unauthorized/
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
