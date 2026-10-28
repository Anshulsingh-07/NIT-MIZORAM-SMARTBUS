'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { campusDateKey, isDateOnly, normalizeCampusDate, matchesCampusDate } = require('../campus_time');

test('campus date changes at midnight IST, not midnight UTC', () => {
    assert.equal(campusDateKey(new Date('2026-10-07T18:29:59.000Z')), '2026-10-07');
    assert.equal(campusDateKey(new Date('2026-10-07T18:30:00.000Z')), '2026-10-08');
    assert.equal(campusDateKey(new Date('2026-10-07T19:02:24.000Z')), '2026-10-08');
    assert.equal(campusDateKey(new Date('2026-10-08T18:29:59.000Z')), '2026-10-08');
    assert.equal(campusDateKey(new Date('2026-10-08T18:30:00.000Z')), '2026-10-09');
});

test('schedule date input accepts only real YYYY-MM-DD calendar dates', () => {
    assert.equal(isDateOnly('2026-10-08'), true);
    assert.equal(isDateOnly('2026-02-30'), false);
    assert.equal(isDateOnly('2026-10-08T00:00:00.000Z'), false);
});

test('schedule matching only keeps the campus day and ignores stale or future dates', () => {
    assert.equal(normalizeCampusDate('2026-10-08'), '2026-10-08');
    assert.equal(matchesCampusDate('2026-10-08', '2026-10-08'), true);
    assert.equal(matchesCampusDate('2026-10-09', '2026-10-08'), false);
    assert.equal(matchesCampusDate('2026-10-08T00:00:00.000Z', '2026-10-08'), false);
});
