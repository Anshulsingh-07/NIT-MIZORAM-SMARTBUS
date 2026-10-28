'use strict';

function boundedString(value, maxLength, { required = false, fallback = null } = {}) {
    if (value === undefined && !required) return fallback;
    if (typeof value !== 'string') return null;
    const normalized = value.trim();
    if (normalized.length > maxLength || (required && !normalized)) return null;
    return normalized;
}

function finiteNumberInRange(value, minimum, maximum, fallback = null) {
    if (value === undefined && fallback !== null) return fallback;
    if ((typeof value !== 'number' && typeof value !== 'string') || String(value).trim() === '') return null;
    const number = Number(value);
    return Number.isFinite(number) && number >= minimum && number <= maximum ? number : null;
}

function positiveSafeInteger(value) {
    if ((typeof value !== 'number' && typeof value !== 'string') || String(value).trim() === '') return null;
    const number = Number(value);
    return Number.isSafeInteger(number) && number > 0 ? number : null;
}

module.exports = { boundedString, finiteNumberInRange, positiveSafeInteger };