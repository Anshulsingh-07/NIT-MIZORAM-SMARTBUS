'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { hashLoginIdentifier, progressiveDelaySeconds } = require('../login_attempts');

test('login identifiers are one-way and domain-separated hashes', () => {
    const phoneHash = hashLoginIdentifier('driver-phone', '+911234567890');
    const ipHash = hashLoginIdentifier('client-ip', '+911234567890');

    assert.match(phoneHash, /^[a-f0-9]{64}$/);
    assert.notEqual(phoneHash, '+911234567890');
    assert.notEqual(phoneHash, ipHash);
});

test('progressive login delay doubles and caps at thirty seconds', () => {
    assert.deepEqual([1, 2, 3, 4, 5, 6, 10].map(progressiveDelaySeconds), [1, 2, 4, 8, 16, 30, 30]);
});