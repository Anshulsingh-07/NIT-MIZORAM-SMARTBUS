'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '..', 'apps-script', 'Code.gs'), 'utf8');

function createAppsScript({ secret = 'shared-secret' } = {}) {
    const sent = [];
    const context = {
        PropertiesService: {
            getScriptProperties: () => ({ getProperty: (key) => key === 'MAIL_SECRET' ? secret : null }),
        },
        ContentService: {
            MimeType: { TEXT: 'text/plain' },
            createTextOutput: (content) => ({
                content,
                setMimeType(value) { this.mimeType = value; return this; },
            }),
        },
        GmailApp: { sendEmail: (...args) => sent.push(args) },
    };
    vm.runInNewContext(source, context, { filename: 'Code.gs' });
    return {
        sent,
        post: (payload) => context.doPost({ postData: { contents: JSON.stringify(payload) } }),
        postRaw: (contents) => context.doPost({ postData: { contents } }),
    };
}

test('Apps Script validates the shared secret before attempting delivery', () => {
    const app = createAppsScript();
    const response = app.post({ secret: 'wrong-secret', to: 'user@example.com', otp: '123456' });
    assert.equal(response.content, 'ERROR: unauthorized');
    assert.equal(app.sent.length, 0);
});

test('Apps Script keeps compatibility with the supplied OTP test payload and never generates OTPs', () => {
    const app = createAppsScript();
    const response = app.post({ secret: 'shared-secret', to: 'user@example.com', otp: '493027' });
    assert.equal(response.content, 'OK');
    assert.equal(response.mimeType, 'text/plain');
    assert.deepEqual(app.sent, [[
        'user@example.com',
        'SmartBus password reset code',
        'Your SmartBus password reset code is 493027.',
    ]]);
});

test('Apps Script sends password-reset link content without changing the message', () => {
    const app = createAppsScript();
    const payload = {
        secret: 'shared-secret',
        to: 'user@example.com',
        subject: 'SmartBus password reset',
        text: 'Open https://bus.example.test/reset-password#token=opaque-token',
        html: '<a href="https://bus.example.test/reset-password#token=opaque-token">Reset password</a>',
    };
    assert.equal(app.post(payload).content, 'OK');
    assert.equal(app.sent.length, 1);
    assert.deepEqual(app.sent[0].slice(0, 3), [payload.to, payload.subject, payload.text]);
    assert.equal(app.sent[0][3].htmlBody, payload.html);
});

test('Apps Script rejects malformed payloads and invalid legacy OTPs without sending email', () => {
    const app = createAppsScript();
    assert.equal(app.postRaw('{malformed').content, 'ERROR: invalid request');
    assert.equal(app.post({ secret: 'shared-secret', to: 'user@example.com', otp: 'not-six-digits' }).content, 'ERROR: invalid request');
    assert.equal(app.post({ secret: 'shared-secret', to: 'invalid-address', subject: 'Subject', text: 'Body' }).content, 'ERROR: invalid request');
    assert.equal(app.sent.length, 0);
});
