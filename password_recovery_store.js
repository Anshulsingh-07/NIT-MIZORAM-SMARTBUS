'use strict';

const crypto = require('crypto');

function createPasswordRecoveryStore(getPool) {
    const getClient = async () => getPool().connect();

    async function transaction(operation) {
        const client = await getClient();
        try {
            await client.query('BEGIN');
            const result = await operation(client);
            await client.query('COMMIT');
            return result;
        } catch (error) {
            await client.query('ROLLBACK').catch(() => {});
            throw error;
        } finally {
            client.release();
        }
    }

    return {
        async cleanupExpired() {
            const pool = getPool();
            await pool.query('DELETE FROM password_resets WHERE expires_at <= NOW() OR used_at IS NOT NULL');
            await pool.query('DELETE FROM password_reset_otps WHERE expires_at <= NOW() OR used_at IS NOT NULL');
        },

        async findUserByEmail(email) {
            const result = await getPool().query(
                'SELECT id, email FROM users WHERE LOWER(email) = LOWER($1) LIMIT 1',
                [email],
            );
            return result.rows[0] || null;
        },

        async findUserByVerifiedPhone(phone) {
            const result = await getPool().query(
                `SELECT id FROM users
                 WHERE recovery_phone = $1 AND recovery_phone_verified_at IS NOT NULL
                 LIMIT 1`,
                [phone],
            );
            return result.rows[0] || null;
        },

        async createEmailReset(userId, tokenHash, expiresAt) {
            return transaction(async (client) => {
                await client.query(
                    'DELETE FROM password_resets WHERE user_id = $1 AND used_at IS NULL',
                    [userId],
                );
                await client.query(
                    'INSERT INTO password_resets (user_id, token_hash, expires_at) VALUES ($1, $2, $3)',
                    [userId, tokenHash, expiresAt],
                );
            });
        },

        async deleteResetToken(tokenHash) {
            await getPool().query('DELETE FROM password_resets WHERE token_hash = $1', [tokenHash]);
        },

        async createOtpIfCooldownElapsed(userId, otpHash, expiresAt, cooldownMs) {
            return transaction(async (client) => {
                const account = await client.query('SELECT id FROM users WHERE id = $1 FOR UPDATE', [userId]);
                if (!account.rows.length) return false;
                const recent = await client.query(
                    `SELECT id FROM password_reset_otps
                     WHERE user_id = $1 AND created_at > NOW() - ($2 * INTERVAL '1 millisecond')
                     LIMIT 1`,
                    [userId, cooldownMs],
                );
                if (recent.rows.length) return false;
                await client.query(
                    'UPDATE password_reset_otps SET used_at = NOW() WHERE user_id = $1 AND used_at IS NULL',
                    [userId],
                );
                await client.query(
                    'INSERT INTO password_reset_otps (user_id, otp_hash, expires_at) VALUES ($1, $2, $3)',
                    [userId, otpHash, expiresAt],
                );
                return true;
            });
        },

        async invalidateOtps(userId) {
            await getPool().query(
                'UPDATE password_reset_otps SET used_at = NOW() WHERE user_id = $1 AND used_at IS NULL',
                [userId],
            );
        },

        async verifyOtpAndCreateReset(userId, candidateHash, resetTokenHash, expiresAt) {
            return transaction(async (client) => {
                const result = await client.query(
                    `SELECT id, otp_hash, attempts FROM password_reset_otps
                     WHERE user_id = $1 AND used_at IS NULL AND expires_at > NOW()
                     ORDER BY created_at DESC LIMIT 1 FOR UPDATE`,
                    [userId],
                );
                const otp = result.rows[0];
                if (!otp || Number(otp.attempts) >= 5) return false;

                const storedHash = Buffer.from(String(otp.otp_hash).trim(), 'hex');
                const submittedHash = Buffer.from(candidateHash, 'hex');
                const matches = storedHash.length === submittedHash.length &&
                    crypto.timingSafeEqual(storedHash, submittedHash);
                if (!matches) {
                    await client.query(
                        `UPDATE password_reset_otps
                         SET attempts = attempts + 1,
                             used_at = CASE WHEN attempts + 1 >= 5 THEN NOW() ELSE used_at END
                         WHERE id = $1`,
                        [otp.id],
                    );
                    return false;
                }

                await client.query('UPDATE password_reset_otps SET used_at = NOW() WHERE id = $1', [otp.id]);
                await client.query(
                    'DELETE FROM password_resets WHERE user_id = $1 AND used_at IS NULL',
                    [userId],
                );
                await client.query(
                    'INSERT INTO password_resets (user_id, token_hash, expires_at) VALUES ($1, $2, $3)',
                    [userId, resetTokenHash, expiresAt],
                );
                return true;
            });
        },

        async consumeResetTokenAndUpdatePassword(tokenHash, passwordHash) {
            return transaction(async (client) => {
                const result = await client.query(
                    `UPDATE password_resets SET used_at = NOW()
                     WHERE token_hash = $1 AND used_at IS NULL AND expires_at > NOW()
                     RETURNING user_id`,
                    [tokenHash],
                );
                const userId = result.rows[0]?.user_id;
                if (!userId) return null;
                await client.query(
                    'UPDATE users SET password = $1, must_change_password = false WHERE id = $2',
                    [passwordHash, userId],
                );
                await client.query('DELETE FROM password_resets WHERE user_id = $1', [userId]);
                await client.query(
                    'UPDATE password_reset_otps SET used_at = NOW() WHERE user_id = $1 AND used_at IS NULL',
                    [userId],
                );
                return userId;
            });
        },
    };
}

module.exports = { createPasswordRecoveryStore };