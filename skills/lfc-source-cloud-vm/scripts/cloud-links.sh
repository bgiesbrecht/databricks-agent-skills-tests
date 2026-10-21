#!/usr/bin/env bash
# cloud-links.sh <vm public ip> [--region <aws region>] [--subscription <azure subscription>] [--resource-id <azure id>]...
#   Clickable links, for inspection, to a test VM and what goes with it, in whichever cloud has that IP: tried with
#   each CLI that's installed and logged in (az, aws, gcloud). One line per resource: "LINK <what>: <url>".
#     Azure: the VM, its NIC, the network security group (on the NIC or its subnet), the public IP, the OS and data disks
#     AWS:   the instance, its security groups, its EBS volumes (AWS_REGION, or --region, or the CLI's default region)
#     GCP:   the instance, its disks, and the VPC firewall rules
#   --resource-id adds the portal link for any other Azure resource, for example the storage account of a master
#   snapshot (bk.env SA_ID). Azure is searched in --subscription, AZURE_SUBSCRIPTION_ID, the subscriptions of the
#   --resource-id values, then the CLI's current one; a default resource group in `az config` is ignored (it would scope
#   every list to that group and hide the VM). Read-only. Exit 1 when no cloud had the IP.
set -uo pipefail
IP=${1:?vm public ip}; shift; REGION=${AWS_REGION:-}; EXTRA=(); SUBS=${AZURE_SUBSCRIPTION_ID:-}
while [ $# -gt 0 ]; do case $1 in --region) REGION=$2; shift 2;; --resource-id) EXTRA+=("$2"); shift 2;;
  --subscription) SUBS="$2 $SUBS"; shift 2;; *) echo "unknown $1"; exit 2;; esac; done
export AZURE_DEFAULTS_GROUP=
found=0
link() { echo "LINK $1: $2"; found=1; }

# --- Azure: portal links are https://portal.azure.com/#@<tenant>/resource<resource id>
if command -v az >/dev/null && az account show >/dev/null 2>&1; then
  TEN=$(az account show --query tenantId -o tsv); AZ="https://portal.azure.com/#@$TEN/resource"
  for id in "${EXTRA[@]}"; do link "Azure $(basename "$id")" "$AZ$id"; done
  for id in "${EXTRA[@]}"; do SUBS="$SUBS $(echo "$id" | awk -F/ '{print $3}')"; done
  pipid=; cfg=
  for sub in $SUBS $(az account show --query id -o tsv); do
    pip=$(az network public-ip list --subscription "$sub" --query "[?ipAddress=='$IP'] | [0].{id:id, cfg:ipConfiguration.id}" -o json 2>/dev/null)
    pipid=$(echo "$pip" | yq -p json '.id // ""' 2>/dev/null); cfg=$(echo "$pip" | yq -p json '.cfg // ""' 2>/dev/null)
    [ -n "$pipid" ] && break
  done
  if [ -n "$pipid" ]; then
    link "Azure public IP $IP" "$AZ$pipid"
    nic=${cfg%/ipConfigurations/*}
    if [ -n "$nic" ]; then
      link "Azure NIC $(basename "$nic")" "$AZ$nic"
      eval "$(az network nic show --ids "$nic" -o json | yq -p json -o shell '{"VM": (.virtualMachine.id // ""), "NSG": (.networkSecurityGroup.id // ""), "SUBNET": (.ipConfigurations[0].subnet.id // "")}')"
      [ -z "$NSG" ] && [ -n "$SUBNET" ] && NSG=$(az network vnet subnet show --ids "$SUBNET" --query networkSecurityGroup.id -o tsv 2>/dev/null)
      [ -n "$NSG" ] && link "Azure network security group $(basename "$NSG")" "$AZ$NSG"
      if [ -n "$VM" ]; then
        link "Azure VM $(basename "$VM")" "$AZ$VM"
        az vm show --ids "$VM" --query "[storageProfile.osDisk.managedDisk.id, storageProfile.dataDisks[].managedDisk.id][]" -o tsv 2>/dev/null \
          | while read -r d; do [ -n "$d" ] && link "Azure disk $(basename "$d")" "$AZ$d"; done
      fi
    fi
  fi
fi

# --- AWS: the EC2 console, per region
if command -v aws >/dev/null && aws sts get-caller-identity >/dev/null 2>&1; then
  R=${REGION:-$(aws configure get region 2>/dev/null)}
  if [ -n "$R" ]; then
    j=$(aws ec2 describe-instances --region "$R" --filters "Name=ip-address,Values=$IP" --query 'Reservations[0].Instances[0]' -o json 2>/dev/null)
    iid=$(echo "$j" | yq -p json '.InstanceId // ""' 2>/dev/null)
    if [ -n "$iid" ] && [ "$iid" != null ]; then
      E="https://$R.console.aws.amazon.com/ec2/home?region=$R"
      link "AWS instance $iid" "$E#InstanceDetails:instanceId=$iid"
      echo "$j" | yq -p json -o tsv '.SecurityGroups[].GroupId' | while read -r g; do link "AWS security group $g" "$E#SecurityGroup:groupId=$g"; done
      echo "$j" | yq -p json -o tsv '.BlockDeviceMappings[].Ebs.VolumeId' | while read -r v; do link "AWS volume $v" "$E#VolumeDetails:volumeId=$v"; done
    fi
  fi
fi

# --- GCP: the Cloud console, per project
if command -v gcloud >/dev/null && [ -n "$(gcloud config get-value account 2>/dev/null)" ]; then
  PRJ=$(gcloud config get-value project 2>/dev/null)
  j=$(gcloud compute instances list --filter="networkInterfaces[0].accessConfigs[0].natIP=$IP" --format=json 2>/dev/null)
  name=$(echo "$j" | yq -p json '.[0].name // ""' 2>/dev/null)
  if [ -n "$name" ] && [ "$name" != null ]; then
    zone=$(echo "$j" | yq -p json '.[0].zone' | awk -F/ '{print $NF}'); C="https://console.cloud.google.com"
    link "GCP instance $name" "$C/compute/instancesDetail/zones/$zone/instances/$name?project=$PRJ"
    echo "$j" | yq -p json -o tsv '.[0].disks[].source' | awk -F/ '{print $NF}' | while read -r d; do link "GCP disk $d" "$C/compute/disksDetail/zones/$zone/disks/$d?project=$PRJ"; done
    link "GCP firewall rules" "$C/net-security/firewall-manager/firewall-policies/list?project=$PRJ"
  fi
fi
[ "$found" = 1 ] || { echo "no logged-in cloud CLI (az, aws, gcloud) has a VM with $IP"; exit 1; }
