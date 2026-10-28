# SmartBus Supabase PostgreSQL Setup

These files are derived from the current `backend/server.js`, `password_recovery_store.js`, and the existing application schema. Run them only in the Supabase project's `public` application schema. They do not create or alter objects under `auth`, `storage`, or other Supabase-managed schemas.

## 1. Create The Application Schema

In Supabase Dashboard, open **SQL Editor**, create a new query, paste the complete contents of `database/supabase_schema.sql`, and click **Run**. It is ordered by foreign-key dependencies and wrapped in a transaction. Do not run the local Node migration against Supabase.

The schema enables RLS on application tables without adding anon/authenticated policies. The SmartBus Node backend must connect with its trusted server-side PostgreSQL account. Do not put the database password, caretaker passwords, OTPs, or API secrets into either SQL file.

## 2. Add Non-Sensitive Initial Data

After the schema succeeds, paste `database/supabase_seed.sql` into a second SQL Editor query and click **Run**. The idempotent seed inserts the six hostel records, 22 backend-defined buses, their initial campus-day schedules, and four sample notifications. It does not create users or driver accounts and contains no personal driver contacts.

## 3. Configure The Local Backend

The active API is `backend/server.js`; Flutter continues to call the Node API and must not connect directly to PostgreSQL. The server accepts the Session Pooler settings through `pg`'s normal environment-variable configuration:

```text
DB_HOST=aws-0-ap-southeast-2.pooler.supabase.com
DB_PORT=5432
DB_NAME=postgres
DB_USER=postgres.igzurztdhdepkodyetop
DB_SSL=true
```

Enter the actual database password directly into a terminal prompt; do not send it in chat, put it in source, or use `[YOUR-PASSWORD]`. From the repository root, use the same terminal session for the server:

```bash
cd backend
read -rsp 'Supabase database password: ' DB_PASSWORD
printf '\n'
export DB_PASSWORD
export DB_HOST='aws-0-ap-southeast-2.pooler.supabase.com'
export DB_PORT=5432
export DB_NAME=postgres
export DB_USER='postgres.igzurztdhdepkodyetop'
export DB_SSL=true
export NODE_ENV=development
export LOCAL_API_BIND_ADDRESS=127.0.0.1
export LOCAL_MOCK_DELIVERY=false
npm start
```

The password is read without echo and is passed to `pg` as the `password` field. No `DATABASE_URL` is constructed, so URL encoding is not applicable. The pool uses `ssl: { rejectUnauthorized: false }` when `DB_SSL=true`, as required for this Session Pooler setup. The application logs only sanitized PostgreSQL error codes, never the password or connection string. `LOCAL_MOCK_DELIVERY=false` prevents the local `.env.local` mock from intercepting recovery traffic when the API is pointed at Supabase. Configure real email/SMS providers before testing actual recovery delivery. Use `unset DB_PASSWORD` after stopping the server.

Do not use `npm run db:migrate:local` or `npm run db:seed:local` for Supabase. Both scripts deliberately require the isolated loopback `smartbus_local` database and port 5433.

## 4. Provision Caretakers Separately

Six accounts are reserved for the following hostel/email mapping:

| Hostel | Email |
|---|---|
| BH1 | caretaker-bh1@nitmz.ac.in |
| BH2 | caretaker-bh2@nitmz.ac.in |
| BH3 | caretaker-bh3@nitmz.ac.in |
| BH4 | caretaker-bh4@nitmz.ac.in |
| GH1 | caretaker-gh1@nitmz.ac.in |
| GH2 | caretaker-gh2@nitmz.ac.in |

Do not add caretaker plaintext passwords to SQL. Before provisioning a real deployment, generate six fresh, unique passwords locally. A trusted backend-only provisioning tool prompts for each password without echo, requires at least 16 characters, bcrypt-hashes it (cost 12), and inserts only the hash with `role='caretaker'`, its matching `hostel_id`, `must_change_password=true`, and the configured recovery contact. It preserves existing password hashes on reruns. The included `my_server/scripts/seed-local-caretakers.js` is guarded for the local database and must never be pointed at Supabase.

All six development accounts historically shared `9140598061` (stored as `+919140598061`). The schema allows that shared caretaker contact while still enforcing uniqueness for verified student recovery numbers. Prefer individual verified caretaker contacts before production. Do not reset any account based only on phone possession; recovery challenges must also identify the account by email.

After the schema and hostel seed have been run, invoke the trusted provisioning script from the repository root in an interactive terminal:

```bash
npm run db:provision:supabase:caretakers
```

It refuses to run unless the configured host, pooler username, database, port, and SSL setting match this Supabase project. If `DB_PASSWORD` is not already in the process environment, it prompts without echo. It then prompts twice for each of six distinct 16-128 character fresh passwords and asks for the literal confirmation `PROVISION`. It creates only missing accounts; existing bcrypt hashes are preserved. Do not run the local-only seeder for Supabase.

From a new terminal, provide only the non-secret connection settings on the command line; the script securely prompts for the actual DB password and then for each caretaker password:

```bash
DB_HOST='aws-0-ap-southeast-2.pooler.supabase.com' \
DB_PORT=5432 \
DB_NAME=postgres \
DB_USER='postgres.igzurztdhdepkodyetop' \
DB_SSL=true \
npm run db:provision:supabase:caretakers
```

## 5. Verify The Backend

Once the schema and seed have been run and the database password has been entered into the terminal:

1. Start the API with `npm start` from the repository root.
2. In another terminal, request `curl --fail http://127.0.0.1:8080/api/health`. A healthy response reports database-backed hostel, bus, and notification counts; it does not include connection credentials.
3. Run `npm test` from the repository root for backend unit tests. The real Supabase connection is not contacted by the ordinary test suite.
4. Test authentication/recovery only with dedicated test accounts and a non-production Supabase project. Do not use live caretaker/student accounts or production OTPs.

If the health check fails, verify the pooler host, port, database name, exact pooler username, entered password, and `DB_SSL=true`. Do not print or paste the connection string while troubleshooting.

## 6. Flutter Networking

Flutter remains API-only. For Linux desktop, run from `flutter_app/` with:

```bash
flutter run -d linux --dart-define=API_BASE_URL=http://127.0.0.1:8080
```

For an Android emulator, bind the backend to host interfaces by setting `LOCAL_API_BIND_ADDRESS=0.0.0.0` before `npm start`, then use:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

For a physical Android device over USB, keep the backend on loopback and run `adb reverse tcp:8080 tcp:8080`, then use `flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8080`.

The recovery mock is development-only. It captures messages in the running Node process and is not real email/SMS delivery. Do not enable `LOCAL_MOCK_DELIVERY` in production; configure and test real providers first. Never send real or production OTPs through a test client.
