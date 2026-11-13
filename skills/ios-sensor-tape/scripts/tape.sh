#!/usr/bin/env bash
# ios-sensor-tape: record the real world on an iPhone, replay it in tests.
#   tape.sh start [seconds=60] [fps=5]  relaunch the app recording a tape
#   tape.sh pull                        copy tapes to $OUT/tapes/ and summarize them
#   tape.sh info <tape dir> [--json]    summarize a tape (works without Xcode)
#   tape.sh validate <tape dir> [--json] require a finalized, structurally valid tape
#   tape.sh doctor                     check tools for offline analysis and capture
# Env: DEVICE=<udid> BUNDLE=<bundle id> [OUT=.blackbox] [LAUNCH_ARGS="..."]
set -eu
OUT_ROOT=${OUT:-.blackbox}
HERE=$(cd "$(dirname "$0")" && pwd)

fail() { printf '%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
device_tools() {
  : "${DEVICE:?set DEVICE}" "${BUNDLE:?set BUNDLE}"
  need xcrun
  xcrun --find devicectl >/dev/null 2>&1 || fail 'devicectl unavailable; install Xcode 16+ and select it with xcode-select'
}

case "${1:-}" in
start)
  shift
  need python3
  seconds=${1:-60}; fps=${2:-5}
  python3 - "$seconds" "$fps" <<'PY'
import math, sys
try:
    seconds, fps = map(float, sys.argv[1:])
    valid = (math.isfinite(seconds) and 0 < seconds <= 86400
             and math.isfinite(fps) and 0 < fps <= 240)
except ValueError:
    valid = False
if not valid:
    sys.exit('seconds and fps must be finite positive numbers (seconds <= 86400, fps <= 240)')
PY
  if [ "$#" -gt 0 ]; then shift; fi
  if [ "$#" -gt 0 ]; then shift; fi
  # Prefer arguments after -- for values containing spaces. Legacy LAUNCH_ARGS
  # retains whitespace splitting, without eval, globbing, or shell execution.
  extra=()
  if [ -n "${LAUNCH_ARGS:-}" ]; then read -r -a extra <<< "$LAUNCH_ARGS"; fi
  if [ "${1:-}" = -- ]; then shift; fi
  device_tools
  launch_log=$(mktemp "${TMPDIR:-/tmp}/sensor-tape-launch.XXXXXX")
  trap 'rm -f "$launch_log"' EXIT
  for i in {1..15}; do
    if xcrun devicectl device process launch --terminate-existing --device "$DEVICE" -- "$BUNDLE" \
         -recordTape YES -tapeSeconds "$seconds" -tapeFPS "$fps" ${extra[@]+"${extra[@]}"} "$@" >"$launch_log" 2>&1; then
      echo "tape recording requested: exercise the scenario, then leave the app or wait for its time limit"; exit 0
    fi
    if [ "$i" = 1 ]; then echo "launch failed; unlock the phone while retrying..."; fi
    sleep 3
  done
  cat "$launch_log" >&2
  fail 'launch failed: check device trust, lock state, app installation, and launch arguments' ;;
pull)
  device_tools
  need python3
  D="$OUT_ROOT/tapes"; mkdir -p "$D"
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source Documents/tapes --destination "$D" -q \
    || fail 'tape copy failed; check the device, app container access, and whether a tape was recorded'
  found=0; status=0
  for t in "$D"/tape-*; do
    [ -d "$t" ] || continue
    found=1
    python3 "$HERE/tape_info.py" "$t" --validate || status=1
  done
  [ "$found" = 1 ] || fail "copy returned no tape directories in $D"
  exit "$status" ;;
info)
  shift; need python3
  exec python3 "$HERE/tape_info.py" "$@" ;;
validate)
  shift; need python3
  exec python3 "$HERE/tape_info.py" --validate "$@" ;;
doctor)
  need python3
  echo 'offline tape summaries and structural validation: ready (python3)'
  if command -v xcrun >/dev/null 2>&1 && xcrun --find devicectl >/dev/null 2>&1; then
    echo 'device capture tools: available; a trusted iPhone and signed Debug app are still required'
  else
    echo 'device capture tools: unavailable here; use macOS with Xcode 16+ for start/pull'
  fi ;;
-h|--help|help|'') sed -n '2,10p' "$0" ;;
*) sed -n '2,10p' "$0" >&2; exit 2 ;;
esac
