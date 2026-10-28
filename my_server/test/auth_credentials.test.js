'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const bcrypt = require('bcryptjs');
const express = require('express');
const {
    canAccessDuringPasswordChange,
    createLoginRateLimiter,
    createLoginHandler,
    createUserLookup,
} = require('../auth_credentials');

const hostels = [{ id: 'BH1' }, { id: 'GH1' }];
const caretakerPassword = 'A-test-only-temporary-password';
const caretakerHash = bcrypt.hash(caretakerPassword, 4);

function publicUser(user) {
    return {
        id: user.id,
        name: user.name,
        email: user.email,
        role: user.role,
        hostelId: user.hostel_id,
        mustChangePassword: Boolean(user.must_change_password),
    };
}

async function sendLogin({ user, body, lookupFailure = false }) {
    const issuedTokens = [];
    const requestedEmails = [];
    const app = express();
    app.use(express.json());
    app.post('/api/auth/login', createLoginHandler({
        findUserByEmail: async (email) => {
            requestedEmails.push(email);
            if (lookupFailure) throw new Error('database details must not reach clients');
            return user;
        },
        hostels,
        createToken: () => {
            issuedTokens.push('test-session-token');
            return 'test-session-token';
        },
        publicUser,
    }));

    const server = app.listen(0, '127.0.0.1');
    await once(server, 'listening');
    try {
        const address = server.address();
        const response = await fetch(`http://127.0.0.1:${address.port}/api/auth/login`, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify(body),
        });
        return {
            status: response.status,
            data: await response.json(),
            issuedTokens,
            requestedEmails,
        };
    } finally {
        await new Promise((resolve, reject) => {
            server.close((error) => error ? reject(error) : resolve());
        });
    }
}

async function caretaker(overrides = {}) {
    return {
        id: 'test-caretaker',
        name: 'Test Caretaker',
        email: 'caretaker-bh1@nitmz.ac.in',
        role: 'caretaker',
        hostel_id: 'BH1',
        password: await caretakerHash,
        must_change_password: true,
        ...overrides,
    };
}

test('account lookup matches case and surrounding whitespace in stored email', async () => {
    const calls = [];
    const lookup = createUserLookup(async (sql, params) => {
        calls.push({ sql, params });
        const storedEmail = '  CARETAKER-BH1@NITMZ.AC.IN  ';
        return storedEmail.trim().toLowerCase() === params[0].toLowerCase()
            ? [{ id: 'test-user', email: storedEmail, role: 'caretaker', hostel_id: 'BH1' }]
            : [];
    });

    const user = await lookup('caretaker-bh1@nitmz.ac.in');

    assert.equal(user.id, 'test-user');
    assert.match(calls[0].sql, /FROM users WHERE LOWER\(BTRIM\(email\)\) = LOWER\(\?\)/);
    assert.deepEqual(calls[0].params, ['caretaker-bh1@nitmz.ac.in']);
});

test('account lookup returns no user when the normalized email is absent', async () => {
    const lookup = createUserLookup(async () => []);
    assert.equal(await lookup('missing@nitmz.ac.in'), undefined);
});

test('valid caretaker login issues a session and preserves forced password change', async () => {
    const result = await sendLogin({
        user: await caretaker(),
        body: { email: ' CARETAKER-BH1@NITMZ.AC.IN ', password: caretakerPassword },
    });

    assert.equal(result.status, 200);
    assert.equal(result.data.token, 'test-session-token');
    assert.equal(result.data.user.role, 'caretaker');
    assert.equal(result.data.user.hostelId, 'BH1');
    assert.equal(result.data.mustChangePassword, true);
    assert.equal(Object.hasOwn(result.data.user, 'password'), false);
    assert.deepEqual(result.requestedEmails, ['caretaker-bh1@nitmz.ac.in']);
    assert.deepEqual(result.issuedTokens, ['test-session-token']);
});

test('incorrect caretaker password returns a generic 401 without issuing a token', async () => {
    const result = await sendLogin({
        user: await caretaker(),
        body: { email: 'caretaker-bh1@nitmz.ac.in', password: 'incorrect-test-password' },
    });

    assert.equal(result.status, 401);
    assert.deepEqual(result.data, { error: 'Invalid credentials' });
    assert.deepEqual(result.issuedTokens, []);
});

test('caretaker with an invalid hostel returns a generic 401', async () => {
    const result = await sendLogin({
        user: await caretaker({ hostel_id: 'UNKNOWN' }),
        body: { email: 'caretaker-bh1@nitmz.ac.in', password: caretakerPassword },
    });

    assert.equal(result.status, 401);
    assert.deepEqual(result.data, { error: 'Invalid credentials' });
});

test('missing caretaker account returns a generic 401', async () => {
    const result = await sendLogin({
        user: null,
        body: { email: 'caretaker-bh1@nitmz.ac.in', password: caretakerPassword },
    });

    assert.equal(result.status, 401);
    assert.deepEqual(result.data, { error: 'Invalid credentials' });
});

test('student login continues to use its own valid bcrypt account', async () => {
    const passwordHash = await bcrypt.hash('Student-test-password', 4);
    const result = await sendLogin({
        user: await caretaker({ role: 'student', hostel_id: null, password: passwordHash }),
        body: { email: 'student@nitmz.ac.in', password: 'Student-test-password' },
    });

    assert.equal(result.status, 200);
    assert.equal(result.data.user.role, 'student');
});

test('temporary-password sessions allow only profile, password change, and logout', () => {
    assert.equal(canAccessDuringPasswordChange('/api/me'), true);
    assert.equal(canAccessDuringPasswordChange('/api/auth/change-password'), true);
    assert.equal(canAccessDuringPasswordChange('/api/auth/logout'), true);
    assert.equal(canAccessDuringPasswordChange('/api/buses'), false);
});

test('login rate limiter blocks excessive attempts per IP and expires old attempts', () => {
    let now = 1000;
    const limiter = createLoginRateLimiter({ limit: 2, windowMs: 100, clock: () => now });
    const attempt = (ip) => {
        let nextCalled = false;
        let statusCode;
        let responseBody;
        const response = {
            status(code) {
                statusCode = code;
                return this;
            },
            json(body) {
                responseBody = body;
                return body;
            },
        };
        limiter({ ip }, response, () => { nextCalled = true; });
        return { nextCalled, statusCode, responseBody };
    };

    assert.equal(attempt('192.0.2.1').nextCalled, true);
    assert.equal(attempt('192.0.2.1').nextCalled, true);
    assert.deepEqual(attempt('192.0.2.1'), {
        nextCalled: false,
        statusCode: 429,
        responseBody: { error: 'Too many login attempts. Try again later.' },
    });
    assert.equal(attempt('192.0.2.2').nextCalled, true);
    now += 101;
    assert.equal(attempt('192.0.2.1').nextCalled, true);
});

test('database lookup failures do not expose internal details', async () => {
    const result = await sendLogin({
        user: null,
        lookupFailure: true,
        body: { email: 'caretaker-bh1@nitmz.ac.in', password: caretakerPassword },
    });

    assert.equal(result.status, 500);
    assert.equal(result.data.error, 'Internal server error');
    assert.match(result.data.errorId, /^[a-f0-9]{8}$/);
});
