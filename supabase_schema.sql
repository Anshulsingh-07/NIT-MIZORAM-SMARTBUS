-- SmartBus application schema for Supabase PostgreSQL.
-- Run in the Supabase SQL Editor as a database owner. This file touches only
-- the public application schema; it does not alter Supabase-managed schemas.
-- The API connects with a trusted server-side database role. RLS is enabled
-- below with no client policies, so anon/authenticated clients cannot read data.

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
  must_change_password BOOLEAN NOT NULL DEFAULT false,
  recovery_email VARCHAR(120) NULL,
  recovery_phone VARCHAR(20) NULL
    CHECK (recovery_phone IS NULL OR recovery_phone ~ '^[+][1-9][0-9]{7,14}$'),
  recovery_phone_verified_at TIMESTAMPTZ NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT users_verified_phone_requires_number
    CHECK (recovery_phone_verified_at IS NULL OR recovery_phone IS NOT NULL),
  CONSTRAINT caretaker_requires_hostel
    CHECK (role <> 'caretaker' OR hostel_id IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_unique
  ON users (LOWER(email));
CREATE UNIQUE INDEX IF NOT EXISTS users_verified_recovery_phone_unique
  ON users (recovery_phone)
  WHERE recovery_phone IS NOT NULL
    AND recovery_phone_verified_at IS NOT NULL
    AND role = 'student';
CREATE INDEX IF NOT EXISTS users_hostel_role_idx
  ON users (hostel_id, role);

CREATE TABLE IF NOT EXISTS password_resets (
  id BIGSERIAL PRIMARY KEY,
  user_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash CHAR(64) NOT NULL UNIQUE
    CHECK (token_hash ~ '^[a-f0-9]{64}$'),
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS password_resets_user_created_idx
  ON password_resets (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS password_resets_expiry_idx
  ON password_resets (expires_at);

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
CREATE INDEX IF NOT EXISTS password_reset_otps_expiry_idx
  ON password_reset_otps (expires_at);

CREATE TABLE IF NOT EXISTS registration_mobile_verifications (
  id VARCHAR(40) PRIMARY KEY,
  email VARCHAR(120) NOT NULL,
  mobile VARCHAR(20) NOT NULL
    CHECK (mobile ~ '^[+][1-9][0-9]{7,14}$'),
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
  bus_name VARCHAR(80) NOT NULL DEFAULT '',
  assigned_hostel VARCHAR(10) NOT NULL REFERENCES hostels(id),
  source_place VARCHAR(120) NOT NULL DEFAULT '',
  destination_place VARCHAR(120) NOT NULL DEFAULT '',
  status VARCHAR(20) NOT NULL DEFAULT 'idle',
  latitude NUMERIC(10,6) NOT NULL CHECK (latitude BETWEEN -90 AND 90),
  longitude NUMERIC(10,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
  speed NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (speed >= 0),
  is_enabled BOOLEAN NOT NULL DEFAULT true,
  route VARCHAR(120) NOT NULL DEFAULT 'Hostel ↔ MBSE',
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS buses_assigned_hostel_idx
  ON buses (assigned_hostel, bus_number);

CREATE TABLE IF NOT EXISTS drivers (
  id VARCHAR(40) PRIMARY KEY,
  bus_number INT NOT NULL UNIQUE REFERENCES buses(bus_number) ON DELETE CASCADE,
  name VARCHAR(120) NULL,
  phone VARCHAR(30) NULL
    CHECK (phone IS NULL OR phone ~ '^[6-9][0-9]{9}$'),
  pin_hash VARCHAR(100) NULL,
  is_active BOOLEAN NOT NULL DEFAULT true
);
CREATE INDEX IF NOT EXISTS drivers_phone_idx
  ON drivers (phone) WHERE phone IS NOT NULL;

CREATE TABLE IF NOT EXISTS schedules (
  id VARCHAR(40) PRIMARY KEY,
  bus_number INT NOT NULL REFERENCES buses(bus_number) ON DELETE CASCADE,
  date DATE NOT NULL,
  from_hostel_time VARCHAR(20) NOT NULL,
  from_mbse_time VARCHAR(20) NOT NULL,
  special_note VARCHAR(255) NULL,
  updated_by VARCHAR(120) NULL,
  updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT schedules_bus_date_unique UNIQUE (bus_number, date)
);
CREATE INDEX IF NOT EXISTS schedules_date_bus_idx
  ON schedules (date, bus_number);

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
CREATE INDEX IF NOT EXISTS notifications_expires_at_idx
  ON notifications (expires_at);
CREATE INDEX IF NOT EXISTS notifications_hostel_sent_idx
  ON notifications (target_hostel, sent_at DESC);

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
CREATE INDEX IF NOT EXISTS reports_hostel_created_idx
  ON reports (hostel_id, created_at DESC);
CREATE INDEX IF NOT EXISTS reports_reporter_created_idx
  ON reports (reporter_id, created_at DESC);

CREATE TABLE IF NOT EXISTS telemetry (
  id SERIAL PRIMARY KEY,
  device_id VARCHAR(60) NULL,
  bus_id VARCHAR(40) NULL,
  lat NUMERIC(10,6) NOT NULL CHECK (lat BETWEEN -90 AND 90),
  lng NUMERIC(10,6) NOT NULL CHECK (lng BETWEEN -180 AND 180),
  speed NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (speed >= 0),
  accuracy NUMERIC(8,2) NOT NULL DEFAULT 1.0 CHECK (accuracy >= 0),
  heading NUMERIC(6,2) NOT NULL DEFAULT 0 CHECK (heading BETWEEN 0 AND 360),
  has_fix BOOLEAN NOT NULL DEFAULT false,
  satellites INT NOT NULL DEFAULT 0 CHECK (satellites >= 0),
  hdop NUMERIC(6,2) NOT NULL DEFAULT 99.9 CHECK (hdop >= 0),
  net_type VARCHAR(20) NOT NULL DEFAULT 'unknown',
  ts VARCHAR(64) NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'idle',
  received_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS telemetry_bus_received_idx
  ON telemetry (bus_id, received_at DESC);
CREATE INDEX IF NOT EXISTS telemetry_received_idx
  ON telemetry (received_at DESC);

-- Protect the application tables from Supabase anon/authenticated REST access.
-- The trusted backend database role must be allowed to bypass RLS or own these
-- tables. Do not create client policies for password or recovery data.
ALTER TABLE hostels ENABLE ROW LEVEL SECURITY;
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_resets ENABLE ROW LEVEL SECURITY;
ALTER TABLE password_reset_otps ENABLE ROW LEVEL SECURITY;
ALTER TABLE registration_mobile_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE buses ENABLE ROW LEVEL SECURITY;
ALTER TABLE drivers ENABLE ROW LEVEL SECURITY;
ALTER TABLE schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE telemetry ENABLE ROW LEVEL SECURITY;

COMMENT ON COLUMN users.password IS
  'Bcrypt password hash only. Never store plaintext passwords.';
COMMENT ON COLUMN users.recovery_phone IS
  'Verified recovery contact in E.164 format; never expose through public APIs.';
COMMENT ON COLUMN password_resets.token_hash IS
  'SHA-256 digest of a one-time reset token; never store the raw token.';
COMMENT ON COLUMN password_reset_otps.otp_hash IS
  'HMAC-SHA-256 digest of an account-bound OTP; never store the raw OTP.';

COMMIT;