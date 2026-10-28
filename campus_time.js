'use strict';

const CAMPUS_TIME_ZONE = 'Asia/Kolkata';

function normalizeCampusDate(value) {
    if (value instanceof Date) {
        return campusDateKey(value);
    }
    if (typeof value !== 'string') {
        return '';
    }
    const raw = value.trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
        return '';
    }
    const [year, month, day] = raw.split('-').map(Number);
    const normalized = new Date(Date.UTC(year, month - 1, day));
    if (
        normalized.getUTCFullYear() !== year ||
        normalized.getUTCMonth() !== month - 1 ||
        normalized.getUTCDate() !== day
    ) {
        return '';
    }
    return raw;
}

/** Return a date-only YYYY-MM-DD key in the campus timezone, independent of host TZ. */
function campusDateKey(value = new Date()) {
    const parts = new Intl.DateTimeFormat('en-CA', {
        timeZone: CAMPUS_TIME_ZONE,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
    }).formatToParts(value);
    const fields = Object.fromEntries(parts.map(({ type, value: part }) => [type, part]));
    return `${fields.year}-${fields.month}-${fields.day}`;
}

function isDateOnly(value) {
    const normalized = normalizeCampusDate(value);
    return normalized !== '' && normalized === value.trim();
}

function matchesCampusDate(value, expected) {
    const actual = normalizeCampusDate(value);
    const wanted = normalizeCampusDate(expected);
    return actual !== '' && wanted !== '' && actual === wanted;
}

module.exports = { CAMPUS_TIME_ZONE, campusDateKey, isDateOnly, normalizeCampusDate, matchesCampusDate };
