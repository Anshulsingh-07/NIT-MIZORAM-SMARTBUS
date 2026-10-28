

## SmartBus Backend

This directory contains the canonical Express/PostgreSQL API. Flutter talks to this API; it never connects directly to PostgreSQL. From this directory, use `npm start` and `npm test`.

For local PostgreSQL, copy `.env.example` to `.env.local`, edit it with local values, then run `npm run db:migrate:local` and `npm run db:seed:local`. Both scripts enforce the isolated loopback `smartbus_local` database at port 5433.

For Supabase instructions, SQL Editor files, and local Session Pooler configuration, see the repository [database guide](../database/README.md). Never commit `.env`, `.env.local`, `.env.supabase.local`, credentials, or real caretaker passwords.

The local caretaker seeder is intentionally restricted to loopback PostgreSQL. Supabase caretaker provisioning is a separate interactive command, `npm run db:provision:supabase:caretakers`, and requires the exact configured Session Pooler target and six unique fresh passwords. Do not run it until `database/supabase_schema.sql` and `database/supabase_seed.sql` have been applied manually.
