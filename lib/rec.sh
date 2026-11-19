#!/usr/bin/env bash
# tx6rec recorder: captures all 12 TX-6 USB channels, then splits them into
# one stereo WAV per TX-6 input. Runs outside matron; the mod only starts it,
# stops it and reads the files in <state>.
#
#   rec.sh start   <state> <takes>   record until `stop`, then split
#   rec.sh stop    <state>           stop recording (data is kept)
#   rec.sh recover <state> <takes>   split takes left over from a crash/power cut
#
# Capture itself is lib/capture.py. A take is captured as raw interleaved PCM (no 4 GB WAV limit, and nothing
# to finalize if the power goes). TX-6 input n = USB channels 2n-1 and 2n.

set -u
RATE=48000
CH=12
BPS=$((CH * 3 * RATE))              # raw bytes per second (1.73 MB/s)
RESERVE=$((256 * 1024 * 1024))      # always leave this much disk free
SOXIN=(-t raw -r "$RATE" -e signed -b 24 -c "$CH" -L)

cmd=${1:-}
state=${2:?state dir}
takes=${3:-}
mkdir -p "$state"

log() { echo "$(date '+%F %T') $*" >> "$state/log"; }

# status file, rewritten atomically; only the main recorder process writes it
S_STATE=idle S_TAKE= S_START=0 S_GLITCH=0 S_MSG= S_PROG=
write_status() {
  printf 'state=%s\ntake=%s\nstart=%s\nglitches=%s\nmsg=%s\nprog=%s\n' \
    "$S_STATE" "$S_TAKE" "$S_START" "$S_GLITCH" "$S_MSG" "$S_PROG" > "$state/status.tmp"
  mv -f "$state/status.tmp" "$state/status"
}

# a pid file can outlive its process (matron restart kills us), so check the cmdline too
running() {
  local p; p=$(cat "$state/pid" 2>/dev/null) || return 1
  [ -n "$p" ] && grep -q rec.sh "/proc/$p/cmdline" 2>/dev/null
}

# split one raw take into <take>_inN.wav, skipping inputs that are digital silence
split_take() {
  local raw=$1 dir take n k=0 total=0 ok=1 peaks active=()
  dir=$(dirname "$raw"); take=$(basename "$raw" .raw)
  if [ ! -s "$raw" ]; then
    rm -f "$raw"; rmdir "$dir" 2>/dev/null
    S_MSG="nothing recorded"; return
  fi
  S_STATE=processing S_PROG="checking inputs"; write_status
  # one pass for all channel peaks: "Pk lev dB <overall> <ch1> ... <ch12>"
  peaks=($(nice -n 19 ionice -c3 sox "${SOXIN[@]}" "$raw" -n stats 2>&1 \
    | awk '/^Pk lev dB/ { for (i = 5; i <= NF; i++) printf "%s ", $i }'))
  if [ ${#peaks[@]} -ne $CH ]; then
    log "split: could not read levels of $raw"; S_MSG="error reading take"; return
  fi
  for n in 1 2 3 4 5 6; do
    if [ "${peaks[$((2*n-2))]}" != "-inf" ] || [ "${peaks[$((2*n-1))]}" != "-inf" ]; then
      active+=("$n")
    fi
  done
  total=${#active[@]}
  for n in "${active[@]}"; do
    k=$((k + 1)); S_PROG="saving input $n ($k/$total)"; write_status
    if ! nice -n 19 ionice -c3 sox "${SOXIN[@]}" "$raw" "$dir/${take}_in$n.wav" \
         remix $((2*n-1)) $((2*n)) 2>>"$state/log"; then
      ok=0; log "split: input $n of $take failed"
    fi
  done
  if [ $ok -eq 1 ]; then
    rm -f "$raw"
    [ "$total" -eq 0 ] && rmdir "$dir" 2>/dev/null
    if [ "$total" -eq 0 ]; then S_MSG="all inputs silent"
    elif [ "$total" -eq 1 ]; then S_MSG="saved 1 track"
    else S_MSG="saved $total tracks"; fi
    log "split: $take -> $total tracks"
  else
    S_MSG="error saving, raw kept"
  fi
}

# disk + size watcher; writes <state>/disk and stops the take when space runs low
monitor() {
  local raw=$1 free bytes
  while sleep 2; do
    kill -0 $$ 2>/dev/null || exit 0   # $$ is the recorder, even in this subshell
    bytes=$(stat -c %s "$raw" 2>/dev/null || echo 0)
    free=$(df -B1 --output=avail "$(dirname "$raw")" | tail -1 | tr -d ' ')
    printf 'free=%s\nbytes=%s\n' "$free" "$bytes" > "$state/disk.tmp"
    mv -f "$state/disk.tmp" "$state/disk"
    # the split needs up to one more raw-sized chunk of space
    if [ "$free" -lt $((bytes + RESERVE)) ]; then
      echo "disk full" > "$state/reason"
      touch "$state/stop"
    fi
  done
}

case "$cmd" in
start)
  if running; then echo "already running"; exit 1; fi
  echo $$ > "$state/pid"
  rm -f "$state/stop" "$state/reason" "$state/disk"
  S_TAKE=$(date +%Y-%m-%d_%H%M%S)
  dir="$takes/$S_TAKE"; raw="$dir/$S_TAKE.raw"
  mkdir -p "$dir"; : > "$raw"
  S_STATE=recording S_START=$(date +%s); write_status
  log "start $S_TAKE"
  rm -f "$state/capture"
  monitor "$raw" & mon=$!
  # capture.py restarts stalled streams and buffers SD write pauses in RAM
  python3 "$(dirname "$0")/capture.py" "$raw" "$state"
  kill $mon 2>/dev/null
  rm -f "$state/stop"
  S_GLITCH=$(sed -n 's/^glitches=//p' "$state/capture" 2>/dev/null); S_GLITCH=${S_GLITCH:-0}
  reason=$(cat "$state/reason" 2>/dev/null); rm -f "$state/reason"
  log "stop $S_TAKE${reason:+ ($reason)}"
  split_take "$raw"
  [ -n "$reason" ] && S_MSG="$reason, $S_MSG"
  S_STATE=idle S_PROG=; write_status
  rm -f "$state/pid"
  ;;
stop)
  # capture.py polls for this file every 50 ms
  running && touch "$state/stop"
  ;;
recover)
  running && exit 0
  [ -n "$takes" ] || exit 1
  mkdir -p "$takes"
  shopt -s nullglob
  left=("$takes"/*/*.raw)
  echo $$ > "$state/pid"
  if [ ${#left[@]} -eq 0 ]; then
    # nothing to split, but clear a status a killed recorder left behind
    if grep -qE '^state=(recording|processing)' "$state/status" 2>/dev/null; then
      S_MSG="interrupted"; write_status
    fi
    rm -f "$state/pid"; exit 0
  fi
  for raw in "${left[@]}"; do
    S_TAKE=$(basename "$raw" .raw); log "recover $S_TAKE"
    split_take "$raw"
  done
  S_STATE=idle S_PROG= S_MSG="recovered: $S_MSG"; write_status
  rm -f "$state/pid"
  ;;
*)
  echo "usage: rec.sh start|stop|recover <state> [takes]"; exit 1 ;;
esac
