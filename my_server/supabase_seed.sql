-- Non-sensitive initial SmartBus data. Run after supabase_schema.sql.
-- Idempotent: existing hostels, buses, and schedules are preserved.
-- No users, caretaker passwords, driver names/phones/PINs, or demo notifications.
-- Caretaker accounts are provisioned separately with npm run caretakers:provision.

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
  (2, 'Bus 2', 'GH1', 'GH1', 'MBSE', 'idle', 23.726000, 92.716500, 0, true, 'Hostel ↔ MBSE'),
  (3, 'Bus 3', 'GH1', 'GH1', 'MBSE', 'idle', 23.729000, 92.720000, 0, true, 'Hostel ↔ MBSE'),
  (4, 'Bus 4', 'GH2', 'GH2', 'MBSE', 'idle', 23.724000, 92.715000, 0, true, 'Hostel ↔ MBSE'),
  (5, 'Bus 5', 'BH1', 'BH1', 'MBSE', 'idle', 23.727500, 92.718500, 0, true, 'Hostel ↔ MBSE'),
  (6, 'Bus 6', 'BH1', 'BH1', 'MBSE', 'idle', 23.726500, 92.717000, 0, true, 'Hostel ↔ MBSE'),
  (7, 'Bus 7', 'BH1', 'BH1', 'MBSE', 'idle', 23.728000, 92.719500, 0, true, 'Hostel ↔ MBSE'),
  (8, 'Bus 8', 'BH1', 'BH1', 'MBSE', 'idle', 23.725500, 92.716000, 0, true, 'Hostel ↔ MBSE'),
  (9, 'Bus 9', 'BH1', 'BH1', 'MBSE', 'idle', 23.729500, 92.720500, 0, true, 'Hostel ↔ MBSE'),
  (10, 'Bus 10', 'BH1', 'BH1', 'MBSE', 'idle', 23.727000, 92.717500, 0, true, 'Hostel ↔ MBSE'),
  (11, 'Bus 11', 'BH1', 'BH1', 'MBSE', 'idle', 23.725000, 92.715500, 0, true, 'Hostel ↔ MBSE'),
  (12, 'Bus 12', 'BH1', 'BH1', 'MBSE', 'idle', 23.728500, 92.719000, 0, true, 'Hostel ↔ MBSE'),
  (13, 'Bus 13', 'BH2', 'BH2', 'MBSE', 'idle', 23.726000, 92.716500, 0, true, 'Hostel ↔ MBSE'),
  (14, 'Bus 14', 'BH2', 'BH2', 'MBSE', 'idle', 23.724500, 92.714800, 0, true, 'Hostel ↔ MBSE'),
  (15, 'Bus 15', 'BH2', 'BH2', 'MBSE', 'idle', 23.730000, 92.721000, 0, true, 'Hostel ↔ MBSE'),
  (16, 'Bus 16', 'BH3', 'BH3', 'MBSE', 'idle', 23.723000, 92.714000, 0, true, 'Hostel ↔ MBSE'),
  (17, 'Bus 17', 'BH3', 'BH3', 'MBSE', 'idle', 23.731500, 92.721500, 0, true, 'Hostel ↔ MBSE'),
  (18, 'Bus 18', 'BH3', 'BH3', 'MBSE', 'idle', 23.724000, 92.715500, 0, true, 'Hostel ↔ MBSE'),
  (19, 'Bus 19', 'BH3', 'BH3', 'MBSE', 'idle', 23.730500, 92.720500, 0, true, 'Hostel ↔ MBSE'),
  (20, 'Bus 20', 'BH3', 'BH3', 'MBSE', 'idle', 23.723500, 92.714500, 0, true, 'Hostel ↔ MBSE'),
  (21, 'Bus 21', 'BH4', 'BH4', 'MBSE', 'idle', 23.732000, 92.722000, 0, true, 'Hostel ↔ MBSE'),
  (22, 'Bus 22', 'GH2', 'GH2', 'MBSE', 'idle', 23.724500, 92.715200, 0, true, 'Hostel ↔ MBSE')
ON CONFLICT (bus_number) DO NOTHING;

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
  ('sch7', 7, '8:15 AM', '5:30 PM', NULL),
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

COMMIT;
