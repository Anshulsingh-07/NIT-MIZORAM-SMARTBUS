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
            await pool.query('DELETE FROM registration_mobile_verifications WHERE expires_at <= NOW() OR used_at IS NOT NULL');
        },

        async findUserByEmail(email) {
            const result = await getPool().query(
                'SELECT id, email FROM users WHERE LOWER(email) = LOWER($1) LIMIT 1',
                [email],
            );
            return result.rows[0] || null;
        },

        async findUserByVerifiedPhone(email, phone) {
            const result = await getPool().query(
                `SELECT id FROM users
                 WHERE LOWER(email) = LOWER($1) AND recovery_phone = $2
                   AND recovery_phone_verified_at IS NOT NULL
                 LIMIT 1`,
                [email, phone],
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

        async createRegistrationMobileChallenge(email, mobile, otpHash, expiresAt, cooldownMs) {
            const result = await getPool().query(
                `INSERT INTO registration_mobile_verifications
                    (id, email, mobile, otp_hash, expires_at)
                 VALUES ($1, $2, $3, $4, $5)
                 ON CONFLICT (email, mobile) DO UPDATE SET
                    id = EXCLUDED.id,
                    otp_hash = EXCLUDED.otp_hash,
                    attempts = 0,
                    verification_token_hash = NULL,
                    expires_at = EXCLUDED.expires_at,
                    verified_at = NULL,
                    used_at = NULL,
                    created_at = NOW()
                 WHERE registration_mobile_verifications.created_at <= NOW() - ($6 * INTERVAL '1 millisecond')
                 RETURNING id`,
                [crypto.randomUUID(), email, mobile, otpHash, expiresAt, cooldownMs],
            );
            return result.rows.length === 1;
        },

        async invalidateRegistrationMobileChallenge(email, mobile) {
            await getPool().query(
                `UPDATE registration_mobile_verifications SET used_at = NOW()
                 WHERE email = $1 AND mobile = $2 AND used_at IS NULL`,
                [email, mobile],
            );
        },

        async verifyRegistrationMobileChallenge(email, mobile, candidateOtpHash, verificationTokenHash, tokenExpiresAt) {
            return transaction(async (client) => {
                const result = await client.query(
                    `SELECT id, otp_hash, attempts FROM registration_mobile_verifications
                     WHERE email = $1 AND mobile = $2 AND used_at IS NULL
                       AND verified_at IS NULL AND expires_at > NOW()
                     LIMIT 1 FOR UPDATE`,
                    [email, mobile],
                );
                const challenge = result.rows[0];
                if (!challenge || Number(challenge.attempts) >= 5) return false;
                const storedHash = Buffer.from(String(challenge.otp_hash).trim(), 'hex');
                const submittedHash = Buffer.from(candidateOtpHash, 'hex');
                const matches = storedHash.length === submittedHash.length &&
                    crypto.timingSafeEqual(storedHash, submittedHash);
                if (!matches) {
                    await client.query(
                        'UPDATE registration_mobile_verifications SET attempts = attempts + 1 WHERE id = $1',
                        [challenge.id],
                    );
                    return false;
                }
                await client.query(
                    `UPDATE registration_mobile_verifications
                     SET verified_at = NOW(), verification_token_hash = $1, expires_at = $2
                     WHERE id = $3`,
                    [verificationTokenHash, tokenExpiresAt, challenge.id],
                );
                return true;
            });
        },

        async consumeRegistrationMobileVerification(client, email, mobile, tokenHash) {
            const result = await client.query(
                `UPDATE registration_mobile_verifications SET used_at = NOW()
                 WHERE email = $1 AND mobile = $2 AND verification_token_hash = $3
                   AND verified_at IS NOT NULL AND used_at IS NULL AND expires_at > NOW()
                 RETURNING id`,
                [email, mobile, tokenHash],
            );
            return result.rows.length === 1;
        },
    };
}

module.exports = { createPasswordRecoveryStore };