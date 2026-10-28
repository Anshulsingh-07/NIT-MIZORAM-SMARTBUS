'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const express = require('express');
const { createRegistrationMobileRouter } = require('../registration_mobile');

async function createHarness({ smsConfigured = true, otpSecret = 'test-only-secret-that-is-longer-than-32-characters', failStore = false, failSms = false } = {}) {
    const logs = [];
    const sends = [];
    let invalidated = false;
    const app = express();
    app.use(express.json());
    app.use('/api/auth/registration-mobile', createRegistrationMobileRouter({
        store: {
            async cleanupExpired() {
                if (failStore) throw new Error('synthetic db failure');
            },
            async createRegistrationMobileChallenge() {
                if (failStore) throw new Error('synthetic db failure');
                return true;
            },
            async invalidateRegistrationMobileChallenge() {
                if (failStore) throw new Error('synthetic db failure');
                invalidated = true;
            },
        },
        smsConfigured: () => smsConfigured,
        sendSms: async (to, message) => {
            sends.push({ to, message });
            if (failSms) throw new Error('synthetic provider failure');
        },
        otpSecret: () => otpSecret,
        logger: {
            warn: (message) => logs.push(message),
            error: (message) => logs.push(message),
        },
    }));
    const server = app.listen(0, '127.0.0.1');
    await once(server, 'listening');
    return {
        logs,
        sends,
        get invalidated() { return invalidated; },
        request: async () => {
            const response = await fetch(`http://127.0.0.1:${server.address().port}/api/auth/registration-mobile/request`, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify({ email: 'synthetic.student@unit.test', mobile: '9876543210' }),
            });
            return { status: response.status, data: await response.json() };
        },
        close: () => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
    };
}

test('registration mobile request is mounted at its prefixed path and sends through the provider', async (t) => {
    const harness = await createHarness();
    t.after(() => harness.close());
    const response = await harness.request();
    assert.equal(response.status, 200);
    assert.equal(response.data.success, true);
    assert.equal(harness.sends.length, 1);
    assert.equal(harness.sends[0].to, '+919876543210');
});

test('registration request identifies unavailable SMS provider configuration', async (t) => {
    const harness = await createHarness({ smsConfigured: false });
    t.after(() => harness.close());
    const response = await harness.request();
    assert.equal(response.status, 503);
    assert.equal(response.data.code, 'SMS_PROVIDER_UNAVAILABLE');
    assert.equal(harness.sends.length, 0);
});

test('registration request identifies an unavailable OTP secret', async (t) => {
    const harness = await createHarness({ otpSecret: 'short' });
    t.after(() => harness.close());
    const response = await harness.request();
    assert.equal(response.status, 503);
    assert.equal(response.data.code, 'OTP_SECRET_UNAVAILABLE');
});

test('registration request distinguishes database and delivery provider failures without sensitive logs', async (t) => {
    const unavailableDb = await createHarness({ failStore: true });
    t.after(() => unavailableDb.close());
    const dbResponse = await unavailableDb.request();
    assert.equal(dbResponse.status, 503);
    assert.equal(dbResponse.data.code, 'REGISTRATION_DATABASE_UNAVAILABLE');

    const unavailableProvider = await createHarness({ failSms: true });
    t.after(() => unavailableProvider.close());
    const providerResponse = await unavailableProvider.request();
    assert.equal(providerResponse.status, 503);
    assert.equal(providerResponse.data.code, 'SMS_DELIVERY_PROVIDER_FAILED');
    assert.equal(unavailableProvider.invalidated, true);
    assert.deepEqual(unavailableProvider.logs, ['Student mobile verification failed: SMS_DELIVERY_PROVIDER_FAILED']);
    assert.equal(JSON.stringify(providerResponse).includes(unavailableProvider.sends[0].message.match(/\d{6}/)[0]), false);
});
