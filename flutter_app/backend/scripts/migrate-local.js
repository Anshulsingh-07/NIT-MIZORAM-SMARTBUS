'use strict';

const fs = require('fs/promises');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '..', '.env.local'), quiet: true });
const { createLocalPool } = require('./local-db');

async function main() {
    const pool = createLocalPool();
    const client = await pool.connect();
    try {
        const schema = await fs.readFile(path.resolve(__dirname, '..', 'schema.sql'), 'utf8');
        await client.query('BEGIN');
        await client.query(schema);
        await client.query('COMMIT');
        console.log('Local SmartBus schema migration completed.');
    } catch (_) {
        await client.query('ROLLBACK').catch(() => {});
        console.error('Local schema migration failed; no partial migration was committed.');
        process.exitCode = 1;
    } finally {
        client.release();
        await pool.end();
    }
}

main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
});
