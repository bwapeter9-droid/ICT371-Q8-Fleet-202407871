-- =====================================================================
-- ICT371 Advanced Database | Student No: 202407871
-- QUESTION 8: Transport Fleet Maintenance  (50 marks)
-- Run with:  psql -d yourdb -f ICT371_202407871_Q8_Fleet.sql
-- Objects live in schema q8_fleet; the script can be re-run safely.
-- =====================================================================
DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path TO q8_fleet, public;

-- ---------------------------------------------------------------------
-- (a) DATABASE AND SEED DATA [6]
-- ---------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id             SERIAL      PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         SERIAL  PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on         DATE    NOT NULL,
    start_odometer  INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer    INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id        INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service  INTEGER NOT NULL,
    flagged_on        DATE    NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1001', 14500, 10000),   -- 4500 km since service: not due (will reach 4900 after trips)
    ('ABC 1002', 25000, 19000),   -- 6000 km since service: DUE
    ('ABC 1003',  5000,     0);   -- exactly 5000 km: DUE (threshold is "at least 5,000")

-- ---------------------------------------------------------------------
-- (b) FUNCTION fn_service_due [6]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_current INTEGER;
    v_last    INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_last
    FROM   vehicles
    WHERE  vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) PROCEDURE pr_record_trip [8]
-- Only validates and inserts. The odometer update is done by the trigger.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start and end odometer must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) TRIGGER BEFORE INSERT on trips [8]
-- Checks the start value against the vehicle, then updates
-- current_odometer once. If the INSERT later fails, the whole statement
-- (including this UPDATE) is rolled back, so it is applied exactly once
-- per stored trip.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current
    FROM   vehicles
    WHERE  vehicle_id = NEW.vehicle_id
    FOR UPDATE;                                           -- lock: no two trips can start from the same value

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
       OR NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start % end %', NEW.start_odometer, NEW.end_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
                        NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles
    SET    current_odometer = NEW.end_odometer
    WHERE  vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- Six trips THROUGH THE PROCEDURE (after the trigger is installed)
CALL pr_record_trip(1, CURRENT_DATE - 5, 14500, 14650);
CALL pr_record_trip(1, CURRENT_DATE - 3, 14650, 14900);
CALL pr_record_trip(2, CURRENT_DATE - 4, 25000, 25300);
CALL pr_record_trip(2, CURRENT_DATE - 2, 25300, 25500);
CALL pr_record_trip(3, CURRENT_DATE - 3,  5000,  5100);
CALL pr_record_trip(3, CURRENT_DATE - 1,  5100,  5200);

-- ---------------------------------------------------------------------
-- (e) VIEW v_service_due [5]  (re-uses fn_service_due: one rule, one place)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM   vehicles
WHERE  fn_service_due(vehicle_id);

-- ---------------------------------------------------------------------
-- (f) INDEX [5]
-- Equality on vehicle_id then range on trip_on: the composite B-tree
-- jumps to the vehicle and reads the date range in order.
-- ---------------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

-- ---------------------------------------------------------------------
-- (g) SCHEDULED JOB [6]
-- Upsert alerts for due vehicles (keeps the ORIGINAL flagged_on date,
-- refreshes km_since_service), delete alerts for vehicles no longer due.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM   vehicles
    WHERE  fn_service_due(vehicle_id)
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts
    WHERE  NOT fn_service_due(vehicle_id);
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every Monday at 06:00  (cron day-of-week: 1 = Monday)
SELECT cron.schedule('q8_refresh_service_alerts', '0 6 * * 1',
                     $$CALL q8_fleet.pr_refresh_service_alerts()$$);

SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q8_refresh_service_alerts';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- =====================================================================
-- TESTS / EVIDENCE
-- =====================================================================
\echo '--- (a) Data ---'
SELECT * FROM vehicles ORDER BY vehicle_id;      -- odometers: 14900, 25500, 5200
SELECT * FROM trips ORDER BY trip_id;

\echo '--- (b) Function ---'
SELECT vehicle_id, fn_service_due(vehicle_id) FROM vehicles ORDER BY vehicle_id;   -- f, t, t
DO $$ BEGIN PERFORM fn_service_due(999);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown vehicle): %', SQLERRM; END $$;

\echo '--- (c) Procedure ---'
DO $$ BEGIN CALL pr_record_trip(999, CURRENT_DATE, 0, 10);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (unknown vehicle): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 14900, 14900);
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (end not > start): %', SQLERRM; END $$;

\echo '--- (d) Trigger: wrong start rejected; odometer updated exactly once ---'
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 14000, 14100);        -- should start at 14900
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (start mismatch): %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
            VALUES (1, CURRENT_DATE, 14900, 14800);                    -- direct SQL, bad mileage
   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'EXPECTED ERROR (invalid mileage): %', SQLERRM; END $$;
SELECT vehicle_id, current_odometer FROM vehicles WHERE vehicle_id = 1;   -- still 14900
CALL pr_record_trip(1, CURRENT_DATE, 14900, 15000);
SELECT vehicle_id, current_odometer FROM vehicles WHERE vehicle_id = 1;   -- exactly 15000 (+100, not +200)

\echo '--- (e) View ---'
SELECT * FROM v_service_due ORDER BY registration;         -- ABC 1001 (5000), ABC 1002 (6500), ABC 1003 (5200)

\echo '--- (f) EXPLAIN ---'
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 2 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

\echo '--- (g) Scheduled procedure: insert, update, remove ---'
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;          -- 3 alerts
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;   -- vehicle 2 serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;          -- vehicle 2 alert removed
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;          -- rerun: unchanged, no duplicates
