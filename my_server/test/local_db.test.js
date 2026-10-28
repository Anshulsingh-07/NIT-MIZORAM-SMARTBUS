'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { assertLocalDatabaseConfig } = require('../scripts/local-db');

const KEYS = ['NODE_ENV', 'DATABASE_URL', 'DB_HOST', 'DB_PORT', 'DB_NAME', 'DB_USER', 'DB_PASSWORD'];

function withLocalEnvironment(callback) {
    const previous = Object.fromEntries(KEYS.map((key) => [key, process.env[key]]));
    Object.assign(process.env, {
        NODE_ENV: 'development',
        DB_HOST: '127.0.0.1',
        DB_PORT: '5433',
        DB_NAME: 'smartbus_local',
        DB_USER: 'test-user',
        DB_PASSWORD: 'test-only-password',
    });
    delete process.env.DATABASE_URL;
    try {
        callback();
    } finally {
        for (const key of KEYS) {
            if (previous[key] === undefined) delete process.env[key];
            else process.env[key] = previous[key];
        }
    }
}

test('local database guard accepts only the isolated loopback database', () => {
    withLocalEnvironment(() => assert.doesNotThrow(assertLocalDatabaseConfig));
});

test('local database guard refuses Supabase hosts and DATABASE_URL', () => {
    withLocalEnvironment(() => {
        process.env.DB_HOST = 'aws-0-ap-southeast-2.pooler.supabase.com';
        assert.throws(assertLocalDatabaseConfig, /loopback/);
        process.env.DB_HOST = '127.0.0.1';
        process.env.DATABASE_URL = 'postgresql://invalid-placeholder';
        assert.throws(assertLocalDatabaseConfig, /no DATABASE_URL/);
    });
});