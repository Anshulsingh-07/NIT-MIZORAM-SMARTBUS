-- Non-sensitive initial SmartBus application data.
-- Run after supabase_schema.sql. This file is idempotent and touches only
-- public application tables. It contains no users, caretaker passwords,
-- driver names/phone numbers/PINs, credentials, secrets, or live OTPs.
-- Caretakers must be provisioned separately by a trusted server-side process:
-- generate six fresh unique temporary passwords offline, hash each with bcrypt
-- (cost 12 or higher), then insert only the hash with role='caretaker', the
-- assigned hostel_id, and must_change_password=true using parameterized queries.
-- Never use my_server/scripts/seed-local-caretakers.js against Supabase: it is
-- intentionally restricted to the isolated local database. Production should
-- use individually verified recovery numbers; the shared development contact
-- normalizes to +919140598061 and is recovery information, not a password.
-- Safe separate provisioning (trusted script only; never paste plaintext or a
-- password into SQL Editor): parameterize one insert per account and provide
-- a bcrypt hash generated outside PostgreSQL.
--   public.users(id, name, email, password, role, hostel_id, recovery_phone,
--                recovery_phone_verified_at, must_change_password)
--   VALUES (:generated_id, :caretaker_name, :predefined_email, :bcrypt_hash,
--           'caretaker', :assigned_hostel, :verified_e164_mobile, NOW(), true)
-- Do not update existing password hashes when rerunning the provisioning task.
-- Predefined account roster:
-- BH1 caretaker-bh1@nitmz.ac.in
-- BH2 caretaker-bh2@nitmz.ac.in
-- BH3 caretaker-bh3@nitmz.ac.in
-- BH4 caretaker-bh4@nitmz.ac.in
-- GH1 caretaker-gh1@nitmz.ac.in
-- GH2 caretaker-gh2@nitmz.ac.in

BEGIN;
SET LOCAL search_path = public;
SET LOCAL TIME ZONE 'Asia/Kolkata';

INSERT INTO hostels (id, name, type, full_name) VALUES
  ('BH1', 'BH1', 'Boys', 'Boys'' Hostel 1'),
  ('BH2', 'BH2', 'Boys', 'Boys'' Hostel 2'),
  ('BH3', 'BH3', 'Boys', 'Boys'' Hostel 3'),
  ('BH4', 'BH4', 'Boys', 'Boys'' Hostel 4'),
  ('GH1', 'GH1', 'Girls', 'Girls'' Hostel 1'),
  ('GH2', 'GH2', 'Girls', 'Girls'' Hostel 2')
ON CONFLICT (id) DO NOTHING;

INSERT INTO buses (
  bus_number, bus_name, assigned_hostel, source_place, destination_place,
  status, latitude, longitude, speed, is_enabled, route
) VALUES
  (1, 'Bus 1', 'GH1', 'GH1', 'MBSE', 'idle', 23.728500, 92.718000, 0, true, 'Hostel ↔ MBSE'),
  (2, 'Bus 2', 'GH1', 'GH1', 'MBSE', 'running', 23.726000, 92.716500, 25, true, 'Hostel ↔ MBSE'),
  (3, 'Bus 3', 'GH1', 'GH1', 'MBSE', 'idle', 23.729000, 92.720000, 0, true, 'Hostel ↔ MBSE'),
  (4, 'Bus 4', 'GH2', 'GH2', 'MBSE', 'running', 23.724000, 92.715000, 25, true, 'Hostel ↔ MBSE'),
  (5, 'Bus 5', 'BH1', 'BH1', 'MBSE', 'running', 23.727500, 92.718500, 25, true, 'Hostel ↔ MBSE'),
  (6, 'Bus 6', 'BH1', 'BH1', 'MBSE', 'idle', 23.726500, 92.717000, 0, true, 'Hostel ↔ MBSE'),
  (7, 'Bus 7', 'BH1', 'BH1', 'MBSE', 'running', 23.728000, 92.719500, 25, true, 'Hostel ↔ MBSE'),
  (8, 'Bus 8', 'BH1', 'BH1', 'MBSE', 'idle', 23.725500, 92.716000, 0, true, 'Hostel ↔ MBSE'),
  (9, 'Bus 9', 'BH1', 'BH1', 'MBSE', 'maintenance', 23.729500, 92.720500, 0, true, 'Hostel ↔ MBSE'),
  (10, 'Bus 10', 'BH1', 'BH1', 'MBSE', 'idle', 23.727000, 92.717500, 0, true, 'Hostel ↔ MBSE'),
  (11, 'Bus 11', 'BH1', 'BH1', 'MBSE', 'running', 23.725000, 92.715500, 25, true, 'Hostel ↔ MBSE'),
  (12, 'Bus 12', 'BH1', 'BH1', 'MBSE', 'idle', 23.728500, 92.719000, 0, true, 'Hostel ↔ MBSE'),
  (13, 'Bus 13', 'BH2', 'BH2', 'MBSE', 'running', 23.726000, 92.716500, 25, true, 'Hostel ↔ MBSE'),
  (14, 'Bus 14', 'BH2', 'BH2', 'MBSE', 'idle', 23.724500, 92.714800, 0, true, 'Hostel ↔ MBSE'),
  (15, 'Bus 15', 'BH2', 'BH2', 'MBSE', 'running', 23.730000, 92.721000, 25, true, 'Hostel ↔ MBSE'),
  (16, 'Bus 16', 'BH3', 'BH3', 'MBSE', 'idle', 23.723000, 92.714000, 0, true, 'Hostel ↔ MBSE'),
  (17, 'Bus 17', 'BH3', 'BH3', 'MBSE', 'running', 23.731500, 92.721500, 25, true, 'Hostel ↔ MBSE'),
  (18, 'Bus 18', 'BH3', 'BH3', 'MBSE', 'idle', 23.724000, 92.715500, 0, true, 'Hostel ↔ MBSE'),
  (19, 'Bus 19', 'BH3', 'BH3', 'MBSE', 'idle', 23.730500, 92.720500, 0, true, 'Hostel ↔ MBSE'),
  (20, 'Bus 20', 'BH3', 'BH3', 'MBSE', 'running', 23.723500, 92.714500, 25, true, 'Hostel ↔ MBSE'),
  (21, 'Bus 21', 'BH4', 'BH4', 'MBSE', 'idle', 23.732000, 92.722000, 0, true, 'Hostel ↔ MBSE'),
  (22, 'Bus 22', 'GH2', 'GH2', 'MBSE', 'running', 23.724500, 92.715200, 25, true, 'Hostel ↔ MBSE')
ON CONFLICT (bus_number) DO NOTHING;

-- The runtime server schedules its first-run bus data for the campus day.
INSERT INTO schedules (
  id, bus_number, date, from_hostel_time, from_mbse_time, special_note, updated_by
)
SELECT seed.id, seed.bus_number, CURRENT_DATE, seed.from_hostel_time,
       seed.from_mbse_time, seed.special_note, 'seed'
FROM (VALUES
  ('sch1', 1, '8:30 AM', '1:30 PM', NULL),
  ('sch2', 2, '9:15 AM', '4:30 PM', NULL),
  ('sch3', 3, '8:30 AM', '5:30 PM', NULL),
  ('sch4', 4, '8:15 AM', '4:30 PM', NULL),
  ('sch5', 5, '8:15 AM', '5:30 PM', NULL),
  ('sch6', 6, '8:15 AM', '7:00 PM', NULL),
  ('sch7', 7, '8:15 PM', '5:30 PM', NULL),
  ('sch8', 8, '6:30 AM', '12:30 PM', 'IoN Digital Centre Mualpui'),
  ('sch9', 9, '1:00 PM', '4:30 PM', NULL),
  ('sch10', 10, '9:15 AM', '1:30 PM', NULL),
  ('sch11', 11, '9:15 AM', '1:30 PM', NULL),
  ('sch12', 12, '10:15 AM', '2:30 PM', NULL),
  ('sch13', 13, '9:20 AM', '2:00 PM', NULL),
  ('sch14', 14, '8:20 AM', '3:20 PM', NULL),
  ('sch15', 15, '8:20 AM', '11:15 AM', NULL),
  ('sch16', 16, '8:00 AM', '4:00 PM', NULL),
  ('sch17', 17, '9:00 AM', '5:00 PM', NULL),
  ('sch18', 18, '8:30 AM', '3:30 PM', NULL),
  ('sch19', 19, '9:30 AM', '4:30 PM', NULL),
  ('sch20', 20, '10:00 AM', '2:00 PM', NULL),
  ('sch21', 21, '8:45 AM', '5:00 PM', NULL),
  ('sch22', 22, '8:25 AM', '5:30 PM', NULL)
) AS seed(id, bus_number, from_hostel_time, from_mbse_time, special_note)
WHERE NOT EXISTS (SELECT 1 FROM schedules)
ON CONFLICT (bus_number, date) DO NOTHING;

INSERT INTO notifications (
  id, title, message, type, bus_number, target_hostel, is_read, sent_by
) VALUES
  ('n1', 'Bus 5 Departure Alert', 'Bus 5 will depart from BH1 at 8:15 AM. Please be ready!', 'departure', 5, 'BH1', false, 'seed'),
  ('n2', 'Bus 7 Schedule Update', 'Bus 7 schedule updated. From Hostel: 8:15 PM, From MBSE: 5:30 PM', 'general', 7, 'BH1', false, 'seed'),
  ('n3', 'Bus 2 Arriving Soon', 'Bus 2 (GH1) is 1 km away from hostel. ETA: 5 minutes!', 'arrival', 2, 'GH1', true, 'seed'),
  ('n4', 'Bus 9 Maintenance', 'Bus 9 is under maintenance today. Please use alternate buses.', 'delay', 9, 'BH1', true, 'seed')
ON CONFLICT (id) DO NOTHING;

COMMIT;
