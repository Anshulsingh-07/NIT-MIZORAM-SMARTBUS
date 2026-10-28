'use strict';

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const express = require('express');

const GENERIC_MESSAGE = 'If this email is registered, a code has been sent.';
const INVALID_MESSAGE = 'Invalid or expired code';

function createEmailPasswordRecoveryRouter({ getPool, env = process.env, logger = console, fetchImpl = globalThis.fetch, clock = Date.now }) {
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

    function enabled() { return Boolean(env.RESEND_API_KEY && env.MAIL_FROM); }
    function unavailable(res) { return res.status(503).json({ error: 'Email recovery is temporarily unavailable.' }); }
    function badCode(res) { return res.status(400).json({ error: INVALID_MESSAGE }); }

    async function sendEmail(to, otp) {
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 8000);
        let response;
        try {
            response = await fetchImpl('https://api.resend.com/emails', {
                method: 'POST',
                headers: { authorization: `Bearer ${env.RESEND_API_KEY}`, 'content-type': 'application/json' },
                body: JSON.stringify({
                    from: env.MAIL_FROM,
                    to: [to],
                    subject: 'Campus Bus Tracker password recovery',
                    text: `Your password recovery code is ${otp}. It expires in 10 minutes. If you did not request this code, ignore this email.`,
                }),
                signal: controller.signal,
            });
        } finally {
            clearTimeout(timeout);
        }
        if (!response.ok) {
            const body = await response.text().catch(() => '');
            const error = new Error(`Resend HTTP ${response.status}`);
            error.providerBody = body;
            throw error;
        }
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

        // Respond generically before lookup and delivery so account existence is not disclosed.
        res.status(200).json({ success: true, message: GENERIC_MESSAGE });
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
                    logger.error('Resend email delivery failed:', error.providerBody || error.message);
                    await pool.query('UPDATE email_password_recovery_otps SET used = true WHERE user_id = $1 AND used = false', [user.id]).catch(() => {});
                }
            } catch (error) {
                logger.error('Password recovery request failed:', error.providerBody || error.message);
            }
        });
    }

    async function verifyHandler(req, res) {
        const email = String(req.body?.email || '').trim().toLowerCase();
        const otp = String(req.body?.otp || '');
        const newPassword = String(req.body?.newPassword || '');
        const ip = req.ip || req.socket?.remoteAddress || 'unknown';
        if (!enabled()) return unavailable(res);
        const limitKey = `${crypto.createHash('sha256').update(email).digest('hex')}:${ip}`;
        if (!allow(verifyRequests, limitKey, 20, 15 * 60 * 1000)) return res.status(429).json({ error: 'Too many verification attempts. Try again later.' });
        if (!email || !/^\d{6}$/.test(otp) || newPassword.length < 8 || newPassword.length > 128) return badCode(res);

        let client;
        try {
            client = await getPool().connect();
            await client.query('BEGIN');
            const userResult = await client.query('SELECT id FROM users WHERE LOWER(email) = $1 LIMIT 1', [email]);
            const user = userResult.rows[0];
            if (!user) { await client.query('ROLLBACK'); return badCode(res); }
            const otpResult = await client.query(`SELECT id, otp_hash, attempts FROM email_password_recovery_otps
                WHERE user_id = $1 AND used = false AND expires_at > NOW()
                ORDER BY created_at DESC LIMIT 1 FOR UPDATE`, [user.id]);
            const record = otpResult.rows[0];
            if (!record || Number(record.attempts) >= 5) { await client.query('ROLLBACK'); return badCode(res); }
            if (!await bcrypt.compare(otp, record.otp_hash)) {
                await client.query(`UPDATE email_password_recovery_otps SET attempts = attempts + 1,
                    used = CASE WHEN attempts + 1 >= 5 THEN true ELSE used END WHERE id = $1`, [record.id]);
                await client.query('COMMIT');
                return badCode(res);
            }
            const passwordHash = await bcrypt.hash(newPassword, 12);
            await client.query('UPDATE users SET password = $1, must_change_password = false WHERE id = $2', [passwordHash, user.id]);
            await client.query('UPDATE email_password_recovery_otps SET used = true WHERE user_id = $1 AND used = false', [user.id]);
            await client.query('DELETE FROM sessions WHERE user_id = $1', [user.id]);
            await client.query('COMMIT');
            return res.json({ success: true, message: 'Password updated. Please sign in with your new password.' });
        } catch (error) {
            if (client) await client.query('ROLLBACK').catch(() => {});
            logger.error('Password recovery verification failed:', error.message);
            return badCode(res);
        } finally {
            client?.release();
        }
    }

    router.post('/password-recovery/request', requestHandler);
    router.post('/password-recovery/verify', verifyHandler);
    router.post('/request', requestHandler);
    return router;
}

module.exports = { createEmailPasswordRecoveryRouter };
