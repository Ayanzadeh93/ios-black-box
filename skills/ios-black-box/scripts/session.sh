#!/bin/zsh
# Black Box — on-device session capture for iOS (debug builds).
#   session.sh build [scheme]      signed Debug build + install on $DEVICE
#   session.sh start [seconds=180] relaunch with screen + app-audio recording
#   session.sh pull                copy recordings/logs, write report + contact sheet
# Env: DEVICE=<udid> BUNDLE=<bundle id>  [PROJECT=*.xcodeproj] [LOGS=Documents/traces]
#      [LAUNCH_ARGS="-myTraceFlag YES"] [OUT=.blackbox] [TIME_FIELD=t]
set -u
: "${DEVICE:?set DEVICE (xcrun devicectl list devices)}" "${BUNDLE:?set BUNDLE}"
LOGS=${LOGS:-Documents/traces}
OUT_ROOT=${OUT:-.blackbox}
DD="$HOME/Library/Caches/ground-truth-dd"

case "${1:-}" in
build)
  PROJECT=${PROJECT:-$(ls -d *.xcodeproj | head -1)}
  SCHEME=${2:-${PROJECT%.xcodeproj}}
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$DD" -allowProvisioningUpdates -quiet build || exit 1
  APP=$(ls -d "$DD"/Build/Products/Debug-iphoneos/*.app | head -1)
  xcrun devicectl device install app --device "$DEVICE" "$APP" -q && echo "installed $(basename "$APP")" ;;
start)
  # A locked phone refuses launches; retry for ~45 s while it gets unlocked.
  for i in {1..15}; do
    if xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" \
         -recordSession YES -recordSeconds "${2:-180}" ${=LAUNCH_ARGS:-} >/dev/null 2>&1; then
      echo "recording: accept the iOS prompt, use the app, then leave it to save"; exit 0
    fi
    [ $i = 1 ] && echo "waiting for the phone to be unlocked..."; sleep 3
  done
  echo "launch failed — is the phone unlocked and the app installed?"; exit 1 ;;
pull)
  D="$OUT_ROOT/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$D"
  for src in Documents/recordings "$LOGS"; do
    xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source "$src" --destination "$D/${src:t}" -q 2>/dev/null \
      || echo "nothing in $src"
  done
  V=$(ls -t "$D"/recordings/*.mp4 2>/dev/null | head -1)
  if [ -n "$V" ] && command -v ffmpeg >/dev/null; then
    {
      echo "video: ${V:t}"
      ffprobe -v error -show_entries format=duration -of default=nw=1 "$V"
      ffmpeg -hide_banner -i "$V" -vn -af volumedetect -f null - 2>&1 | grep -oE "(mean|max)_volume: .*"
      echo "silences (no app audio for >= 0.4 s):"
      ffmpeg -hide_banner -i "$V" -vn -af silencedetect=n=-35dB:d=0.4 -f null - 2>&1 \
        | grep -oE "silence_(start|end): [0-9.]+" | paste - - | sed 's/^/  /'
    } > "$D/report.txt"
    ffmpeg -hide_banner -loglevel error -y -i "$V" -vf "fps=0.4,scale=220:-1,tile=8x1" -frames:v 1 "$D/contact.jpg"
  fi
  # Same clock: map every log event onto the video (needs the recorder's sidecar).
  SIDE="${V%.mp4}.json"; TR=("$D"/${LOGS:t}/*.jsonl(N))
  if [ -n "$V" ] && [ -s "$SIDE" ] && [ ${#TR} -gt 0 ]; then
    python3 "${0:A:h}/align.py" "$SIDE" "${TR[@]}" --field "${TIME_FIELD:-t}" --out "$D/timeline.csv"
  fi
  find "$D" -type f | sed "s|^$D/|  |"; echo "$D" ;;
*) sed -n '2,7p' "$0" ;;
esac
