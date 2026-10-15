SELECT 'scd1 pk_ts (soft del 6-10)' c, count(*) rows, count_if(val LIKE 'upd%') upd, count_if(id BETWEEN 6 AND 10) del_left, count_if(id > 100) new FROM ${LFC_CATALOG}.shapes_scd1.pk_ts
UNION ALL SELECT 'scd1 pk_num (numeric cursor)', count(*), count_if(val LIKE 'upd%'), 0, count_if(id > 100) FROM ${LFC_CATALOG}.shapes_scd1.pk_num
UNION ALL SELECT 'scd1 uk_only (key=code)', count(*), count_if(val LIKE 'upd%'), 0, count_if(code > 'C0100') FROM ${LFC_CATALOG}.shapes_scd1.uk_only
UNION ALL SELECT 'scd1 null_cursor (101 NULL, 102 set)', count(*), count_if(val LIKE 'upd%'), count_if(id = 101), count_if(id = 102) FROM ${LFC_CATALOG}.shapes_scd1.null_cursor
UNION ALL SELECT 'scd1 fake_pk (src 102)', count(*), count_if(val LIKE 'upd%'), count_if(id IS NULL), count_if(val IN ('dup-of-1','null-id')) FROM ${LFC_CATALOG}.shapes_scd1.fake_pk
UNION ALL SELECT 'scd1 insert_only_cursor', count(*), count_if(val LIKE 'upd%'), 0, count_if(id > 100) FROM ${LFC_CATALOG}.shapes_scd1.insert_only_cursor
UNION ALL SELECT 'scd1 pk_hard (hard del 6-10)', count(*), 0, count_if(id BETWEEN 6 AND 10), count_if(id > 100) FROM ${LFC_CATALOG}.shapes_scd1.pk_hard
UNION ALL SELECT 'scd1 pk_nocursor (hard del 6-10)', count(*), count_if(val LIKE 'upd%'), count_if(id BETWEEN 6 AND 10), count_if(id > 100) FROM ${LFC_CATALOG}.shapes_scd1.pk_nocursor
UNION ALL SELECT 'scd2 pk_ts', count(*), count_if(val LIKE 'upd%'), count_if(id BETWEEN 6 AND 10 AND __END_AT IS NULL), count_if(__END_AT IS NULL) FROM ${LFC_CATALOG}.shapes_scd2.pk_ts
UNION ALL SELECT 'scd2 pk_num', count(*), count_if(val LIKE 'upd%'), 0, count_if(__END_AT IS NULL) FROM ${LFC_CATALOG}.shapes_scd2.pk_num
UNION ALL SELECT 'scd2 uk_only', count(*), count_if(val LIKE 'upd%'), 0, count_if(__END_AT IS NULL) FROM ${LFC_CATALOG}.shapes_scd2.uk_only
UNION ALL SELECT 'append pk_ts', count(*), count_if(val LIKE 'upd%'), count_if(is_deleted), count_if(id > 100) FROM ${LFC_CATALOG}.shapes_append.pk_ts
UNION ALL SELECT 'append nokey_dups', count(*), 0, 0, count_if(val LIKE 'new%') FROM ${LFC_CATALOG}.shapes_append.nokey_dups
UNION ALL SELECT 'append nokey_cursor', count(*), count_if(val LIKE 'upd%'), 0, count_if(val LIKE 'new%') FROM ${LFC_CATALOG}.shapes_append.nokey_cursor
UNION ALL SELECT 'probe6 scd1 nokey nocursor', count(*), count_if(val LIKE 'upd%'), 0, count_if(val LIKE 'new%') FROM ${LFC_CATALOG}.shapes_probe.nokey_nocursor
