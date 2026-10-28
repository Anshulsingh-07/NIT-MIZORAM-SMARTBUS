'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
    TELEMETRY_DIAGNOSTIC_CODES,
    diagnoseEmptyLatestTelemetry,
    hasValidDeviceFix,
    parseTelemetryBusNumber,
    telemetryErrorPayload,
} = require('../telemetry_diagnostics');

test('empty latest-location query distinguishes no telemetry from scope filtering', async () => {
    const queries = [];
    const noRecords = await diagnoseEmptyLatestTelemetry(async (sql) => {
        queries.push(sql);
        return { rows: [{ has_records: false }] };
    });
    const filtered = await diagnoseEmptyLatestTelemetry(async (sql) => {
        queries.push(sql);
        return { rows: [{ has_records: true }] };
    });

    assert.equal(noRecords, TELEMETRY_DIAGNOSTIC_CODES.NO_RECORDS);
    assert.equal(filtered, TELEMETRY_DIAGNOSTIC_CODES.EXCLUDED_BY_FILTER);
    assert.equal(queries.length, 2);
    assert.ok(queries.every((sql) => sql === 'SELECT EXISTS (SELECT 1 FROM telemetry) AS has_records'));
});

test('telemetry diagnostic codes are fixed and do not contain request data', () => {
    assert.deepEqual(Object.values(TELEMETRY_DIAGNOSTIC_CODES), [
        'TELEMETRY_AUTHENTICATION_FAILED',
        'UNKNOWN_OR_UNASSIGNED_BUS',
        'INVALID_COORDINATES',
        'TELEMETRY_DATABASE_INSERT_FAILED',
        'NO_TELEMETRY_RECORDS',
        'TELEMETRY_EXCLUDED_BY_FILTER',
    ]);
});

test('synthetic device coordinates are validated without accepting malformed GPS fields', () => {
    assert.equal(hasValidDeviceFix({ lat: 23.7271, lng: 92.7176, speed: 12, accuracy: 2 }), true);
    assert.equal(hasValidDeviceFix({ lat: 91, lng: 92.7176, speed: 12, accuracy: 2 }), false);
    assert.equal(hasValidDeviceFix({ lat: 23.7271, lng: -181, speed: 12, accuracy: 2 }), false);
    assert.equal(hasValidDeviceFix({ lat: NaN, lng: 92.7176, speed: 12, accuracy: 2 }), false);
    assert.equal(hasValidDeviceFix({ lat: 23.7271, lng: 92.7176, speed: -1, accuracy: 2 }), false);
});

test('device bus identifiers are normalized to the numeric buses table key', () => {
    assert.equal(parseTelemetryBusNumber('Bus 5'), 5);
    assert.equal(parseTelemetryBusNumber('BUS-005'), 5);
    assert.equal(parseTelemetryBusNumber('unknown'), null);
    assert.equal(parseTelemetryBusNumber('0'), null);
});

test('application telemetry rejection payloads contain only fixed codes and generic messages', () => {
    const cases = [
        [TELEMETRY_DIAGNOSTIC_CODES.AUTHENTICATION_FAILED, 'Unauthorized'],
        [TELEMETRY_DIAGNOSTIC_CODES.UNKNOWN_BUS, 'Bus not registered or disabled'],
        [TELEMETRY_DIAGNOSTIC_CODES.INVALID_COORDINATES, 'Invalid GPS fix'],
        [TELEMETRY_DIAGNOSTIC_CODES.DATABASE_INSERT_FAILED, 'Unable to store telemetry'],
    ];
    for (const [code, error] of cases) {
        assert.deepEqual(telemetryErrorPayload(code, error), { error, code });
    }
});
