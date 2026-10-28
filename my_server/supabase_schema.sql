  -- SmartBus schema for the Node/Postgres backend in this directory.
  -- Run in the Supabase SQL Editor as a database owner before the seed file.
  -- Table columns match my_server/server.js startup initialization; ALTERs below
  -- upgrade existing installations that were initialized by older server builds.

  BEGIN;
  SET LOCAL search_path = public;

  CREATE TABLE IF NOT EXISTS hostels (
    id VARCHAR(10) PRIMARY KEY,
    name VARCHAR(20) NOT NULL,
    type VARCHAR(20) NOT NULL CHECK (type IN ('Boys', 'Girls')),
    full_name VARCHAR(100) NOT NULL
  );

  CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(40) PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(120) NOT NULL UNIQUE,
    password VARCHAR(120) NOT NULL
      CHECK (password ~ '^[$]2[aby][$][0-9]{2}[$][./A-Za-z0-9]{53}$'),
    role VARCHAR(20) NOT NULL CHECK (role IN ('student', 'caretaker', 'admin')),
    hostel_id VARCHAR(10) NULL REFERENCES hostels(id) ON DELETE SET NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CHECK (role <> 'caretaker' OR hostel_id IS NOT NULL)
  );
  ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT false;
  ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_email VARCHAR(120) NULL;
  ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_phone VARCHAR(20) NULL;
  ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_phone_verified_at TIMESTAMPTZ NULL;
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_recovery_phone_format_check') THEN
      ALTER TABLE users ADD CONSTRAINT users_recovery_phone_format_check
        CHECK (recovery_phone IS NULL OR recovery_phone ~ '^[+][1-9][0-9]{7,14}$');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'users_verified_phone_requires_number') THEN
      ALTER TABLE users ADD CONSTRAINT users_verified_phone_requires_number
        CHECK (recovery_phone_verified_at IS NULL OR recovery_phone IS NOT NULL);
    END IF;
  END $$;
  CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_unique ON users (LOWER(email));
  CREATE UNIQUE INDEX IF NOT EXISTS users_verified_recovery_phone_unique
    ON users (recovery_phone)
    WHERE recovery_phone IS NOT NULL AND recovery_phone_verified_at IS NOT NULL AND role = 'student';
  CREATE INDEX IF NOT EXISTS users_hostel_role_idx ON users (hostel_id, role);

  CREATE TABLE IF NOT EXISTS sessions (
    token_hash CHAR(64) PRIMARY KEY CHECK (token_hash ~ '^[a-f0-9]{64}$'),
    user_id VARCHAR(40) NOT NULL,
    email VARCHAR(120) NULL,
    role VARCHAR(20) NOT NULL,
    hostel_id VARCHAR(10) NULL,
    phone VARCHAR(30) NULL,
    bus_number INT NULL,
    must_change_password BOOLEAN NOT NULL DEFAULT false,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  CREATE INDEX IF NOT EXISTS sessions_user_id_idx ON sessions (user_id);
  CREATE INDEX IF NOT EXISTS sessions_expires_at_idx ON sessions (expires_at);

  CREATE TABLE IF NOT EXISTS login_attempts (
    identifier_hash CHAR(64) PRIMARY KEY CHECK (identifier_hash ~ '^[a-f0-9]{64}$'),
    failed_attempts SMALLINT NOT NULL DEFAULT 0,
    blocked_until TIMESTAMPTZ NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );
  CREATE INDEX IF NOT EXISTS login_attempts_updated_at_idx ON login_attempts (updated_at);

  CREATE TABLE IF NOT EXISTS password_resets (
    id SERIAL PRIMARY KEY,
    user_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash CHAR(64) NOT NULL UNIQUE CHECK (token_hash ~ '^[a-f0-9]{64}$'),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (expires_at > created_at)
  );
  CREATE INDEX IF NOT EXISTS password_resets_user_created_idx ON password_resets (user_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS password_resets_expiry_idx ON password_resets (expires_at);

  CREATE TABLE IF NOT EXISTS password_reset_otps (
    id BIGSERIAL PRIMARY KEY,
    user_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    otp_hash CHAR(64) NOT NULL CHECK (otp_hash ~ '^[a-f0-9]{64}$'),
    attempts SMALLINT NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CHECK (expires_at > created_at)
  );
  CREATE INDEX IF NOT EXISTS password_reset_otps_user_created_idx
    ON password_reset_otps (user_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS password_reset_otps_expiry_idx ON password_reset_otps (expires_at);

  CREATE TABLE IF NOT EXISTS registration_mobile_verifications (
    id VARCHAR(40) PRIMARY KEY,
    email VARCHAR(120) NOT NULL,
    mobile VARCHAR(20) NOT NULL CHECK (mobile ~ '^[+][1-9][0-9]{7,14}$'),
    otp_hash CHAR(64) NOT NULL CHECK (otp_hash ~ '^[a-f0-9]{64}$'),
    attempts SMALLINT NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    verification_token_hash CHAR(64) NULL
      CHECK (verification_token_hash IS NULL OR verification_token_hash ~ '^[a-f0-9]{64}$'),
    expires_at TIMESTAMPTZ NOT NULL,
    verified_at TIMESTAMPTZ NULL,
    used_at TIMESTAMPTZ NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT registration_mobile_email_unique UNIQUE (email, mobile),
    CHECK (expires_at > created_at)
  );
  CREATE INDEX IF NOT EXISTS registration_mobile_verifications_expiry_idx
    ON registration_mobile_verifications (expires_at);

  CREATE TABLE IF NOT EXISTS buses (
    bus_number INT PRIMARY KEY CHECK (bus_number > 0),
    assigned_hostel VARCHAR(10) NOT NULL REFERENCES hostels(id),
    status VARCHAR(20) NOT NULL DEFAULT 'idle',
    latitude NUMERIC(10,6) NOT NULL CHECK (latitude BETWEEN -90 AND 90),
    longitude NUMERIC(10,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    speed NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (speed >= 0),
    is_enabled BOOLEAN NOT NULL DEFAULT true,
    route VARCHAR(120) NOT NULL DEFAULT 'Hostel ↔ MBSE',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
  );
  ALTER TABLE buses ADD COLUMN IF NOT EXISTS bus_name VARCHAR(80) NOT NULL DEFAULT '';
  ALTER TABLE buses ADD COLUMN IF NOT EXISTS source_place VARCHAR(120) NOT NULL DEFAULT '';
  ALTER TABLE buses ADD COLUMN IF NOT EXISTS destination_place VARCHAR(120) NOT NULL DEFAULT '';
  CREATE INDEX IF NOT EXISTS buses_assigned_hostel_idx ON buses (assigned_hostel, bus_number);

  CREATE TABLE IF NOT EXISTS drivers (
    id VARCHAR(40) PRIMARY KEY,
    bus_number INT NOT NULL UNIQUE REFERENCES buses(bus_number) ON DELETE CASCADE,
    name VARCHAR(120) NULL,
    phone VARCHAR(30) NULL CHECK (phone IS NULL OR phone ~ '^[6-9][0-9]{9}$'),
    pin_hash VARCHAR(100) NULL,
    is_active BOOLEAN NOT NULL DEFAULT true
  );
  ALTER TABLE drivers ADD COLUMN IF NOT EXISTS pin_hash VARCHAR(100) NULL;
  CREATE INDEX IF NOT EXISTS drivers_phone_idx ON drivers (phone) WHERE phone IS NOT NULL;

  CREATE TABLE IF NOT EXISTS schedules (
    id VARCHAR(40) PRIMARY KEY,
    bus_number INT NOT NULL REFERENCES buses(bus_number) ON DELETE CASCADE,
    date DATE NOT NULL,
    from_hostel_time VARCHAR(20) NOT NULL,
    from_mbse_time VARCHAR(20) NOT NULL,
    special_note VARCHAR(255) NULL,
    updated_by VARCHAR(120) NULL,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (bus_number, date)
  );
  CREATE INDEX IF NOT EXISTS schedules_date_bus_idx ON schedules (date, bus_number);
  DO $$
  DECLARE
    stored_type TEXT;
    date_expression TEXT;
    has_collisions BOOLEAN;
  BEGIN
    SELECT data_type INTO stored_type
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'schedules' AND column_name = 'date';
    IF stored_type IS NOT NULL AND stored_type <> 'date' THEN
      IF stored_type = 'timestamp with time zone' THEN
        date_expression := '(date AT TIME ZONE ''Asia/Kolkata'')::date';
      ELSE
        date_expression := 'date::date';
      END IF;
      EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.schedules GROUP BY bus_number, %s HAVING COUNT(*) > 1)', date_expression)
        INTO has_collisions;
      IF has_collisions THEN
        RAISE EXCEPTION 'schedules date migration found duplicate records for one bus and IST date';
      END IF;
      EXECUTE format('ALTER TABLE public.schedules ALTER COLUMN date TYPE DATE USING %s', date_expression);
    END IF;
  END $$;

  CREATE TABLE IF NOT EXISTS notifications (
    id VARCHAR(40) PRIMARY KEY,
    title VARCHAR(160) NOT NULL,
    message TEXT NOT NULL,
    type VARCHAR(30) NOT NULL,
    bus_number INT NULL,
    target_hostel VARCHAR(10) NULL REFERENCES hostels(id) ON DELETE SET NULL,
    sent_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '30 days'),
    is_read BOOLEAN NOT NULL DEFAULT false,
    sent_by VARCHAR(120) NULL,
    CHECK (expires_at > sent_at)
  );
  ALTER TABLE notifications ADD COLUMN IF NOT EXISTS expires_at TIMESTAMP;
  UPDATE notifications SET expires_at = sent_at + INTERVAL '30 days' WHERE expires_at IS NULL;
  ALTER TABLE notifications ALTER COLUMN expires_at SET DEFAULT (CURRENT_TIMESTAMP + INTERVAL '30 days');
  ALTER TABLE notifications ALTER COLUMN expires_at SET NOT NULL;
  CREATE INDEX IF NOT EXISTS notifications_expires_at_idx ON notifications (expires_at);
  CREATE INDEX IF NOT EXISTS notifications_hostel_sent_idx ON notifications (target_hostel, sent_at DESC);

  CREATE TABLE IF NOT EXISTS reports (
    id VARCHAR(40) PRIMARY KEY,
    reporter_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    hostel_id VARCHAR(10) NOT NULL REFERENCES hostels(id),
    bus_number INT NULL REFERENCES buses(bus_number) ON DELETE SET NULL,
    category VARCHAR(40) NOT NULL,
    message TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'open',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
  );
  CREATE INDEX IF NOT EXISTS reports_hostel_created_idx ON reports (hostel_id, created_at DESC);
  CREATE INDEX IF NOT EXISTS reports_reporter_created_idx ON reports (reporter_id, created_at DESC);

  CREATE TABLE IF NOT EXISTS telemetry (
    id SERIAL PRIMARY KEY,
    device_id VARCHAR(60) NULL,
    bus_id VARCHAR(40) NULL,
    lat NUMERIC(10,6) NOT NULL CHECK (lat BETWEEN -90 AND 90),
    lng NUMERIC(10,6) NOT NULL CHECK (lng BETWEEN -180 AND 180),
    speed NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (speed >= 0),
    accuracy NUMERIC(8,2) NOT NULL DEFAULT 1.0 CHECK (accuracy >= 0),
    heading NUMERIC(6,2) NOT NULL DEFAULT 0 CHECK (heading BETWEEN 0 AND 360),
    ts VARCHAR(64) NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'idle',
    received_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
  );
  ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS has_fix BOOLEAN DEFAULT false;
  ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS satellites INT DEFAULT 0;
  ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS hdop NUMERIC(6,2) DEFAULT 99.9;
  ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS net_type VARCHAR(20) DEFAULT 'unknown';
  ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS heading NUMERIC(6,2) NOT NULL DEFAULT 0;
  CREATE INDEX IF NOT EXISTS telemetry_bus_received_idx ON telemetry (bus_id, received_at DESC);
  CREATE INDEX IF NOT EXISTS telemetry_received_idx ON telemetry (received_at DESC);

  CREATE TABLE IF NOT EXISTS device_keys (
    bus_number INT NOT NULL REFERENCES buses(bus_number) ON DELETE CASCADE,
    key_hash CHAR(64) PRIMARY KEY CHECK (key_hash ~ '^[a-f0-9]{64}$'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    revoked_at TIMESTAMPTZ NULL
  );
  CREATE INDEX IF NOT EXISTS device_keys_bus_active_idx
    ON device_keys (bus_number) WHERE revoked_at IS NULL;

  ALTER TABLE hostels ENABLE ROW LEVEL SECURITY;
  ALTER TABLE users ENABLE ROW LEVEL SECURITY;
  ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;
  ALTER TABLE login_attempts ENABLE ROW LEVEL SECURITY;
  ALTER TABLE password_resets ENABLE ROW LEVEL SECURITY;
  ALTER TABLE password_reset_otps ENABLE ROW LEVEL SECURITY;
  ALTER TABLE registration_mobile_verifications ENABLE ROW LEVEL SECURITY;
  ALTER TABLE buses ENABLE ROW LEVEL SECURITY;
  ALTER TABLE drivers ENABLE ROW LEVEL SECURITY;
  ALTER TABLE schedules ENABLE ROW LEVEL SECURITY;
  ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
  ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
  ALTER TABLE telemetry ENABLE ROW LEVEL SECURITY;
  ALTER TABLE device_keys ENABLE ROW LEVEL SECURITY;

  REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
  REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
  REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated;

  COMMIT;
