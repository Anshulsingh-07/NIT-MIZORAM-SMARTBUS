'use strict';

const path = require('node:path');
// This entry point is deliberately independent from any DATABASE_URL exported
// by the caller. The local database guard below permits loopback only.
delete process.env.DATABASE_URL;
require('dotenv').config({ path: path.resolve(__dirname, '..', '.env.local'), quiet: true });
// Also discard a DATABASE_URL found in the file itself; auth integration may
// use only the loopback DB_* settings checked by assertLocalDatabaseConfig.
delete process.env.DATABASE_URL;
process.env.NODE_ENV = 'development';
const { assertLocalDatabaseConfig } = require('./local-db');

try {
    assertLocalDatabaseConfig();
} catch (error) {
    console.error(`Refusing auth tests: ${error.message}`);
    process.exit(1);
}

if (String(process.env.DB_HOST || '').toLowerCase().includes('supabase')) {
    console.error('Refusing auth tests against a Supabase host.');
    process.exit(1);
}

process.env.SMARTBUS_LOCAL_INTEGRATION = '1';
process.env.LOCAL_MOCK_DELIVERY = 'true';
require('node:child_process').spawnSync(
    process.execPath,
    ['--test', 'test/local_auth.integration.test.js', 'test/password_recovery.test.js', 'test/session_store.test.js', 'test/auth_credentials.test.js'],
    { stdio: 'inherit', cwd: path.resolve(__dirname, '..'), env: process.env },
).status === 0 || process.exit(1);
