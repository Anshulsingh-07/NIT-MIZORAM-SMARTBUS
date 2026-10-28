'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
    assertTargetConfiguration,
    validatePasswords,
} = require('../scripts/provision-supabase-caretakers');

const targetEnvironment = {
    DB_HOST: 'aws-0-ap-southeast-2.pooler.supabase.com',
    DB_USER: 'postgres.igzurztdhdepkodyetop',
    DB_NAME: 'postgres',
    DB_PORT: '5432',
    DB_SSL: 'true',
};

function withEnvironment(values, operation) {
    const previous = new Map();
    for (const [key, value] of Object.entries(values)) {
        previous.set(key, process.env[key]);
        process.env[key] = value;
    }
    try {
        return operation();
    } finally {
        for (const [key, value] of previous) {
            if (value === undefined) delete process.env[key];
            else process.env[key] = value;
        }
    }
}

function validPasswords() {
    return {
        BH1: 'fresh-temporary-BH1-unique',
        BH2: 'fresh-temporary-BH2-unique',
        BH3: 'fresh-temporary-BH3-unique',
        BH4: 'fresh-temporary-BH4-unique',
        GH1: 'fresh-temporary-GH1-unique',
        GH2: 'fresh-temporary-GH2-unique',
    };
}

test('Supabase caretaker provisioner requires the configured Session Pooler target', () => {
    assert.doesNotThrow(() => withEnvironment(targetEnvironment, assertTargetConfiguration));
    assert.throws(
        () => withEnvironment({ ...targetEnvironment, DB_HOST: '127.0.0.1' }, assertTargetConfiguration),
        /Refusing to run/,
    );
    assert.throws(
        () => withEnvironment({ ...targetEnvironment, DB_SSL: 'false' }, assertTargetConfiguration),
        /Refusing to run/,
    );
});

test('Supabase caretaker passwords must be unique and at least 12 characters', () => {
    assert.doesNotThrow(() => validatePasswords(validPasswords()));

    const duplicate = validPasswords();
    duplicate.GH2 = duplicate.GH1;
    assert.throws(() => validatePasswords(duplicate), /must be unique/);

    const tooShort = validPasswords();
    tooShort.BH1 = 'caretaker-bh1';
    assert.throws(() => validatePasswords(tooShort), /16-128 character/);
});
