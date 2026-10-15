# PostgreSQL

Tested on Postgres 16 (Podman, arm64). The planners use `pg_catalog` only, so no extensions are needed. `ORDER BY key DESC LIMIT 1` finds the max through the primary-key index for any key type; Postgres 16 has no `max(uuid)`.

## Connect

Every command pipes SQL into `$SQL`, a `psql` session to the source database. Only SQL text goes over it.

```bash
SQL="psql -h <host> -U <user> -d <database> -At -q -v ON_ERROR_STOP=1"      # password via PGPASSWORD from a umask 077 file
# Local Podman: SQL="podman exec -i <container> psql -U postgres -d <database> -At -q -v ON_ERROR_STOP=1"
```

## Files

Write these once per working directory.

**`cast.sql`: the cast table.** Session-only (`pg_temp`) functions that turn `x.n` into a valid value of any column type (`lfc_cast`), a primary key back into `n` (`lfc_to_int`), and a data column into a check against its key (`lfc_check`, for the audit). They exist only while the planner runs; the SQL they write doesn't need them. Domains use their base type, enums pick a label by position, arrays wrap the element cast.

```bash
cat > cast.sql <<'EOF'
-- pg_temp.lfc_cast(type, typmod): SQL expression that turns x.n (bigint, any n >= 1) into a valid value of the type,
-- or NULL if the type isn't supported. Lives only in the planning session; the SQL it writes doesn't need it.
SET check_function_bodies = off;
-- Strings and binaries of the column's length: n at the start and, from 38 characters (16 bytes), at the end too, so a
-- truncated value shows up in the audit. Unbounded types (text, varchar, bytea) are :lob_len long (default 100).
\if :{?lob_len} \else \set lob_len 100 \endif
SELECT set_config('lfc.lob_len', greatest(:lob_len, 38)::text, false) AS lfc_lob_len \gset
CREATE OR REPLACE FUNCTION pg_temp.lfc_len(m int) RETURNS int LANGUAGE sql STABLE AS $f$
SELECT CASE WHEN m = -1 THEN current_setting('lfc.lob_len')::int ELSE m - 4 END
$f$;
CREATE OR REPLACE FUNCTION pg_temp.lfc_str(m int) RETURNS text LANGUAGE sql STABLE AS $f$
SELECT CASE WHEN l < 19 THEN format('right(lpad(x.n::text, 19, ''0''), %s)', l)
            WHEN l < 38 THEN format('left(lpad(x.n::text, 19, ''0'') || repeat(md5(x.n::text), 1), %s)', l)
            ELSE format('lpad(x.n::text, 19, ''0'') || left(repeat(md5(x.n::text), %s), %s) || lpad(x.n::text, 19, ''0'')',
                        greatest(ceil((l - 38) / 32.0)::int, 1), l - 38) END
FROM (SELECT pg_temp.lfc_len(m) AS l) q
$f$;
CREATE OR REPLACE FUNCTION pg_temp.lfc_bin(l int) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
SELECT format('(int8send(x.n) || substr(decode(repeat(md5(x.n::text), %s), ''hex''), 1, %s) || int8send(x.n))',
              greatest(ceil((l - 16) / 16.0)::int, 1), l - 16)
$f$;
CREATE OR REPLACE FUNCTION pg_temp.lfc_cast(ty oid, m int) RETURNS text LANGUAGE sql STABLE AS $f$
SELECT CASE
  WHEN t.typtype = 'd' THEN pg_temp.lfc_cast(t.typbasetype, t.typtypmod)            -- domain: its base type (CHECKs still apply)
  WHEN t.typtype = 'e' THEN format('(enum_range(NULL::%1$s))[1 + x.n %% cardinality(enum_range(NULL::%1$s))]', ty::regtype)
  WHEN t.typcategory = 'A' AND t.typelem <> 0 THEN 'ARRAY[' || pg_temp.lfc_cast(t.typelem, m) || ']'
  ELSE CASE ty::regtype::text
    -- integers
    WHEN 'smallint' THEN '(x.n % 32767)::smallint'
    WHEN 'integer'  THEN '(x.n % 2147483647)::int'
    WHEN 'bigint'   THEN 'x.n'
    WHEN 'oid'      THEN '(x.n % 4294967296)::oid'
    -- exact numeric: integer part kept below 10^(p-s), at most 18 digits of n
    WHEN 'numeric'  THEN CASE WHEN m < 0 THEN 'x.n::numeric'
                         ELSE format('((x.n %% 1%s)::numeric / 1%s)::numeric(%s,%s)',     -- p digits of n, scaled by 10^s
                                     repeat('0', least((m - 4) >> 16, 18)), repeat('0', (m - 4) & 65535), (m - 4) >> 16, (m - 4) & 65535) END
    WHEN 'money'    THEN '((x.n % 100000000000)::numeric / 100)::money'
    -- floats
    WHEN 'real'     THEN 'x.n::real'
    WHEN 'double precision' THEN 'x.n::float8'
    -- strings: 19-digit zero-padded n first (so a key maps back to n), then MD5 filler, cut to the length
    WHEN 'character varying' THEN pg_temp.lfc_str(m)
    WHEN 'character' THEN pg_temp.lfc_str(m)
    WHEN 'text'      THEN pg_temp.lfc_str(m)                                   -- m = -1 unless lfc:len sets it
    WHEN 'name'      THEN pg_temp.lfc_str(67)
    WHEN 'bytea'     THEN pg_temp.lfc_bin(pg_temp.lfc_len(m))
    -- date/time: epoch plus n days or seconds, wrapped to stay at or before 9999-12-31
    WHEN 'date'      THEN '(date ''1970-01-01'' + (x.n % 2932896)::int)'
    WHEN 'timestamp without time zone' THEN '(timestamp ''1970-01-01'' + (x.n % 253402300800) * interval ''1 second'')'
    WHEN 'timestamp with time zone'    THEN '(timestamptz ''1970-01-01 00:00:00+00'' + (x.n % 253402300800) * interval ''1 second'')'
    WHEN 'time without time zone'      THEN '(time ''00:00'' + (x.n % 86400) * interval ''1 second'')'
    WHEN 'time with time zone'         THEN '(timetz ''00:00+00'' + (x.n % 86400) * interval ''1 second'')'
    WHEN 'interval'  THEN '((x.n % 1000000000000) * interval ''1 second'')'
    -- other scalars
    WHEN 'boolean'   THEN '(x.n % 2 = 1)'
    WHEN 'uuid'      THEN 'lpad(to_hex(x.n), 32, ''0'')::uuid'
    WHEN 'json'      THEN 'json_build_object(''n'', x.n)'
    WHEN 'jsonb'     THEN 'jsonb_build_object(''n'', x.n)'
    WHEN 'xml'       THEN 'xmlelement(name n, x.n)'
    WHEN 'pg_lsn'    THEN '(to_hex(x.n >> 32) || ''/'' || to_hex(x.n & 4294967295))::pg_lsn'
    -- network: n as an IPv4 address or a MAC address
    WHEN 'inet'      THEN '(''0.0.0.0''::inet + (x.n % 4294967296))'
    WHEN 'cidr'      THEN 'set_masklen(''0.0.0.0''::inet + (x.n % 4294967296), 32)::cidr'
    WHEN 'macaddr'   THEN 'lpad(to_hex(x.n % 281474976710656), 12, ''0'')::macaddr'
    WHEN 'macaddr8'  THEN 'lpad(to_hex(x.n), 16, ''0'')::macaddr8'
    -- bit strings: the low bits of n
    WHEN 'bit'       THEN CASE WHEN m <= 64 THEN format('x.n::bit(%s)', greatest(m, 1))
                               ELSE format('(repeat(''0'', %s) || x.n::bit(64)::text)::bit(%s)', m - 64, m) END
    WHEN 'bit varying' THEN format('x.n::bit(%s)::varbit', CASE WHEN m BETWEEN 1 AND 64 THEN m ELSE 64 END)
    -- geometric: coordinates from n, always well-formed
    WHEN 'point'     THEN 'point(x.n % 1000, x.n % 997)'
    WHEN 'line'      THEN 'line(point(0, 0), point(1 + x.n % 1000, 1))'
    WHEN 'lseg'      THEN 'lseg(point(0, 0), point(x.n % 1000, 1))'
    WHEN 'box'       THEN 'box(point(0, 0), point(x.n % 1000, 1))'
    WHEN 'path'      THEN 'path(polygon(box(point(0, 0), point(1 + x.n % 1000, 1))))'
    WHEN 'polygon'   THEN 'polygon(box(point(0, 0), point(1 + x.n % 1000, 1)))'
    WHEN 'circle'    THEN 'circle(point(x.n % 1000, 0), 1 + x.n % 100)'
    -- ranges: [v, v + 1) from n
    WHEN 'int4range' THEN 'int4range((x.n % 2147483646)::int, (x.n % 2147483646)::int + 1)'
    WHEN 'int8range' THEN 'int8range(x.n, x.n + 1)'
    WHEN 'numrange'  THEN 'numrange(x.n, x.n + 1)'
    WHEN 'daterange' THEN 'daterange(date ''1970-01-01'' + (x.n % 2932895)::int, date ''1970-01-01'' + (x.n % 2932895)::int + 1)'
    WHEN 'tsrange'   THEN 'tsrange(timestamp ''1970-01-01'' + (x.n % 253402300799) * interval ''1 second'', timestamp ''1970-01-01'' + (x.n % 253402300799 + 1) * interval ''1 second'')'
    WHEN 'tstzrange' THEN 'tstzrange(timestamptz ''1970-01-01 00:00:00+00'' + (x.n % 253402300799) * interval ''1 second'', timestamptz ''1970-01-01 00:00:00+00'' + (x.n % 253402300799 + 1) * interval ''1 second'')'
    WHEN 'int4multirange' THEN 'int4multirange(int4range((x.n % 2147483646)::int, (x.n % 2147483646)::int + 1))'
    WHEN 'int8multirange' THEN 'int8multirange(int8range(x.n, x.n + 1))'
    WHEN 'nummultirange'  THEN 'nummultirange(numrange(x.n, x.n + 1))'
    WHEN 'datemultirange' THEN 'datemultirange(daterange(date ''1970-01-01'' + (x.n % 2932895)::int, date ''1970-01-01'' + (x.n % 2932895)::int + 1))'
    -- text search
    WHEN 'tsvector'  THEN 'to_tsvector(''simple'', ''w'' || x.n)'
    WHEN 'tsquery'   THEN '(''w'' || x.n)::tsquery'
    END
  END
FROM pg_type t WHERE t.oid = ty
$f$;
-- column type -> n, for a primary key (NULL if the type can't map back to n)
CREATE OR REPLACE FUNCTION pg_temp.lfc_to_int(ty oid, m int, col text) RETURNS text LANGUAGE sql STABLE AS $f$
SELECT CASE
  WHEN t.typtype = 'd' THEN pg_temp.lfc_to_int(t.typbasetype, t.typtypmod, col)
  ELSE CASE ty::regtype::text
    WHEN 'smallint' THEN col WHEN 'integer' THEN col WHEN 'bigint' THEN col
    WHEN 'numeric' THEN CASE WHEN m < 0 OR ((m - 4) & 65535) = 0 THEN col || '::bigint' END
    WHEN 'character varying' THEN CASE WHEN m = -1 OR m - 4 >= 19 THEN format('left(%s, 19)::bigint', col) END
    WHEN 'character' THEN CASE WHEN m - 4 >= 19 THEN format('left(%s, 19)::bigint', col) END
    WHEN 'text' THEN format('left(%s, 19)::bigint', col)
    WHEN 'uuid' THEN format('(''x'' || right(replace(%s::text, ''-'', ''''), 16))::bit(64)::bigint', col)
    END
  END
FROM pg_type t WHERE t.oid = ty
$f$;
-- column -> n, for auditing a data column against its key: the SQL that decodes the column back to n modulo the
-- cast's wrap, as "<decoded> = (<key> % <wrap>)" (NULL if the type can't be decoded exactly).
CREATE OR REPLACE FUNCTION pg_temp.lfc_check(ty oid, m int, col text, k text) RETURNS text LANGUAGE sql STABLE AS $f$
SELECT CASE
  WHEN t.typtype = 'd' THEN pg_temp.lfc_check(t.typbasetype, t.typtypmod, col, k)
  WHEN t.typtype = 'e' THEN format('array_position(enum_range(NULL::%1$s), %2$s) - 1 = %3$s %% cardinality(enum_range(NULL::%1$s))', ty::regtype, col, k)
  ELSE CASE ty::regtype::text
    WHEN 'smallint' THEN format('%s = %s %% 32767', col, k)
    WHEN 'integer'  THEN format('%s = %s %% 2147483647', col, k)
    WHEN 'bigint'   THEN format('%s = %s', col, k)
    WHEN 'oid'      THEN format('%s::bigint = %s %% 4294967296', col, k)
    WHEN 'numeric'  THEN CASE WHEN m < 0 THEN format('%s = %s', col, k)
                         ELSE format('%s * 1%s = %s %% 1%s', col, repeat('0', (m - 4) & 65535), k, repeat('0', least((m - 4) >> 16, 18))) END
    WHEN 'money'    THEN format('%s::numeric * 100 = %s %% 100000000000', col, k)
    WHEN 'double precision' THEN format('%s = %s::float8', col, k)
    -- strings: n at the start (and at the end from 38 characters) and the full length; a value that isn't digits where
    -- n should be counts as a mismatch, not an error
    WHEN 'character varying' THEN pg_temp.lfc_strchk(pg_temp.lfc_len(m), col, k)
    WHEN 'character' THEN pg_temp.lfc_strchk(pg_temp.lfc_len(m), col, k)
    WHEN 'text'      THEN pg_temp.lfc_strchk(pg_temp.lfc_len(m), col, k)
    WHEN 'bytea'     THEN format('(''x'' || encode(substr(%1$s, 1, 8), ''hex''))::bit(64)::bigint = %2$s AND (''x'' || encode(substr(%1$s, length(%1$s) - 7, 8), ''hex''))::bit(64)::bigint = %2$s AND length(%1$s) = %3$s',
                                 col, k, pg_temp.lfc_len(m))
    WHEN 'date'      THEN format('%s - date ''1970-01-01'' = %s %% 2932896', col, k)
    WHEN 'timestamp without time zone' THEN format('extract(epoch from %s)::bigint = %s %% 253402300800', col, k)
    WHEN 'timestamp with time zone'    THEN format('extract(epoch from %s)::bigint = %s %% 253402300800', col, k)
    WHEN 'time without time zone'      THEN format('extract(epoch from %s)::bigint = %s %% 86400', col, k)
    WHEN 'interval'  THEN format('extract(epoch from %s)::bigint = %s %% 1000000000000', col, k)
    WHEN 'boolean'   THEN format('%s = (%s %% 2 = 1)', col, k)
    WHEN 'uuid'      THEN format('(''x'' || right(replace(%s::text, ''-'', ''''), 16))::bit(64)::bigint = %s', col, k)
    WHEN 'json'      THEN format('CASE WHEN %1$s->>''n'' ~ ''^[0-9]+$'' THEN (%1$s->>''n'')::bigint END = %2$s', col, k)
    WHEN 'jsonb'     THEN format('CASE WHEN %1$s->>''n'' ~ ''^[0-9]+$'' THEN (%1$s->>''n'')::bigint END = %2$s', col, k)
    WHEN 'inet'      THEN format('%s - ''0.0.0.0''::inet = %s %% 4294967296', col, k)
    WHEN 'int8range' THEN format('lower(%s) = %s', col, k)
    END
  END
FROM pg_type t WHERE t.oid = ty
$f$;

CREATE OR REPLACE FUNCTION pg_temp.lfc_strchk(l int, col text, k text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
SELECT CASE WHEN l < 19 THEN format('CASE WHEN %1$s ~ ''^[0-9]+$'' THEN %1$s::bigint END = %2$s %% 1%3$s', col, k, repeat('0', l))
            -- from 38 characters both ends carry n, which is enough to catch truncation and keeps values written before a
            -- column was widened valid; shorter strings must have the exact length
            WHEN l >= 38 THEN format('CASE WHEN left(%1$s, 19) ~ ''^[0-9]{19}$'' THEN left(%1$s, 19)::bigint END = %2$s AND right(%1$s, 19) = lpad((%2$s)::text, 19, ''0'')', col, k)
            ELSE format('CASE WHEN left(%1$s, 19) ~ ''^[0-9]{19}$'' THEN left(%1$s, 19)::bigint END = %2$s AND length(%1$s) = %3$s', col, k, l) END
$f$;
-- Tags in comments, in braces: a column's lfc:v={integer expression in x.n} replaces n in its cast (spec formulas: sparse
-- keys, composite keys, value ranges); a table's lfc:n={expression of its columns} gives n back from a row, for composite
-- keys or tables without a primary key, and lfc:by={column} names the column n rises with (default: the first key column).
-- A column's lfc:len={L} makes its strings or binaries L long instead of the declared length (or :lob_len), for a source's
-- average width; lfc_mod gives the typmod the casts and checks use.
CREATE OR REPLACE FUNCTION pg_temp.lfc_mod(rel oid, att int2, m int) RETURNS int LANGUAGE sql STABLE AS $f$
SELECT coalesce(substring(col_description(rel, att) from 'lfc:len=\{([0-9]+)\}')::int + 4, m)
$f$;
CREATE OR REPLACE FUNCTION pg_temp.lfc_tag(c text, tag text) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
SELECT substring(c from 'lfc:' || tag || '=\{([^}]*)\}')
$f$;
EOF
```

**`plan-insert.sql`: inserts** (`mode=append` adds `rows` per table; `mode=fill` tops each table up to its `lfc:rows=` comment; `order` and `data` choose shuffled keys and scrambled or random values):

```bash
cat > plan-insert.sql <<'EOF'
-- cat cast.sql plan-insert.sql | psql -v schema=lfc -v rows=10000 -v src=series [-v mode=fill] -At > inserts.sql
-- Emits one INSERT per table in :schema that has a usable one-column primary key.
--   mode=append (default): add :rows rows above the current max key.
--   mode=fill: top the table up to the row count in its comment ('lfc:rows=<n>'), at most :rows per statement;
--              rerun until status shows every table at its target.
--   order=random (default) | asc | desc: the order the new keys are inserted in (always exactly max+1 .. max+need).
--   data=seq (default) | scramble | random: non-key columns from n itself; from n scrambled per column,
--     (m * ((m + a) mod p) + b) mod p with m = n mod p, p = 2^31 - 1, and a, b drawn once per column at plan time
--     (non-linear, so neighbouring rows don't form a sequence; the same rows on every run);
--     or from one random value per row (random()), scrambled per column. Key and UNIQUE columns always use plain n;
--   plain_every=k, block=B (k = 0 is off): every k-th block of B keys ((n - 1) / B % k = 0) keeps plain values in every
--     column whatever data is, so those rows can be audited from the key alone (plan-audit.sql);
--   non-key identity and serial columns are left to the database.
-- Each INSERT reads the table's min and max key itself, so rerunning it never duplicates rows.
-- Foreign keys (one column, to the parent's primary key) get parent_min + scramble(n) % (parent_max - parent_min + 1), cast
-- to the parent key's type, with the parent's range probed when the statement runs: every value is an existing key.
-- Tables with a composite key or none qualify when their comment has lfc:n={...} (see cast.sql); a column's lfc:v={...}
-- replaces n in its cast. Each INSERT then probes the max of n among the rows with the highest lfc:by column.
-- Each statement starts with /* lfc level N */: parents are level 0, a table referencing them is one level higher.
-- Run the levels in order (tables within a level can run in parallel).
\if :{?mode} \else \set mode append \endif
\if :{?order} \else \set order random \endif
\if :{?plain_every} \else \set plain_every 0 \endif
\if :{?block} \else \set block 1000 \endif
\if :{?data} \else \set data seq \endif
WITH c AS (
  SELECT r.oid AS rel, s.nspname, r.relname, a.attnum, a.attname, a.attidentity <> '' AS ident,
         coalesce(a.attnum = ANY (pk.conkey), false) AS is_pk, array_position(pk.conkey, a.attnum) AS kpos,
         pg_temp.lfc_tag(obj_description(r.oid, 'pg_class'), 'n') AS nkey, pg_temp.lfc_tag(obj_description(r.oid, 'pg_class'), 'by') AS byc,
         CASE WHEN pg_temp.lfc_tag(col_description(r.oid, a.attnum), 'v') IS NOT NULL THEN            -- a spec formula for this column
           replace(pg_temp.lfc_cast(a.atttypid, pg_temp.lfc_mod(r.oid, a.attnum, a.atttypmod)), 'x.n', '(' || pg_temp.lfc_tag(col_description(r.oid, a.attnum), 'v') || ')')
              WHEN fk.confrelid IS NOT NULL AND NOT coalesce(a.attnum = ANY (pk.conkey), false) THEN   -- foreign key: inside the parent's current key range
           replace(pg_temp.lfc_cast(fk.ptyp, fk.pmod), 'x.n', format(
             '((SELECT %1$s FROM %3$I.%4$I ORDER BY %2$I LIMIT 1) + ((((%5$s %% 2147483647) * ((%5$s %% 2147483647 + %6$s) %% 2147483647)) %% 2147483647 + %7$s) %% 2147483647) %% ((SELECT %1$s FROM %3$I.%4$I ORDER BY %2$I DESC LIMIT 1) - (SELECT %1$s FROM %3$I.%4$I ORDER BY %2$I LIMIT 1) + 1))',
             pg_temp.lfc_to_int(fk.ptyp, fk.pmod, quote_ident(fk.pcol)), fk.pcol, fk.pns, fk.prel,
             CASE :'data' WHEN 'random' THEN 'x.r' ELSE 'x.n' END, 1 + floor(random() * 2147483645)::bigint, floor(random() * 2147483647)::bigint))
              WHEN :'data' = 'seq' OR coalesce(a.attnum = ANY (pk.conkey), false) OR EXISTS (SELECT 1 FROM pg_index u WHERE u.indrelid = r.oid AND u.indisunique AND u.indnkeyatts = 1
                                                  AND u.indkey[0] = a.attnum)          -- key and UNIQUE columns keep plain n
              THEN pg_temp.lfc_cast(a.atttypid, pg_temp.lfc_mod(r.oid, a.attnum, a.atttypmod))
              ELSE format(CASE WHEN :plain_every > 0 THEN format('CASE WHEN (x.n - 1) / %s %%%% %s = 0 THEN %%s ELSE %%s END', :block, :plain_every)
                               ELSE '%2$s' END, pg_temp.lfc_cast(a.atttypid, pg_temp.lfc_mod(r.oid, a.attnum, a.atttypmod)),
                   replace(pg_temp.lfc_cast(a.atttypid, pg_temp.lfc_mod(r.oid, a.attnum, a.atttypmod)), 'x.n',
                           format('((((%1$s %% 2147483647) * ((%1$s %% 2147483647 + %2$s) %% 2147483647)) %% 2147483647 + %3$s) %% 2147483647 + 1)',
                                  CASE :'data' WHEN 'random' THEN 'x.r' ELSE 'x.n' END,
                                  1 + floor(random() * 2147483645)::bigint, floor(random() * 2147483647)::bigint))) END AS expr,
         pg_temp.lfc_to_int(a.atttypid, a.atttypmod, quote_ident(a.attname)) AS to_int
  FROM pg_attribute a
  JOIN pg_class r ON r.oid = a.attrelid AND r.relkind = 'r'
  JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
  LEFT JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p'
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum      -- non-key identity and serial columns: the database numbers them
  LEFT JOIN LATERAL (                                                           -- a one-column foreign key to the parent's primary key
    SELECT f.confrelid, pa.attname AS pcol, pa.atttypid AS ptyp, pa.atttypmod AS pmod, ps.nspname AS pns, pr.relname AS prel
    FROM pg_constraint f
    JOIN pg_constraint ppk ON ppk.conrelid = f.confrelid AND ppk.contype = 'p' AND ppk.conkey = f.confkey
    JOIN pg_attribute pa ON pa.attrelid = f.confrelid AND pa.attnum = f.confkey[1]
    JOIN pg_class pr ON pr.oid = f.confrelid JOIN pg_namespace ps ON ps.oid = pr.relnamespace
    WHERE f.conrelid = r.oid AND f.contype = 'f' AND cardinality(f.conkey) = 1 AND f.conkey[1] = a.attnum LIMIT 1) fk ON true
  WHERE a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
    AND (coalesce(a.attnum = ANY (pk.conkey), false) OR (a.attidentity = '' AND NOT coalesce(pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%', false)))
), lv AS (                                                                       -- level: 0 for tables no FK points from, else 1 + parent's
  WITH RECURSIVE e AS (SELECT DISTINCT f.conrelid AS child, f.confrelid AS parent FROM pg_constraint f
                       JOIN pg_class r ON r.oid = f.conrelid JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
                       WHERE f.contype = 'f' AND f.conrelid <> f.confrelid),
  l(rel, lvl) AS (SELECT r.oid, 0 FROM pg_class r JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema' WHERE r.relkind = 'r'
                  UNION ALL SELECT e.child, l.lvl + 1 FROM e JOIN l ON l.rel = e.parent WHERE l.lvl < 50)
  SELECT rel, max(lvl) AS lvl FROM l GROUP BY rel
), tb AS (
  SELECT nspname, relname, max(lv.lvl) AS lvl,
         string_agg(quote_ident(attname), ', ' ORDER BY attnum) AS cols,
         CASE WHEN bool_or(ident) THEN ' OVERRIDING SYSTEM VALUE' ELSE '' END AS ovr,
         string_agg(coalesce(expr, 'NULL'), ', ' ORDER BY attnum) AS exprs,
         CASE WHEN max(nkey) IS NOT NULL THEN max(nkey) WHEN count(*) FILTER (WHERE is_pk) = 1 THEN max(to_int) FILTER (WHERE is_pk) END AS pk_int,
         max(nkey) AS nkey, quote_ident(coalesce(max(byc), max(attname) FILTER (WHERE kpos = 1))) AS byc,
         max(attname) FILTER (WHERE is_pk) AS pk,
         substring(obj_description(c.rel, 'pg_class') from 'lfc:rows=([0-9]+)')::bigint AS target
  FROM c JOIN lv ON lv.rel = c.rel GROUP BY c.rel, nspname, relname
  HAVING max(nkey) IS NOT NULL OR (count(*) FILTER (WHERE is_pk) = 1 AND max(to_int) FILTER (WHERE is_pk) IS NOT NULL)
), pr AS (                                                                       -- the max and min of n: two index probes
  SELECT tb.*, CASE WHEN nkey IS NULL THEN format('(SELECT %s FROM %I.%I ORDER BY %I DESC LIMIT 1)', pk_int, nspname, relname, pk)
                    ELSE format('(SELECT max(%1$s) FROM %2$I.%3$I WHERE %4$s = (SELECT %4$s FROM %2$I.%3$I ORDER BY %4$s DESC LIMIT 1))', nkey, nspname, relname, byc) END AS hi_q,
               CASE WHEN nkey IS NULL THEN format('(SELECT %s FROM %I.%I ORDER BY %I LIMIT 1)', pk_int, nspname, relname, pk)
                    ELSE format('(SELECT min(%1$s) FROM %2$I.%3$I WHERE %4$s = (SELECT %4$s FROM %2$I.%3$I ORDER BY %4$s LIMIT 1))', nkey, nspname, relname, byc) END AS lo_q
  FROM tb
)
SELECT format('/* lfc level %s */ INSERT INTO %I.%I (%s)%s SELECT %s FROM (SELECT b.base + g.%s AS n%s FROM '
              '(SELECT coalesce(hi, 0) AS base, %s AS need FROM (SELECT %s AS hi, %s AS lo) m) b, %s%s OFFSET 0) x;',
         lvl, nspname, relname, cols, ovr, exprs,
         CASE WHEN :'order' = 'random' AND :'src' = 'seed' THEN 'r' ELSE 'i' END,
         CASE :'data' WHEN 'random' THEN ', floor(random() * 2147483647)::bigint AS r' ELSE '' END,
         CASE :'mode' WHEN 'fill' THEN format('least(%s, greatest(%s - coalesce(hi - lo + 1, 0), 0))', :rows, target) ELSE :'rows' END,
         hi_q, lo_q,
         CASE WHEN :'src' <> 'seed' THEN 'generate_series(1, b.need) g(i)'
              WHEN :'order' = 'random' THEN 'lfc_seed.seed g WHERE g.r <= b.need' ELSE 'lfc_seed.seed g WHERE g.i <= b.need' END,
         CASE :'order' WHEN 'asc' THEN ' ORDER BY g.i' WHEN 'desc' THEN ' ORDER BY g.i DESC'
                       ELSE CASE WHEN :'src' <> 'seed' THEN ' ORDER BY random()' ELSE '' END END)
FROM pr
WHERE :'mode' <> 'fill' OR target IS NOT NULL
ORDER BY lvl, relname;
EOF
```

**`plan-audit.sql`: audit plain rows** (decode every checkable column back to `n` and compare it with the key; with `plain_every` it checks only the plain blocks):

```bash
cat > plan-audit.sql <<'EOF'
-- cat cast.sql plan-audit.sql | psql -v schema=lfc [-v plain_every=k -v block=B] -At > audit.sql; psql -At < audit.sql
-- Emits one query per table that decodes every checkable column back to n and compares it with the key, over the rows
-- that hold plain values (all rows if plain_every is 0, else the plain blocks). Prints table|rows checked|bad rows|columns checked.
\if :{?plain_every} \else \set plain_every 0 \endif
\if :{?block} \else \set block 1000 \endif
WITH c AS (
  SELECT s.nspname, r.relname, a.attnum, a.attname, coalesce(a.attnum = ANY (pk.conkey), false) AS is_pk,
         pg_temp.lfc_tag(obj_description(r.oid, 'pg_class'), 'n') AS nkey, pg_temp.lfc_tag(col_description(r.oid, a.attnum), 'v') AS v,
         pg_temp.lfc_to_int(a.atttypid, a.atttypmod, quote_ident(a.attname)) AS to_int, a.atttypid, pg_temp.lfc_mod(r.oid, a.attnum, a.atttypmod) AS atttypmod
  FROM pg_attribute a
  JOIN pg_class r ON r.oid = a.attrelid AND r.relkind = 'r'
  JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
  LEFT JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p'
  LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
  WHERE a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''              -- the same columns plan-insert.sql fills
    AND (coalesce(a.attnum = ANY (pk.conkey), false) OR (a.attidentity = '' AND NOT coalesce(pg_get_expr(d.adbin, d.adrelid) LIKE 'nextval(%', false)))
    AND (coalesce(a.attnum = ANY (pk.conkey), false) OR pg_temp.lfc_tag(col_description(r.oid, a.attnum), 'v') IS NOT NULL OR NOT EXISTS (SELECT 1 FROM pg_constraint f WHERE f.conrelid = r.oid AND f.contype = 'f'
                                                  AND a.attnum = ANY (f.conkey)))      -- FK values depend on the parent, unless a formula
), k AS (SELECT nspname, relname, CASE WHEN max(nkey) IS NOT NULL THEN max(nkey) WHEN count(*) FILTER (WHERE is_pk) = 1 THEN max(to_int) FILTER (WHERE is_pk) END AS key
         FROM c GROUP BY 1, 2
         HAVING max(nkey) IS NOT NULL OR (count(*) FILTER (WHERE is_pk) = 1 AND max(to_int) FILTER (WHERE is_pk) IS NOT NULL)),
ch AS (SELECT c.nspname, c.relname, c.attnum,   -- a column with a formula (lfc:v) is checked against the formula at n
              -- a column added after rows existed (tagged 'lfc:added' by plan-ddl.sql) may be NULL in the older rows
              CASE WHEN col_description(format('%I.%I', c.nspname, c.relname)::regclass, c.attnum) LIKE '%lfc:added%'
                   THEN format('(%I IS NULL OR %s)', c.attname, pg_temp.lfc_check(c.atttypid, c.atttypmod, quote_ident(c.attname), '(' || coalesce(replace(c.v, 'x.n', '(' || k.key || ')::bigint'), k.key) || ')'))
                   ELSE pg_temp.lfc_check(c.atttypid, c.atttypmod, quote_ident(c.attname), '(' || coalesce(replace(c.v, 'x.n', '(' || k.key || ')::bigint'), k.key) || ')') END AS chk
       FROM c JOIN k USING (nspname, relname) WHERE NOT c.is_pk)
SELECT format('SELECT %L, count(*), count(*) FILTER (WHERE NOT (%s)), %s FROM %I.%I%s;',
              relname, string_agg('coalesce(' || chk || ', false)', ' AND ' ORDER BY attnum), count(*), nspname, relname,
              CASE WHEN :plain_every > 0 THEN format(' WHERE (%s - 1) / %s %% %s = 0', max(k.key), :block, :plain_every) ELSE '' END)
FROM ch JOIN k USING (nspname, relname) WHERE chk IS NOT NULL GROUP BY nspname, relname ORDER BY relname;
EOF
```

**`plan-delete.sql`: deletes from one end** (`end=head` or `tail`), dimension first: it re-points foreign keys that reference the keys going away, then deletes. It never empties a table:

```bash
cat > plan-delete.sql <<'EOF'
-- cat cast.sql plan-delete.sql | psql -v schema=lfc -v rows=100 -v end=head|tail -At > deletes.sql
-- Emits, per table, a DELETE that removes :rows keys from one end of the key range (head or tail), never the middle, and
-- never the last rows: it deletes the keys before the (:rows + 1)-th, so a table with :rows rows or fewer is left alone.
-- Dimension first: before a table loses keys, every one-column foreign key that points at them is re-pointed into the
-- range that stays (an UPDATE of a non-key column, so the child's key range doesn't change). Tables go in level order.
-- Skipped: tables whose key comes from a formula (lfc:n), and parents of a foreign key that is part of the child's key or
-- has a formula (lfc:v), since re-pointing those would change a key or break the formula.
WITH RECURSIVE e AS (SELECT DISTINCT f.conrelid AS child, f.confrelid AS parent FROM pg_constraint f
                     JOIN pg_class r ON r.oid = f.conrelid JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
                     WHERE f.contype = 'f' AND f.conrelid <> f.confrelid),
l(rel, lvl) AS (SELECT r.oid, 0 FROM pg_class r JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema' WHERE r.relkind = 'r'
                UNION ALL SELECT e.child, l.lvl + 1 FROM e JOIN l ON l.rel = e.parent WHERE l.lvl < 50),
t AS (                                                         -- tables with a one-column key that maps back to n
  SELECT r.oid AS rel, s.nspname, r.relname, a.attname AS pk, a.atttypid, a.atttypmod,
         pg_temp.lfc_to_int(a.atttypid, a.atttypmod, quote_ident(a.attname)) AS pk_int, (SELECT max(lvl) FROM l WHERE l.rel = r.oid) AS lvl,
         -- the first key that stays: head -> the (:rows + 1)-th smallest, tail -> the (:rows + 1)-th largest
         format('(SELECT %I FROM %I.%I ORDER BY %I %s OFFSET %s LIMIT 1)', a.attname, s.nspname, r.relname, a.attname,
                CASE :'end' WHEN 'tail' THEN 'DESC' ELSE 'ASC' END, :rows) AS keep
  FROM pg_constraint pk JOIN pg_class r ON r.oid = pk.conrelid JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
  JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = pk.conkey[1]
  WHERE pk.contype = 'p' AND cardinality(pk.conkey) = 1
    AND coalesce(obj_description(r.oid, 'pg_class'), '') NOT LIKE '%lfc:n={%'      -- spec-formula keys (TPC schemas): not yet
    AND NOT EXISTS (SELECT 1 FROM pg_constraint f JOIN pg_attribute ca ON ca.attrelid = f.conrelid AND ca.attnum = ANY (f.conkey)
                    LEFT JOIN pg_constraint cpk ON cpk.conrelid = f.conrelid AND cpk.contype = 'p'
                    WHERE f.contype = 'f' AND f.confrelid = r.oid      -- a child that can't be re-pointed: the FK is part of its key,
                      AND (ca.attnum = ANY (cpk.conkey) OR coalesce(col_description(f.conrelid, ca.attnum), '') LIKE '%lfc:v={%'))  -- or a formula
),
fk AS (                                                        -- one-column foreign keys to those tables' keys
  SELECT f.confrelid AS parent, cs.nspname AS cns, cr.relname AS crel, ca.attname AS ccol
  FROM pg_constraint f JOIN pg_constraint ppk ON ppk.conrelid = f.confrelid AND ppk.contype = 'p' AND ppk.conkey = f.confkey
  JOIN pg_class cr ON cr.oid = f.conrelid JOIN pg_namespace cs ON cs.oid = cr.relnamespace
  JOIN pg_attribute ca ON ca.attrelid = f.conrelid AND ca.attnum = f.conkey[1]
  WHERE f.contype = 'f' AND cardinality(f.conkey) = 1
),
stmt AS (
  -- re-point children: v -> lo' + (v % span'), where [lo', hi'] is the range that stays
  SELECT t.lvl, t.relname, 1 AS step, format('UPDATE %I.%I SET %I = %s WHERE %I %s %s;', fk.cns, fk.crel, fk.ccol,
           replace(pg_temp.lfc_cast(t.atttypid, t.atttypmod), 'x.n', format('(%s + %s %% (%s - %s + 1))',
             CASE :'end' WHEN 'tail' THEN format('(SELECT %s FROM %I.%I ORDER BY %I LIMIT 1)', t.pk_int, t.nspname, t.relname, t.pk)
                         ELSE replace(t.pk_int, quote_ident(t.pk), t.keep) END,
             pg_temp.lfc_to_int(t.atttypid, t.atttypmod, quote_ident(fk.ccol)),
             CASE :'end' WHEN 'tail' THEN replace(t.pk_int, quote_ident(t.pk), t.keep)
                         ELSE format('(SELECT %s FROM %I.%I ORDER BY %I DESC LIMIT 1)', t.pk_int, t.nspname, t.relname, t.pk) END,
             CASE :'end' WHEN 'tail' THEN format('(SELECT %s FROM %I.%I ORDER BY %I LIMIT 1)', t.pk_int, t.nspname, t.relname, t.pk)
                         ELSE replace(t.pk_int, quote_ident(t.pk), t.keep) END)),
           fk.ccol, CASE :'end' WHEN 'tail' THEN '>' ELSE '<' END, t.keep) AS sql
  FROM t JOIN fk ON fk.parent = t.rel WHERE t.pk_int IS NOT NULL
  UNION ALL
  SELECT t.lvl, t.relname, 2, format('DELETE FROM %I.%I WHERE %I %s %s;', t.nspname, t.relname, t.pk,
           CASE :'end' WHEN 'tail' THEN '>' ELSE '<' END, t.keep)
  FROM t
)
SELECT format('/* lfc level %s */ %s', lvl, sql) FROM stmt ORDER BY lvl, relname, step;
EOF
```

**`plan-status.sql`: min, max, and rows** for every table, one query per 500 tables:

```bash
cat > plan-status.sql <<'EOF'
-- psql -v schema=lfc -At -f pg-plan-status.sql > status.sql; psql -At -f status.sql
-- Emits SELECTs (500 tables each) returning table|min key|max key|rows|target (from 'lfc:rows=', if set). Keys only ever change at the
-- ends, so rows = max - min + 1 without COUNT(*); each min and max is one index probe.
WITH t AS (                                                    -- a one-column key, or a key formula (lfc:n={...}, see cast.sql)
  SELECT s.nspname, r.relname, a.attname, a.atttypid::regtype::text AS ty,
         coalesce(substring(obj_description(r.oid, 'pg_class') from 'lfc:rows=([0-9]+)'), '') AS target,
         substring(obj_description(r.oid, 'pg_class') from 'lfc:n=\{([^}]*)\}') AS nkey,
         coalesce(substring(obj_description(r.oid, 'pg_class') from 'lfc:by=\{([^}]*)\}'), quote_ident(a.attname)) AS byc,
         row_number() OVER (ORDER BY r.relname) - 1 AS k
  FROM pg_class r
  JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
  LEFT JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p'
  LEFT JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = pk.conkey[1]
  WHERE r.relkind = 'r' AND (cardinality(pk.conkey) = 1 OR obj_description(r.oid, 'pg_class') LIKE '%lfc:n={%')
), q AS (
  SELECT k / 500 AS chunk, format('SELECT %L, lo, hi, coalesce(hi - lo + 1, 0), %L FROM (SELECT %s lo, %s hi) m', relname, target,
           CASE WHEN nkey IS NULL THEN format('(SELECT %s FROM %I.%I ORDER BY %I LIMIT 1)', i, nspname, relname, attname)
                ELSE format('(SELECT min(%1$s) FROM %2$I.%3$I WHERE %4$s = (SELECT %4$s FROM %2$I.%3$I ORDER BY %4$s LIMIT 1))', nkey, nspname, relname, byc) END,
           CASE WHEN nkey IS NULL THEN format('(SELECT %s FROM %I.%I ORDER BY %I DESC LIMIT 1)', i, nspname, relname, attname)
                ELSE format('(SELECT max(%1$s) FROM %2$I.%3$I WHERE %4$s = (SELECT %4$s FROM %2$I.%3$I ORDER BY %4$s DESC LIMIT 1))', nkey, nspname, relname, byc) END) AS sel
  FROM (SELECT *, CASE ty WHEN 'uuid' THEN format('(''x'' || right(replace(%I::text, ''-'', ''''), 16))::bit(64)::bigint', attname)
                          WHEN 'character varying' THEN format('left(%I, 19)::bigint', attname)
                          WHEN 'character' THEN format('left(%I, 19)::bigint', attname)
                          WHEN 'text' THEN format('left(%I, 19)::bigint', attname)
                          ELSE format('%I::bigint', attname) END AS i FROM t) t2
)
SELECT string_agg(sel, E'\nUNION ALL ') || ';' FROM q GROUP BY chunk ORDER BY chunk;
EOF
```

**`make-dataset.sql`: create N tables** with a variety of types and a target row count each:

```bash
cat > make-dataset.sql <<'EOF'
-- psql -v schema=lfc -v tables=100 -v max_rows=1000000 -v cols=12 [-v dist=even|random] -f make-dataset.sql
-- Creates :tables tables, each with a bigint key and :cols columns cycling through a menu of types (each table starts
-- at a different type, so all types are covered), and records each table's target row count in its comment:
--   dist=even (default): table k gets ceil(k * max_rows / tables) rows, an even spread from small to max_rows
--   dist=random: a uniform pseudo-random count in 1..max_rows, the same on every run
-- dims=D, fks=K (default 0): the first D tables are dimensions; every other table gets K foreign-key columns
--   (f1_t01_id ...) referencing the dimensions in turn, each with an index (the delete planner's re-point UPDATEs use it)
\if :{?dist} \else \set dist even \endif
\if :{?dims} \else \set dims 0 \endif
\if :{?fks} \else \set fks 0 \endif
CREATE SCHEMA IF NOT EXISTS :"schema";
WITH menu(types) AS (SELECT ARRAY['int', 'bigint', 'smallint', 'numeric(18,2)', 'numeric(38,10)', 'real', 'double precision',
       'varchar(50)', 'varchar(255)', 'char(20)', 'text', 'date', 'timestamp', 'timestamptz', 'time', 'interval',
       'boolean', 'bytea', 'uuid', 'jsonb', 'point', 'inet']),
t AS (SELECT k, format('t%s', lpad(k::text, length(:'tables'), '0')) AS name,
             CASE :'dist' WHEN 'random' THEN 1 + ('x' || substr(md5(k::text), 1, 15))::bit(60)::bigint % :max_rows
                          ELSE ceil(k * :max_rows::numeric / :tables)::bigint END AS target
      FROM generate_series(1, :tables) k)
SELECT format('CREATE TABLE %I.%I (id bigint PRIMARY KEY, %s%s); COMMENT ON TABLE %I.%I IS %L;%s',
              :'schema', t.name,
              (SELECT string_agg(format('c%s_%s %s', j, trim(both '_' from regexp_replace(m.types[1 + (t.k + j) % cardinality(m.types)], '[^a-z0-9]+', '_', 'g')),
                                        m.types[1 + (t.k + j) % cardinality(m.types)]), ', ' ORDER BY j)
               FROM generate_series(1, :cols) j),
              (SELECT coalesce(string_agg(format(', f%s_%s_id bigint NOT NULL REFERENCES %I.%I', f, d.name, :'schema', d.name), '' ORDER BY f), '')
               FROM generate_series(1, :fks) f JOIN t d ON d.k = 1 + (t.k + f) % :dims WHERE t.k > :dims),
              :'schema', t.name, 'lfc:rows=' || t.target,
              (SELECT coalesce(string_agg(format(' CREATE INDEX ON %I.%I (f%s_%s_id);', :'schema', t.name, f, d.name), '' ORDER BY f), '')
               FROM generate_series(1, :fks) f JOIN t d ON d.k = 1 + (t.k + f) % :dims WHERE t.k > :dims))
FROM t, menu m ORDER BY t.k \gexec
EOF
```

**`plan-ddl.sql`: random DDL** (see "Schema changes during a load" in the skill):

```bash
cat > plan-ddl.sql <<'EOF'
-- cat cast.sql plan-ddl.sql | psql -v schema=lfc -v ops=10 [-v new_rows=10000] -At > ddl.sql; psql -v ON_ERROR_STOP=0 < ddl.sql
-- Emits :ops random DDL operations on :schema, weighted like real schema changes: add column 25%, modify column 20%,
-- create index 15%, truncate 15%, create table 10%, drop column 10%, drop table 5%. Each picks an object that keeps
-- the generator working: added columns are nullable and tagged 'lfc:added' (the audit accepts NULL there); modify only
-- widens varchar(L >= 38), widens int to bigint, or drops NOT NULL; drop and truncate only touch tables no foreign key
-- points at; drop column never takes the key or a foreign key. Operations planned together can still clash (one drops
-- a column another modifies): run the file without stopping on errors, then re-plan the fill.
\if :{?new_rows} \else \set new_rows 10000 \endif
WITH RECURSIVE
menu(types) AS (SELECT ARRAY['int', 'bigint', 'numeric(18,2)', 'double precision', 'varchar(60)', 'varchar(200)', 'text',
                             'date', 'timestamp', 'timestamptz', 'boolean', 'bytea', 'uuid', 'jsonb']),
tbl AS (SELECT r.oid, r.relname FROM pg_class r JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
        JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p' AND cardinality(pk.conkey) = 1 WHERE r.relkind = 'r'),
col AS (SELECT t.oid, t.relname, a.attnum, a.attname, a.atttypid::regtype::text AS ty, a.atttypmod AS m, a.attnotnull AS notnull,
               EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conrelid = t.oid AND c.contype IN ('p', 'f') AND a.attnum = ANY (c.conkey)) AS keyish,
               EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = t.oid AND i.indkey[0] = a.attnum) AS indexed
        FROM tbl t JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped),
leaf AS (SELECT * FROM tbl t WHERE NOT EXISTS (SELECT 1 FROM pg_constraint f WHERE f.confrelid = t.oid AND f.contype = 'f' AND f.conrelid <> t.oid)),
op AS (SELECT i, CASE WHEN p < 25 THEN 'add' WHEN p < 45 THEN 'modify' WHEN p < 60 THEN 'index' WHEN p < 75 THEN 'truncate'
                      WHEN p < 85 THEN 'create' WHEN p < 95 THEN 'drop_column' ELSE 'drop_table' END AS op
       FROM (SELECT i, floor(random() * 100) AS p FROM generate_series(1, :ops) i) q)
SELECT format('/* ddl %s %s */ %s', op.i, op.op, x.sql) FROM op, menu m, LATERAL (
  SELECT CASE op.op
    WHEN 'add' THEN (SELECT format('ALTER TABLE %I.%I ADD COLUMN %I %s; COMMENT ON COLUMN %I.%I.%I IS ''lfc:added'';',
                               :'schema', t.relname, nm, ty, :'schema', t.relname, nm)
                     FROM (SELECT t.relname, m.types[1 + floor(random() * cardinality(m.types) + 0 * op.i)::int] AS ty,
                                  format('a%s_%s', op.i, to_char(clock_timestamp(), 'HH24MISS')) AS nm
                           FROM tbl t ORDER BY random() + 0 * op.i LIMIT 1) t)
    WHEN 'modify' THEN (SELECT CASE WHEN c.ty = 'character varying' THEN format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE varchar(%s);', :'schema', c.relname, c.attname, least((c.m - 4) * 2, 10485760))
                                    WHEN c.ty = 'integer' THEN format('ALTER TABLE %I.%I ALTER COLUMN %I TYPE bigint;', :'schema', c.relname, c.attname)
                                    ELSE format('ALTER TABLE %I.%I ALTER COLUMN %I DROP NOT NULL;', :'schema', c.relname, c.attname) END
                        FROM col c WHERE NOT c.keyish AND ((c.ty = 'character varying' AND c.m - 4 >= 38) OR c.ty = 'integer' OR c.notnull)
                        ORDER BY random() + 0 * op.i LIMIT 1)
    WHEN 'index' THEN (SELECT format('CREATE INDEX ON %I.%I (%I);', :'schema', c.relname, c.attname) FROM col c
                       WHERE NOT c.indexed AND c.ty IN ('smallint', 'integer', 'bigint', 'numeric', 'character varying', 'date',
                                                        'timestamp without time zone', 'timestamp with time zone', 'uuid', 'boolean')
                       ORDER BY random() + 0 * op.i LIMIT 1)
    WHEN 'truncate' THEN (SELECT format('TRUNCATE %I.%I;', :'schema', relname) FROM leaf ORDER BY random() + 0 * op.i LIMIT 1)
    WHEN 'create' THEN (SELECT format('CREATE TABLE %I.%I (id bigint PRIMARY KEY, %s); COMMENT ON TABLE %I.%I IS %L;', :'schema', nm,
                                      (SELECT string_agg(format('c%s %s', j, m.types[1 + (j * 5 + op.i * 3) % cardinality(m.types)]), ', ') FROM generate_series(1, 6) j),
                                      :'schema', nm, 'lfc:rows=' || (1 + floor(random() * :new_rows))::bigint)
                        FROM (SELECT format('n%s_%s', op.i, to_char(clock_timestamp(), 'HH24MISS')) AS nm) q)
    WHEN 'drop_column' THEN (SELECT format('ALTER TABLE %I.%I DROP COLUMN %I;', :'schema', c.relname, c.attname) FROM col c
                             WHERE NOT c.keyish AND (SELECT count(*) FROM col c2 WHERE c2.oid = c.oid) > 2 ORDER BY random() + 0 * op.i LIMIT 1)
    WHEN 'drop_table' THEN (SELECT format('DROP TABLE %I.%I;', :'schema', relname) FROM leaf ORDER BY random() + 0 * op.i LIMIT 1)
  END AS sql) x
WHERE x.sql IS NOT NULL ORDER BY op.i;
EOF
```

**`skipped.sql`: tables the planner leaves out:**

```bash
cat > skipped.sql <<'EOF'
-- Tables the planner skips: no primary key, a composite key, or a text key shorter than 19 characters, unless the table
-- has a key formula (lfc:n={...} in its comment).
SELECT r.relname, CASE WHEN pk.oid IS NULL THEN 'no primary key' WHEN cardinality(pk.conkey) > 1 THEN 'composite key'
                       ELSE 'key type ' || format_type(a.atttypid, a.atttypmod) END AS reason
FROM pg_class r
JOIN pg_namespace s ON s.oid = r.relnamespace AND s.nspname = :'schema'
LEFT JOIN pg_constraint pk ON pk.conrelid = r.oid AND pk.contype = 'p'
LEFT JOIN pg_attribute a ON a.attrelid = r.oid AND a.attnum = pk.conkey[1] AND cardinality(pk.conkey) = 1
WHERE r.relkind = 'r' AND coalesce(obj_description(r.oid, 'pg_class'), '') NOT LIKE '%lfc:n={%'     -- lfc:n: a key formula
  AND (pk.oid IS NULL OR cardinality(pk.conkey) > 1
       OR NOT (a.atttypid IN ('smallint'::regtype, 'integer'::regtype, 'bigint'::regtype, 'numeric'::regtype, 'uuid'::regtype, 'text'::regtype)
               OR (a.atttypid IN ('varchar'::regtype, 'bpchar'::regtype) AND (a.atttypmod = -1 OR a.atttypmod - 4 >= 19))))
ORDER BY 1;
EOF
```

**`boundary.sql`: check the casts for a table** before loading it (any `ERROR` in the output is a bad cast):

```bash
cat > boundary.sql <<'EOF'
-- cat cast.sql boundary.sql | psql -v table=lfc.mytable -At > bnd.sql; psql -v ON_ERROR_STOP=0 < bnd.sql
-- Writes one SELECT per column that casts n at its boundaries (1 up to 2^63 - 2) to the column's type; any ERROR is a bad cast.
SELECT format('SELECT %L AS col, %L AS ty, n, (%s)::text AS v FROM (VALUES (1::bigint), (2), (1000003), (1000000000039), (4611686018427387904), (9223372036854775806)) x(n);',
              a.attname, format_type(a.atttypid, a.atttypmod), coalesce(pg_temp.lfc_cast(a.atttypid, a.atttypmod), 'NULL') || '::' || format_type(a.atttypid, a.atttypmod))
FROM pg_attribute a WHERE a.attrelid = :'table'::regclass AND a.attnum > 0 AND NOT a.attisdropped ORDER BY a.attnum;
EOF
```

## Run

```bash
S=lfc                                                                          # schema
# A dataset: 100 tables, even spread up to 1M rows, 12 columns each; the 10 smallest are dimensions, the rest have 2 FKs each
$SQL -v schema=$S -v tables=100 -v max_rows=1000000 -v cols=12 -v dist=even -v dims=10 -v fks=2 < make-dataset.sql > /dev/null
$SQL -v schema=$S < skipped.sql                                                # should print nothing
echo "CREATE SCHEMA IF NOT EXISTS lfc_seed; DROP TABLE IF EXISTS lfc_seed.seed;
CREATE TABLE lfc_seed.seed (i bigint PRIMARY KEY, r bigint NOT NULL);           -- r: a random permutation of i, for shuffled keys
INSERT INTO lfc_seed.seed SELECT i, r FROM (SELECT i, row_number() OVER (ORDER BY random()) AS r FROM generate_series(1, 1000000) i) q ORDER BY i;" | $SQL
for round in $(seq 1 50); do                      # fill until done: re-plan every round, so DDL and failed INSERTs are picked up
  cat cast.sql plan-insert.sql | $SQL -v schema=$S -v rows=1000000 -v src=seed -v mode=fill -v order=random -v data=scramble -v plain_every=4 -v block=1000 -v lob_len=100 > inserts.sql
  for l in $(grep -o '^/\* lfc level [0-9]*' inserts.sql | awk '{ print $4 }' | sort -un); do   # levels in order, 4 sessions each
    grep "^/\* lfc level $l \*/" inserts.sql | awk -v n=4 '{ print > ("part-" NR % n ".sql") }'
    for f in part-*.sql; do $SQL < "$f" > /dev/null 2>> fill.err & done; wait; rm -f part-*.sql
  done
  $SQL -v schema=$S < plan-status.sql > status.sql && $SQL < status.sql > status.out    # table|min|max|rows|target
  awk -F'|' '$5 != "" && $4 < $5 { n++ } END { exit n > 0 }' status.out && break
done
awk -F'|' '{ t += $4 } END { print NR " tables, " t " rows" }' status.out
cat cast.sql plan-audit.sql | $SQL -v schema=$S -v plain_every=4 -v block=1000 -v lob_len=100 > audit.sql && $SQL < audit.sql   # same lob_len; bad must be 0
```

Other operations:

```bash
cat cast.sql plan-insert.sql | $SQL -v schema=$S -v rows=10000 -v src=series -v order=random -v data=random > more.sql && $SQL < more.sql   # append 10,000 per table (data=random: these rows can't be audited)
cat cast.sql plan-delete.sql | $SQL -v schema=$S -v rows=1000 -v end=head > deletes.sql && $SQL < deletes.sql   # 1,000 from each head, one session
cat cast.sql plan-ddl.sql | $SQL -v schema=$S -v ops=8 > ddl.sql && $SQL -v ON_ERROR_STOP=0 < ddl.sql 2>&1 | grep ERROR || true   # 8 random DDL; then run the fill loop again
cat cast.sql boundary.sql | $SQL -v table=$S.t001 > bnd.sql && $SQL -v ON_ERROR_STOP=0 < bnd.sql 2>&1 | grep ERROR || echo "no bad casts"
```

## Types

`n` is the row's `bigint`. All casts are in `cast.sql`; this table summarizes them. "Key" types can be the primary key (they map back to `n`).

| Category | Types | Range | Value from `n` | Key |
|---|---|---|---|---|
| Integer | `smallint`, `integer`, `bigint` (and `smallserial`, `serial`, `bigserial`), `oid` | ±32,767; ±2,147,483,647; ±9.2 × 10¹⁸; `oid` 0 … 4,294,967,295 | `n % 32767`, `n % 2147483647`, `n`, `n % 2^32` | yes |
| Exact numeric | `numeric(p,s)` (p ≤ 1,000), `numeric`, `money` | below 10^(p−s); `money` ±9.2 × 10¹⁶ | `(n % 10^min(p,18)) / 10^s`; `n`; `(n % 10^11) / 100` | `numeric` with scale 0 |
| Float | `real`, `double precision` | 6 / 15 significant digits | `n::real`, `n::float8` | — |
| String | `varchar(L)` (L ≤ 10,485,760), `char(L)`, `text`, `name` (63 bytes) | 1 GB per value | exactly L characters (`lob_len` for `text` and plain `varchar`): zero-padded 19-digit `n`, MD5 filler, and from L = 38 the zero-padded `n` again at the end; L < 19: the last L digits | L ≥ 19 |
| Binary | `bytea` | 1 GB | exactly `lob_len` bytes: 8-byte `n` (`int8send`), MD5 bytes, 8-byte `n` | — |
| Date / time | `date`, `timestamp(p)`, `timestamptz`, `time`, `timetz`, `interval` | dates 4713 BC … 5,874,897 AD; timestamps … 294,276 AD | 1970-01-01 plus `n % 2,932,896` days or `n % 253,402,300,800` s (≤ 9999-12-31); `time`: `n % 86400` s; `interval`: `n % 10^12` s | — |
| Boolean, UUID | `boolean`, `uuid` | | `n % 2 = 1`; `lpad(to_hex(n), 32, '0')::uuid` | `uuid` |
| JSON, XML | `json`, `jsonb`, `xml` | 1 GB | `{"n": n}`; `<n>n</n>` | — |
| Network | `inet`, `cidr`, `macaddr`, `macaddr8` | IPv4 / IPv6; 6 / 8 bytes | `0.0.0.0 + n % 2^32` (as `/32` for `cidr`); `n` as 12 / 16 hex digits | — |
| Bit string | `bit(L)`, `bit varying(L)` | | the low L bits of `n` (zero-padded above 64) | — |
| Geometric | `point`, `line`, `lseg`, `box`, `path`, `polygon`, `circle` | float8 coordinates | shapes from `n % 1000` (always non-degenerate) | — |
| Range | `int4range`, `int8range`, `numrange`, `daterange`, `tsrange`, `tstzrange`, and the `*multirange` types | | `[v, v + 1)` with `v` from `n` | — |
| Text search | `tsvector`, `tsquery` | | `to_tsvector('simple', 'w' \|\| n)`; `'w' \|\| n` | — |
| Other | `pg_lsn`; arrays of any type above; enums; domains | | `n` as `hi/lo`; `ARRAY[element cast]`; label `1 + n % count`; base type's cast | — |
| Not supported (`NULL`) | composite types, `regclass` and other `reg*` types, `"char"`, extension types (PostGIS etc.) | | | |

Tested: every type above at `n` = 1, 2, 1,000,003, 1,000,000,000,039, 2⁶², and 2⁶³ − 2, with no errors (62 columns, 372 values).

**Audit (`lfc_check`)** decodes these back to `n` modulo their wrap (strings and `bytea` also at the end, and their exact length, so truncation shows up): integers, `oid`, `numeric`, `money`, `double precision`, all string types (a value that isn't digits where `n` should be counts as bad, not as an error), `bytea`, `date`, `timestamp`, `timestamptz`, `time`, `interval`, `boolean`, `uuid`, `json`, `jsonb`, `inet`, `int8range`, and enums. `real` (exact only below 2²⁴) and the geometric, bit, and text-search types aren't checked. Tested: 0 bad rows on plain blocks; a changed date, varchar, uuid, JSON value, or inet address each shows up as one bad row, and so does a 5,000-character `text` cut to 4,096, a 5,000-byte `bytea` cut to 4,000, or a `varchar(100)` one character short. A change in the middle filler isn't detected.

## Limits

| Limit | Value | Source |
|---|---|---|
| Columns per table | 1,600, including dropped columns (tested: 1,601 fails) | [limits](https://www.postgresql.org/docs/current/limits.html) |
| Row size | Must fit an 8 KB page: 8,160 bytes in-row (tested: 1,600 `bigint` columns create, but a full row fails with "row is too big: size 12824, maximum size 8160"). Long variable-length values move out of row (TOAST) | [limits](https://www.postgresql.org/docs/current/limits.html) |
| Field size | 1 GB | [limits](https://www.postgresql.org/docs/current/limits.html) |
| Table size | 32 TB (8 KB blocks) | [limits](https://www.postgresql.org/docs/current/limits.html) |
| Rows in one `VALUES` list | No fixed limit (tested: 1,000,000 rows, 8.9 MB of SQL) | [INSERT](https://www.postgresql.org/docs/current/sql-insert.html) |
| Bind parameters per statement | 65,535 | [limits](https://www.postgresql.org/docs/current/limits.html) |
| Identifier length | 63 bytes (longer names are truncated silently) | [lexical structure](https://www.postgresql.org/docs/current/sql-syntax-lexical.html) |
| Columns per index | 32 | [limits](https://www.postgresql.org/docs/current/limits.html) |
| `numeric` | up to 131,072 digits before the point and 16,383 after; 1,000 declared digits | [numeric types](https://www.postgresql.org/docs/current/datatype-numeric.html) |

## Measured (Podman machine, 4 vCPU, XFS)

| Step | Time |
|---|---|
| 100-table dataset, even spread up to 1M rows (50.5M rows, 20 GB), 4 sessions | 2 min 48 s |
| Create 10,000 tables | 9.3 s |
| Plan inserts for 10,000 tables | 0.4 s |
| Insert 100 rows into each of 10,000 tables (1M rows) | 8.6 s |
| Status of 10,000 tables (20,000 index probes) | 6.2 s (plan 0.4 s) |
| 1M rows into one table, `generate_series` / seed table | 3.1 s / 3.0 s |
| 8 tables × 500,000 rows, 1 session / 4 sessions | 11.3 s / 7.0 s |
| 1M rows into one table: keys in order / shuffled / in order with `data=random` | 2.8 s / 4.3 s / 3.1 s (key index 21 MB / 30 MB) |
| Key order per 8,000-key batch: `random` / `asc` / `desc` | 3,982 down and 4,017 up / all up / all down |

**Foreign keys, tested** (two dimensions, one with a `varchar` key; a fact referencing both; a table referencing the fact; a self-referencing table): fill in level order with every foreign key enforced, facts spread over all 1,000 and 200 dimension keys; 150 keys deleted from every head and then every tail with 4 re-point UPDATEs and no violations, every key range still contiguous and the facts pointing only into the dimensions' remaining ranges; a refill continues above the max and the new facts reference the new dimension keys; a table with fewer rows than the delete count is left alone. A 12-table dataset with `dims=3, fks=2` filled level by level to exactly its targets and audited with 0 bad rows.

## Gotchas

- **Identity keys** (`GENERATED ALWAYS AS IDENTITY`) are inserted with `OVERRIDING SYSTEM VALUE`. Identity and `serial` sequences don't move: `SELECT setval(pg_get_serial_sequence('<schema>.<table>', '<key>'), <max>)` before anything else inserts.
- **Dropping thousands of tables** in one statement fails with `out of shared memory` (lock limit): drop them in batches of 500.
- **The seed table must be stored in `i` order** (`... ORDER BY i` when filling it): `row_number() OVER (ORDER BY random())` returns its rows sorted by the random value, which would make `r` ascending in a table scan and the "shuffled" keys sequential again.
- **`data=random`** draws one `random()` per row in a subquery that `OFFSET 0` keeps from being merged; without it, a cast that uses its input twice (ranges, strings) could get two different values.
- **Domains keep their `CHECK`s**: a domain on `int` with `CHECK (VALUE < 100)` rejects most values of `n % 2147483647`.
- `numeric` with a negative scale (Postgres 15+) isn't handled.
