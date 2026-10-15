#!/usr/bin/env bash
# Copy to env.local.sh (gitignored) and fill in. env.sh sources it.
# Prompts in prompts/lfc-matrix/ use these as ${VAR} placeholders.

# export SKILLS_REPO=~/github/databricks-agent-skills
export OMNIGENT_WS=<file-bridge-profile>
export PIPELINE_WS=<workspace-profile>          # workspace the tests deploy into

# Unity Catalog target for test pipelines (a regular managed catalog)
export LFC_CATALOG=<catalog>

# Existing UC connections and the source databases/schemas they read
export LFC_PG_CONNECTION=<postgres-connection>
export LFC_PG_DATABASE=<postgres-database>
export LFC_PG_SCHEMA=<postgres-schema>
export LFC_MYSQL_CONNECTION=<mysql-connection>
export LFC_MYSQL_DATABASE=<mysql-database>
export LFC_SQLSERVER_CONNECTION=<sqlserver-connection>
export LFC_SQLSERVER_DATABASE=<sqlserver-database>
export LFC_SQLSERVER_SCHEMA=<sqlserver-schema>

# Lakebase demo (created by the qbc-lakebase test)
export LFC_LAKEBASE_PROJECT=lfc-demo
export LFC_LAKEBASE_PIPELINE=<firstname><lastname>-lfc_demo_pg_conn
