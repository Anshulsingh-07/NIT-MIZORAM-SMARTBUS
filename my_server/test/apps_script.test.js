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
            getScriptProperties: () => ({ getProperty: (key) => key === 'APPS_SCRIPT_SECRET' ? secret : null }),
        },
        ContentService: {
            MimeType: { JSON: 'application/json' },
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
    assert.deepEqual(JSON.parse(response.content), { ok: false, error: 'unauthorized' });
    assert.equal(app.sent.length, 0);
});

test('Apps Script rejects requests when the configured secret is empty', () => {
    const app = createAppsScript({ secret: '' });
    const response = app.post({ secret: '', to: 'user@example.com', otp: '123456' });
    assert.deepEqual(JSON.parse(response.content), { ok: false, error: 'unauthorized' });
    assert.equal(app.sent.length, 0);
});

test('Apps Script sends only the supplied OTP and returns JSON success', () => {
    const app = createAppsScript();
    const response = app.post({ secret: 'shared-secret', to: 'user@example.com', otp: '493027' });
    assert.deepEqual(JSON.parse(response.content), { ok: true });
    assert.equal(response.mimeType, 'application/json');
    assert.equal(app.sent.length, 1);
    assert.equal(app.sent[0][0], 'user@example.com');
    assert.equal(app.sent[0][1], 'SmartBus password recovery code');
    assert.equal(app.sent[0][2].includes('expires in 10 minutes'), true);
});

test('Apps Script rejects malformed payloads and invalid legacy OTPs without sending email', () => {
    const app = createAppsScript();
    assert.deepEqual(JSON.parse(app.postRaw('{malformed').content), { ok: false, error: 'bad_to' });
    assert.deepEqual(JSON.parse(app.post({ secret: 'shared-secret', to: 'user@example.com', otp: 'not-six-digits' }).content), { ok: false, error: 'bad_otp' });
    assert.deepEqual(JSON.parse(app.post({ secret: 'shared-secret', to: 'invalid-address', otp: '123456' }).content), { ok: false, error: 'bad_to' });
    assert.equal(app.sent.length, 0);
});

test('Apps Script maps Gmail delivery exceptions to send_failed', () => {
    const app = createAppsScript();
    app.sent.push = () => { throw new Error('fixture only'); };
    const response = app.post({ secret: 'shared-secret', to: 'user@example.com', otp: '123456' });
    assert.deepEqual(JSON.parse(response.content), { ok: false, error: 'send_failed' });
});
