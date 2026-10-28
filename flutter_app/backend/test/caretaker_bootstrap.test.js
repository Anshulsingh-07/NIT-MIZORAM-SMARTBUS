'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { getCaretakerBootstrapAction } = require('../caretaker_bootstrap');

const bcryptHash = '$2b$12$example-hash-value-not-used-for-authentication';

test('bootstrap creates only a missing caretaker when an initial password is configured', () => {
    assert.equal(getCaretakerBootstrapAction(null, true), 'create');
    assert.equal(getCaretakerBootstrapAction(null, false), 'skip');
});

test('bootstrap preserves an existing caretaker regardless of initial-password configuration', () => {
    const existing = { role: 'caretaker', password: bcryptHash };

    assert.equal(getCaretakerBootstrapAction(existing, true), 'preserve');
    assert.equal(getCaretakerBootstrapAction(existing, false), 'preserve');
});

test('bootstrap never repairs or mutates existing legacy or conflicting accounts', () => {
    assert.equal(getCaretakerBootstrapAction({ role: 'caretaker', password: 'legacy' }, true), 'legacy');
    assert.equal(getCaretakerBootstrapAction({ role: 'student', password: bcryptHash }, true), 'conflict');
});
