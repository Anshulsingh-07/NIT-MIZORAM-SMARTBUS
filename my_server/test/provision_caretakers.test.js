'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createTemporaryPassword, parseArguments, rosterFor } = require('../scripts/provision-caretakers');

test('temporary caretaker passwords are random sixteen-character strings', () => {
    const first = createTemporaryPassword();
    const second = createTemporaryPassword();

    assert.equal(first.length, 16);
    assert.equal(second.length, 16);
    assert.match(first, /^[A-HJ-NP-Za-km-z2-9]{16}$/);
    assert.notEqual(first, second);
});

test('provisioner restricts --only and --reset to the six-account roster', () => {
    assert.deepEqual(parseArguments(['--only', 'bh1']), { dryRun: false, only: 'bh1', reset: null });
    assert.equal(rosterFor(parseArguments(['--only', 'BH1'])).length, 1);
    assert.equal(rosterFor(parseArguments(['--reset', 'CARETAKER-GH2@NITMZ.AC.IN'])).length, 1);
    assert.throws(() => parseArguments(['--only', 'UNKNOWN']), /--only must be one of/);
    assert.throws(() => parseArguments(['--reset', 'student@nitmz.ac.in']), /--reset must name/);
    assert.throws(() => parseArguments(['--only', 'BH1', '--reset', 'caretaker-bh1@nitmz.ac.in']), /cannot be combined/);
});