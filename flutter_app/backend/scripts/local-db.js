'use strict';

const { Pool } = require('pg');

function assertLocalDatabaseConfig() {
    const host = process.env.DB_HOST || '127.0.0.1';
    const database = process.env.DB_NAME || '';
    const port = Number(process.env.DB_PORT || 0);
    if (process.env.NODE_ENV !== 'development' || process.env.DATABASE_URL) {
        throw new Error('Local database scripts require NODE_ENV=development and no DATABASE_URL.');
    }
    if (!['127.0.0.1', 'localhost', '::1'].includes(host) || database !== 'smartbus_local' || port !== 5433) {
        throw new Error('Refusing database operation: expected the isolated local smartbus_local database on loopback port 5433.');
    }
    if (!process.env.DB_USER || !process.env.DB_PASSWORD) {
        throw new Error('Local PostgreSQL credentials are missing from .env.local.');
    }
}

function createLocalPool() {
    assertLocalDatabaseConfig();
    return new Pool({
        host: process.env.DB_HOST || '127.0.0.1',
        port: Number(process.env.DB_PORT || 5433),
        user: process.env.DB_USER,
        password: process.env.DB_PASSWORD,
        database: process.env.DB_NAME,
        ssl: false,
        max: 2,
        connectionTimeoutMillis: 5000,
        query_timeout: 10000,
    });
}

module.exports = { assertLocalDatabaseConfig, createLocalPool };
