#!/usr/bin/env bash
# sync tx6rec to the norns. Mods load only at startup, so --restart restarts
# the norns software afterwards (like SYSTEM > RESTART) and reloads the script
# that was running.
set -euo pipefail
HOST="${NORNS_SSH:-we@norns.tretiotre.local}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPL="$DIR/tools/repl.py"

rsync -a --delete --exclude .git --exclude tools --exclude '*.md' "$DIR/" "$HOST:/home/we/dust/code/tx6rec/"
if [ "${1:-}" = "--restart" ]; then
  # a systemctl restart counts as an unclean shutdown, after which norns forgets
  # the script, so note it first
  script=$(python3 "$REPL" -t 1 'print("SCRIPT=" .. (norns.state.script or ""))' | sed -n 's/^SCRIPT=//p')
  ssh "$HOST" 'sudo systemctl stop "norns-*"; sudo systemctl start norns.target'
  sleep 8
  python3 "$REPL" -t 1 'print("tx6rec loaded: " .. tostring(require("core/mods").is_loaded("tx6rec")))' | grep tx6rec || true
  if [ -n "$script" ]; then
    python3 "$REPL" -t 6 "norns.script.load(\"$script\")" | grep -E "init ok|rror|MISSING" || true
  fi
fi
