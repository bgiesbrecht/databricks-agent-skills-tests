#!/usr/bin/env bash
# vm-facts.sh azure <resource-group> <vm-name> | aws <instance-id>  [options]: the source VM's facts as one JSON line for
# pipeline-diagram.py --source-facts: VM type, vCPU, RAM, disks (size, type, IOPS, MB/s), and over SSH the JuiceFS
# mounts (object storage) and one database container's limits and data size.
#   --subscription S (azure) | --region R --aws-profile P (aws)
#   --ssh <user@host> [--key <file>]   read the VM itself: JuiceFS mounts, container limits, data size (sudo podman)
#   --container <name>                 the database container (needs --ssh)
set -euo pipefail
CLOUD=${1:?usage: vm-facts.sh azure <resource-group> <vm-name> | aws <instance-id> [options]}; shift
SUB="" REGION="" AWSP="" SSH="" KEY="" CTR=""
case $CLOUD in
  (azure) RG=${1:?resource group}; VM=${2:?vm name}; shift 2;;
  (aws) IID=${1:?instance id}; shift;;
  (*) echo "cloud: azure or aws" >&2; exit 2;;
esac
while [ $# -gt 0 ]; do
  case $1 in
    (--subscription) SUB=$2; shift 2;; (--region) REGION=$2; shift 2;; (--aws-profile) AWSP=$2; shift 2;;
    (--ssh) SSH=$2; shift 2;; (--key) KEY=$2; shift 2;; (--container) CTR=$2; shift 2;;
    (*) echo "unknown option $1" >&2; exit 2;;
  esac
done

if [ "$CLOUD" = azure ]; then
  az_(){ if [ -n "$SUB" ]; then az "$@" --subscription "$SUB"; else az "$@"; fi; }
  vmj=$(az_ vm show -g "$RG" -n "$VM" -o json)
  size=$(jq -r .hardwareProfile.vmSize <<<"$vmj"); loc=$(jq -r .location <<<"$vmj")
  caps=$(az_ vm list-skus -l "$loc" --size "$size" --resource-type virtualMachines -o json \
    | jq -c --arg s "$size" '[.[] | select(.name == $s)][0].capabilities // [] | map({(.name): .value}) | add // {}')
  disks="[]"
  for d in $(jq -r '[.storageProfile.osDisk.name] + [.storageProfile.dataDisks[].name] | .[]' <<<"$vmj"); do
    role=data; [ "$d" = "$(jq -r .storageProfile.osDisk.name <<<"$vmj")" ] && role=os
    dj=$(az_ disk show -g "$RG" -n "$d" -o json)
    disks=$(jq -c --arg r "$role" --argjson d "$dj" '. + [{role: $r, gb: $d.diskSizeGB, type: $d.sku.name,
      iops: $d.diskIOPSReadWrite, mbps: $d.diskMBpsReadWrite}]' <<<"$disks")
  done
  vm=$(jq -nc --arg t "$size" --argjson c "$caps" --argjson d "$disks" \
    '{cloud: "azure", type: $t, cpu: ($c.vCPUs | tonumber? // null), ram_gb: ($c.MemoryGB | tonumber? // null), disks: $d}')
  backend="Azure Blob"
else
  aws_(){ local a=(); [ -n "$REGION" ] && a+=(--region "$REGION"); [ -n "$AWSP" ] && a+=(--profile "$AWSP"); aws "$@" ${a[@]+"${a[@]}"} --output json; }
  ij=$(aws_ ec2 describe-instances --instance-ids "$IID" | jq -c '.Reservations[0].Instances[0]')
  itype=$(jq -r .InstanceType <<<"$ij")
  tj=$(aws_ ec2 describe-instance-types --instance-types "$itype" | jq -c '.InstanceTypes[0]')
  root=$(jq -r .RootDeviceName <<<"$ij")
  vols=$(jq -r '[.BlockDeviceMappings[].Ebs.VolumeId] | join(" ")' <<<"$ij")
  disks=$(aws_ ec2 describe-volumes --volume-ids $vols | jq -c --arg root "$root" '[.Volumes[] | {role: (if .Attachments[0].Device == $root
    then "os" else "data" end), gb: .Size, type: .VolumeType, iops: .Iops, mbps: .Throughput}]')
  vm=$(jq -nc --arg t "$itype" --argjson j "$tj" --argjson d "$disks" \
    '{cloud: "aws", type: $t, cpu: $j.VCpuInfo.DefaultVCpus, ram_gb: (($j.MemoryInfo.SizeInMiB // 0) / 1024 | floor), disks: $d}')
  backend="Amazon S3"
fi

jfs="[]" db="null"
if [ -n "$SSH" ]; then
  so=(-o ConnectTimeout=20 -o BatchMode=yes); [ -n "$KEY" ] && so+=(-i "$KEY")
  # one round trip: JuiceFS mounts, then (with a container) its CPU/memory limits, SQL Server's memory cap, data mount + size
  remote=$(ssh "${so[@]}" "$SSH" "findmnt -n -t fuse.juicefs -o SOURCE,TARGET | sed 's/^/J /';
    c='$CTR'; [ -n \"\$c\" ] || exit 0
    sudo podman inspect \"\$c\" --format 'L {{.HostConfig.NanoCpus}} {{.HostConfig.CpuQuota}} {{.HostConfig.CpuPeriod}} {{.HostConfig.Memory}}'
    sudo podman inspect \"\$c\" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E '^MSSQL_MEMORY_LIMIT_MB=' | sed 's/^/E /'
    src=\$(sudo podman inspect \"\$c\" --format '{{range .Mounts}}{{.Destination}} {{.Source}}{{println}}{{end}}' \
      | grep -E '^(/var/opt/mssql|/var/lib/postgresql/data|/var/lib/mysql|/opt/oracle/oradata) ' | head -1 | cut -d' ' -f2)
    [ -n \"\$src\" ] && echo \"D \$src \$(sudo du -sm \"\$src\" | cut -f1)\"")
  jfs=$(grep '^J ' <<<"$remote" | jq -Rc --arg b "$backend" '[inputs] as $l | ([.] + $l) | map(select(startswith("J "))
    | split(" ") | {name: (.[1] | sub("^JuiceFS:"; "")), mount: .[2], backend: $b})' 2>/dev/null || echo "[]")
  [ -n "$jfs" ] || jfs="[]"
  if [ -n "$CTR" ]; then
    lim=$(grep '^L ' <<<"$remote" || true); env=$(grep '^E ' <<<"$remote" || true); dat=$(grep '^D ' <<<"$remote" || true)
    db=$(jq -nc --arg c "$CTR" --arg l "$lim" --arg e "$env" --arg d "$dat" --argjson j "$jfs" '
      ($l | split(" ")) as $L | ($d | split(" ")) as $D |
      {container: $c,
       cpu: (if ($L[1] // "0") != "0" then (($L[1] | tonumber) / 1e9)
             elif ($L[2] // "0") != "0" and ($L[2] | tonumber) > 0 then (($L[2] | tonumber) / ($L[3] | tonumber)) else null end),
       ram_gb: (if ($L[4] // "0") != "0" then (($L[4] | tonumber) / 1073741824 * 10 | round / 10) else null end),
       engine_ram_gb: (if $e != "" then (($e | split("=")[1] | tonumber) / 1024 * 10 | round / 10) else null end),
       data_mb: (if ($D[2] // "") != "" then ($D[2] | tonumber) else null end),
       data_on: (if ($D[1] // "") as $s | any($j[]; . as $m | $s | startswith($m.mount)) then "juicefs" else "disk" end)}')
  fi
fi
jq -nc --argjson vm "$vm" --argjson db "$db" --argjson j "$jfs" '{vm: $vm, db: $db, juicefs: $j}'
