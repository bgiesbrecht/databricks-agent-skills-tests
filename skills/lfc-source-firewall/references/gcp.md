# GCP firewall rules (Cloud SQL, VM)

Uses `fw.env`, `lib.sql`, `q.sh`, and `missing.sql` from the parent skill. Start every block with `set -a; . ./fw.env`.

## Cloud SQL: authorized networks

The instance needs a public IP. Read what's already authorized first: the entries other people added often cover the workspace's serverless ranges already.

```bash
echo "I=<instance>" >> fw.env
set -a; . ./fw.env
eval "$(gcloud sql instances describe "$I" --format=json \
  | yq -p json -o shell '{"HAVE": ([.settings.ipConfiguration.authorizedNetworks[]?.value] | join(" "))}' | tee -a fw.env)"
eval "$(./q.sh missing.sql | tee -a fw.env)"
echo "missing: $(echo $MISSING | wc -w)"      # 0: nothing to change
```

Only if something is missing, patch. `--authorized-networks` **replaces the whole list** (and drops entry names), so always send the existing entries too:

```bash
set -a; . ./fw.env
gcloud sql instances patch "$I" --authorized-networks="$(echo $HAVE $MISSING | tr ' ' ,)"
```

Because entry names don't survive the patch, `HAVE` here includes entries you added earlier; to remove one, patch again with the list minus that CIDR. Never use `--clear-authorized-networks` on a shared instance: it removes everyone's entries.

Cloud SQL has no published limit on authorized networks; a single region's serverless list is 3 to 4 CIDRs. Test before relying on it for every region.

## VM: VPC firewall

Projects often already have ingress rules for the workspace's serverless ranges or team laptops, applied by network tag. Reuse them by tagging the VM instead of creating new rules.

```bash
cat >> fw.env <<'EOF'
NET=<network>
PORTS=<db-port>
VM=<vm-name>
ZONE=<zone>
EOF
set -a; . ./fw.env
gcloud compute firewall-rules list --filter="network~/$NET\$ AND direction=INGRESS AND disabled=false" --format=json > fw.json
cat > fw_cover.sql <<'EOF'
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
EOF
eval "$(./q.sh fw_cover.sql | tee -a fw.env)"
eval "$(./q.sh missing.sql | tee -a fw.env)"
echo "reuse: $REUSE_RULES (tags: $REUSE_TAGS)"; echo "missing: $(echo $MISSING | wc -w)"
```

- A rule with no target tags already applies to every VM in the network.
- Otherwise add the rule's target tags to the VM. Show the user each rule first (`gcloud compute firewall-rules describe <rule>`), since a tag also opens whatever else that rule allows:

  ```bash
  [ -n "$REUSE_TAGS" ] && gcloud compute instances add-tags "$VM" --zone "$ZONE" --tags "$(echo $REUSE_TAGS | tr ' ' ,)"
  ```

Create `lfc-` rules only for `MISSING`, one rule per purpose. One rule takes up to 5,000 source ranges, so that's always enough. `--source-ranges` on `update` is a full replacement, which is what you want: the rule ends up holding exactly what's still missing.

```bash
set -a; . ./fw.env
TAG=lfc-test
for p in myip serverless classic; do
  rule="lfc-$p-$TAG"
  case $p in myip) list="$MYIP/32";; serverless) list=$SERVERLESS;; classic) list=${CLASSIC:-};; esac
  ranges=$(for w in $MISSING; do case " $list " in *" $w "*) echo "$w";; esac; done | paste -sd, -)   # MISSING ∩ list
  eval "$(gcloud compute firewall-rules list --filter="name=$rule" --format=json | yq -p json -o shell '{"EXISTS": ([.[].name] | join(" "))}')"
  if [ -n "$ranges" ] && [ -n "$EXISTS" ]; then
    gcloud compute firewall-rules update "$rule" --source-ranges "$ranges"
  elif [ -n "$ranges" ]; then
    gcloud compute firewall-rules create "$rule" --network "$NET" --direction INGRESS \
      --allow "tcp:$PORTS" --source-ranges "$ranges" --target-tags "$TAG"
  elif [ -n "$EXISTS" ]; then
    gcloud compute firewall-rules delete "$rule" --quiet       # nothing left for it to allow
  fi
done
gcloud compute instances add-tags "$VM" --zone "$ZONE" --tags "$TAG"
```

Never change rules you reused but didn't create.

Projects have a quota on the number of firewall rules (`gcloud compute project-info describe --format=json | yq -p json -o json -r '.quotas[] | select(.metric == "FIREWALLS")'`); reusing rules keeps you under it.
