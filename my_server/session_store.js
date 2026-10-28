'use strict';

const crypto = require('crypto');

function hashSessionToken(token) {
    return crypto.createHash('sha256').update(String(token)).digest('hex');
}

function createSessionStore(getPool) {
    return {
        async create(token, user, expiresAt) {
            await getPool().query(
                `INSERT INTO sessions
                   (token_hash, user_id, email, role, hostel_id, phone, bus_number, must_change_password, expires_at)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
                [hashSessionToken(token), user.id, user.email || null, user.role, user.hostel_id || null,
                    user.phone || null, user.bus_number || null, Boolean(user.must_change_password), expiresAt],
            );
        },

        async findByToken(token) {
            const tokenHash = hashSessionToken(token);
            const result = await getPool().query(
                `SELECT user_id AS "userId", email, role, hostel_id AS "hostelId", phone,
                        bus_number AS "busNumber", must_change_password AS "mustChangePassword",
                        expires_at AS "expiresAt"
                 FROM sessions WHERE token_hash = $1 AND expires_at > NOW() LIMIT 1`,
                [tokenHash],
            );
            if (result.rows.length) return result.rows[0];
            await getPool().query('DELETE FROM sessions WHERE token_hash = $1 AND expires_at <= NOW()', [tokenHash]);
            return null;
        },

        async revoke(token) {
            await getPool().query('DELETE FROM sessions WHERE token_hash = $1', [hashSessionToken(token)]);
        },

        async revokeOtherUserSessions(userId, currentToken) {
            await getPool().query(
                'DELETE FROM sessions WHERE user_id = $1 AND token_hash <> $2',
                [userId, hashSessionToken(currentToken)],
            );
        },

        async revokeAllUserSessions(userId) {
            await getPool().query('DELETE FROM sessions WHERE user_id = $1', [userId]);
        },

        async updateMustChangePassword(token, value) {
            await getPool().query(
                'UPDATE sessions SET must_change_password = $1 WHERE token_hash = $2',
                [Boolean(value), hashSessionToken(token)],
            );
        },

        async cleanupExpired() {
            await getPool().query('DELETE FROM sessions WHERE expires_at <= NOW()');
        },
    };
}

module.exports = { createSessionStore, hashSessionToken };