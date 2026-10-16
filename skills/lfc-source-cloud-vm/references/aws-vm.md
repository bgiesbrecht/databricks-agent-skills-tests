# AWS EC2 VM creation

Tested in us-east-2 (2026-10): Ubuntu 24.04 on `m6i.xlarge` (4 vCPU, 16 GB) in the account's default VPC, a separate gp3 data volume formatted XFS by [`disk-setup.sh`](../scripts/disk-setup.sh), and rootful Podman 4.9 with MySQL 8.4, PostgreSQL 16, SQL Server 2022 and Oracle 23ai Free, each reachable from the workspace's serverless compute.

Put the VM in **the workspace's region** (`databricks metastores summary` gives it). Check the login first (`aws sts get-caller-identity --profile <profile>`): show the account and role, and let the user choose the profile; an expired SSO session needs `aws sso login --profile <profile>`.

## Variables

```bash
export AWS_PROFILE=<profile>
R=<region>                                   # the workspace's, e.g. us-east-2
VPC=<vpc-id>                                 # the default VPC: aws ec2 describe-vpcs --filters Name=isDefault,Values=true
SUB=<subnet-id>                              # a subnet of $VPC with MapPublicIpOnLaunch=true
NAME=<pfx>-lfc-vm-<region-no-dashes>-<epoch> # e.g. jane-doe-lfc-vm-useast2-1779207800
KEY=lfc-test-<pfx>                           # your SSH public key, imported once per region
TYPE=m6i.xlarge                              # 4 vCPU, 16 GB: room for the four engines at once
```

Find a public subnet: `aws ec2 describe-subnets --region $R --filters Name=vpc-id,Values=$VPC --output json | yq -p json -o tsv '.Subnets[] | [.SubnetId, .AvailabilityZone, .MapPublicIpOnLaunch]'`.

## Security group

One `lfc-test-<n>` group per VPC, shared by every test VM in it: SSH from your laptop only, and the Podman port range `30000-30063` from your laptop and the workspace region's serverless ranges (**lfc-source-firewall** Step 1, `SCOPE=region`; 4 CIDRs for us-east-2). A security group holds 60 rules by default, so every serverless region (about 760) doesn't fit: for a source shared by workspaces in many regions, use an Azure VM ([azure-vm.md](azure-vm.md)). Each rule carries an `lfc-` description so it can be found and removed.

```bash
SG=$(aws ec2 create-security-group --region $R --vpc-id $VPC --group-name lfc-test-1 \
  --description "lfc test sources: laptop + Databricks serverless" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=owner,Value=<pfx>},{Key=purpose,Value=lfc-test}]" \
  --output json | yq -p json '.GroupId')
perm() { echo "{\"IpProtocol\":\"tcp\",\"FromPort\":$1,\"ToPort\":$2,\"IpRanges\":[$(for c in $3; do printf '{"CidrIp":"%s","Description":"%s"},' $c "$4"; done | sed 's/,$//')]}"; }
aws ec2 authorize-security-group-ingress --region $R --group-id $SG --ip-permissions \
  "[$(perm 22 22 $MYIP/32 lfc-myip-ssh),$(perm 30000 30063 $MYIP/32 lfc-myip-db),$(perm 30000 30063 "$SERVERLESS" lfc-serverless)]"
```

Reuse the group if it already exists (`aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=group-name,Values=lfc-test-1`), adding only missing rules. A classic-compute gateway (standard CDC on a classic workspace) leaves through the workspace's NAT, not the serverless ranges: add its IP the same way, with the description `lfc-classic` (**lfc-source-firewall**, "Classic compute egress", has a one-off job that reports it). Tested: without it the gateway failed with `INCORRECT_SOURCE_HOSTNAME_OR_PORT_SPECIFIED_FAILURE`; with it, standard CDC worked.

## Create the VM

```bash
aws ec2 import-key-pair --region $R --key-name $KEY --public-key-material fileb://$HOME/.ssh/lfc_test_rsa.pub
AMI=$(aws ssm get-parameters --region $R --output json \
  --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id | yq -p json '.Parameters[0].Value')
IID=$(aws ec2 run-instances --region $R --image-id $AMI --instance-type $TYPE --key-name $KEY \
  --subnet-id $SUB --security-group-ids $SG --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":true}},
                            {"DeviceName":"/dev/sdf","Ebs":{"VolumeSize":64,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=owner,Value=<pfx>},{Key=purpose,Value=lfc-test}]" \
                       "ResourceType=volume,Tags=[{Key=owner,Value=<pfx>},{Key=purpose,Value=lfc-test}]" \
  --output json | yq -p json '.Instances[0].InstanceId')
aws ec2 wait instance-running --region $R --instance-ids $IID
IP=$(aws ec2 describe-instances --region $R --instance-ids $IID --output json | yq -p json '.Reservations[0].Instances[0].PublicIpAddress')
```

The SSH user is `ubuntu`. The public IP changes after a stop and start: re-read it and update the UC connections' `host` (or attach an Elastic IP, which bills while the VM is stopped).

## Data disk and Podman

On Nitro instances (every current type) an EBS volume appears as NVMe, not as `/dev/sdf`. Its stable path names the volume ID without the dash:

```bash
VOL=$(aws ec2 describe-instances --region $R --instance-ids $IID --output json \
  | yq -p json '.Reservations[0].Instances[0].BlockDeviceMappings[] | select(.DeviceName == "/dev/sdf") | .Ebs.VolumeId')
ssh ubuntu@$IP DISK=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOL/-/} MNT=/var/lib/containers 'bash -s' < scripts/disk-setup.sh
ssh ubuntu@$IP 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman'
ssh ubuntu@$IP 'sudo podman info --format "{{.Store.GraphRoot}}"; findmnt -no FSTYPE /var/lib/containers'   # /var/lib/containers/storage, xfs
```

Then start the engines as in [configure-lfc.md](configure-lfc.md) (`sudo bash -s` with the same script works unchanged on Azure and AWS).

## Stop, start, delete

```bash
aws ec2 stop-instances --region $R --instance-ids $IID      # stops compute billing; the volumes still bill
aws ec2 start-instances --region $R --instance-ids $IID     # new public IP: update the connections
aws ec2 terminate-instances --region $R --instance-ids $IID # deletes both volumes (DeleteOnTermination)
```

Delete the security group and key pair only when no other VM uses them. Delete the UC connections too.
