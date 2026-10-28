# SmartBus Password Recovery Timeout Fix Report

## Summary

This report records the password recovery implementation. The production API origin is now `https://nit-mizoram-campus-bus-service.onrender.com`; see the current app configuration for the active endpoint. The server's recovery routes return a generic response before queued database and provider work, so the SMS request itself was not blocking the HTTP response; however, the queued database and provider calls had no finite bounds.

## Implemented

- Updated the Flutter default API URL to `https://nit-mizoram-campus-bus-service.onrender.com`.
- Added 15-second response-header, 10-second response-body, and 30-second overall limits to recovery HTTP calls. No automatic retry is performed.
- Mapped connection failures, timeouts, malformed JSON, HTTP 400/401/429/500/503, and unexpected errors to user-readable messages. Prevented duplicate submissions while a request is pending and added regression tests to keep raw exception text off screen.
- Kept the backend's generic response and deferred account lookup to avoid disclosing account existence. Added a bounded background-work deadline, 5-second PostgreSQL connection timeout, 8-second query timeout, and 8-second abortable email/SMS provider requests.
- Standardized recovery JSON errors as `{ success: false, code, message }`. Missing SMS or email configuration returns `503 SERVICE_TEMPORARILY_UNAVAILABLE`; recovery tokens and OTPs remain absent from responses/logs.
- Kept OTPs hashed, six digits, five-minute expiry, five failed attempts, 60-second resend cooldown, rate limits, and single-use reset grants. Password reset hashes the new password and invalidates existing in-memory sessions.
- Added an authentication regression around the same bcrypt and caretaker-hostel checks used by `/api/auth/login`.
- Updated the email reset landing page to display the API's structured messages.
- Applied compatible transitive dependency security updates. No direct package version was changed.

## Files Changed

- `server.js`
- `auth_credentials.js`
- `password_recovery.js`
- `password_recovery_store.js`
- `sms.js`
- `mailer.js`
- `test/password_recovery.test.js`
- `test/mailer.test.js`
- `package-lock.json`
- `.env.example`
- `render.yaml`
- `flutter_app/lib/config/app_config.dart`
- `flutter_app/lib/services/api_service.dart`
- `flutter_app/lib/screens/auth/forgot_password_screen.dart`
- `flutter_app/test/forgot_password_screen_test.dart`

## Database and Provider Status

The backend startup migration creates nullable `recovery_phone` and `recovery_phone_verified_at` columns, the OTP table/index, and unique indexing for verified numbers. It caps outstanding email reset links at 15 minutes. Existing numbers are not populated or marked verified automatically. Mobile recovery works only for an account whose phone is already stored in E.164 form and has a verified timestamp.

The Twilio adapter is implemented and tested with mocked requests, including timeout and missing-credential behavior. No production Twilio credentials were available to this workspace, and no real SMS was sent. The existing Brevo/Resend email adapters now have bounded requests and are mock-tested; no production email delivery was attempted. Configure provider credentials in Render before expecting live delivery.

## Verification

- `node --check` passed for `server.js` and all recovery/provider modules.
- `npm test`: 30 tests passed.
- `npm audit`: 0 vulnerabilities after `npm audit fix`.
- `flutter test`: passed; includes production URL, duplicate-submit, recovery navigation, and timeout-message coverage.
- `flutter analyze --no-pub`: recovery code analyzed cleanly. It reports one pre-existing unused import in `flutter_app/test/student_map_report_test.dart`, which is outside this task.
- Local integration against a disposable PostgreSQL 16 container succeeded: backend initialized, listened on `PORT=18080`, `/api/health` returned HTTP 200, caretaker bcrypt login returned HTTP 200 with the caretaker role/hostel, and mobile/email recovery correctly returned controlled 503 responses with providers unconfigured. The disposable server and database were stopped afterward.
- No production database or account was accessed or modified.

## Render Configuration

Names only; set secret values in Render, not in source control:

- Existing database and application configuration: `API_SECRET_KEY`, `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_SSL`
- Bounded database access: `DB_CONNECTION_TIMEOUT_MS`, `DB_QUERY_TIMEOUT_MS`
- Email delivery: `MAIL_FROM` and either `BREVO_API_KEY` or `RESEND_API_KEY`
- Mobile delivery: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `TWILIO_FROM_NUMBER`, `PASSWORD_RESET_OTP_SECRET`
- Reset links and caretaker bootstrap: `PUBLIC_BASE_URL`, `CARETAKER_INITIAL_PASSWORD`, `CARETAKER_RECOVERY_EMAILS`

`PASSWORD_RESET_OTP_SECRET` should be a separate random value of at least 32 characters. A mobile number must be populated and independently verified before its account can use SMS recovery.

## Git

- Authorized remote verified: `https://github.com/Anshulsingh-07/NIT-MIZORAM-CAMPUS-BUS-SERVER.git`
- Commit on `main`: `8df999f` (`fix(auth): resolve password recovery timeout and improve OTP handling`), replayed on fetched `origin/main` at `10b200e`.
- Push result: pushed successfully with a normal fast-forward update; verified GitHub `refs/heads/main` at `8df999f`.
- The `.env.example` conflict was resolved in the isolated push worktree by preserving main's blank secret/contact placeholders and adding the new variable names. Duplicate Render service settings were removed and the YAML was parsed successfully.

The pre-existing staged `schema.sql` contains additional driver/telemetry changes and is intentionally excluded from this recovery commit. Runtime migrations in `server.js` apply the recovery schema safely at startup.

The original workspace remains on its detached pre-replay commit with its staged schema and unrelated untracked frontend/server-copy trees preserved; the pushed commit was validated and sent from a temporary worktree based on `main`.

## Remaining Deployment Checks

The live deployment and recovery-route status described in the original report are historical and should be rechecked against `https://nit-mizoram-campus-bus-service.onrender.com`. Flutter now uses that origin by default and reports a missing recovery endpoint clearly instead of showing an invalid-response error.

Live provider delivery and the state of Render environment variables cannot be verified from this workspace. The pushed backend commit is on GitHub, but the active Render service still needs to deploy it. After deployment and configuration of provider credentials and verified account recovery numbers, test with a controlled account. No real SMS or email was sent during automated tests.
