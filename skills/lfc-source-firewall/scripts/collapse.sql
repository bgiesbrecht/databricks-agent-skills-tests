-- collapse.sql: drop every CIDR in SERVERLESS that another one in the list already covers (ip-ranges.json has
-- overlaps across regions, and an Azure NSG rule refuses overlapping prefixes). Keeps the first of exact duplicates.
WITH w AS (SELECT DISTINCT w FROM unnest(words(getvariable('SERVERLESS'))) t(w))
SELECT coalesce(string_agg(a.w, ' ' ORDER BY lo(a.w)), '') AS SERVERLESS
FROM w a
WHERE NOT EXISTS (SELECT 1 FROM w b WHERE b.w <> a.w AND covers(b.w, a.w));
