'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { shouldSeedSampleData } = require('../server');

test('sample startup seeding is opt-in and requires the exact true value', () => {
    assert.equal(shouldSeedSampleData({}), false);
    assert.equal(shouldSeedSampleData({ SEED_SAMPLE_DATA: 'false' }), false);
    assert.equal(shouldSeedSampleData({ SEED_SAMPLE_DATA: '1' }), false);
    assert.equal(shouldSeedSampleData({ SEED_SAMPLE_DATA: 'true' }), true);
});