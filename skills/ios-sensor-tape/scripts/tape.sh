#!/bin/zsh
# ios-sensor-tape: record the real world on an iPhone, replay it in tests.
#   tape.sh start [seconds=60] [fps=5]  relaunch the app recording a tape
#   tape.sh pull                        copy tapes to $OUT/tapes/ and summarize them
#   tape.sh info <tape dir>             duration, sample counts, achieved fps, size
# Env: DEVICE=<udid> BUNDLE=<bundle id> [OUT=.blackbox] [LAUNCH_ARGS="..."]
set -u
OUT_ROOT=${OUT:-.blackbox}
HERE=${0:A:h}

case "${1:-}" in
start)
  : "${DEVICE:?set DEVICE}" "${BUNDLE:?set BUNDLE}"
  for i in {1..15}; do
    if xcrun devicectl device process launch --terminate-existing --device "$DEVICE" -- "$BUNDLE" \
         -recordTape YES -tapeSeconds "${2:-60}" -tapeFPS "${3:-5}" ${=LAUNCH_ARGS:-} >/dev/null 2>&1; then
      echo "recording a tape: walk the scene, then leave the app (or wait ${2:-60}s)"; exit 0
    fi
    [ $i = 1 ] && echo "waiting for the phone to be unlocked..."; sleep 3
  done
  echo "launch failed: is the phone unlocked and the app installed?"; exit 1 ;;
pull)
  : "${DEVICE:?set DEVICE}" "${BUNDLE:?set BUNDLE}"
  D="$OUT_ROOT/tapes"; mkdir -p "$D"
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source Documents/tapes --destination "$D" -q 2>/dev/null \
    || { echo "no tapes on the device yet"; exit 1; }
  for t in "$D"/tape-*(N/); do python3 "$HERE/tape_info.py" "$t"; done ;;
info)
  python3 "$HERE/tape_info.py" "${2:?tape dir}" ;;
*) sed -n '2,7p' "$0" ;;
esac
