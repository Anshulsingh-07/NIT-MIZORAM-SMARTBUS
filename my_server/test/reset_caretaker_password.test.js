'use strict';

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const bcrypt = require('bcryptjs');
const {
    identifierQuery,
    normalizeVerifiedMobile,
    parseArgs,
    updateCaretakerPassword,
} = require('../scripts/reset-caretaker-password');

const candidatePassword = 'CLI-test-password-123';

function createFakeClient({ user, hasHostel = true } = {}) {
    const calls = [];
    return {
        calls,
        async query(sql, values = []) {
            calls.push({ sql, values });
            if (sql.startsWith('SELECT id, role, hostel_id FROM users')) {
                return { rows: user ? [user] : [] };
            }
            if (sql.startsWith('SELECT id FROM hostels')) {
                return { rows: hasHostel ? [{ id: user.hostel_id }] : [] };
            }
            return { rows: [] };
        },
    };
}

test('reset CLI parses exactly one identifier and requires explicit confirmation', () => {
    assert.deepEqual(parseArgs(['--email', 'caretaker-bh1@nitmz.ac.in', '--confirm']), {
        confirm: true,
        identifierType: 'email',
        identifier: 'caretaker-bh1@nitmz.ac.in',
    });
    assert.throws(() => parseArgs(['--email', 'one@example.test', '--username', 'usr_1']), /exactly one caretaker identifier/);
    assert.throws(() => parseArgs(['--unknown']), /Unknown command-line option/);
});

test('identifier queries normalize email and require verified mobile ownership', () => {
    assert.equal(identifierQuery('email', 'CARETAKER-BH1@NITMZ.AC.IN').value, 'caretaker-bh1@nitmz.ac.in');
    const mobileQuery = identifierQuery('mobile', '+91 98765 43210');
    assert.equal(mobileQuery.value, '+919876543210');
    assert.match(mobileQuery.sql, /recovery_phone_verified_at IS NOT NULL/);
    assert.equal(normalizeVerifiedMobile('98765-43210'), '+919876543210');
    assert.throws(() => normalizeVerifiedMobile('12345'), /valid 10-digit/);
});

test('schema keeps a verified-only unique recovery phone index, not a global unique constraint', () => {
    const schemaPath = path.join(__dirname, '..', 'schema.sql');
    const sql = fs.readFileSync(schemaPath, 'utf8');

    assert.match(sql, /CREATE UNIQUE INDEX IF NOT EXISTS users_verified_recovery_phone_unique\s+ON users \(recovery_phone\)\s+WHERE recovery_phone IS NOT NULL AND recovery_phone_verified_at IS NOT NULL AND role = 'student';/s);
    assert.doesNotMatch(sql, /CREATE UNIQUE INDEX IF NOT EXISTS .*recovery_phone.*\bON users \(recovery_phone\);/s);
});

test('reset transaction hashes the password and invalidates existing recovery grants', async () => {
    const user = { id: 'usr_caretaker_test', role: 'caretaker', hostel_id: 'BH1' };
    const client = createFakeClient({ user });
    const result = await updateCaretakerPassword(
        client,
        identifierQuery('email', 'caretaker-bh1@nitmz.ac.in'),
        candidatePassword,
    );

    assert.equal(result, 'updated');
    assert.equal(client.calls[0].sql, 'BEGIN');
    const update = client.calls.find(({ sql }) => sql.startsWith('UPDATE users SET password'));
    assert.ok(update);
    assert.notEqual(update.values[0], candidatePassword);
    assert.equal(await bcrypt.compare(candidatePassword, update.values[0]), true);
    assert.deepEqual(update.values.slice(1), [user.id, 'caretaker']);
    assert.ok(client.calls.some(({ sql }) => sql === 'DELETE FROM password_resets WHERE user_id = $1'));
    assert.ok(client.calls.some(({ sql }) => sql.startsWith('UPDATE password_reset_otps SET used_at')));
    assert.equal(client.calls.at(-1).sql, 'COMMIT');
});

test('reset refuses missing, non-caretaker, and invalid-hostel accounts without updating', async () => {
    const query = identifierQuery('email', 'caretaker-bh1@nitmz.ac.in');
    const missing = createFakeClient({ user: null });
    assert.equal(await updateCaretakerPassword(missing, query, candidatePassword), 'not_found');
    assert.equal(missing.calls.at(-1).sql, 'ROLLBACK');
    assert.equal(missing.calls.some(({ sql }) => sql.startsWith('UPDATE users SET password')), false);

    const otherRole = createFakeClient({ user: { id: 'usr_student', role: 'student', hostel_id: 'BH1' } });
    assert.equal(await updateCaretakerPassword(otherRole, query, candidatePassword), 'not_found');
    assert.equal(otherRole.calls.some(({ sql }) => sql.startsWith('UPDATE users SET password')), false);

    const invalidHostel = createFakeClient({
        user: { id: 'usr_caretaker_test', role: 'caretaker', hostel_id: 'INVALID' },
        hasHostel: false,
    });
    assert.equal(await updateCaretakerPassword(invalidHostel, query, candidatePassword), 'invalid_hostel');
    assert.equal(invalidHostel.calls.at(-1).sql, 'ROLLBACK');
    assert.equal(invalidHostel.calls.some(({ sql }) => sql.startsWith('UPDATE users SET password')), false);
});
