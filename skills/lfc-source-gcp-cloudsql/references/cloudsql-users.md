# Cloud SQL User Management and Passwords

## Password generation and security

Passwords must be generated securely and never passed on the command line in a way that persists to shell history or audit logs.

```bash
# Generate passwords securely with restricted permissions
umask 077
echo "Lfc1$(openssl rand -hex 12)" > admin.pw
echo "Lfc1$(openssl rand -hex 12)" > lfc_user.pw

# Verify file permissions (should be 600)
ls -la admin.pw lfc_user.pw
```

## Create admin user

The `--password` flag accepts a value that is briefly visible in the process list. To minimize exposure:
1. Generate the password into a file (above)
2. Read from file with `$(cat admin.pw)`
3. The password is only visible in `ps aux` for a few milliseconds during the gcloud command

**MySQL:**

> `gcloud sql users create` and `gcloud sql instances create` take passwords only as flags, so they're briefly visible in this machine's process list while the command runs. Run them on a machine you control, or create the Lakeflow Connect user in SQL instead (with `PGPASSWORD` / `MYSQL_PWD` / `SQLCMDPASSWORD`), and delete the `.pw` files once the UC connection exists.

```bash
gcloud sql users create root \
  --instance="${INSTANCE_NAME}" \
  --password="$(cat admin.pw)" \
  --project="${PROJECT_ID}"
```

**PostgreSQL:**

```bash
gcloud sql users create postgres \
  --instance="${INSTANCE_NAME}" \
  --password="$(cat admin.pw)" \
  --project="${PROJECT_ID}"
```

**SQL Server:**

```bash
gcloud sql users create sqladmin \
  --instance="${INSTANCE_NAME}" \
  --password="$(cat admin.pw)" \
  --project="${PROJECT_ID}"
```

## Create LFC user

```bash
gcloud sql users create lfc_user \
  --instance="${INSTANCE_NAME}" \
  --password="$(cat lfc_user.pw)" \
  --project="${PROJECT_ID}"
```

## Test connectivity from laptop

**Get the public IP:**

```bash
eval "$(gcloud sql instances describe "${INSTANCE_NAME}" \
  --project="${PROJECT_ID}" --format=json \
  | yq -p json -o shell '{"HOST": (.ipAddresses[0].ipAddress // "")}')"

echo "Instance IP: $HOST"
```

**MySQL:**

```bash
export MYSQL_PWD="$(cat lfc_user.pw)"
mysql -h "${HOST}" -u lfc_user lfc_test_db -e "SELECT 1;"
unset MYSQL_PWD
```

**PostgreSQL:**

```bash
export PGPASSWORD="$(cat lfc_user.pw)"
psql -h "${HOST}" -U lfc_user -d lfc_test_db -c "SELECT 1;"
unset PGPASSWORD
```

**SQL Server:**

```bash
export SQLCMDPASSWORD="$(cat lfc_user.pw)"
sqlcmd -S "${HOST},1433" -U sqladmin -Q "SELECT 1;"
unset SQLCMDPASSWORD
```

## Password reset

If the password is lost after instance creation:

```bash
gcloud sql users set-password lfc_user \
  --instance="${INSTANCE_NAME}" \
  --password="$(cat lfc_user.pw)" \
  --project="${PROJECT_ID}"
```

## Cleanup

After UC connection is created and tested:

```bash
rm admin.pw lfc_user.pw
```
