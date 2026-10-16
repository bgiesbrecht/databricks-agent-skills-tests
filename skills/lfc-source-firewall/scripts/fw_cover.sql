-- Input: fw.json (gcloud compute firewall-rules list --format=json). Env: WANT, PORTS. Out: rules and tags to reuse, coverage.
CREATE TEMP TABLE r AS SELECT * FROM read_json('fw.json', columns = {name: 'VARCHAR',
  allowed: 'STRUCT(IPProtocol VARCHAR, ports VARCHAR[])[]', sourceRanges: 'VARCHAR[]', sourceTags: 'VARCHAR[]',
  sourceServiceAccounts: 'VARCHAR[]', targetTags: 'VARCHAR[]'})
  WHERE NOT starts_with(name, 'lfc-')                                           -- your own rules are recomputed
    AND len(coalesce(sourceTags, [])) + len(coalesce(sourceServiceAccounts, [])) = 0
    AND NOT list_bool_or([open_to_all(c) FOR c IN coalesce(sourceRanges, [])])  -- never rely on 0.0.0.0/0
    AND list_bool_or([a.IPProtocol = 'all' OR (a.IPProtocol = 'tcp' AND (a.ports IS NULL OR list_bool_or([opens(p) FOR p IN a.ports])))
                      FOR a IN allowed]);
CREATE TEMP TABLE cov AS SELECT DISTINCT name, targetTags AS tags, w FROM r, unnest(sourceRanges) s(c), unnest(words(getvariable('WANT'))) t(w)
  WHERE covers(c, w);
SELECT coalesce((SELECT string_agg(name || ':' || n, ' ') FROM (SELECT name, count(*) AS n FROM cov GROUP BY name ORDER BY n DESC)), '') AS REUSE_RULES,
       coalesce((SELECT string_agg(DISTINCT t, ' ') FROM (SELECT unnest(tags) AS t FROM cov)), '') AS REUSE_TAGS,
       coalesce((SELECT string_agg(DISTINCT w, ' ') FROM cov), '') AS HAVE;
