'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { rejectRequest } = require('../request_rejections');

test('rejection diagnostics contain only method and fixed reason code', () => {
    const logs = [];
    let statusCode;
    let responseBody;
    const response = {
        status(code) { statusCode = code; return this; },
        json(body) { responseBody = body; return body; },
    };
    const req = {
        method: 'POST',
        path: '/api/reports/private@example.test',
        headers: { authorization: 'Bearer synthetic-secret-token' },
        body: { phone: '9999999999', message: 'private test content' },
    };

    rejectRequest(response, req, 403, 'ROLE_NOT_ALLOWED', 'Forbidden', {
        warn(message) { logs.push(message); },
    });

    assert.equal(statusCode, 403);
    assert.deepEqual(responseBody, { error: 'Forbidden', code: 'ROLE_NOT_ALLOWED' });
    assert.deepEqual(logs, ['Request rejected: POST ROLE_NOT_ALLOWED']);
});
