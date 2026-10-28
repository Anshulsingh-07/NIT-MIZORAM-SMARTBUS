# SmartBus Password Recovery Bug Fix Report

## Confirmed Root Cause

This report records the earlier recovery diagnosis. The current Flutter API origin is `https://nit-mizoram-campus-bus-service.onrender.com`; the historical deployment observations below should be rechecked against that service.

## Client Changes

- Flutter defaults to the workspace-documented active Render host and existing `/api/auth/forgot-password` route.
- Recovery response handling checks status before parsing success, requires JSON for success responses, validates the JSON object and `success` field, and maps 404/429/server/network/timeout/HTML/malformed JSON cases to safe messages.
- Development-only logs contain the route path, HTTP status, content type, duration, and a sanitized summary. They do not include request bodies, phone numbers, response values, OTPs, tokens, or passwords.
- Repeated submit is guarded while a request is in flight. Rejected HTTP responses do not advance the UI to OTP entry.

## Backend State

The recovery backend previously pushed to the authorized repository already includes Postgres recovery migrations, hashed OTPs, five-minute expiry, attempt limits, cooldown/rate limits, a bounded Twilio adapter, and generic account responses. Its success response is queued before asynchronous SMS delivery finishes. Returning per-account delivery success/failure to an unauthenticated client would reveal whether a mobile number is registered, conflicting with the requirement not to enumerate accounts. The generic response was retained; delivery cannot be confirmed to the client without changing that privacy contract. Provider failures invalidate the OTP and are logged without sensitive data.

## Verification

- Flutter recovery tests: 9 passed, including HTML, malformed JSON, HTTP 404/429/500, valid success JSON, timeout messaging, and no navigation on a rejected response.
- Targeted Flutter analysis: no issues in the changed API/client/test files.
- Full Flutter suite: 20 tests passed. Workspace analysis still reports one unrelated unused import in `test/student_map_report_test.dart`.
- Backend `node --check server.js`: passed.
- Backend `npm test`: 30 passed.
- Backend `npm audit`: 0 vulnerabilities at the last verified backend commit.
- A disposable PostgreSQL integration test previously verified backend startup on `PORT=18080`, health HTTP 200, and caretaker bcrypt login HTTP 200. No production database or provider was used.
- The live active Render health endpoint responds, but live recovery currently returns 404, so end-to-end recovery against the deployed service is not verified and must not be considered fixed yet.

## GitHub

- Authorized repository: `https://github.com/Anshulsingh-07/NIT-MIZORAM-CAMPUS-BUS-SERVER`
- Backend recovery commit on `main`: `8df999f` (`fix(auth): resolve password recovery timeout and improve OTP handling`).
- This report and Flutter-only diagnostics changes are local workspace files; no Flutter files were pushed to the backend repository.

## Remaining Deployment Work

Verify that `/api/auth/forgot-password` on `https://nit-mizoram-campus-bus-service.onrender.com` returns the new JSON contract. Configure the SMS/email providers and ensure mobile numbers have a verified recovery timestamp before testing delivery.
