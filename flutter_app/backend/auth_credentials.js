'use strict';

const bcrypt = require('bcryptjs');

const PASSWORD_CHANGE_ALLOWED_PATHS = new Set([
    '/api/me',
    '/api/auth/change-password',
    '/api/auth/logout',
]);

function canAccessDuringPasswordChange(path) {
    return PASSWORD_CHANGE_ALLOWED_PATHS.has(path);
}

async function getAuthenticationFailureReason(user, password, hostels) {
    if (!user) return 'account_not_found';
    const storedPassword = user.password || '';
    if (!/^\$2[aby]\$/.test(storedPassword)) return 'unsupported_password_hash';
    let passwordMatches = false;
    try {
        passwordMatches = await bcrypt.compare(password, storedPassword);
    } catch (_) {
        return 'invalid_password_hash';
    }
    if (!passwordMatches) return 'password_mismatch';
    if (user.role === 'caretaker' && !hostels.some((hostel) => hostel.id === user.hostel_id)) {
        return 'invalid_caretaker_hostel';
    }
    return null;
}

async function canAuthenticateUser(user, password, hostels) {
    return (await getAuthenticationFailureReason(user, password, hostels)) === null;
}

function createLoginRateLimiter({ limit = 10, windowMs = 15 * 60 * 1000, clock = Date.now } = {}) {
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
            return res.status(429).json({ error: 'Too many login attempts. Try again later.' });
        }
        attempts.push(now);
        attemptsByIp.set(ip, attempts);
        return next();
    };
}

function createLoginHandler({ findUserByEmail, hostels, createToken, publicUser, logger = console }) {
    return async (req, res) => {
        try {
            const email = String(req.body?.email || '').trim().toLowerCase();
            const password = String(req.body?.password || '');
            const user = await findUserByEmail(email);
            const failureReason = await getAuthenticationFailureReason(user, password, hostels);
            if (failureReason) {
                logger.warn(`Login rejected: ${failureReason}`);
                return res.status(401).json({ error: 'Invalid credentials' });
            }

            const token = createToken(user);
            return res.json({
                token,
                user: publicUser(user),
                mustChangePassword: Boolean(user.must_change_password),
            });
        } catch (error) {
            const code = typeof error?.code === 'string' ? error.code : 'unknown_error';
            logger.error(`Login processing failed: ${code}`);
            return res.status(500).json({ error: 'Login failed' });
        }
    };
}

module.exports = {
    canAuthenticateUser,
    canAccessDuringPasswordChange,
    createLoginRateLimiter,
    createLoginHandler,
};