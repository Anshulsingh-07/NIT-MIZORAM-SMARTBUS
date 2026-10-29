'use strict';

const express = require('express');
const bcrypt = require('bcryptjs');
const { normalizeMobile } = require('./password_recovery');

function createStudentRegistrationRouter({
    pool,
    rateLimiter,
    hostels,
    emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/,
    createToken,
    makeId,
    logger = console,
}) {
    const router = express.Router();

    router.post('/register', rateLimiter, async (req, res) => {
        const { name, email, mobile, password, confirmPassword, hostelId } = req.body || {};
        const normalizedName = String(name || '').trim();
        const normalizedEmail = String(email || '').trim().toLowerCase();
        const rawMobile = String(mobile || '').trim();
        const compactMobile = rawMobile.replace(/[()\s-]/g, '');
        const normalizedMobile = rawMobile && /^[+0-9()\s-]+$/.test(rawMobile) &&
            /^(?:\+?91)?[6-9]\d{9}$/.test(compactMobile)
            ? normalizeMobile(compactMobile)
            : null;
        const clearPassword = String(password || '');
        const clearConfirmation = String(confirmPassword || '');
        const selectedHostel = String(hostelId || '').trim().toUpperCase();

        if (!normalizedName || normalizedName.length > 100 ||
            !emailPattern.test(normalizedEmail) ||
            rawMobile && !normalizedMobile ||
            clearPassword.length < 8 || clearPassword.length > 128 ||
            clearPassword !== clearConfirmation) {
            return res.status(400).json({ error: 'Complete the required fields with valid values.' });
        }
        if (!hostels.some((hostel) => hostel.id === selectedHostel)) {
            return res.status(400).json({ error: 'Select a valid hostel.' });
        }

        let client;
        try {
            const passwordHash = await bcrypt.hash(clearPassword, 12);
            client = await pool.connect();
            await client.query('BEGIN');
            const existing = await client.query(
                'SELECT id FROM users WHERE LOWER(email) = LOWER($1) LIMIT 1 FOR UPDATE',
                [normalizedEmail],
            );
            if (existing.rows.length) {
                await client.query('ROLLBACK');
                return res.status(409).json({ error: 'This email is already registered — log in instead.' });
            }

            const user = {
                id: makeId('usr_'),
                name: normalizedName,
                email: normalizedEmail,
                role: 'student',
                hostel_id: selectedHostel,
                must_change_password: false,
            };
            await client.query(
                `INSERT INTO users
                    (id, name, email, password, role, hostel_id, recovery_email,
                     recovery_phone, recovery_phone_verified_at, must_change_password)
                 VALUES ($1, $2, $3, $4, 'student', $5, $6, $7, NULL, false)`,
                [user.id, user.name, user.email, passwordHash, user.hostel_id,
                    normalizedEmail, normalizedMobile],
            );
            await client.query('COMMIT');
            const token = await createToken(user);
            return res.status(201).json({
                token,
                user: {
                    id: user.id,
                    name: user.name,
                    email: user.email,
                    role: user.role,
                    hostelId: user.hostel_id,
                    mustChangePassword: false,
                },
            });
        } catch (error) {
            if (client) await client.query('ROLLBACK').catch(() => {});
            if (error.code === '23505') {
                return res.status(409).json({ error: 'This email is already registered — log in instead.' });
            }
            logger.error('Student registration failed: REGISTRATION_DATABASE_UNAVAILABLE');
            return res.status(500).json({ error: 'Registration could not be completed.' });
        } finally {
            client?.release();
        }
    });

    return router;
}

module.exports = { createStudentRegistrationRouter };
