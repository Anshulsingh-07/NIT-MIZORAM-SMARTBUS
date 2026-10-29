'use strict';

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const express = require('express');
const { recoveryEmailProvider, sendRecoveryEmail } = require('./recovery_email');

const GENERIC_MESSAGE = 'If this email is registered, a code has been sent. Check your spam folder too.';
const INVALID_MESSAGE = 'Invalid or expired code';

function createEmailPasswordRecoveryRouter({ getPool, env = process.env, logger = console, fetchImpl = globalThis.fetch, timeoutMs = 15000, clock = Date.now }) {
    const router = express.Router();
    const emailRequests = new Map();
    const ipRequests = new Map();
    const verifyRequests = new Map();

    function allow(map, key, limit, windowMs) {
        const now = clock();
        const recent = (map.get(key) || []).filter((time) => now - time < windowMs);
        if (recent.length >= limit) { map.set(key, recent); return false; }
        recent.push(now);
        map.set(key, recent);
        return true;
    }

    function enabled() { return Boolean(recoveryEmailProvider(env)); }
    function unavailable(res) { return res.status(503).json({ error: 'Email recovery is temporarily unavailable.' }); }
    function badCode(res) { return res.status(400).json({ error: INVALID_MESSAGE }); }

    async function sendEmail(to, otp) {
        await sendRecoveryEmail({ to, otp }, { env, fetchImpl, timeoutMs });
    }

    async function requestHandler(req, res) {
        const email = String(req.body?.email || '').trim().toLowerCase();
        const ip = req.ip || req.socket?.remoteAddress || 'unknown';
        if (!email || email.length > 120 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
            return res.status(400).json({ error: 'Enter a valid email address.' });
        }
        const emailKey = crypto.createHash('sha256').update(email).digest('hex');
        if (!allow(emailRequests, emailKey, 3, 15 * 60 * 1000) || !allow(ipRequests, ip, 10, 60 * 60 * 1000)) {
            return res.status(429).json({ error: 'Too many recovery requests. Try again later.' });
        }
        if (!enabled()) return unavailable(res);

        // Acknowledge before lookup and delivery so account existence is not disclosed.
        res.status(202).json({ accepted: true, deliveryConfirmed: false, code: 'RECOVERY_ACCEPTED', message: GENERIC_MESSAGE });
        setImmediate(async () => {
            try {
                const pool = getPool();
                const result = await pool.query('SELECT id, email FROM users WHERE LOWER(email) = $1 LIMIT 1', [email]);
                const user = result.rows[0];
                if (!user) return;
                const otp = String(crypto.randomInt(0, 1000000)).padStart(6, '0');
                const otpHash = await bcrypt.hash(otp, 12);
                const client = await pool.connect();
                try {
                    await client.query('BEGIN');
                    await client.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [user.id]);
                    const recent = await client.query(`SELECT id FROM email_password_recovery_otps
                        WHERE user_id = $1 AND created_at > NOW() - INTERVAL '60 seconds'
                        LIMIT 1`, [user.id]);
                    if (recent.rows.length) {
                        await client.query('ROLLBACK');
                        return;
                    }
                    await client.query('UPDATE email_password_recovery_otps SET used = true WHERE user_id = $1 AND used = false', [user.id]);
                    await client.query('INSERT INTO email_password_recovery_otps (user_id, otp_hash, expires_at) VALUES ($1, $2, NOW() + INTERVAL \'10 minutes\')', [user.id, otpHash]);
                    await client.query('COMMIT');
                } catch (error) {
                    await client.query('ROLLBACK').catch(() => {});
                    throw error;
                } finally {
                    client.release();
                }
                try {
                    await sendEmail(user.email, otp);
                } catch (error) {
                    logger.error('Password recovery email delivery failed', {
                        route: req.baseUrl + req.path,
                        provider: error.provider || 'unknown',
                        status: Number.isInteger(error.status) ? error.status : 0,
                        error: error.providerError || 'send_failed',
                    });
                    await pool.query('UPDATE email_password_recovery_otps SET used = true WHERE user_id = $1 AND used = false', [user.id]).catch(() => {});
                }
            } catch (error) {
                logger.error('Password recovery request failed: RECOVERY_DATABASE_UNAVAILABLE', error?.name || 'Error');
            }
        });
    }

    async function verifyHandler(req, res) {
        const email = String(req.body?.email || '').trim().toLowerCase();
        const otp = String(req.body?.otp || '');
        const newPassword = String(req.body?.newPassword || '');
        const ip = req.ip || req.socket?.remoteAddress || 'unknown';
        const limitKey = `${crypto.createHash('sha256').update(email).digest('hex')}:${ip}`;
        if (!allow(verifyRequests, limitKey, 20, 15 * 60 * 1000)) return res.status(429).json({ code: 'TOO_MANY_ATTEMPTS', error: 'Too many verification attempts. Try again later.' });
        if (!email || !/^\d{6}$/.test(otp) || newPassword.length < 8 || newPassword.length > 128) return badCode(res);

        let client;
        try {
            client = await getPool().connect();
            await client.query('BEGIN');
            const userResult = await client.query('SELECT id FROM users WHERE LOWER(email) = $1 LIMIT 1', [email]);
            const user = userResult.rows[0];
            if (!user) { await client.query('ROLLBACK'); return badCode(res); }
            const otpResult = await client.query(`SELECT id, otp_hash, attempts, used, expires_at FROM email_password_recovery_otps
                WHERE user_id = $1
                ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [user.id]);
            const record = otpResult.rows[0];
            if (!record) { await client.query('ROLLBACK'); return badCode(res); }
            if (Number(record.attempts) >= 5) {
                await client.query('UPDATE email_password_recovery_otps SET used = true WHERE id = $1', [record.id]);
                await client.query('COMMIT');
                return res.status(429).json({ code: 'TOO_MANY_ATTEMPTS', error: 'Too many attempts. Request a new code.' });
            }
            if (record.used) { await client.query('ROLLBACK'); return badCode(res); }
            if (new Date(record.expires_at).getTime() <= clock()) {
                await client.query('UPDATE email_password_recovery_otps SET used = true WHERE id = $1', [record.id]);
                await client.query('COMMIT');
                return res.status(400).json({ code: 'OTP_EXPIRED', error: 'This code has expired. Request a new code.' });
            }
            if (!await bcrypt.compare(otp, record.otp_hash)) {
                await client.query(`UPDATE email_password_recovery_otps SET attempts = attempts + 1,
                    used = CASE WHEN attempts + 1 >= 5 THEN true ELSE used END WHERE id = $1`, [record.id]);
                await client.query('COMMIT');
                return Number(record.attempts) + 1 >= 5
                    ? res.status(429).json({ code: 'TOO_MANY_ATTEMPTS', error: 'Too many attempts. Request a new code.' })
                    : res.status(400).json({ code: 'INVALID_OTP', error: 'The code is incorrect.' });
            }
            const passwordHash = await bcrypt.hash(newPassword, 12);
            await client.query('UPDATE users SET password = $1, must_change_password = false WHERE id = $2', [passwordHash, user.id]);
            await client.query('UPDATE email_password_recovery_otps SET used = true WHERE user_id = $1 AND used = false', [user.id]);
            await client.query('DELETE FROM sessions WHERE user_id = $1', [user.id]);
            await client.query('COMMIT');
            return res.json({ success: true, message: 'Password updated. Please sign in with your new password.' });
        } catch (error) {
            if (client) await client.query('ROLLBACK').catch(() => {});
            logger.error('Password recovery verification failed: RECOVERY_DATABASE_UNAVAILABLE');
            return badCode(res);
        } finally {
            client?.release();
        }
    }

    function canonicalRequest(req, res, next) {
        const method = String(req.body?.method || 'email').toLowerCase();
        return method === 'email' ? requestHandler(req, res) : next();
    }

    function resendRequest(req, res, next) {
        return req.body?.email && !req.body?.mobile ? requestHandler(req, res) : next();
    }

    function canonicalVerify(req, res, next) {
        return req.body?.email && !req.body?.mobile ? verifyHandler(req, res) : next();
    }

    router.post('/forgot-password', canonicalRequest);
    router.post('/password-recovery/request', requestHandler);
    router.post('/request', requestHandler);
    router.post('/resend-otp', resendRequest);
    router.post('/password-recovery/verify', verifyHandler);
    router.post('/verify-email-otp', verifyHandler);
    router.post('/verify-otp', canonicalVerify);
    return router;
}

module.exports = { createEmailPasswordRecoveryRouter };
