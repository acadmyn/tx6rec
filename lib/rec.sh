#!/usr/bin/env bash
# tx6rec split: turns a raw 12-channel take into one file per TX-6 input,
# following the input modes in <state>/settings (read now, so changes made
# during a take apply).
#
#   rec.sh split   <raw> <state> <shm> [reason]   called by tx6d.py after a take
#   rec.sh recover <state> <shm> <takes>          split raws left by a crash
#
# Raw takes are interleaved S24_3LE, 48 kHz, 12 channels; TX-6 input n is on
# channels 2n-1 (left) and 2n (right). Progress goes to <shm>/split.
#
# Modes: stereo -> <base>_inN.wav, mono -> <base>_inN.wav (left channel, where
# the TX-6 puts a mono cable), 2x mono -> <base>_inNL.wav + <base>_inNR.wav,
# off -> nothing. With skip=1, channels that are pure digital silence are skipped.

set -u
SOXIN=(-t raw -r 48000 -e signed -b 24 -c 12 -L)
cmd=${1:-}

S_STATE=done S_PROG= S_MSG= S_TAKE=
write_split() {
  printf 'state=%s\ntake=%s\nprog=%s\nmsg=%s\nt=%s\n' \
    "$S_STATE" "$S_TAKE" "$S_PROG" "$S_MSG" "$(date +%s)" > "$shm/split.tmp"
  mv -f "$shm/split.tmp" "$shm/split"
}
log() { echo "$(date '+%F %T') $*" >> "$state/log"; }
setting() { sed -n "s/^$1=//p" "$state/settings" 2>/dev/null | head -1; }

split_take() {
  local raw=$1 dir base peaks jobs=() job n m a b k=0 ok=1 silent
  dir=$(dirname "$raw"); base=$(basename "$raw" .raw); S_TAKE=$base
  if [ ! -s "$raw" ]; then
    rm -f "$raw"; rmdir "$dir" 2>/dev/null; S_MSG="nothing recorded"; return
  fi
  S_STATE=processing S_PROG="checking"; write_split
  # one pass for every channel's peak: "Pk lev dB <overall> <ch1> ... <ch12>"
  peaks=($(nice -n 19 ionice -c3 sox "${SOXIN[@]}" "$raw" -n stats 2>&1 \
    | awk '/^Pk lev dB/ { for (i = 5; i <= NF; i++) printf "%s ", $i }'))
  if [ ${#peaks[@]} -ne 12 ]; then
    log "split: could not read levels of $raw"; S_MSG="error, raw kept"; return
  fi
  local skip; skip=$(setting skip); skip=${skip:-1}
  silent() { [ "$skip" = 1 ] && [ "${peaks[$(($1 - 1))]}" = "-inf" ]; }
  for n in 1 2 3 4 5 6; do
    m=$(setting "mode$n"); m=${m:-stereo}
    a=$((2 * n - 1)); b=$((2 * n))
    case "$m" in
      stereo) silent $a && silent $b || jobs+=("$a $b in$n") ;;
      mono)   silent $a || jobs+=("$a in$n") ;;
      2xmono) silent $a || jobs+=("$a in${n}L"); silent $b || jobs+=("$b in${n}R") ;;
    esac
  done
  for job in "${jobs[@]}"; do
    k=$((k + 1)); S_PROG="$k/${#jobs[@]}"; write_split
    local chans=${job% *} name=${job##* }
    # shellcheck disable=SC2086
    if ! nice -n 19 ionice -c3 sox "${SOXIN[@]}" "$raw" "$dir/${base}_$name.wav" \
         remix $chans 2>>"$state/log"; then
      ok=0; log "split: $name of $base failed"
    fi
  done
  if [ $ok -eq 1 ]; then
    rm -f "$raw"; rmdir "$dir" 2>/dev/null
    case ${#jobs[@]} in
      0) S_MSG="all inputs silent" ;;
      1) S_MSG="saved 1 track" ;;
      *) S_MSG="saved ${#jobs[@]} tracks" ;;
    esac
    log "split: $base -> ${#jobs[@]} tracks"
  else
    S_MSG="error, raw kept"
  fi
}

case "$cmd" in
split)
  raw=${2:?raw}; state=${3:?state}; shm=${4:?shm}; reason=${5:-}
  mkdir -p "$shm"
  split_take "$raw"
  [ -n "$reason" ] && S_MSG="$reason, $S_MSG"
  S_STATE=done S_PROG=; write_split
  ;;
recover)
  state=${2:?state}; shm=${3:?shm}; takes=${4:?takes}
  mkdir -p "$shm" "$takes"
  shopt -s nullglob
  left=("$takes"/*/*.raw)
  [ ${#left[@]} -eq 0 ] && exit 0
  for raw in "${left[@]}"; do log "recover $raw"; split_take "$raw"; done
  S_STATE=done S_PROG= S_MSG="recovered: $S_MSG"; write_split
  ;;
*)
  echo "usage: rec.sh split <raw> <state> <shm> [reason] | recover <state> <shm> <takes>"; exit 1 ;;
esac
