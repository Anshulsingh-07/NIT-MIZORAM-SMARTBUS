'use strict';

const crypto = require('crypto');
const express = require('express');
const { digest, hashOtp, normalizeMobile } = require('./password_recovery');

const GENERIC_MESSAGE = 'If this email and mobile can be verified, a code has been sent.';
const INVALID_OTP_MESSAGE = 'The code is invalid or expired.';

function createRegistrationMobileRouter({
    store,
    smsConfigured,
    sendSms,
    otpSecret,
    clock = Date.now,
    logger = console,
}) {
    const router = express.Router();
    const requestLimits = new Map();
    const verifyLimits = new Map();

    function allow(limits, key, maximum, windowMs) {
        const now = clock();
        const recent = (limits.get(key) || []).filter((timestamp) => now - timestamp < windowMs);
        if (recent.length >= maximum) {
            limits.set(key, recent);
            return false;
        }
        recent.push(now);
        limits.set(key, recent);
        return true;
    }

    function parseIdentity(body) {
        const email = String(body?.email || '').trim().toLowerCase();
        const mobile = normalizeMobile(body?.mobile);
        if (email.length > 120 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !mobile) {
            return null;
        }
        return { email, mobile };
    }

    router.post('/request', async (req, res) => {
        const identity = parseIdentity(req.body);
        if (!identity) {
            return res.status(400).json({
                success: false,
                code: 'INVALID_REQUEST',
                message: 'Enter a valid college email and 10-digit mobile number.',
            });
        }
        const ip = req.ip || req.socket.remoteAddress || 'unknown';
        const identityKey = digest(`${identity.email}:${identity.mobile}`);
        if (!allow(requestLimits, identityKey, 3, 15 * 60 * 1000) ||
            !allow(requestLimits, `ip:${ip}`, 10, 60 * 60 * 1000)) {
            return res.status(429).json({
                success: false,
                code: 'RATE_LIMITED',
                message: 'Too many verification requests. Try again later.',
            });
        }
        if (!smsConfigured()) {
            return res.status(503).json({
                success: false,
                code: 'SMS_PROVIDER_UNAVAILABLE',
                message: 'Mobile verification is temporarily unavailable.',
            });
        }
        if (typeof otpSecret() !== 'string' || otpSecret().length < 32) {
            return res.status(503).json({
                success: false,
                code: 'OTP_SECRET_UNAVAILABLE',
                message: 'Mobile verification is temporarily unavailable.',
            });
        }

        const otp = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
        try {
            await store.cleanupExpired();
        } catch (_) {
            logger.error('Student mobile verification failed: REGISTRATION_DATABASE_UNAVAILABLE');
            return res.status(503).json({
                success: false,
                code: 'REGISTRATION_DATABASE_UNAVAILABLE',
                message: 'Mobile verification is temporarily unavailable.',
            });
        }
        let created;
        try {
            created = await store.createRegistrationMobileChallenge(
                identity.email,
                identity.mobile,
                hashOtp(otpSecret(), `${identity.email}:${identity.mobile}`, otp),
                new Date(clock() + 5 * 60 * 1000),
                60 * 1000,
            );
        } catch (_) {
            logger.error('Student mobile verification failed: REGISTRATION_DATABASE_UNAVAILABLE');
            return res.status(503).json({
                success: false,
                code: 'REGISTRATION_DATABASE_UNAVAILABLE',
                message: 'Mobile verification is temporarily unavailable.',
            });
        }
        if (!created) {
            return res.status(429).json({
                success: false,
                code: 'RATE_LIMITED',
                message: 'Wait before requesting another verification code.',
            });
        }
        try {
            await sendSms(
                identity.mobile,
                `Your SmartBus student registration code is ${otp}. It expires in 5 minutes.`,
            );
            return res.json({ success: true, message: GENERIC_MESSAGE });
        } catch (_) {
            try {
                await store.invalidateRegistrationMobileChallenge(identity.email, identity.mobile);
            } catch (_) {
                logger.error('Student mobile verification failed: REGISTRATION_DATABASE_UNAVAILABLE');
                return res.status(503).json({
                    success: false,
                    code: 'REGISTRATION_DATABASE_UNAVAILABLE',
                    message: 'Mobile verification is temporarily unavailable.',
                });
            }
            logger.warn('Student mobile verification failed: SMS_DELIVERY_PROVIDER_FAILED');
            return res.status(503).json({
                success: false,
                code: 'SMS_DELIVERY_PROVIDER_FAILED',
                message: 'Mobile verification is temporarily unavailable.',
            });
        }
    });

    router.post('/verify', async (req, res) => {
        const identity = parseIdentity(req.body);
        const otp = String(req.body?.otp || '');
        if (!identity || !/^\d{6}$/.test(otp)) {
            return res.status(400).json({
                success: false,
                code: 'INVALID_OTP',
                message: INVALID_OTP_MESSAGE,
            });
        }
        const ip = req.ip || req.socket.remoteAddress || 'unknown';
        const identityKey = digest(`${identity.email}:${identity.mobile}`);
        if (!allow(verifyLimits, `${identityKey}:${ip}`, 10, 15 * 60 * 1000)) {
            return res.status(429).json({
                success: false,
                code: 'RATE_LIMITED',
                message: 'Too many verification attempts. Try again later.',
            });
        }
        if (typeof otpSecret() !== 'string' || otpSecret().length < 32) {
            return res.status(503).json({
                success: false,
                code: 'OTP_SECRET_UNAVAILABLE',
                message: 'Mobile verification is temporarily unavailable.',
            });
        }

        try {
            const verificationToken = crypto.randomBytes(32).toString('hex');
            const verified = await store.verifyRegistrationMobileChallenge(
                identity.email,
                identity.mobile,
                hashOtp(otpSecret(), `${identity.email}:${identity.mobile}`, otp),
                digest(verificationToken),
                new Date(clock() + 10 * 60 * 1000),
            );
            if (!verified) {
                return res.status(400).json({
                    success: false,
                    code: 'INVALID_OTP',
                    message: INVALID_OTP_MESSAGE,
                });
            }
            return res.json({ success: true, verificationToken });
        } catch (error) {
            const errorId = crypto.randomBytes(4).toString('hex');
            logger.error(`Student mobile verification failed (${errorId}): REGISTRATION_DATABASE_UNAVAILABLE`);
            return res.status(500).json({
                success: false,
                code: 'REGISTRATION_DATABASE_UNAVAILABLE',
                message: 'Mobile verification could not be completed.',
                errorId,
            });
        }
    });

    return router;
}

module.exports = { createRegistrationMobileRouter };
