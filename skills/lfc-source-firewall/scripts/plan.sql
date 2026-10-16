-- Env: MISSING, LFC_RULES ("<name>" or "<rule-id>=<name>"). Out: TO_ADD (cidrs), TO_ADD_SPEC (cidr,name,start,end), TO_DROP (ids)
WITH m AS (SELECT w, rule_name(w) AS name FROM unnest(words(getvariable('MISSING'))) t(w)),
     h AS (SELECT split_part(e, '=', 1) AS id, list_last(string_split(e, '=')) AS name FROM unnest(words(getvariable('LFC_RULES'))) t(e)),
     a AS (SELECT * FROM m WHERE name NOT IN (SELECT name FROM h))
SELECT coalesce((SELECT string_agg(w, ' ') FROM a), '') AS TO_ADD,
       coalesce((SELECT string_agg(concat_ws(',', w, name, n2ip(lo(w)), n2ip(hi(w))), ' ') FROM a), '') AS TO_ADD_SPEC,
       coalesce((SELECT string_agg(id, ' ') FROM h WHERE name NOT IN (SELECT name FROM m)), '') AS TO_DROP;
