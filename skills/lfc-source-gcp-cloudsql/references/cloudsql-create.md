# Cloud SQL Instance Creation Details

## Determine databaseVersion

Map the version alias to GCP's enum value:

```bash
case "${ENGINE}:${VERSION}" in
  mysql:5)       DB_VERSION="MYSQL_5_7" ;;
  mysql:8)       DB_VERSION="MYSQL_8_0" ;;
  mysql:9)       DB_VERSION="MYSQL_9_0" ;;
  postgres:15)   DB_VERSION="POSTGRES_15" ;;
  postgres:16)   DB_VERSION="POSTGRES_16" ;;
  postgres:17)   DB_VERSION="POSTGRES_17" ;;
  sqlserver:2019) DB_VERSION="SQLSERVER_2019_STANDARD" ;;
  sqlserver:2022) DB_VERSION="SQLSERVER_2022_STANDARD" ;;
  sqlserver:2024) DB_VERSION="SQLSERVER_2024_STANDARD" ;;
  *)             echo "Unsupported version"; exit 1 ;;
esac
```

## Configure backup policy

### MySQL (binary logging)

```bash
BACKUP_CFG='{
  "enabled": true,
  "binaryLogEnabled": true,
  "transactionLogRetentionDays": 1,
  "backupRetentionSettings": {
    "retentionUnit": "COUNT",
    "retainedBackups": 1
  }
}'
```

### PostgreSQL (PITR)

```bash
BACKUP_CFG='{
  "enabled": true,
  "pointInTimeRecoveryEnabled": true,
  "transactionLogRetentionDays": 1,
  "backupRetentionSettings": {
    "retentionUnit": "COUNT",
    "retainedBackups": 1
  }
}'
```

### SQL Server

```bash
BACKUP_CFG='{
  "enabled": false
}'
```

## Prepare database flags for CDC

### MySQL

```bash
DATABASE_FLAGS='
[
  {"name": "binlog_row_image", "value": "full"},
  {"name": "binlog_expire_logs_seconds", "value": "604800"}
]'
```

### PostgreSQL

```bash
DATABASE_FLAGS='
[
  {"name": "cloudsql.logical_decoding", "value": "on"},
  {"name": "max_replication_slots", "value": "10"},
  {"name": "max_wal_senders", "value": "10"}
]'
```

### SQL Server

```bash
DATABASE_FLAGS='[]'
```

## Create instance commands

### MySQL example

```bash
gcloud sql instances create "${INSTANCE_NAME}" \
  --database-version="${DB_VERSION}" \
  --region="${REGION}" \
  --tier="${TIER}" \
  --storage-size="${STORAGE_GB}GB" \
  --storage-type=PD_HDD \
  --backup-start-time=03:00 \
  --enable-bin-log \
  --backup-location="${REGION}" \
  --database-flags="${DATABASE_FLAGS}" \
  --enable-ip-v4 \
  --project="${PROJECT_ID}" \
  --wait-for-completion
```

### PostgreSQL example

```bash
gcloud sql instances create "${INSTANCE_NAME}" \
  --database-version="${DB_VERSION}" \
  --region="${REGION}" \
  --tier="${TIER}" \
  --storage-size="${STORAGE_GB}GB" \
  --storage-type=PD_SSD \
  --backup-start-time=03:00 \
  --enable-point-in-time-recovery \
  --database-flags="${DATABASE_FLAGS}" \
  --enable-ip-v4 \
  --project="${PROJECT_ID}" \
  --wait-for-completion
```

### SQL Server example

```bash
gcloud sql instances create "${INSTANCE_NAME}" \
  --database-version="${DB_VERSION}" \
  --region="${REGION}" \
  --tier="${TIER}" \
  --storage-size="${STORAGE_GB}GB" \
  --storage-type=PD_SSD \
  --enable-ip-v4 \
  --project="${PROJECT_ID}" \
  --wait-for-completion
```

## Create databases

### MySQL/PostgreSQL

```bash
# MySQL
gcloud sql databases create lfc_test_db \
  --instance="${INSTANCE_NAME}" \
  --charset=utf8mb4 \
  --collation=utf8mb4_unicode_ci \
  --project="${PROJECT_ID}"

# PostgreSQL
gcloud sql databases create lfc_test_db \
  --instance="${INSTANCE_NAME}" \
  --project="${PROJECT_ID}"
```

### SQL Server

SQL Server creates `master` by default; use it as the database name in UC connection.
