# Podman Container Installation

## Disk setup for Podman (XFS)

Podman uses an XFS filesystem at `/var/lib/containers` for its graphroot.

```bash
ssh -i ~/.ssh/lfc_test_rsa azureuser@${AZURE_PUBLIC_IP}

# Find the data disk (not /dev/sda1)
lsblk -dn -o NAME,SIZE,TYPE | grep -v sda1

# Assume it's /dev/sdb; adjust if different
DISK="/dev/sdb"

# Install xfsprogs
sudo apt-get update && sudo apt-get install -y xfsprogs

# Format XFS (ftype=1 required for Podman overlay, reflink=1 for COW)
sudo mkfs.xfs -f -n ftype=1 -m reflink=1 "$DISK"

# Create mount directory
sudo mkdir -p /var/lib/containers

# Mount
sudo mount "$DISK" /var/lib/containers

# Make permanent via fstab
UUID=$(sudo blkid -s UUID -o value "$DISK")
echo "UUID=$UUID /var/lib/containers xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab

# Verify
mount | grep containers
```

## Install Podman

```bash
sudo apt-get update
sudo apt-get install -y podman

# Enable rootful mode (required for databases)
sudo usermod -aG podman azureuser
newgrp podman

# Verify
podman --version
podman ps
```

## Run database containers

Generate password files for container env vars:

```bash
umask 077
mkdir -p /tmp/podman-secrets
echo 'set-mysql-root-password-here' > /tmp/podman-secrets/mysql_root_pwd
echo 'set-oracle-password-here' > /tmp/podman-secrets/oracle_pwd
```

### MySQL 8.0

```bash
podman pull docker.io/library/mysql:8.0

sudo podman run -d \
  --name jane-doe-mysql-8.0-dockerhub-remote-1779207800 \
  -e MYSQL_ROOT_PASSWORD=$(cat /tmp/podman-secrets/mysql_root_pwd) \
  -p 3306:3306 \
  -v mysql-data:/var/lib/mysql \
  docker.io/library/mysql:8.0

# Verify
sudo podman exec jane-doe-mysql-8.0-dockerhub-remote-1779207800 \
  mysql -u root -p$(cat /tmp/podman-secrets/mysql_root_pwd) -e "SELECT VERSION();"
```

### PostgreSQL 16

```bash
podman pull docker.io/library/postgres:16

sudo podman run -d \
  --name jane-doe-postgres-16-dockerhub-remote-1779207800 \
  -e POSTGRES_PASSWORD=$(cat /tmp/podman-secrets/postgres_pwd) \
  -p 5432:5432 \
  -v postgres-data:/var/lib/postgresql/data \
  docker.io/library/postgres:16

# Verify
export PGPASSWORD=$(cat /tmp/podman-secrets/postgres_pwd)
sudo podman exec jane-doe-postgres-16-dockerhub-remote-1779207800 \
  psql -U postgres -c "SELECT VERSION();"
unset PGPASSWORD
```

### SQL Server 2022

```bash
podman pull mcr.microsoft.com/mssql/server:2022-latest

sudo podman run -d \
  --name jane-doe-mssql-2022-mcr-remote-1779207800 \
  -e ACCEPT_EULA=Y \
  -e SA_PASSWORD=$(cat /tmp/podman-secrets/mssql_pwd) \
  -p 1433:1433 \
  mcr.microsoft.com/mssql/server:2022-latest

# Verify (wait ~30 seconds for startup)
export SQLCMDPASSWORD=$(cat /tmp/podman-secrets/mssql_pwd)
sudo podman exec jane-doe-mssql-2022-mcr-remote-1779207800 \
  sqlcmd -U sa -Q "SELECT @@VERSION"
unset SQLCMDPASSWORD
```

### Oracle 23ai

```bash
# Large image (~5 GB); may take time to pull
podman pull container-registry.oracle.com/database/free:latest

sudo podman run -d \
  --name jane-doe-ora-23ai-oci-remote-1779207800 \
  --privileged \
  -e ORACLE_PWD=$(cat /tmp/podman-secrets/oracle_pwd) \
  -p 1521:1521 \
  -v oracle-data:/opt/oracle/oradata \
  container-registry.oracle.com/database/free:latest

# Monitor startup (Oracle is slow, ~2-3 minutes)
sudo podman logs -f jane-doe-ora-23ai-oci-remote-1779207800
# Wait for "DATABASE IS READY TO USE!"

# Verify
sudo podman exec jane-doe-ora-23ai-oci-remote-1779207800 \
  sqlplus -v
```

## Container management

### View running containers

```bash
sudo podman ps
```

### Stop container

```bash
sudo podman stop <container-name>
```

### Remove container

```bash
sudo podman rm <container-name>
```

### Container logs

```bash
sudo podman logs <container-name>
```

## SSH tunnel for laptop testing

To test Podman containers from your laptop (not for Databricks serverless):

```bash
# From your laptop
ssh -i ~/.ssh/lfc_test_rsa \
  -L 3306:127.0.0.1:3306 \
  azureuser@${AZURE_PUBLIC_IP} \
  -N  # keep tunnel open

# In another terminal
mysql -h 127.0.0.1 -u root -p -e "SELECT VERSION();"
```

**Important:** SSH tunneling is laptop testing only. Databricks serverless must reach the database directly via public IP.
