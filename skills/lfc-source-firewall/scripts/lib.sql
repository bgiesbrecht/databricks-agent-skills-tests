-- IPv4 helpers. Inputs are read with getvariable('NAME'); lists are space-separated.
CREATE MACRO words(s) AS [x FOR x IN string_split(coalesce(s, ''), ' ') IF x <> ''];
CREATE MACRO ip2n(ip) AS (split_part(ip, '.', 1)::BIGINT << 24) + (split_part(ip, '.', 2)::BIGINT << 16)
                       + (split_part(ip, '.', 3)::BIGINT << 8) + split_part(ip, '.', 4)::BIGINT;
CREATE MACRO n2ip(n) AS concat_ws('.', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255);
CREATE MACRO is_ip(s) AS regexp_full_match(s, '[0-9]+(\.[0-9]+){3}(/[0-9]+|-[0-9]+(\.[0-9]+){3})?');
-- "a.b.c.d/n", "a.b.c.d", or a range "a.b.c.d-e.f.g.h" -> first and last address as integers
CREATE MACRO size(s) AS (1::BIGINT << (32 - coalesce(TRY_CAST(nullif(split_part(s, '/', 2), '') AS INT), 32)));
CREATE MACRO lo(s) AS CASE WHEN NOT is_ip(s) THEN NULL WHEN contains(s, '-') THEN ip2n(split_part(s, '-', 1))
                          ELSE ip2n(split_part(s, '/', 1)) // size(s) * size(s) END;
CREATE MACRO hi(s) AS CASE WHEN NOT is_ip(s) THEN NULL WHEN contains(s, '-') THEN ip2n(split_part(s, '-', 2)) ELSE lo(s) + size(s) - 1 END;
CREATE MACRO covers(h, w) AS coalesce(lo(h) <= lo(w) AND hi(w) <= hi(h), false);
CREATE MACRO open_to_all(s) AS s IN ('*', 'Any', 'Internet') OR coalesce(lo(s) = 0 AND hi(s) = 4294967295, false);
-- What a wanted CIDR is for, and a stable rule name for it: lfc-serverless-198-51-100-0-28
CREATE MACRO purpose(c) AS CASE WHEN c = getvariable('MYIP') || '/32' THEN 'myip'
                                WHEN list_contains(words(getvariable('CLASSIC')), c) THEN 'classic' ELSE 'serverless' END;
CREATE MACRO rule_name(c) AS 'lfc-' || purpose(c) || '-' || regexp_replace(c, '[./]', '-', 'g');
-- Does a port spec ("5432", "30000-30063", "*", or NULL for all ports) include every port in getvariable('PORTS')?
CREATE MACRO port_lo(r) AS TRY_CAST(split_part(r, '-', 1) AS INT);
CREATE MACRO port_hi(r) AS coalesce(TRY_CAST(nullif(split_part(r, '-', 2), '') AS INT), port_lo(r));
CREATE MACRO opens(r) AS r IS NULL OR r = '*'
  OR coalesce(port_lo(r) <= port_lo(getvariable('PORTS')) AND port_hi(getvariable('PORTS')) <= port_hi(r), false);
