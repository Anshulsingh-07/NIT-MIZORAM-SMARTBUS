'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { boundedString, finiteNumberInRange, positiveSafeInteger } = require('../input_validation');

test('bounded strings enforce type, trimming, required values, and maximum length', () => {
    assert.equal(boundedString('  bus  ', 8, { required: true }), 'bus');
    assert.equal(boundedString('x'.repeat(9), 8), null);
    assert.equal(boundedString('', 8, { required: true }), null);
    assert.equal(boundedString(undefined, 8, { fallback: 'default' }), 'default');
});

test('numeric validators reject non-finite, out-of-range, and unsafe values', () => {
    assert.equal(finiteNumberInRange('90', -90, 90), 90);
    assert.equal(finiteNumberInRange('91', -90, 90), null);
    assert.equal(finiteNumberInRange('NaN', -90, 90), null);
    assert.equal(positiveSafeInteger('12'), 12);
    assert.equal(positiveSafeInteger('1.2'), null);
    assert.equal(positiveSafeInteger('-1'), null);
});