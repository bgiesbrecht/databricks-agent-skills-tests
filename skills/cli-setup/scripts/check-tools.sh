#!/usr/bin/env bash
# check-tools.sh [all|base|local|aws|azure|gcp|clients]: which of the lfc-source-* skills' tools are installed, their
# versions, and the install command for the missing ones (Homebrew on macOS; on Linux the distribution's package or the
# vendor's installer, as in lfc-source-setup "Tools"). Lima is checked on macOS only: Linux runs Podman natively.
# Exits 1 if anything asked for is missing. Default: base.
set -u
want=${1:-base}
os=$(uname -s)
missing=()
other=()
check() {                                  # check <group> <command> <brew install args> <Linux install> [version args]
  local group=$1 cmd=$2 pkg=$3 lin=$4 ver=${5:---version}
  [ "$want" = all ] || [ "$want" = "$group" ] || { [ "$want" = local ] && [ "$group" = base ]; } || return 0
  if command -v "$cmd" > /dev/null; then printf "%-11s %-8s %s\n" "$cmd" ok "$($cmd $ver 2>&1 | grep -v -i warning | grep -m1 -E '[0-9]+\.[0-9]+' | cut -c1-70)"
  elif [ "$os" = Darwin ]; then printf "%-11s %-8s %s\n" "$cmd" MISSING "brew install $pkg"; missing+=("$pkg")
  else printf "%-11s %-8s %s\n" "$cmd" MISSING "$lin"; other+=("$cmd"); fi
}
check base    databricks "databricks/tap/databricks" "curl -fsSL https://raw.githubusercontent.com/databricks/setup-cli/main/install.sh | sh" -v
check base    uv         uv           "curl -LsSf https://astral.sh/uv/install.sh | sh"
check base    jq         jq           "apt install jq (or dnf install jq)"
check base    yq         yq           "the binary from https://github.com/mikefarah/yq/releases"      # the Go yq (mikefarah), not the Python wrapper
check base    duckdb     duckdb       "the binary from https://github.com/duckdb/duckdb/releases"
check local   podman     podman       "apt install podman (or dnf install podman)"
[ "$os" = Darwin ] && check local limactl lima ""
check clients psql       libpq        "apt install postgresql-client"                                # keg-only: add $(brew --prefix libpq)/bin to PATH
check clients mysql      mysql-client "apt install mysql-client"                                     # keg-only: add $(brew --prefix mysql-client)/bin to PATH
check clients sqlcmd     sqlcmd       "the binary from https://github.com/microsoft/go-sqlcmd/releases" "-?"   # Microsoft's Go sqlcmd (the older ODBC one works too)
check clients mongosh    mongosh      "https://www.mongodb.com/try/download/shell"
check aws     aws        awscli       "https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
check azure   az         azure-cli    "https://learn.microsoft.com/cli/azure/install-azure-cli-linux"
check gcp     gcloud     "--cask gcloud-cli" "https://cloud.google.com/sdk/docs/install"
if [ ${#missing[@]} -gt 0 ]; then
  echo; echo "install: brew install ${missing[*]}" | sed 's/ --cask gcloud-cli//'
  printf '%s\n' ${missing[@]+"${missing[@]}"} | grep -q cask && echo "         brew install --cask gcloud-cli"
  exit 1
fi
[ ${#other[@]} -eq 0 ]
