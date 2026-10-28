# NIT-MIZORAM-CAMPUS-BUS-SERVICE

Flutter client and Node.js/PostgreSQL API for the NIT Mizoram campus bus service.

## Supabase Database

The Flutter app communicates only with the Node API. It does not connect directly to PostgreSQL. First run `database/supabase_schema.sql` and then `database/supabase_seed.sql` manually in the Supabase Dashboard SQL Editor. See [database/README.md](database/README.md) for the Session Pooler settings, safe local password prompts, caretaker provisioning, and device networking steps.

## Backend

The API source is in `backend/`. For local PostgreSQL, follow `backend/README.md`. For Supabase, see `database/README.md`, start the API from `backend/` with the Session Pooler environment variables, and keep the DB password out of source and chat.

## Flutter

Install Flutter dependencies and test from the repository root:

```bash
flutter pub get
flutter test
flutter analyze
```

Run Flutter on Linux with `flutter run -d linux --dart-define=API_BASE_URL=http://127.0.0.1:8080`.

For Android emulator use `--dart-define=API_BASE_URL=http://10.0.2.2:8080`. For a physical phone over USB, run `adb reverse tcp:8080 tcp:8080` and use `--dart-define=API_BASE_URL=http://127.0.0.1:8080`.
