-- Changes between run 1 and run 2. Per table: 5 inserts, 5 updates, and deletes where the shape has them.
SET search_path = lfc_shapes;
INSERT INTO pk_ts (id, val, n) SELECT g, 'new'||g, g FROM generate_series(101,105) g;
UPDATE pk_ts SET val = 'upd'||id WHERE id BETWEEN 1 AND 5;
UPDATE pk_ts SET is_deleted = true WHERE id BETWEEN 6 AND 10;                -- soft deletes
INSERT INTO pk_num (id, val, ver) SELECT g, 'new'||g, 0 FROM generate_series(101,105) g;
UPDATE pk_num SET val = 'upd'||id WHERE id BETWEEN 1 AND 5;
INSERT INTO uk_only (code, val) SELECT 'C'||lpad(g::text,4,'0'), 'new'||g FROM generate_series(101,105) g;
UPDATE uk_only SET val = 'upd'||code WHERE code BETWEEN 'C0001' AND 'C0005';
INSERT INTO nokey_cursor (val, n) SELECT 'new'||g, g FROM generate_series(101,105) g;
UPDATE nokey_cursor SET val = 'upd'||n WHERE n BETWEEN 1 AND 5;
INSERT INTO nokey_dups (val, n, updated_at) SELECT 'new'||g, g, now() FROM generate_series(101,102) g, generate_series(1,3) r;
INSERT INTO nokey_nocursor (val, n) SELECT 'new'||g, g FROM generate_series(101,105) g;
UPDATE nokey_nocursor SET val = 'upd'||n WHERE n BETWEEN 1 AND 5;
INSERT INTO pk_nocursor (id, val) SELECT g, 'new'||g FROM generate_series(101,105) g;
UPDATE pk_nocursor SET val = 'upd'||id WHERE id BETWEEN 1 AND 5;
DELETE FROM pk_nocursor WHERE id BETWEEN 6 AND 10;                           -- hard deletes, no cursor
INSERT INTO null_cursor (id, val, updated_at) VALUES (101, 'new101', NULL), (102, 'new102', now());
UPDATE null_cursor SET val = 'upd'||id WHERE id BETWEEN 1 AND 5;
INSERT INTO fake_pk (id, val) VALUES (1, 'dup-of-1'), (NULL, 'null-id');
UPDATE fake_pk SET val = 'upd'||val WHERE id BETWEEN 20 AND 24;
INSERT INTO insert_only_cursor (id, val) SELECT g, 'new'||g FROM generate_series(101,105) g;
UPDATE insert_only_cursor SET val = 'upd'||id WHERE id BETWEEN 1 AND 5;        -- not visible: cursor not bumped
INSERT INTO pk_hard (id, val) SELECT g, 'new'||g FROM generate_series(101,105) g;
DELETE FROM pk_hard WHERE id BETWEEN 6 AND 10;                               -- hard deletes
