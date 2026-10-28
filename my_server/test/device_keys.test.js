'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createTelemetryRateLimiter, findDeviceKeyAssignment, hashDeviceKey, timingSafeSecretEqual } = require('../device_keys');

test('device keys are stored as one-way SHA-256 hashes', () => {
    const key = 'generated-device-key';
    const hash = hashDeviceKey(key);

    assert.match(hash, /^[a-f0-9]{64}$/);
    assert.notEqual(hash, key);
    assert.equal(hashDeviceKey(key), hash);
});

test('secret comparison is safe for equal and unequal lengths', () => {
    assert.equal(timingSafeSecretEqual('same', 'same'), true);
    assert.equal(timingSafeSecretEqual('short', 'a much longer secret'), false);
    assert.equal(timingSafeSecretEqual('', ''), true);
});

test('device key assignment identifies only the matching stored key', () => {
    const key = 'test-device-key';
    const rows = [
        { bus_number: 5, key_hash: hashDeviceKey('different-key') },
        { bus_number: 6, key_hash: hashDeviceKey(key) },
    ];

    assert.equal(findDeviceKeyAssignment(key, rows)?.bus_number, 6);
    assert.equal(findDeviceKeyAssignment('unknown-key', rows), null);
});

test('telemetry limiter allows the configured number of requests per IP', () => {
    let now = 1000;
    const limiter = createTelemetryRateLimiter({ limit: 2, windowMs: 1000, clock: () => now });
    const makeResponse = () => ({
        statusCode: null,
        payload: null,
        status(code) { this.statusCode = code; return this; },
        json(payload) { this.payload = payload; return this; },
    });
    const makeRequest = () => ({ ip: '192.0.2.1' });
    let nextCalls = 0;

    limiter(makeRequest(), makeResponse(), () => nextCalls++);
    limiter(makeRequest(), makeResponse(), () => nextCalls++);
    const blocked = makeResponse();
    limiter(makeRequest(), blocked, () => nextCalls++);
    assert.equal(nextCalls, 2);
    assert.equal(blocked.statusCode, 429);

    now += 1001;
    limiter(makeRequest(), makeResponse(), () => nextCalls++);
    assert.equal(nextCalls, 3);
});