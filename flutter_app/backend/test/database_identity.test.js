'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { fingerprintDatabaseIdentity } = require('../database_identity');

const identity = {
    database: 'postgres',
    schema: 'public',
    address: '2001:db8::1',
    port: 5432,
};

test('database identity fingerprint is stable and does not expose source values', () => {
    const fingerprint = fingerprintDatabaseIdentity(identity);

    assert.equal(fingerprint, fingerprintDatabaseIdentity({ ...identity }));
    assert.match(fingerprint, /^[a-f0-9]{16}$/);
    assert.equal(fingerprint.includes(identity.database), false);
});

test('database identity fingerprint changes when the connected database changes', () => {
    const original = fingerprintDatabaseIdentity(identity);
    const otherDatabase = fingerprintDatabaseIdentity({ ...identity, address: '2001:db8::2' });

    assert.notEqual(original, otherDatabase);
});
