'use strict';

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const express = require('express');

const GENERIC_MESSAGE = 'If an account exists for these details, recovery instructions will be sent.';
const INVALID_OTP_MESSAGE = 'The code is invalid or expired.';
const INVALID_TOKEN_MESSAGE = 'The password reset link is invalid or expired.';

function recoveryError(res, status, code, message) {
    return res.status(status).json({ success: false, code, message });
}

function digest(value) {
    return crypto.createHash('sha256').update(value).digest('hex');
}

function hashOtp(secret, userId, otp) {
    return crypto.createHmac('sha256', secret).update(`${userId}:${otp}`).digest('hex');
}

function normalizeMobile(value) {
    const digits = String(value || '').replace(/\D/g, '');
    if (digits.length === 10 && /^[6-9]/.test(digits)) return `+91${digits}`;
    if (digits.length === 12 && digits.startsWith('91') && /^[6-9]/.test(digits.slice(2))) {
        return `+${digits}`;
    }
    return null;
}

function consumeLimit(limits, key, limit, windowMs, now) {
    for (const [entryKey, entryTimestamps] of limits) {
        const recent = entryTimestamps.filter((timestamp) => now - timestamp < windowMs);
        if (recent.length) limits.set(entryKey, recent);
        else limits.delete(entryKey);
    }
    const timestamps = limits.get(key) || [];
    if (timestamps.length >= limit) {
        limits.set(key, timestamps);
        return false;
    }
    timestamps.push(now);
    limits.set(key, timestamps);
    return true;
}

function buildResetUrl(baseUrl, token, production) {
    const url = new URL(baseUrl);
    if ((production && url.protocol !== 'https:') || !['http:', 'https:'].includes(url.protocol) ||
        url.username || url.password || url.search || url.hash) {
        throw new Error('Password reset base URL is not allowed');
    }
    url.pathname = '/reset-password';
    url.hash = `token=${token}`;
    return url.toString();
}

function createPasswordRecoveryRouter({
    store,
    sessions,
    emailConfigured,
    sendMail,
    smsConfigured,
    sendSms,
    otpSecret,
    baseUrl,
    production = false,
    backgroundWorkTimeoutMs = 15000,
    clock = Date.now,
    logger = console,
}) {
    const router = express.Router();
    const accountLimits = new Map();
    const ipLimits = new Map();
    const verificationLimits = new Map();

    function allowed(method, identity, ip) {
        const now = clock();
        const key = digest(`${method}:${identity}`);
        return consumeLimit(accountLimits, key, 3, 15 * 60 * 1000, now) &&
            consumeLimit(ipLimits, ip, 10, 60 * 60 * 1000, now);
    }

    function enqueueRecovery(operation) {
        setImmediate(() => {
            let timeout;
            const deadline = new Promise((_, reject) => {
                timeout = setTimeout(() => reject(new Error('Recovery work timed out')), backgroundWorkTimeoutMs);
            });
            Promise.race([Promise.resolve().then(operation), deadline])
                .catch(() => logger.error('Password recovery request could not be processed'))
                .finally(() => clearTimeout(timeout));
        });
    }

    async function sendOtpForPhone(phone) {
        const user = await store.findUserByVerifiedPhone(phone);
        if (!user) return;

        const otp = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
        const otpHash = hashOtp(otpSecret(), user.id, otp);
        const accepted = await store.createOtpIfCooldownElapsed(
            user.id,
            otpHash,
            new Date(clock() + 5 * 60 * 1000),
            60 * 1000,
        );
        if (!accepted) return;

        try {
            await sendSms(phone, `Your SmartBus password reset code is ${otp}. It expires in 5 minutes.`);
        } catch (_) {
            await store.invalidateOtps(user.id);
            logger.warn('Password recovery SMS delivery failed');
        }
    }

    router.post('/forgot-password', async (req, res) => {
        const method = String(req.body?.method || '').toLowerCase();
        const ip = req.ip || req.socket.remoteAddress || 'unknown';
        const now = clock();

        if (method === 'email') {
            const email = String(req.body?.email || '').trim().toLowerCase();
            if (email.length > 120 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
                return recoveryError(res, 400, 'INVALID_REQUEST', 'Enter a valid college email address.');
            }
            if (!allowed(method, email, ip)) {
                return recoveryError(res, 429, 'RATE_LIMITED', 'Too many recovery requests. Try again later.');
            }
            if (!emailConfigured()) {
                return recoveryError(res, 503, 'SERVICE_TEMPORARILY_UNAVAILABLE', 'Email recovery is temporarily unavailable. Please try again later.');
            }

            enqueueRecovery(async () => {
                await store.cleanupExpired();
                const user = await store.findUserByEmail(email);
                if (user) {
                    const token = crypto.randomBytes(32).toString('hex');
                    const tokenHash = digest(token);
                    const expiresAt = new Date(now + 15 * 60 * 1000);
                    const resetUrl = buildResetUrl(baseUrl(), token, production);
                    await store.createEmailReset(user.id, tokenHash, expiresAt);
                    try {
                        await sendMail({
                            to: user.email,
                            subject: 'SmartBus password reset',
                            text: `Use this link to reset your password. It expires in 15 minutes:\n${resetUrl}`,
                            html: `<p>Use this link to reset your password. It expires in 15 minutes.</p><p><a href="${resetUrl}">Reset password</a></p>`,
                        });
                    } catch (_) {
                        await store.deleteResetToken(tokenHash);
                        logger.warn('Password recovery email delivery failed');
                    }
                }
            });
            return res.json({ success: true, message: GENERIC_MESSAGE });
        }

        if (method === 'mobile') {
            const phone = normalizeMobile(req.body?.mobile);
            if (!phone) return recoveryError(res, 400, 'INVALID_REQUEST', 'Enter a valid 10-digit Indian mobile number.');
            if (!allowed(method, phone, ip)) {
                return recoveryError(res, 429, 'RATE_LIMITED', 'Too many recovery requests. Try again later.');
            }
            if (!smsConfigured() || typeof otpSecret() !== 'string' || otpSecret().length < 32) {
                return recoveryError(res, 503, 'SERVICE_TEMPORARILY_UNAVAILABLE', 'Mobile recovery is temporarily unavailable. Please try email recovery.');
            }

            enqueueRecovery(async () => {
                await store.cleanupExpired();
                await sendOtpForPhone(phone);
            });
            return res.json({ success: true, message: GENERIC_MESSAGE });
        }

        return recoveryError(res, 400, 'INVALID_REQUEST', 'Choose email or mobile recovery.');
    });

    router.post('/resend-otp', async (req, res) => {
        const phone = normalizeMobile(req.body?.mobile);
        if (!phone) return recoveryError(res, 400, 'INVALID_REQUEST', 'Enter a valid 10-digit Indian mobile number.');
        const ip = req.ip || req.socket.remoteAddress || 'unknown';
        if (!allowed('mobile-resend', phone, ip)) {
            return recoveryError(res, 429, 'RATE_LIMITED', 'Too many recovery requests. Try again later.');
        }
        if (!smsConfigured() || typeof otpSecret() !== 'string' || otpSecret().length < 32) {
            return recoveryError(res, 503, 'SERVICE_TEMPORARILY_UNAVAILABLE', 'Mobile recovery is temporarily unavailable. Please try email recovery.');
        }

        enqueueRecovery(async () => {
            await store.cleanupExpired();
            await sendOtpForPhone(phone);
        });
        return res.json({ success: true, message: GENERIC_MESSAGE });
    });

    router.post('/verify-otp', async (req, res) => {
        const phone = normalizeMobile(req.body?.mobile);
        const otp = String(req.body?.otp || '');
        if (!phone || !/^\d{6}$/.test(otp)) {
            return recoveryError(res, 400, 'INVALID_OTP', INVALID_OTP_MESSAGE);
        }
        const ip = req.ip || req.socket.remoteAddress || 'unknown';
        const limitKey = `${digest(phone)}:${ip}`;
        if (!consumeLimit(verificationLimits, limitKey, 20, 15 * 60 * 1000, clock())) {
            return recoveryError(res, 429, 'RATE_LIMITED', 'Too many verification attempts. Try again later.');
        }
        if (typeof otpSecret() !== 'string' || otpSecret().length < 32) {
            return recoveryError(res, 503, 'SERVICE_TEMPORARILY_UNAVAILABLE', 'Mobile recovery is temporarily unavailable. Please try again later.');
        }

        try {
            const user = await store.findUserByVerifiedPhone(phone);
            if (!user) return recoveryError(res, 400, 'INVALID_OTP', INVALID_OTP_MESSAGE);
            const resetToken = crypto.randomBytes(32).toString('hex');
            const accepted = await store.verifyOtpAndCreateReset(
                user.id,
                hashOtp(otpSecret(), user.id, otp),
                digest(resetToken),
                new Date(clock() + 15 * 60 * 1000),
            );
            if (!accepted) return recoveryError(res, 400, 'INVALID_OTP', INVALID_OTP_MESSAGE);
            return res.json({ success: true, resetToken });
        } catch (_) {
            logger.error('Password recovery verification could not be processed');
            return recoveryError(res, 500, 'RECOVERY_FAILED', 'Password recovery could not be processed.');
        }
    });

    router.post('/reset-password', async (req, res) => {
        const token = String(req.body?.token || '');
        const newPassword = String(req.body?.newPassword || '');
        const ip = req.ip || req.socket.remoteAddress || 'unknown';
        if (!consumeLimit(verificationLimits, `${digest(token)}:${ip}`, 20, 15 * 60 * 1000, clock())) {
            return recoveryError(res, 429, 'RATE_LIMITED', 'Too many password reset attempts. Try again later.');
        }
        if (!/^[a-f0-9]{64}$/i.test(token)) {
            return recoveryError(res, 400, 'INVALID_TOKEN', INVALID_TOKEN_MESSAGE);
        }
        if (newPassword.length < 9 || newPassword.length > 128) {
            return recoveryError(res, 400, 'INVALID_PASSWORD', 'Choose a password between 9 and 128 characters.');
        }

        try {
            const passwordHash = await bcrypt.hash(newPassword, 12);
            const userId = await store.consumeResetTokenAndUpdatePassword(digest(token), passwordHash);
            if (!userId) return recoveryError(res, 400, 'INVALID_TOKEN', INVALID_TOKEN_MESSAGE);
            for (const [sessionToken, session] of sessions) {
                if (session.userId === userId) sessions.delete(sessionToken);
            }
            return res.json({
                success: true,
                message: 'Your password has been reset successfully. Please log in using your new password.',
            });
        } catch (_) {
            logger.error('Password reset could not be processed');
            return recoveryError(res, 500, 'RESET_FAILED', 'Could not reset password.');
        }
    });

    return router;
}

module.exports = {
    createPasswordRecoveryRouter,
    digest,
    hashOtp,
    normalizeMobile,
};