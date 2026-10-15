-- Lakebase "shapes" fixture: one table per source shape the Lakeflow Connect matrix covers.
-- Run as the project owner:  databricks psql --project <project> -- -X -v ON_ERROR_STOP=1 -f seed.sql
-- Re-runnable: drops and recreates schema lfc_shapes.

DROP SCHEMA IF EXISTS lfc_shapes CASCADE;
CREATE SCHEMA lfc_shapes;
SET search_path = lfc_shapes;

CREATE FUNCTION set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := clock_timestamp(); RETURN NEW; END $$;
CREATE SEQUENCE ver_seq;
CREATE FUNCTION set_ver() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.ver := nextval('lfc_shapes.ver_seq'); RETURN NEW; END $$;

-- 1. pk_ts: primary key, timestamp cursor bumped on every update, cursor indexed, soft-delete flag
CREATE TABLE pk_ts (id int PRIMARY KEY, val text NOT NULL, n int NOT NULL,
  is_deleted boolean NOT NULL DEFAULT false, updated_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE INDEX pk_ts_updated_at ON pk_ts (updated_at);
CREATE TRIGGER t BEFORE UPDATE ON pk_ts FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 2. pk_num: primary key, numeric cursor (bigint version from a sequence), cursor indexed
CREATE TABLE pk_num (id int PRIMARY KEY, val text NOT NULL, ver bigint NOT NULL);
CREATE INDEX pk_num_ver ON pk_num (ver);
CREATE TRIGGER t BEFORE INSERT OR UPDATE ON pk_num FOR EACH ROW EXECUTE FUNCTION set_ver();

-- 3. uk_only: no primary key, UNIQUE NOT NULL business key, timestamp cursor, cursor indexed
CREATE TABLE uk_only (code text NOT NULL UNIQUE, val text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE INDEX uk_only_updated_at ON uk_only (updated_at);
CREATE TRIGGER t BEFORE UPDATE ON uk_only FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 4. nokey_cursor: no key at all, rows distinct, timestamp cursor, cursor NOT indexed
CREATE TABLE nokey_cursor (val text NOT NULL, n int NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TRIGGER t BEFORE UPDATE ON nokey_cursor FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 5. nokey_dups: no key, fully duplicate rows (each distinct row 3 times), timestamp cursor
CREATE TABLE nokey_dups (val text NOT NULL, n int NOT NULL, updated_at timestamptz NOT NULL);

-- 6. nokey_nocursor: no key, no usable cursor column
CREATE TABLE nokey_nocursor (val text NOT NULL, n int NOT NULL);

-- 7. pk_nocursor: primary key, no cursor column
CREATE TABLE pk_nocursor (id int PRIMARY KEY, val text NOT NULL);

-- 8. null_cursor: primary key, cursor nullable and NULL on 10 rows
CREATE TABLE null_cursor (id int PRIMARY KEY, val text NOT NULL, updated_at timestamptz);
CREATE INDEX null_cursor_updated_at ON null_cursor (updated_at);
CREATE TRIGGER t BEFORE UPDATE ON null_cursor FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 9. fake_pk: no constraints; "id" is meant to be declared as the key but has 10 duplicate ids
--    and 5 NULL ids; cursor NOT indexed
CREATE TABLE fake_pk (id int, val text NOT NULL, updated_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE TRIGGER t BEFORE UPDATE ON fake_pk FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 10. insert_only_cursor: primary key, cursor set on insert only (DEFAULT, no update trigger)
CREATE TABLE insert_only_cursor (id int PRIMARY KEY, val text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE INDEX insert_only_cursor_updated_at ON insert_only_cursor (updated_at);

-- 11. pk_hard: primary key, timestamp cursor, rows get hard-deleted (for hard-delete tracking)
CREATE TABLE pk_hard (id int PRIMARY KEY, val text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp());
CREATE INDEX pk_hard_updated_at ON pk_hard (updated_at);
CREATE TRIGGER t BEFORE UPDATE ON pk_hard FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Seed 100 rows each. Timestamps spread over the past day so the cursor increases with id.
INSERT INTO pk_ts (id, val, n, updated_at) SELECT g, 'v'||g, g, now() - (100-g) * interval '1 minute' FROM generate_series(1,100) g;
INSERT INTO pk_num (id, val, ver) SELECT g, 'v'||g, 0 FROM generate_series(1,100) g;
INSERT INTO uk_only (code, val, updated_at) SELECT 'C'||lpad(g::text,4,'0'), 'v'||g, now() - (100-g) * interval '1 minute' FROM generate_series(1,100) g;
INSERT INTO nokey_cursor (val, n, updated_at) SELECT 'v'||g, g, now() - (100-g) * interval '1 minute' FROM generate_series(1,100) g;
INSERT INTO nokey_dups (val, n, updated_at) SELECT 'v'||g, g, now() - (100-g) * interval '1 minute' FROM generate_series(1,34) g, generate_series(1,3) r;
INSERT INTO nokey_nocursor (val, n) SELECT 'v'||g, g FROM generate_series(1,100) g;
INSERT INTO pk_nocursor (id, val) SELECT g, 'v'||g FROM generate_series(1,100) g;
INSERT INTO null_cursor (id, val, updated_at) SELECT g, 'v'||g, CASE WHEN g % 10 = 0 THEN NULL ELSE now() - (100-g) * interval '1 minute' END FROM generate_series(1,100) g;
INSERT INTO fake_pk (id, val, updated_at) SELECT CASE WHEN g > 95 THEN NULL WHEN g > 85 THEN g - 85 ELSE g END, 'v'||g, now() - (100-g) * interval '1 minute' FROM generate_series(1,100) g;
INSERT INTO insert_only_cursor (id, val, updated_at) SELECT g, 'v'||g, now() - (100-g) * interval '1 minute' FROM generate_series(1,100) g;
INSERT INTO pk_hard (id, val, updated_at) SELECT g, 'v'||g, now() - (100-g) * interval '1 minute' FROM generate_series(1,100) g;
