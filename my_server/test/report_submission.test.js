'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { once } = require('node:events');
const express = require('express');
const { requireAuth } = require('../server');
const { createReportSubmissionHandler } = require('../report_submission');

const quietLogger = { warn() {} };
const validBody = { category: 'other', message: 'A test report', busNumber: 7 };

async function requestReport(session, body = validBody) {
    const app = express();
    app.use(express.json());
    app.use((req, _res, next) => {
        const token = (req.get('authorization') || '').replace(/^Bearer /, '');
        req.authToken = token || null;
        req.authSession = token ? session : null;
        next();
    });

    const queryCalls = [];
    const handler = createReportSubmissionHandler({
        requireAuth: (req, res, roles) => requireAuth(req, res, roles, quietLogger),
        query: async (sql, params) => {
            queryCalls.push({ sql, params });
            if (sql.includes('SELECT bus_number')) return [{ bus_number: 7, assigned_hostel: 'BH1' }];
            return [{ id: 'r_test', reporterId: 'student_test', hostelId: 'BH1', busNumber: 7, status: 'open' }];
        },
        uid: () => 'r_test',
        internalError: (res) => res.status(500).json({ error: 'Internal server error' }),
        logger: quietLogger,
    });
    app.post('/api/reports', handler);

    const server = app.listen(0, '127.0.0.1');
    await once(server, 'listening');
    try {
        const response = await fetch(`http://127.0.0.1:${server.address().port}/api/reports`, {
            method: 'POST',
            headers: {
                'content-type': 'application/json',
                ...(session ? { authorization: 'Bearer synthetic-session' } : {}),
            },
            body: JSON.stringify(body),
        });
        return { status: response.status, data: await response.json(), queryCalls };
    } finally {
        await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
}

test('assigned student can submit a report for a bus in the same hostel', async () => {
    const result = await requestReport({
        userId: 'student_test', role: 'student', hostelId: 'BH1',
        mustChangePassword: false, expiresAt: new Date(Date.now() + 60_000),
    });
    assert.equal(result.status, 201);
    assert.equal(result.data.data.status, 'open');
    assert.equal(result.queryCalls.length, 2);
});

test('non-student role is forbidden from submitting reports', async () => {
    const result = await requestReport({
        userId: 'caretaker_test', role: 'caretaker', hostelId: 'BH1',
        mustChangePassword: false, expiresAt: new Date(Date.now() + 60_000),
    });
    assert.equal(result.status, 403);
    assert.equal(result.data.code, 'ROLE_NOT_ALLOWED');
    assert.equal(result.queryCalls.length, 0);
});

test('student with temporary password change required receives a distinct forbidden code', async () => {
    const result = await requestReport({
        userId: 'student_test', role: 'student', hostelId: 'BH1',
        mustChangePassword: true, expiresAt: new Date(Date.now() + 60_000),
    });
    assert.equal(result.status, 403);
    assert.equal(result.data.code, 'PASSWORD_CHANGE_REQUIRED');
    assert.equal(result.queryCalls.length, 0);
});

test('student without an assigned hostel receives a distinct forbidden code', async () => {
    const result = await requestReport({
        userId: 'student_test', role: 'student', hostelId: null,
        mustChangePassword: false, expiresAt: new Date(Date.now() + 60_000),
    });
    assert.equal(result.status, 403);
    assert.equal(result.data.code, 'STUDENT_HOSTEL_UNASSIGNED');
    assert.equal(result.queryCalls.length, 0);
});

test('student cannot report a bus assigned to another hostel', async () => {
    const result = await requestReport({
        userId: 'student_test', role: 'student', hostelId: 'GH1',
        mustChangePassword: false, expiresAt: new Date(Date.now() + 60_000),
    });
    // The query fixture returns BH1, while this student's session is GH1.
    assert.equal(result.status, 403);
    assert.equal(result.data.code, 'BUS_HOSTEL_MISMATCH');
    assert.equal(result.queryCalls.length, 1);
});

test('unauthenticated report submission remains unauthorized', async () => {
    const result = await requestReport(null);
    assert.equal(result.status, 401);
    assert.equal(result.data.code, 'AUTHENTICATION_REQUIRED');
    assert.equal(result.queryCalls.length, 0);
});
