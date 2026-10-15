#!/usr/bin/env bash
# Test environment -- source this before running tests:  source env.sh
#
# Put your own values in env.local.sh (gitignored; copy env.example.sh to start).
# Anything not set there falls back to the defaults below.

_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$_ENV_DIR/env.local.sh" ] && source "$_ENV_DIR/env.local.sh"

export SKILLS_REPO="${SKILLS_REPO:-$_ENV_DIR/../databricks-agent-skills}"
export OMNIGENT_WS="${OMNIGENT_WS:-DEFAULT}"   # profile for the workspace file bridge (sync.sh)
export PIPELINE_WS="${PIPELINE_WS:-DEFAULT}"   # profile passed to Claude as DATABRICKS_CONFIG_PROFILE

echo "SKILLS_REPO=$SKILLS_REPO"
echo "OMNIGENT_WS=$OMNIGENT_WS"
echo "PIPELINE_WS=$PIPELINE_WS"
