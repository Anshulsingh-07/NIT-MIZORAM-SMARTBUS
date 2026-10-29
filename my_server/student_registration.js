'use strict';

const express = require('express');
const bcrypt = require('bcryptjs');
const { normalizeMobile } = require('./password_recovery');

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const PHONE_FORMAT_ERROR = 'Enter the mobile number as +91XXXXXXXXXX or leave it blank';

function safeMessage(error, sensitiveValues = []) {
    let message = String(error?.message || '').replace(/[^\s<>"']+@[^\s<>"']+/g, '[email]');
    for (const value of [...new Set(sensitiveValues)].filter(Boolean).sort((a, b) => b.length - a.length)) {
        message = message.split(value).join('[redacted]');
    }
    return message.slice(0, 200);
}

function missingColumn(error) {
    if (typeof error?.column === 'string' && error.column) return error.column;
    return String(error?.message || '').match(/column\s+"([^"\r\n]+)"/i)?.[1] || null;
}

function isConnectionError(code) {
    return code === 'ECONNREFUSED' || code === 'ETIMEDOUT' || code === '57P01' ||
        (typeof code === 'string' && /^08[A-Z0-9]{3}$/.test(code));
}

function createStudentRegistrationRouter({
    pool,
    rateLimiter,
    hostels,
    emailPattern = EMAIL_PATTERN,
    createToken,
    makeId,
    hashPassword = (password, cost) => bcrypt.hash(password, cost),
    logger = console,
}) {
    const router = express.Router();

    router.post('/register', rateLimiter, async (req, res) => {
        let step = 'validate';
        let client;
        const sensitiveValues = Object.values(req.body && typeof req.body === 'object' ? req.body : {})
            .filter((value) => typeof value === 'string');
        try {
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
            sensitiveValues.push(normalizedName, normalizedEmail, rawMobile, normalizedMobile,
                clearPassword, clearConfirmation, selectedHostel);

            if (!normalizedName || normalizedName.length > 100 ||
                !emailPattern.test(normalizedEmail) ||
                (rawMobile && !normalizedMobile) ||
                clearPassword.length < 8 || clearPassword.length > 128 ||
                clearPassword !== clearConfirmation) {
                return res.status(400).json({ error: 'Complete the required fields with valid values.' });
            }
            if (!hostels.some((hostel) => hostel.id === selectedHostel)) {
                return res.status(400).json({ error: 'Select a valid hostel.' });
            }

            step = 'hash';
            const passwordHash = await hashPassword(clearPassword, 12);
            sensitiveValues.push(passwordHash);

            step = 'insert';
            client = await pool.connect();
            await client.query('BEGIN');
            const existing = await client.query(
                'SELECT id FROM users WHERE LOWER(email) = LOWER($1) LIMIT 1 FOR UPDATE',
                [normalizedEmail],
            );
            if (existing.rows.length) {
                await client.query('ROLLBACK');
                return res.status(409).json({ error: 'Email already registered' });
            }

            const user = {
                id: makeId('usr_'),
                name: normalizedName,
                email: normalizedEmail,
                role: 'student',
                hostel_id: selectedHostel,
                must_change_password: false,
            };
            sensitiveValues.push(user.id);
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

            const code = typeof error?.code === 'string' ? error.code : null;
            const column = missingColumn(error);
            logger.error('Student registration failed', {
                step,
                name: typeof error?.name === 'string' ? error.name : 'Error',
                code,
                constraint: typeof error?.constraint === 'string' ? error.constraint : null,
                column,
                message: safeMessage(error, sensitiveValues),
            });

            if (code === '23505') return res.status(409).json({ error: 'Email already registered' });
            if (code === '23514' &&
                (column === 'recovery_phone' || /recovery_phone/i.test(String(error?.constraint || error?.message || '')))) {
                return res.status(400).json({ error: PHONE_FORMAT_ERROR });
            }
            if (code === '23503') return res.status(400).json({ error: 'Invalid hostel' });
            if (code === '42703') return res.status(500).json({ error: 'Registration failed' });
            if (isConnectionError(code)) {
                return res.status(503).json({ error: 'Registration service temporarily unavailable' });
            }
            return res.status(500).json({ error: 'Registration failed' });
        } finally {
            client?.release();
        }
    });

    return router;
}

module.exports = { createStudentRegistrationRouter, isConnectionError };
