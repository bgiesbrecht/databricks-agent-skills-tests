-- Input: nsg.json (az network nsg rule list). Env: WANT, PORTS. Out: HAVE, your lfc- rules, other rules' priorities.
CREATE TEMP TABLE r AS SELECT *, list_distinct([x FOR x IN [sourceAddressPrefix] IF x IS NOT NULL] || coalesce(sourceAddressPrefixes, [])) AS src,
    [x FOR x IN [destinationPortRange] IF x IS NOT NULL] || coalesce(destinationPortRanges, []) AS dst
  FROM read_json('nsg.json', columns = {name: 'VARCHAR', priority: 'INT', direction: 'VARCHAR', access: 'VARCHAR', protocol: 'VARCHAR',
    sourceAddressPrefix: 'VARCHAR', sourceAddressPrefixes: 'VARCHAR[]', destinationPortRange: 'VARCHAR', destinationPortRanges: 'VARCHAR[]'});
SELECT coalesce((SELECT string_agg(DISTINCT c, ' ') FROM (SELECT unnest(src) AS c FROM r
         WHERE direction = 'Inbound' AND access = 'Allow' AND protocol IN ('Tcp', '*') AND NOT starts_with(name, 'lfc-')
           AND list_bool_or([opens(p) FOR p IN dst]) AND NOT list_bool_or([open_to_all(c) FOR c IN src])) WHERE is_ip(c)), '') AS HAVE,
       coalesce((SELECT string_agg(name, ' ') FROM r WHERE starts_with(name, 'lfc-')), '') AS LFC_RULES,
       coalesce((SELECT string_agg(priority::VARCHAR, ' ' ORDER BY priority) FROM r WHERE NOT starts_with(name, 'lfc-')), '') AS USED_PRIOS;
