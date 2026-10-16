-- Input: sgs.json (aws ec2 describe-security-groups), pl.ndjson ({"id", "cidr"} per prefix-list entry).
-- Env: WANT, PORTS, ATTACHED, REUSE. Out: the best group to reuse next (BEST), coverage so far (HAVE), per-group scores.
CREATE TEMP TABLE perm AS
  SELECT * FROM (SELECT g.GroupId AS id, g.GroupName AS name, unnest(g.IpPermissions) AS p
  FROM (SELECT unnest(SecurityGroups) AS g FROM read_json('sgs.json', columns = {SecurityGroups:
    'STRUCT(GroupId VARCHAR, GroupName VARCHAR, IpPermissions STRUCT(IpProtocol VARCHAR, FromPort INT, ToPort INT,
       IpRanges STRUCT(CidrIp VARCHAR, Description VARCHAR)[], PrefixListIds STRUCT(PrefixListId VARCHAR)[])[])[]'})))
  WHERE p.IpProtocol = '-1' OR (p.IpProtocol = 'tcp' AND p.FromPort <= port_lo(getvariable('PORTS')) AND port_hi(getvariable('PORTS')) <= p.ToPort);
CREATE TEMP TABLE src AS
  SELECT id, name, r.CidrIp AS c FROM (SELECT id, name, unnest(p.IpRanges) AS r FROM perm)
  WHERE NOT starts_with(coalesce(r.Description, ''), 'lfc-')                -- your own rules are recomputed
  UNION ALL
  SELECT x.id, x.name, pl.cidr FROM (SELECT id, name, unnest(p.PrefixListIds).PrefixListId AS pid FROM perm) x
  JOIN read_json('pl.ndjson', format = 'newline_delimited', columns = {id: 'VARCHAR', cidr: 'VARCHAR'}) pl ON pl.id = x.pid;
CREATE TEMP TABLE cov AS
  SELECT id, any_value(name) AS name, w FROM src, unnest(words(getvariable('WANT'))) t(w)
  WHERE NOT starts_with(name, 'lfc-') AND covers(c, w)
    AND id NOT IN (SELECT id FROM src WHERE open_to_all(c))               -- never rely on 0.0.0.0/0
  GROUP BY id, w;
WITH taken AS (SELECT unnest(words(getvariable('ATTACHED')) || words(getvariable('REUSE'))) AS id),
     have AS (SELECT DISTINCT w FROM cov WHERE id IN (SELECT id FROM taken)),
     best AS (SELECT id, count(*) AS gain FROM cov WHERE id NOT IN (SELECT id FROM taken) AND w NOT IN (SELECT w FROM have)
              GROUP BY id ORDER BY gain DESC, id LIMIT 1)
SELECT coalesce((SELECT id FROM best), '') AS BEST,
       coalesce((SELECT string_agg(w, ' ') FROM (SELECT w FROM have UNION SELECT w FROM cov WHERE id = (SELECT id FROM best))), '') AS HAVE,
       coalesce((SELECT string_agg(id || '=' || name || ':' || n, ' ') FROM (SELECT id, name, count(*) AS n FROM cov GROUP BY ALL ORDER BY n DESC)), '') AS SG_SCORES;
