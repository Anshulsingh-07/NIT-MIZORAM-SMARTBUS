'use strict';

const crypto = require('crypto');

function hashLoginIdentifier(kind, value) {
    return crypto.createHash('sha256').update(`${kind}:${value}`).digest('hex');
}

function progressiveDelaySeconds(failedAttempts) {
    const exponent = Math.max(0, Math.min(5, Number(failedAttempts) - 1));
    return Math.min(30, 2 ** exponent);
}

function createLoginAttemptStore(getPool) {
    return {
        async getBlockedUntil(identifierHashes) {
            const result = await getPool().query(
                `SELECT MAX(blocked_until) AS blocked_until FROM login_attempts
                 WHERE identifier_hash = ANY($1::char(64)[]) AND blocked_until > NOW()`,
                [identifierHashes],
            );
            return result.rows[0]?.blocked_until || null;
        },

        async recordFailure(identifierHashes) {
            const client = await getPool().connect();
            try {
                await client.query('BEGIN');
                for (const identifierHash of identifierHashes) {
                    const result = await client.query(
                        `INSERT INTO login_attempts (identifier_hash, failed_attempts)
                         VALUES ($1, 1)
                         ON CONFLICT (identifier_hash) DO UPDATE SET
                           failed_attempts = LEAST(login_attempts.failed_attempts + 1, 6),
                           updated_at = NOW()
                         RETURNING failed_attempts`,
                        [identifierHash],
                    );
                    const delaySeconds = progressiveDelaySeconds(result.rows[0].failed_attempts);
                    await client.query(
                        `UPDATE login_attempts
                         SET blocked_until = NOW() + make_interval(secs => $2), updated_at = NOW()
                         WHERE identifier_hash = $1`,
                        [identifierHash, delaySeconds],
                    );
                }
                await client.query('COMMIT');
            } catch (error) {
                await client.query('ROLLBACK').catch(() => {});
                throw error;
            } finally {
                client.release();
            }
        },

        async clear(identifierHashes) {
            await getPool().query(
                'DELETE FROM login_attempts WHERE identifier_hash = ANY($1::char(64)[])',
                [identifierHashes],
            );
        },

        async cleanup() {
            await getPool().query("DELETE FROM login_attempts WHERE updated_at < NOW() - INTERVAL '30 days'");
        },
    };
}

module.exports = { createLoginAttemptStore, hashLoginIdentifier, progressiveDelaySeconds };