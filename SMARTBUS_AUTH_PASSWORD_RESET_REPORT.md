# SmartBus Authentication and Password Reset Report

**Scope:** Open VS Code workspace only. The tracked backend entrypoint is the workspace-root `server.js`; the untracked `my_server/` directory was not treated as the production source. No external repository, production account, or production database was changed.

## Status Summary

- **Implemented and tested:** tracked backend startup conflict repair, caretaker login-path review, email reset with 15-minute single-use tokens, verified-mobile OTP recovery endpoints, Twilio adapter, Flutter recovery flow, and Android login deep link.
- **Implemented but awaiting external configuration:** email and SMS delivery in production. Delivery tests used injected/mock providers only.
- **Blocked from live verification:** production caretaker credentials, database initialization, and real email/SMS delivery. No production credentials or safe database connection were available in the workspace.
- **Not implemented:** self-service enrollment/verification of a user's recovery phone. The app and backend will not treat an unverified number as verified; a trusted enrollment process must populate the new nullable fields before that account can use OTP recovery.

## 1. Original Caretaker Authentication Issues

The Flutter login client sends `email` and `password`. `AuthService` normalizes caretaker aliases before calling the API; the backend lowercases the email and checks the password using `bcrypt.compare`. The request fields are compatible, and the client does not submit a student role for a caretaker login.

The root server contained unresolved Git merge markers, so `node --check server.js` failed before the repair. It also contained duplicate driver login and driver-me routes. The conflicting code included a hard-coded API-secret fallback on one side; the resolution retained the required production secret check and did not retain that fallback.

## 2. Confirmed Root Causes and Limits

Code confirms these causes can produce caretaker login HTTP 401 responses:

- Caretaker bootstrap skips creating missing accounts unless `CARETAKER_INITIAL_PASSWORD` is configured with a valid 9–128 character value.
- Existing bcrypt passwords are intentionally preserved by bootstrap. Setting `CARETAKER_INITIAL_PASSWORD` does not reset an existing bcrypt password.
- Login rejects missing accounts, incorrect passwords, non-bcrypt legacy values, and caretaker records without a configured hostel assignment.
- The server cannot establish that a production password matches a production database row without access to that database. No credentials were read, printed, or changed during this task.

The tracked startup failure was confirmed locally: `node --check server.js` initially failed at a conflict marker and passed after resolution. No duplicate `campusDateKey` declaration was present in the tracked root source after the merge repair.

## 3. Files Modified

- `server.js`: resolved the existing merge conflict, removed duplicate driver routes, added recovery migrations, and mounted the recovery API.
- `password_recovery.js`: generic recovery responses, input validation, email/mobile throttles, hashed OTP and reset tokens, OTP expiry/attempt/cooldown rules, and single-use password reset handling.
- `password_recovery_store.js`: PostgreSQL persistence using transactions, row locks, token cleanup, and password/session invalidation.
- `sms.js`: credential-gated Twilio REST adapter using built-in `fetch`; provider responses and message contents are not logged.
- `schema.sql`: nullable recovery-phone fields, verified timestamp, reset-token and OTP tables, and indexes. The file also contains pre-existing staged edits; those were preserved.
- `.env.example`, `render.yaml`: documented/configured environment-variable names only.
- `flutter_app/lib/services/api_service.dart`, `flutter_app/lib/screens/auth/login_screen.dart`, `flutter_app/lib/screens/auth/forgot_password_screen.dart`: recovery API client and UI.
- `flutter_app/lib/main.dart`, `flutter_app/android/app/src/main/AndroidManifest.xml`, `flutter_app/ios/Runner/Info.plist`, `flutter_app/pubspec.yaml`, `flutter_app/pubspec.lock`: fixed `smartbus://login` return link registration and handling.
- `test/password_recovery.test.js`, `flutter_app/test/forgot_password_screen_test.dart`: backend and widget tests.

## 4. Database Changes

The PostgreSQL startup migration and `schema.sql` add nullable `users.recovery_phone` and `users.recovery_phone_verified_at` fields. No phone values are inserted or marked verified. A partial unique index prevents a verified recovery number from being assigned to multiple accounts.

`password_reset_otps` stores only a keyed HMAC hash, attempt count, expiry, usage timestamp, and creation timestamp. Existing `password_resets` continues storing SHA-256 token hashes; new reset grants expire after 15 minutes. Startup clamps still-active legacy reset records to a maximum 15-minute lifetime. Expired and used records are cleaned during recovery requests.

## 5. API Contract

- `POST /api/auth/forgot-password` with `{ "method": "email", "email": "..." }` requests an email link.
- `POST /api/auth/forgot-password` with `{ "method": "mobile", "mobile": "..." }` requests an OTP to a verified recovery number.
- `POST /api/auth/resend-otp` with `{ "mobile": "..." }` requests a replacement code; the server enforces the cooldown.
- `POST /api/auth/verify-otp` with `{ "mobile": "...", "otp": "......" }` returns a short-lived reset grant only after successful verification.
- `POST /api/auth/reset-password` with `{ "token": "...", "newPassword": "..." }` consumes either grant and updates the bcrypt password.

Recovery never accepts a role. Unknown accounts receive the same generic recovery response. Email is sent only to the account's registered email, not to the unverified `recovery_email` fallback.

## 6. Security Behavior Implemented

- Account lookup and channel delivery run after the same generic request response is sent, reducing account-existence timing differences.

## 7. Flutter Screens and Navigation
The login screen now opens a recovery wizard with mobile OTP and college email choices. The mobile flow includes a six-digit input, five-minute expiry display, 60-second resend timer, password and confirmation inputs, visibility controls, inline errors, loading state, success text, and Back to Login. The email flow gives generic instructions and opens the backend reset page from the email link.
The email reset success button uses the fixed `smartbus://login` target. Android and iOS schemes are registered, and Flutter accepts only the exact `smartbus://login` URI. No password-reset token is passed through that app link.

## 8. SMS Provider Status

**Implemented and tested with a mocked HTTP client:** Twilio REST delivery adapter. No real SMS was sent. SMS is unavailable until all of these are configured: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and `TWILIO_FROM_NUMBER`, plus a 32-character `PASSWORD_RESET_OTP_SECRET` (or a sufficiently long `API_SECRET_KEY`).

An account can receive an OTP only when `recovery_phone` is populated and `recovery_phone_verified_at` is non-null. No self-service phone-enrollment flow currently exists, so verified numbers must be established through a trusted process before OTP recovery is usable for those accounts.

## 9. Email Provider Status

**Implemented and tested with mocked providers:** existing Brevo and Resend mail adapters. No real email was sent and production provider credentials were not inspected. Production email recovery requires `MAIL_FROM` and either `BREVO_API_KEY` or `RESEND_API_KEY`, plus a valid HTTPS `PUBLIC_BASE_URL` (or Render's external service URL).

## 10. Render Environment Variables

Names only; no secrets are included in this report:

- Backend/database: `NODE_ENV`, `PORT`, `API_SECRET_KEY`, `DATABASE_URL` or `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSL`
- Caretaker bootstrap: `CARETAKER_INITIAL_PASSWORD`
- Email: `MAIL_FROM`, `BREVO_API_KEY` or `RESEND_API_KEY`, `PUBLIC_BASE_URL`
- SMS/OTP: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `PASSWORD_RESET_OTP_SECRET`

The backend continues to use Render's configured `PORT` and starts only after PostgreSQL initialization succeeds.

## 11. Commands and Test Results

- `node --check server.js` — passed.
- `node --check password_recovery.js` — passed.
- `node --check password_recovery_store.js` — passed.
- `node --check sms.js` — passed.
- `npm test` — 26 tests passed, 0 failed. Includes mocked email/SMS recovery tests.
- `flutter analyze --no-pub` on all changed Flutter source/test files — no issues found.
- `flutter test` — 13 tests passed, 0 failed.
- `flutter build apk --debug` — succeeded; APK emitted at `flutter_app/build/app/outputs/flutter-apk/app-debug.apk`.
- `git diff --check` — passed.

`npm install` was run because the tracked backend package's declared `bcryptjs` and `pg` dependencies were missing locally. It normalized the existing lockfile by removing unused entries. npm reported 3 dependency audit findings (1 low, 1 moderate, 1 critical); no automatic audit upgrades were applied.

## 12. Remaining Issues

- Production database initialization and caretaker login with real credentials were not exercised. Running the server would initialize/seed the configured database, and no safe database credentials were available.
- Real email and SMS delivery remain unverified until provider credentials and sender configuration are supplied.
- No existing user phone was populated or verified. The OTP implementation is ready for verified records, but self-service recovery-phone enrollment remains unimplemented.
- Rate-limit counters and session revocation use the backend's in-memory session architecture. Process restarts reset counters; with multiple server instances, each instance has independent limits and session invalidation. A shared store is needed before horizontal scaling.
- iOS was not build-tested in this Linux environment. Android debug build passed.
- npm reported 3 dependency audit findings; they were not investigated or upgraded as part of this authentication task.

## 13. Manual Configuration and Deployment Steps

1. In Render, configure `CARETAKER_INITIAL_PASSWORD` only if bootstrap must create a missing caretaker account. Use a unique value and do not assume it will overwrite an existing bcrypt password.
2. Configure `MAIL_FROM` and one email provider key, then ensure `PUBLIC_BASE_URL` points to the HTTPS backend hosting `/reset-password`.
3. Configure Twilio credentials and `PASSWORD_RESET_OTP_SECRET` to enable SMS delivery.
4. Add a user's recovery phone only after its ownership has been verified; set `recovery_phone_verified_at` only as part of that verification process. Do not seed guessed or unverified numbers.
5. Deploy the backend. Its startup migration creates the new fields/table/indexes and clamps outstanding reset-link expiry. Verify Render startup and database health before testing an account.
6. Test recovery with a controlled caretaker account and provider test destination. Do not use a production user's account for destructive tests.

## 14. Deployment and Verification Boundary

Backend deployment, Render environment changes, actual caretaker credential checks, and real provider delivery were not performed. The code and tests are ready for review, but production recovery is **not claimed operational** until the required configuration and verified phone records exist and live delivery is confirmed.
