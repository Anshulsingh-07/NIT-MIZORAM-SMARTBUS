# Deployment

## Supabase Setup

Run these files in the Supabase SQL Editor, in this order:

1. `supabase_schema.sql`
2. `supabase_seed.sql`
3. From a trusted terminal with the Supabase database environment configured, run `npm run caretakers:provision`.
4. Create one device key per bus with `npm run device:key:create -- <busNumber>`.

The caretaker command creates only missing accounts, prints each generated 16-character temporary password once, and stores only a bcrypt hash. Use `--dry-run`, `--only BH1`, or `--reset caretaker-bh1@nitmz.ac.in` as needed. Deliver temporary passwords securely and have caretakers change them at first login.

Rotate the Supabase database password before deployment if it was ever exposed, reused, or pasted into chat. Do not commit the database password, generated caretaker passwords, API secrets, email/SMS credentials, or device keys. No real secret values belong in `.env.example`, `.env.render.example`, SQL files, or Git history.

## Render Environment

Set the database connection variables in Render's private Environment page. `DATABASE_URL` may be used instead of the individual `DB_*` settings. Keep `SEED_SAMPLE_DATA=false` in production; startup creates/upgrades tables but inserts only canonical hostel rows unless sample seeding is explicitly enabled.

Set `CORS_ORIGINS` to the exact comma-separated browser origins allowed to call this API, for example `https://app.example.edu`. Do not include paths or trailing slashes. Native mobile and ESP32 requests without an `Origin` header remain allowed. An empty allowlist rejects browser-origin requests.

Set `ALLOW_LEGACY_API_KEY=false` for normal operation and leave `LEGACY_API_BUS_NUMBER` blank. `API_SECRET_KEY` is only required if the legacy fallback is explicitly enabled. During a short migration, the fallback must be restricted to one bus by setting `LEGACY_API_BUS_NUMBER`; disable it after that device has a per-device key.

## Device Keys

After `supabase_schema.sql` has created the `device_keys` table, create a key from the backend directory using the configured database environment:

```sh
npm run device:key:create -- 5
```

The command prints a random key once and stores only its SHA-256 hash, associated with that bus. Put the key in that physical device's protected configuration. Send it as `x-api-key` to `POST /api/update-location`; the payload's bus ID must match the key's bus. Do not put device keys in Git, logs, shell history, or shared Render variables. Revoke a key by setting its `revoked_at` timestamp in the database.

For the local random sender, run `python3 esp32_random_sender.py --bus-id 'Bus 5'`; it securely prompts for the device key if `--api-key` is omitted.

## Session and Schema Notes

Sessions are persisted as SHA-256 token hashes and survive service restarts. Expired sessions and old login-attempt records are cleaned periodically. The startup initializer and `supabase_schema.sql` use the same application column names and types. The SQL file is authoritative for Supabase: it additionally applies integrity constraints, supporting indexes, RLS, and public-role privilege revocations, and upgrades older optional columns. Runtime initialization remains an idempotent compatibility bootstrap for local/legacy databases and does not remove data or modify Supabase privileges.

## Supabase Verification

Run these read-only queries in the Supabase SQL Editor after provisioning.

Confirm every public table has RLS enabled:

```sql
SELECT n.nspname AS schema_name, c.relname AS table_name, c.relrowsecurity AS rls_enabled
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p')
ORDER BY c.relname;
```

Confirm anon/authenticated have no table, sequence, or function grants in public:

```sql
SELECT 'table' AS object_type, table_name AS object_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND grantee IN ('anon', 'authenticated')
UNION ALL
SELECT 'sequence', object_name, grantee, privilege_type
FROM information_schema.role_usage_grants
WHERE object_schema = 'public' AND object_type = 'SEQUENCE'
	AND grantee IN ('anon', 'authenticated')
UNION ALL
SELECT 'function', routine_name, grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public' AND grantee IN ('anon', 'authenticated');
```

No rows should be returned by the grants query.

Confirm all six caretaker identities exist with bcrypt hashes:

```sql
SELECT email, role, hostel_id, must_change_password,
			 password ~ '^[$]2[aby][$][0-9]{2}[$][./A-Za-z0-9]{53}$' AS has_bcrypt_hash
FROM public.users
WHERE email IN (
	'caretaker-bh1@nitmz.ac.in', 'caretaker-bh2@nitmz.ac.in',
	'caretaker-bh3@nitmz.ac.in', 'caretaker-bh4@nitmz.ac.in',
	'caretaker-gh1@nitmz.ac.in', 'caretaker-gh2@nitmz.ac.in'
)
ORDER BY hostel_id;
```

List every bus and whether an active assigned driver exists:

```sql
SELECT b.bus_number, b.assigned_hostel,
			 CASE WHEN d.id IS NULL THEN 'MISSING DRIVER' ELSE 'ASSIGNED' END AS driver_assignment
FROM public.buses b
LEFT JOIN public.drivers d ON d.bus_number = b.bus_number AND d.is_active = true
ORDER BY b.bus_number;
```

Before production use, rotate any credential that was ever committed, pasted into chat, or entered into a local env example. Verify tracked env paths with:

```sh
git ls-files | grep -i env
```

Only example templates should appear in that output; real `.env` files must remain ignored.
