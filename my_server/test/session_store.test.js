'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createSessionStore, hashSessionToken } = require('../session_store');

function fakePool() {
    const calls = [];
    return {
        calls,
        async query(text, params) {
            calls.push({ text, params });
            if (text.includes('SELECT user_id')) return { rows: [{ userId: 'user-1', role: 'student' }] };
            return { rows: [], rowCount: 1 };
        },
    };
}

test('session token hash is stable and does not contain the raw token', () => {
    const token = 'opaque-session-token';
    const hash = hashSessionToken(token);
    assert.match(hash, /^[a-f0-9]{64}$/);
    assert.notEqual(hash, token);
});

test('session store sends only the token hash to Postgres', async () => {
    const pool = fakePool();
    const store = createSessionStore(() => pool);
    const token = 'opaque-session-token';

    await store.create(token, { id: 'user-1', role: 'student' }, new Date());
    const session = await store.findByToken(token);
    await store.revoke(token);

    assert.equal(session.userId, 'user-1');
    assert.equal(pool.calls[0].params[0], hashSessionToken(token));
    assert.equal(pool.calls[0].params.includes(token), false);
    assert.equal(pool.calls[1].params[0], hashSessionToken(token));
    assert.equal(pool.calls.at(-1).params[0], hashSessionToken(token));
});