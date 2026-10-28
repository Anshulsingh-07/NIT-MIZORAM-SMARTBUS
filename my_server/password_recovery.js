'use strict';

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const express = require('express');

const GENERIC_MESSAGE = 'If an account exists and delivery is available, recovery instructions will be sent.';
const INVALID_OTP_MESSAGE = 'The code is invalid or expired.';
const INVALID_TOKEN_MESSAGE = 'The password reset link is invalid or expired.';

function recoveryError(res, status, code, message) {
    return res.status(status).json({ success: false, code, message });
}

function acceptedRecovery(res) {
    return res.status(202).json({
        accepted: true,
        deliveryConfirmed: false,
        code: 'RECOVERY_ACCEPTED',
        message: GENERIC_MESSAGE,
    });
}

class RecoveryDependencyError extends Error {
    constructor(code) {
        super(code);
        this.code = code;
    }
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
    sessionStore,
    emailConfigurationIssue,
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
                .catch((error) => {
                    const code = error instanceof RecoveryDependencyError
                        ? error.code
                        : error?.message === 'Recovery work timed out'
                            ? 'RECOVERY_WORK_TIMEOUT'
                            : 'RECOVERY_APPLICATION_FAILURE';
                    logger.error(`Password recovery failed: ${code}`);
                })
                .finally(() => clearTimeout(timeout));
        });
    }

    async function sendOtpForPhone(email, phone) {
        let user;
        try {
            user = await store.findUserByVerifiedPhone(email, phone);
        } catch (_) {
            throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
        }
        if (!user) return;

        const otp = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
        const otpHash = hashOtp(otpSecret(), user.id, otp);
        let accepted;
        try {
            accepted = await store.createOtpIfCooldownElapsed(
                user.id,
                otpHash,
                new Date(clock() + 5 * 60 * 1000),
                60 * 1000,
            );
        } catch (_) {
            throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
        }
        if (!accepted) return;

        try {
            await sendSms(phone, `Your SmartBus password reset code is ${otp}. It expires in 5 minutes.`);
        } catch (_) {
            await store.invalidateOtps(user.id).catch(() => {
                throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
            });
            throw new RecoveryDependencyError('SMS_DELIVERY_PROVIDER_FAILED');
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
            const emailConfigIssue = emailConfigurationIssue?.();
            if (emailConfigIssue) {
                return recoveryError(res, 503, emailConfigIssue, 'Email recovery is temporarily unavailable. Please try again later.');
            }
            if (!emailConfigured()) {
                return recoveryError(res, 503, 'EMAIL_PROVIDER_UNAVAILABLE', 'Email recovery is temporarily unavailable. Please try again later.');
            }

            enqueueRecovery(async () => {
                let user;
                try {
                    await store.cleanupExpired();
                    user = await store.findUserByEmail(email);
                } catch (_) {
                    throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
                }
                if (user) {
                    const token = crypto.randomBytes(32).toString('hex');
                    const tokenHash = digest(token);
                    const expiresAt = new Date(now + 15 * 60 * 1000);
                    let resetUrl;
                    try {
                        resetUrl = buildResetUrl(baseUrl(), token, production);
                    } catch (_) {
                        throw new RecoveryDependencyError('RECOVERY_CONFIGURATION_INVALID');
                    }
                    try {
                        await store.createEmailReset(user.id, tokenHash, expiresAt);
                    } catch (_) {
                        throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
                    }
                    try {
                        await sendMail({
                            to: user.email,
                            subject: 'SmartBus password reset',
                            text: `Use this link to reset your password. It expires in 15 minutes:\n${resetUrl}`,
                            html: `<p>Use this link to reset your password. It expires in 15 minutes.</p><p><a href="${resetUrl}">Reset password</a></p>`,
                        });
                    } catch (_) {
                        await store.deleteResetToken(tokenHash).catch(() => {
                            throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
                        });
                        throw new RecoveryDependencyError('EMAIL_DELIVERY_PROVIDER_FAILED');
                    }
                }
            });
            return acceptedRecovery(res);
        }

        if (method === 'mobile') {
            const email = String(req.body?.email || '').trim().toLowerCase();
            const phone = normalizeMobile(req.body?.mobile);
            if (email.length > 120 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !phone) {
                return recoveryError(res, 400, 'INVALID_REQUEST', 'Enter the registered college email and mobile number.');
            }
            if (!allowed(method, `${email}:${phone}`, ip)) {
                return recoveryError(res, 429, 'RATE_LIMITED', 'Too many recovery requests. Try again later.');
            }
            if (!smsConfigured()) {
                return recoveryError(res, 503, 'SMS_PROVIDER_UNAVAILABLE', 'Mobile recovery is temporarily unavailable. Please try email recovery.');
            }
            if (typeof otpSecret() !== 'string' || otpSecret().length < 32) {
                return recoveryError(res, 503, 'OTP_SECRET_UNAVAILABLE', 'Mobile recovery is temporarily unavailable. Please try email recovery.');
            }

            enqueueRecovery(async () => {
                try {
                    await store.cleanupExpired();
                } catch (_) {
                    throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
                }
                await sendOtpForPhone(email, phone);
            });
            return acceptedRecovery(res);
        }

        return recoveryError(res, 400, 'INVALID_REQUEST', 'Choose email or mobile recovery.');
    });

    router.post('/resend-otp', async (req, res) => {
        const email = String(req.body?.email || '').trim().toLowerCase();
        const phone = normalizeMobile(req.body?.mobile);
        if (email.length > 120 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !phone) {
            return recoveryError(res, 400, 'INVALID_REQUEST', 'Enter the registered college email and mobile number.');
        }
        const ip = req.ip || req.socket.remoteAddress || 'unknown';
        if (!allowed('mobile-resend', `${email}:${phone}`, ip)) {
            return recoveryError(res, 429, 'RATE_LIMITED', 'Too many recovery requests. Try again later.');
        }
        if (!smsConfigured()) {
            return recoveryError(res, 503, 'SMS_PROVIDER_UNAVAILABLE', 'Mobile recovery is temporarily unavailable. Please try email recovery.');
        }
        if (typeof otpSecret() !== 'string' || otpSecret().length < 32) {
            return recoveryError(res, 503, 'OTP_SECRET_UNAVAILABLE', 'Mobile recovery is temporarily unavailable. Please try email recovery.');
        }

        enqueueRecovery(async () => {
            try {
                await store.cleanupExpired();
            } catch (_) {
                throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
            }
            await sendOtpForPhone(email, phone);
        });
        return acceptedRecovery(res);
    });

    router.post('/verify-otp', async (req, res) => {
        const email = String(req.body?.email || '').trim().toLowerCase();
        const phone = normalizeMobile(req.body?.mobile);
        const otp = String(req.body?.otp || '');
        if (email.length > 120 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !phone || !/^\d{6}$/.test(otp)) {
            return recoveryError(res, 400, 'INVALID_OTP', INVALID_OTP_MESSAGE);
        }
        const ip = req.ip || req.socket.remoteAddress || 'unknown';
        const limitKey = `${digest(`${email}:${phone}`)}:${ip}`;
        if (!consumeLimit(verificationLimits, limitKey, 20, 15 * 60 * 1000, clock())) {
            return recoveryError(res, 429, 'RATE_LIMITED', 'Too many verification attempts. Try again later.');
        }
        if (typeof otpSecret() !== 'string' || otpSecret().length < 32) {
            return recoveryError(res, 503, 'OTP_SECRET_UNAVAILABLE', 'Mobile recovery is temporarily unavailable. Please try again later.');
        }

        try {
            let user;
            try {
                user = await store.findUserByVerifiedPhone(email, phone);
            } catch (_) {
                throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
            }
            if (!user) return recoveryError(res, 400, 'INVALID_OTP', INVALID_OTP_MESSAGE);
            const resetToken = crypto.randomBytes(32).toString('hex');
            let accepted;
            try {
                accepted = await store.verifyOtpAndCreateReset(
                    user.id,
                    hashOtp(otpSecret(), user.id, otp),
                    digest(resetToken),
                    new Date(clock() + 15 * 60 * 1000),
                );
            } catch (_) {
                throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
            }
            if (!accepted) return recoveryError(res, 400, 'INVALID_OTP', INVALID_OTP_MESSAGE);
            return res.json({ success: true, resetToken });
        } catch (error) {
            const errorId = crypto.randomBytes(4).toString('hex');
            const code = error instanceof RecoveryDependencyError ? error.code : 'RECOVERY_APPLICATION_FAILURE';
            logger.error(`Password recovery verification failed (${errorId}): ${code}`);
            return res.status(500).json({ success: false, code, message: 'Password recovery could not be processed.', errorId });
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
            let userId;
            try {
                userId = await store.consumeResetTokenAndUpdatePassword(digest(token), passwordHash);
            } catch (_) {
                throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
            }
            if (!userId) return recoveryError(res, 400, 'INVALID_TOKEN', INVALID_TOKEN_MESSAGE);
            if (sessionStore) {
                try {
                    await sessionStore.revokeAllUserSessions(userId);
                } catch (_) {
                    throw new RecoveryDependencyError('RECOVERY_DATABASE_UNAVAILABLE');
                }
            } else if (sessions) {
                for (const [sessionToken, session] of sessions) {
                    if (session.userId === userId) sessions.delete(sessionToken);
                }
            }
            return res.json({
                success: true,
                message: 'Your password has been reset successfully. Please log in using your new password.',
            });
        } catch (error) {
            const errorId = crypto.randomBytes(4).toString('hex');
            const code = error instanceof RecoveryDependencyError ? error.code : 'RESET_OPERATION_FAILED';
            logger.error(`Password reset failed (${errorId}): ${code}`);
            return res.status(500).json({ success: false, code, message: 'Could not reset password.', errorId });
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
