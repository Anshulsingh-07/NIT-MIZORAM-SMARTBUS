'use strict';

const TELEMETRY_DIAGNOSTIC_CODES = Object.freeze({
    AUTHENTICATION_FAILED: 'TELEMETRY_AUTHENTICATION_FAILED',
    UNKNOWN_BUS: 'UNKNOWN_OR_UNASSIGNED_BUS',
    INVALID_COORDINATES: 'INVALID_COORDINATES',
    DATABASE_INSERT_FAILED: 'TELEMETRY_DATABASE_INSERT_FAILED',
    NO_RECORDS: 'NO_TELEMETRY_RECORDS',
    EXCLUDED_BY_FILTER: 'TELEMETRY_EXCLUDED_BY_FILTER',
});

function latestTelemetryDiagnostic({ hasMatchingRecords, hasAnyRecords }) {
    if (hasMatchingRecords) return null;
    return hasAnyRecords
        ? TELEMETRY_DIAGNOSTIC_CODES.EXCLUDED_BY_FILTER
        : TELEMETRY_DIAGNOSTIC_CODES.NO_RECORDS;
}

function hasValidDeviceFix({ lat, lng, speed, accuracy }) {
    return Number.isFinite(lat) && lat >= -90 && lat <= 90 &&
        Number.isFinite(lng) && lng >= -180 && lng <= 180 &&
        Number.isFinite(speed) && speed >= 0 &&
        Number.isFinite(accuracy) && accuracy >= 0;
}

function parseTelemetryBusNumber(value) {
    const digits = String(value || '').replace(/[^0-9]/g, '');
    const number = Number(digits);
    return Number.isSafeInteger(number) && number > 0 ? number : null;
}

function telemetryErrorPayload(code, error) {
    return { error, code };
}

async function diagnoseEmptyLatestTelemetry(query) {
    const result = await query('SELECT EXISTS (SELECT 1 FROM telemetry) AS has_records');
    return latestTelemetryDiagnostic({
        hasMatchingRecords: false,
        hasAnyRecords: result.rows[0]?.has_records === true,
    });
}

module.exports = {
    TELEMETRY_DIAGNOSTIC_CODES,
    latestTelemetryDiagnostic,
    diagnoseEmptyLatestTelemetry,
    hasValidDeviceFix,
    parseTelemetryBusNumber,
    telemetryErrorPayload,
};
