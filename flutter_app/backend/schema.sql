-- Schema for Campus Bus Tracker (created from server.js)

CREATE TABLE IF NOT EXISTS hostels (
  id VARCHAR(10) PRIMARY KEY,
  name VARCHAR(20) NOT NULL,
  type VARCHAR(20) NOT NULL,
  full_name VARCHAR(100) NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
  id VARCHAR(40) PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  email VARCHAR(120) NOT NULL UNIQUE,
  password VARCHAR(120) NOT NULL,
  role VARCHAR(20) NOT NULL,
  hostel_id VARCHAR(10) NULL,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (hostel_id) REFERENCES hostels(id) ON DELETE SET NULL
);

ALTER TABLE users ADD COLUMN IF NOT EXISTS must_change_password BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_email VARCHAR(120) NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_phone VARCHAR(20) NULL;
ALTER TABLE users ADD COLUMN IF NOT EXISTS recovery_phone_verified_at TIMESTAMPTZ NULL;
-- Shared numbers are allowed before verification; only verified numbers are globally unique.
DROP INDEX IF EXISTS users_recovery_phone_unique;
DROP INDEX IF EXISTS users_verified_recovery_phone_unique;
CREATE UNIQUE INDEX IF NOT EXISTS users_verified_recovery_phone_unique
  ON users (recovery_phone)
  WHERE recovery_phone IS NOT NULL AND recovery_phone_verified_at IS NOT NULL AND role = 'student';
CREATE UNIQUE INDEX IF NOT EXISTS users_email_lower_unique ON users (LOWER(email));

CREATE TABLE IF NOT EXISTS password_resets (
  id BIGSERIAL PRIMARY KEY,
  user_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash CHAR(64) NOT NULL UNIQUE,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS password_reset_otps (
  id BIGSERIAL PRIMARY KEY,
  user_id VARCHAR(40) NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  otp_hash CHAR(64) NOT NULL,
  attempts SMALLINT NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS password_reset_otps_user_created_idx
  ON password_reset_otps (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS registration_mobile_verifications (
  id VARCHAR(40) PRIMARY KEY,
  email VARCHAR(120) NOT NULL,
  mobile VARCHAR(20) NOT NULL,
  otp_hash CHAR(64) NOT NULL,
  attempts SMALLINT NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
  verification_token_hash CHAR(64) NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  verified_at TIMESTAMPTZ NULL,
  used_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (email, mobile)
);
CREATE INDEX IF NOT EXISTS registration_mobile_verifications_expiry_idx
  ON registration_mobile_verifications (expires_at);

CREATE TABLE IF NOT EXISTS buses (
  bus_number INT PRIMARY KEY,
  assigned_hostel VARCHAR(10) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'idle',
  latitude NUMERIC(10,6) NOT NULL,
  longitude NUMERIC(10,6) NOT NULL,
  speed NUMERIC(8,2) NOT NULL DEFAULT 0,
  is_enabled BOOLEAN NOT NULL DEFAULT true,
  route VARCHAR(120) NOT NULL DEFAULT 'Hostel ↔ MBSE',
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (assigned_hostel) REFERENCES hostels(id)
);

CREATE TABLE IF NOT EXISTS drivers (
  id VARCHAR(40) PRIMARY KEY,
  bus_number INT NOT NULL UNIQUE,
  name VARCHAR(120) NULL,
  phone VARCHAR(30) NULL,
  pin_hash VARCHAR(100) NULL,
  is_active BOOLEAN NOT NULL DEFAULT true,
  FOREIGN KEY (bus_number) REFERENCES buses(bus_number) ON DELETE CASCADE
);

ALTER TABLE drivers ADD COLUMN IF NOT EXISTS pin_hash VARCHAR(100) NULL;


CREATE TABLE IF NOT EXISTS schedules (
  id VARCHAR(40) PRIMARY KEY,
  bus_number INT NOT NULL,
  date DATE NOT NULL,
  from_hostel_time VARCHAR(20) NOT NULL,
  from_mbse_time VARCHAR(20) NOT NULL,
  special_note VARCHAR(255) NULL,
  updated_by VARCHAR(120) NULL,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (bus_number, date),
  FOREIGN KEY (bus_number) REFERENCES buses(bus_number) ON DELETE CASCADE
);

-- Schedule dates are campus calendar dates (IST) stored as SQL DATE, never timestamps.
-- If an older deployment used timestamp columns, convert instants to their IST day.
DO $$
DECLARE
  stored_type TEXT;
  date_expression TEXT;
  has_collisions BOOLEAN;
BEGIN
  SELECT data_type INTO stored_type
  FROM information_schema.columns
  WHERE table_schema = current_schema() AND table_name = 'schedules' AND column_name = 'date';
  IF stored_type IS NOT NULL AND stored_type <> 'date' THEN
    IF stored_type = 'timestamp with time zone' THEN
      date_expression := '(date AT TIME ZONE ''Asia/Kolkata'')::date';
    ELSE
      date_expression := 'date::date';
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM schedules GROUP BY bus_number, %s HAVING COUNT(*) > 1)', date_expression)
      INTO has_collisions;
    IF has_collisions THEN
      RAISE EXCEPTION 'schedules date migration found duplicate records for one bus and IST date';
    END IF;
    EXECUTE format('ALTER TABLE schedules ALTER COLUMN date TYPE DATE USING %s', date_expression);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS notifications (
  id VARCHAR(40) PRIMARY KEY,
  title VARCHAR(160) NOT NULL,
  message TEXT NOT NULL,
  type VARCHAR(30) NOT NULL,
  bus_number INT NULL,
  target_hostel VARCHAR(10) NULL,
  sent_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP NOT NULL DEFAULT (CURRENT_TIMESTAMP + INTERVAL '30 days'),
  is_read BOOLEAN NOT NULL DEFAULT false,
  sent_by VARCHAR(120) NULL,
  FOREIGN KEY (target_hostel) REFERENCES hostels(id) ON DELETE SET NULL
);

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

ALTER TABLE notifications ADD COLUMN IF NOT EXISTS expires_at TIMESTAMP;
UPDATE notifications SET expires_at = sent_at + INTERVAL '30 days' WHERE expires_at IS NULL;
ALTER TABLE notifications ALTER COLUMN expires_at SET DEFAULT (CURRENT_TIMESTAMP + INTERVAL '30 days');
ALTER TABLE notifications ALTER COLUMN expires_at SET NOT NULL;
CREATE INDEX IF NOT EXISTS notifications_expires_at_idx ON notifications (expires_at);

CREATE TABLE IF NOT EXISTS telemetry (
  id SERIAL PRIMARY KEY,
  device_id VARCHAR(60) NULL,
  bus_id VARCHAR(40) NULL,
  lat NUMERIC(10,6) NOT NULL,
  lng NUMERIC(10,6) NOT NULL,
  speed NUMERIC(8,2) NOT NULL DEFAULT 0,
  accuracy NUMERIC(8,2) NOT NULL DEFAULT 1.0,
  heading NUMERIC(6,2) NOT NULL DEFAULT 0,
  has_fix BOOLEAN NOT NULL DEFAULT false,
  satellites INT NOT NULL DEFAULT 0,
  hdop NUMERIC(6,2) NOT NULL DEFAULT 99.9,
  net_type VARCHAR(20) NOT NULL DEFAULT 'unknown',
  ts VARCHAR(64) NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'idle',
  received_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS has_fix BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS satellites INT NOT NULL DEFAULT 0;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS hdop NUMERIC(6,2) NOT NULL DEFAULT 99.9;
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS net_type VARCHAR(20) NOT NULL DEFAULT 'unknown';
ALTER TABLE telemetry ADD COLUMN IF NOT EXISTS heading NUMERIC(6,2) NOT NULL DEFAULT 0;

-- End of schema
