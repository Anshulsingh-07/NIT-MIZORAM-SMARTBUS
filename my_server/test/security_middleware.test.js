'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.CORS_ORIGINS = 'https://app.example.test';
const { app } = require('../server');

async function withServer(callback) {
    const server = app.listen(0, '127.0.0.1');
    await new Promise((resolve) => server.once('listening', resolve));
    try {
        const address = server.address();
        await callback(`http://127.0.0.1:${address.port}`);
    } finally {
        await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
}

test('CORS reflects only configured origins and allows requests without Origin', async () => {
    await withServer(async (baseUrl) => {
        const allowed = await fetch(`${baseUrl}/`, { headers: { Origin: 'https://app.example.test' } });
        assert.equal(allowed.status, 200);
        assert.equal(allowed.headers.get('access-control-allow-origin'), 'https://app.example.test');

        const denied = await fetch(`${baseUrl}/`, { headers: { Origin: 'https://other.example.test' } });
        assert.equal(denied.status, 403);
        assert.equal((await denied.json()).code, 'ORIGIN_NOT_ALLOWED');
        assert.equal(denied.headers.get('access-control-allow-origin'), null);

        const native = await fetch(`${baseUrl}/`);
        assert.equal(native.status, 200);
        assert.equal(native.headers.get('access-control-allow-origin'), null);
    });
});

test('Helmet headers are present and reset page retains its custom CSP', async () => {
    await withServer(async (baseUrl) => {
        const root = await fetch(`${baseUrl}/`);
        assert.equal(root.headers.get('x-content-type-options'), 'nosniff');
        assert.ok(root.headers.get('strict-transport-security'));

        const resetPage = await fetch(`${baseUrl}/reset-password`);
        assert.match(resetPage.headers.get('content-security-policy'), /default-src 'none'/);
    });
});

test('latest location requires a session and unused legacy location route is removed', async () => {
    await withServer(async (baseUrl) => {
        const latest = await fetch(`${baseUrl}/api/location/latest`);
        assert.equal(latest.status, 401);

        const legacy = await fetch(`${baseUrl}/get-location`);
        assert.equal(legacy.status, 404);
    });
});
