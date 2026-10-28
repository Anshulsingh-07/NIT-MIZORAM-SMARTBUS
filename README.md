# NIT-MIZORAM-CAMPUS-BUS-SERVER

## Local Development

The supported backend entry point is `my_server/server.js`; root npm and Docker commands use it. It is an Express API backed by PostgreSQL. No production URL or cloud account is needed for local development.

Requirements: Node.js 18+, npm, Docker Compose, Flutter, and Android SDK for Android builds.

1. Create a private local config only if one does not already exist: `cp -n my_server/.env.example my_server/.env.local`.
2. Set a local PostgreSQL password, a random `API_SECRET_KEY`, a separate random `PASSWORD_RESET_OTP_SECRET`, and six unique `LOCAL_CARETAKER_PASSWORDS_JSON` values in `my_server/.env.local`. Keep the file private and ignored. Caretaker passwords are never stored in source or printed by the seed script.
3. Start the isolated PostgreSQL 16 container: `docker compose --env-file my_server/.env.local -f my_server/docker-compose.local.yml up -d postgres`.
4. Apply the additive schema: `npm run db:migrate:local`.
5. Provision missing caretaker accounts: `npm run db:seed:local`. Existing caretaker password hashes are not overwritten.
6. Start the API: `npm start`.
7. Check the local service: `curl http://127.0.0.1:8080/api/health`.
8. Run backend tests: `npm test`.

Local OTP messages are captured only when `NODE_ENV=development` and `LOCAL_MOCK_DELIVERY=true`. They can be read once from `GET http://127.0.0.1:8080/api/dev/delivery-outbox`; this endpoint is loopback-only. This mock proves application flow, not real email or SMS delivery. Production must configure real providers and never enable the mock.

## Flutter

From `flutter_app/`, run `flutter pub get` and `flutter test`. Desktop uses `flutter run -d linux --dart-define=API_BASE_URL=http://127.0.0.1:8080`.

For an Android emulator, start the backend bound to host interfaces with `LOCAL_API_BIND_ADDRESS=0.0.0.0 npm start` and run `flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080`.

For a physical Android phone over USB, start the backend normally, then run `adb reverse tcp:8080 tcp:8080` and `flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8080`. The reverse rule lets the phone's loopback reach the computer. The debug Android manifest permits local HTTP only; configure HTTPS for release builds.

## Authentication And Recovery

Public registration creates students only. It requires college email, mobile OTP verification, hostel, and matching passwords. Caretaker accounts are provisioned only by the trusted local seed script and require a password change on first login. The shared initial recovery mobile is stored in PostgreSQL; recovery also requires the caretaker's email, and OTP challenges are tied to that user's account ID. Replace the shared contact with individually verified numbers before production.

Password recovery supports email reset links and account+mobile OTP recovery. Challenges expire, are attempt-limited and one-time, and reset tokens are stored hashed. Local mock delivery is unavailable in production. Configure and test real providers before claiming delivery is active.

## GitHub And Future Deployment

The repository is configured to use the existing Git remote, but no commit, push, or cloud deployment was performed. Before publishing, review `git status`, ensure `.env.local`, `.env`, signing keys, generated output, exports, and backup trees remain untracked, rotate any previously exposed credentials, and provision unique caretaker passwords. Then configure production PostgreSQL, `API_SECRET_KEY`, `PASSWORD_RESET_OTP_SECRET`, HTTPS mail/SMS providers, and a production Flutter `API_BASE_URL`. Do not enable `LOCAL_MOCK_DELIVERY` outside development.
# NIT-MIZORAM-CAMPUS-BUS-SERVICE
# NIT-MIZORAM-CAMPUS-BUS-SERVER
# NIT-MIZORAM-CAMPUS-BUS-SERVER
# NIT-MIZORAM-CAMPUS-BUS-SERVER
# NIT-MIZORAM-CAMPUS-BUS-SERVER
# NIT-MIZORAM-
