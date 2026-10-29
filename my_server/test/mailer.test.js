'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const shared = require('../recovery_email');
const compatibility = require('../mailer');

test('legacy mailer entrypoint exports the shared recovery provider', () => {
    assert.equal(compatibility.sendRecoveryEmail, shared.sendRecoveryEmail);
    assert.equal(compatibility.recoveryEmailProvider, shared.recoveryEmailProvider);
});
