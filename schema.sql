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
-- Add only numbers whose ownership has been verified through a trusted process.
DROP INDEX IF EXISTS users_recovery_phone_unique;
DROP INDEX IF EXISTS users_verified_recovery_phone_unique;
CREATE UNIQUE INDEX IF NOT EXISTS users_verified_recovery_phone_unique
  ON users (recovery_phone)
  WHERE recovery_phone IS NOT NULL AND recovery_phone_verified_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS password_resets (
  id SERIAL PRIMARY KEY,
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
DROP INDEX IF EXISTS drivers_active_phone_unique;


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

CREATE TABLE IF NOT EXISTS notifications (
  id VARCHAR(40) PRIMARY KEY,
  title VARCHAR(160) NOT NULL,
  message TEXT NOT NULL,
  type VARCHAR(30) NOT NULL,
  bus_number INT NULL,
  target_hostel VARCHAR(10) NULL,
  sent_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  is_read BOOLEAN NOT NULL DEFAULT false,
  sent_by VARCHAR(120) NULL,
  FOREIGN KEY (target_hostel) REFERENCES hostels(id) ON DELETE SET NULL
);

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
