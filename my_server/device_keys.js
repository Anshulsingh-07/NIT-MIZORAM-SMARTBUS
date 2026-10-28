'use strict';

const crypto = require('crypto');

function hashDeviceKey(value) {
    return crypto.createHash('sha256').update(String(value || '')).digest('hex');
}

function timingSafeSecretEqual(candidate, expected) {
    const candidateHash = crypto.createHash('sha256').update(String(candidate || '')).digest();
    const expectedHash = crypto.createHash('sha256').update(String(expected || '')).digest();
    return crypto.timingSafeEqual(candidateHash, expectedHash);
}

function findDeviceKeyAssignment(candidateKey, keyRows) {
    const candidateHash = hashDeviceKey(candidateKey);
    let matched = null;
    for (const row of keyRows) {
        if (timingSafeSecretEqual(candidateHash, row.key_hash)) matched = row;
    }
    return matched;
}

function createTelemetryRateLimiter({ limit = 120, windowMs = 60 * 1000, clock = Date.now } = {}) {
    const attemptsByIp = new Map();
    return (req, res, next) => {
        const now = clock();
        for (const [ip, timestamps] of attemptsByIp) {
            const recent = timestamps.filter((timestamp) => now - timestamp < windowMs);
            if (recent.length) attemptsByIp.set(ip, recent);
            else attemptsByIp.delete(ip);
        }

        const ip = req.ip || req.socket?.remoteAddress || 'unknown';
        const attempts = attemptsByIp.get(ip) || [];
        if (attempts.length >= limit) {
            return res.status(429).json({ error: 'Too many telemetry requests. Try again later.' });
        }
        attempts.push(now);
        attemptsByIp.set(ip, attempts);
        if (attemptsByIp.size > 10000) attemptsByIp.delete(attemptsByIp.keys().next().value);
        return next();
    };
}

module.exports = { createTelemetryRateLimiter, findDeviceKeyAssignment, hashDeviceKey, timingSafeSecretEqual };