#!/usr/bin/env bash
# bundle.sh <out.tgz>: the generator as one portable file: copies.sh, fill.sh and every engine's planner files. Unpack
# it anywhere with bash and the engine's SQL client, add a client script (sq: SQL on stdin, connected to the database)
# and run copies.sh. Nothing to install; no Python on the target.
#
#   bash scripts/bundle.sh /tmp/lfc-datagen.tgz
#   scp /tmp/lfc-datagen.tgz model.sql vm: && ssh vm 'mkdir -p g && tar xzf lfc-datagen.tgz -C g && ...'
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
COPYFILE_DISABLE=1 tar --no-xattrs -czf "${1:?out.tgz}" -C "$HERE" copies.sh fill.sh sqlserver postgres mysql oracle
echo "$1"
