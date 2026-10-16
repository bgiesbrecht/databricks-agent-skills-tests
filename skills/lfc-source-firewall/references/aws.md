# AWS firewall rules (RDS, Aurora)

RDS and Aurora are reached through the **security groups** attached to the instance or cluster. Every CIDR is one inbound rule. The limits that matter (defaults, per region):

| Limit | Default | Quota name (service `vpc`) |
|---|---|---|
| Inbound rules per security group | 60 | "Inbound or outbound rules per security group" |
| Security groups per network interface (so per RDS instance) | 5 | "Security groups per network interface" |
| The two multiplied | at most 1,000 | AWS caps the product, so raising one lowers the other |
| A referenced prefix list | counts its **max entries**, not its current entries, against the group's rules | |

So one instance holds at most about 300 CIDRs by default. One region's serverless list (1 to 5 CIDRs) fits easily. Every serverless region (about 760) doesn't fit even with five groups: use region scope, or an Azure source.

Uses `fw.env` and the parent skill's `$Q` and `$FW` (its Step 0). Start every block with `set -a; . ./fw.env`.

## Step 1: limits, the database, and what already allows these IPs

```bash
cat >> fw.env <<'EOF'
REGION=<aws-region>
PORTS=<db-port>
DB=<db-instance-id>
EOF
set -a; . ./fw.env

# Quotas (defaults if the names don't match). yq has no floor, so strip the ".0" in the shell.
eval "$(aws service-quotas list-service-quotas --service-code vpc --region "$REGION" --output json \
  | yq -p json -o shell '{"RULES_PER_SG": ([.Quotas[] | select(.QuotaName | test("rules per security group")) | .Value][0] // 60),
                          "SGS_PER_ENI": ([.Quotas[] | select(.QuotaName | test("per network interface")) | .Value][0] // 5)}')"
echo "RULES_PER_SG=${RULES_PER_SG%.*}" >> fw.env; echo "SGS_PER_ENI=${SGS_PER_ENI%.*}" >> fw.env

# The instance's VPC and attached groups (Aurora: see Step 3)
eval "$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB" --output json \
  | yq -p json -o shell '.DBInstances[0] | {"VPC": (.DBSubnetGroup.VpcId // ""), "ATTACHED": ([.VpcSecurityGroups[].VpcSecurityGroupId] | join(" "))}' \
  | tee -a fw.env)"

# Every security group in the VPC, and the entries of every prefix list they reference
aws ec2 describe-security-groups --region "$REGION" --filters Name=vpc-id,Values="$VPC" --output json > sgs.json
: > pl.ndjson
for pl in $(yq -p json -o json -r '[.SecurityGroups[].IpPermissions[].PrefixListIds[]?.PrefixListId] | unique | .[]' sgs.json); do
  aws ec2 get-managed-prefix-list-entries --region "$REGION" --prefix-list-id "$pl" --output json \
    | PL="$pl" yq -p json -o json -I0 '.Entries[] | {"id": strenv(PL), "cidr": .Cidr}' >> pl.ndjson
done
```

Pick groups to reuse, greedily: each round, `sg_pick.sql` returns the group that covers the most of what the attached and already-picked groups don't (`BEST`). One slot stays free for an `lfc-` group:

```bash
set -a; . ./fw.env
REUSE=
for i in $(seq 1 $(( SGS_PER_ENI - $(echo $ATTACHED | wc -w) - 1 ))); do
  eval "$($Q $FW/sg_pick.sql)"
  [ -n "$BEST" ] || break
  REUSE="${REUSE:+$REUSE }$BEST"
done
eval "$($Q $FW/sg_pick.sql | grep -v '^BEST=' | tee -a fw.env)"    # final HAVE and SG_SCORES
echo "REUSE='$REUSE'" >> fw.env
eval "$($Q $FW/missing.sql | tee -a fw.env)"
echo "groups covering something: $SG_SCORES"; echo "reuse: $REUSE"; echo "missing: $(echo $MISSING | wc -w)"
```

Groups named `lfc-*`, rules described `lfc-*`, and any group open to `0.0.0.0/0` are never counted. Before attaching a reused group, show the user its rules (`aws ec2 describe-security-group-rules --region "$REGION" --filters Name=group-id,Values=<id>`): it also opens whatever else it allows. Don't reuse a group that opens other ports or sources this database shouldn't have.

## Step 2: add only what's missing, packed into `lfc-test-<n>` groups

Find your `lfc-` groups in the VPC and their rules (each rule's description is its `rule_name`), then plan:

```bash
set -a; . ./fw.env
eval "$(yq -p json -o shell '{"LFC_IDS": ([.SecurityGroups[] | select(.GroupName | test("^lfc-")) | .GroupId] | join(" "))}' sgs.json | tee -a fw.env)"
if [ -n "$LFC_IDS" ]; then
  eval "$(aws ec2 describe-security-group-rules --region "$REGION" --filters Name=group-id,Values="$(echo $LFC_IDS | tr ' ' ,)" --output json \
    | yq -p json -o shell '[.SecurityGroupRules[] | select(.IsEgress == false)] as $r
        | {"LFC_RULES": ([$r[] | select((.Description // "") | test("^lfc-")) | .GroupId + "/" + .SecurityGroupRuleId + "=" + .Description] | join(" ")),
           "LFC_GROUPS": ([$r | group_by(.GroupId)[] | .[0].GroupId + ":" + (length | tostring)] | join(" "))}' \
    | tee -a fw.env)"
fi
eval "$($Q $FW/plan.sql | tee -a fw.env)"
echo "add: $(echo $TO_ADD | wc -w), drop: $(echo $TO_DROP | wc -w), lfc- groups (id:rules used): ${LFC_GROUPS:-none}"
```

**Capacity check before adding anything.** Free rules are `RULES_PER_SG - used` on each group in `LFC_GROUPS`, plus `RULES_PER_SG` for each new group the instance can still take (`SGS_PER_ENI` minus the attached, reused, and `lfc-` groups). If `TO_ADD` doesn't fit, stop and tell the user. The options, in order: scope to the workspace's region instead of every region; request a quota increase (it raises one limit by lowering the other, so it rarely helps much); or use an Azure source, whose NSG holds every region.

Apply: drop stale rules (`TO_DROP` entries are `<group>/<rule-id>`), then fill an `lfc-` group up to the quota:

```bash
set -a; . ./fw.env
for r in $TO_DROP; do
  aws ec2 revoke-security-group-ingress --region "$REGION" --group-id "${r%/*}" --security-group-rule-ids "${r#*/}" > /dev/null
done
SG=<lfc-group-id>; USED=<rules used in it, from LFC_GROUPS>
for s in $TO_ADD_SPEC; do
  IFS=, read -r cidr name _ _ <<< "$s"
  [ "$USED" -ge "$RULES_PER_SG" ] && { echo "group $SG is full: create or pick the next lfc-test-<n> group"; break; }
  aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
    --ip-permissions "IpProtocol=tcp,FromPort=${PORTS%-*},ToPort=${PORTS#*-},IpRanges=[{CidrIp=$cidr,Description=$name}]" > /dev/null
  USED=$((USED + 1))
done
```

If the loop stops on a full group, rerun Step 2's first block to get the remaining `TO_ADD`, and continue in the next group. Create a group only after asking:

```bash
aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC" --group-name lfc-test-<n> \
  --description "Lakeflow Connect test sources" --tag-specifications 'ResourceType=security-group,Tags=[{Key=purpose,Value=lfc-test}]'
```

## Step 3: attach the chosen groups

`--vpc-security-group-ids` **replaces** the whole list, so pass the groups already attached that you want to keep, plus the reused and `lfc-` groups:

```bash
set -a; . ./fw.env
aws rds modify-db-instance --region "$REGION" --db-instance-identifier "$DB" \
  --vpc-security-group-ids $(echo $ATTACHED $REUSE $LFC_IDS | tr ' ' '\n' | sort -u) --apply-immediately
```

**Aurora:** groups attach to the cluster. Get them with

```bash
eval "$(aws rds describe-db-clusters --region "$REGION" --db-cluster-identifier <cluster> --output json \
  | yq -p json -o shell '.DBClusters[0] | {"ATTACHED": ([.VpcSecurityGroups[].VpcSecurityGroupId] | join(" "))}' | tee -a fw.env)"
```

(the VPC comes from any member instance, as in Step 1), and attach with `aws rds modify-db-cluster --db-cluster-identifier <cluster> --vpc-security-group-ids ... --apply-immediately`.

Never edit or remove rules in a group you reused but didn't create; detach it instead.

## Reachability

The instance must be publicly accessible (`--publicly-accessible` at create, or `aws rds modify-db-instance --publicly-accessible`) and in subnets with a route to an internet gateway, or no rule has any effect.

**Prefix lists don't raise the limit:** a customer-managed prefix list counts its max entries against every group that references it. Reuse one when it already exists and covers the IPs, but don't create one to get around the 60-rule limit.
