# Detailed Steps: Azure SQL Managed Instance

> **Warning:** MI provisioning takes 4–6 hours for the first MI in a new subnet, then 30–60 minutes for additional ones. Do not proceed unless you can wait.

## 1. Create MI subnet

```bash
az network vnet subnet create \
  --resource-group <resource_group> \
  --vnet-name lfc-test-vnet \
  --name lfc-test-mi-subnet \
  --address-prefix 10.10.200.0/27 \
  --service-endpoints Microsoft.Sql Microsoft.Storage
```

The NSG is managed by Azure for MI subnets; service endpoints are required for MI management and backup storage.

## 2. Configure NSG for port 3342 (public data endpoint)

Create or update NSG rules to allow inbound TCP 3342 from your IP or Databricks egress range:

```bash
# Assuming NSG is `lfc-test-nsg`
az network nsg rule create \
  --resource-group <resource_group> \
  --nsg-name lfc-test-nsg \
  --name "lfc-test-public-data-endpoint" \
  --priority 1100 \
  --protocol Tcp \
  --direction Inbound \
  --source-address-prefixes "<your_cidr_24>/24" "198.51.100.0/24" \
  --source-port-ranges "*" \
  --destination-port-ranges "3342" \
  --destination-address-prefix "*" \
  --access Allow
```

## 3. Create Managed Instance

> `az` takes the admin password only as a flag (`--admin-password`), so it's briefly visible in this machine's process list while the command runs. Run it on a machine you control, and delete `admin.pw` once the UC connection exists.

```bash
umask 077
echo "Lfc1$(openssl rand -hex 12)" > admin.pw

az sql mi create --no-wait \
  --resource-group <resource_group> \
  --name <pfx>-mssql-mi-<location>-<epoch> \
  --location <location> \
  --admin-user sqladmin \
  --admin-password "$(cat admin.pw)" \
  --subnet "/subscriptions/<subscription_id>/resourceGroups/<resource_group>/providers/Microsoft.Network/virtualNetworks/lfc-test-vnet/subnets/lfc-test-mi-subnet" \
  --sku-name GP_Gen5 \
  --vcores 4 \
  --storage 32 \
  --public-data-endpoint-enabled true \
  --enable-minimal-tls-version Tls12 \
  --backup-storage-redundancy Local \
  --tags owner="<pfx>" purpose="lfc-test" created="$(date -u +'%Y-%m-%d')"

echo "Admin password stored in: $(pwd)/admin.pw"
```

**Monitor progress** in the background, often at first and then less often (**watch-progress**): the create returns at once (`--no-wait`), and the operation's percent complete is the progress signal, so a stalled create shows up early instead of after hours:

```bash
MI=<pfx>-mssql-mi-<location>-<epoch>; RG=<resource_group>
for wait in 60 120 300 600 900 1800 1800 1800 1800 1800 1800 1800 1800 1800; do   # about 6.5 hours in all
  sleep $wait
  state=$(az sql mi show -g "$RG" -n "$MI" --query provisioningState -o tsv 2>/dev/null)
  pct=$(az sql mi op list -g "$RG" --mi "$MI" --query "[0].percentComplete" -o tsv 2>/dev/null)
  echo "$(date +%T) $state ${pct:-?}%"
  case $state in Succeeded) exit 0 ;; Failed|Canceled) exit 1 ;; esac
done
echo "still provisioning: check the portal's deployment details, don't delete and retry"; exit 2
```

Run it with the agent's background-task option (or `&` and a log file) and look at each line as it comes.

Expected states: `Created` → `Accepted` → `Running` → `Succeeded`.

**Get the public FQDN:**

```bash
eval "$(az sql mi show \
  --resource-group <resource_group> \
  --name <pfx>-mssql-mi-<location>-<epoch> -o json \
  | yq -p json -o shell '{"PUBLIC_FQDN": (.fullyQualifiedDomainName // "")}')"

# Convert private FQDN to public: replace first segment with `<name>.public`
PUBLIC_HOST=$(echo "$PUBLIC_FQDN" | sed 's/^[^.]*/.public./' | sed 's/^\.//')
echo "Public endpoint: $PUBLIC_HOST:3342"
```

## 4. Verify connectivity

```bash
SQLCMDPASSWORD="$(cat admin.pw)" sqlcmd -S "$PUBLIC_HOST",3342 \
  -U sqladmin -Q "SELECT 1;"
```

## 5. Networking: Private endpoint (alternative to public endpoint)

If you want to reach MI from Databricks without exposing the public endpoint, use a **private endpoint** in a separate subnet. See [mi-networking.md](mi-networking.md) for full setup.
