#!/usr/bin/env bash
# sync tx6rec to the norns. Mods load only at startup, so --restart restarts
# the norns software afterwards (like SYSTEM > RESTART) and shows matron output.
set -euo pipefail
HOST="${NORNS_SSH:-we@norns.tretiotre.local}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"

rsync -a --delete --exclude .git --exclude tools --exclude '*.md' "$DIR/" "$HOST:/home/we/dust/code/tx6rec/"
if [ "${1:-}" = "--restart" ]; then
  ssh "$HOST" 'sudo systemctl stop "norns-*"; sudo systemctl start norns.target'
  sleep 8
  python3 "$DIR/tools/repl.py" -t 3 'print("tx6rec loaded: " .. tostring(require("core/mods").is_loaded("tx6rec")))'
fi
