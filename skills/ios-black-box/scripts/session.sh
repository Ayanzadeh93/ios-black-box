#!/usr/bin/env bash
# Black Box: on-device Debug capture plus offline analysis (macOS Bash 3.2+).
#   session.sh doctor
#   session.sh build [scheme]
#   session.sh start [seconds=180] [-- app-argument ...]
#   session.sh pull
#   session.sh analyze <session-directory> [video.mp4]
# Env: DEVICE BUNDLE [PROJECT|WORKSPACE] [SCHEME] [APP] [LOGS=Documents/traces]
#      [LAUNCH_ARGS="space-separated args"] [OUT=.blackbox] [TIME_FIELD=t]
set -euo pipefail
shopt -s nullglob
HERE=$(cd "$(dirname "$0")" && pwd)
OUT_ROOT=${OUT:-.blackbox}
LOGS=${LOGS:-Documents/traces}

fail() { echo "session: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing $1"; }
device() { : "${DEVICE:?set DEVICE (xcrun devicectl list devices)}" "${BUNDLE:?set BUNDLE}"; need xcrun; }
seconds() {
  case "$1" in ''|*[!0-9]*) fail "seconds must be an integer from 1 to 3600";; esac
  [ "${#1}" -le 4 ] && [ "$1" -ge 1 ] && [ "$1" -le 3600 ] || fail "seconds must be an integer from 1 to 3600"
}
usage() { sed -n '2,9p' "$0"; }

analyze() {
  local directory=$1 selected=${2:-} video stem prefix duration audio
  local videos=() traces=()
  [ -d "$directory" ] || fail "session directory does not exist: $directory"
  need python3
  videos=("$directory"/recordings/*.mp4)
  if [ -n "$selected" ]; then
    if [ -f "$selected" ]; then video=$selected; else video="$directory/recordings/$selected"; fi
    [ -f "$video" ] || fail "video does not exist: $video"
  else
    [ "${#videos[@]}" -gt 0 ] || fail "no recordings/*.mp4 in $directory"
    [ "${#videos[@]}" -eq 1 ] || fail "multiple videos; select one: analyze '$directory' video.mp4"
    video=${videos[0]}
  fi
  stem=$(basename "${video%.mp4}") || return 1
  prefix="$directory/"
  [ "${#videos[@]}" -le 1 ] || prefix="$directory/$stem-"
  traces=("$directory/$(basename "$LOGS")"/*.jsonl)
  if [ -s "${video%.mp4}.json" ] && [ "${#traces[@]}" -gt 0 ]; then
    python3 "$HERE/align.py" "${video%.mp4}.json" "${traces[@]}" --field "${TIME_FIELD:-t}" --out "${prefix}timeline.csv" || return 1
  else
    echo "warning: no timeline for $stem (sidecar or JSONL traces unavailable)" >&2
  fi
  if ! command -v ffmpeg >/dev/null 2>&1 || ! command -v ffprobe >/dev/null 2>&1; then
    echo "warning: install ffmpeg and ffprobe for media analysis; timeline analysis completed where inputs were available" >&2
    return 0
  fi
  duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$video") || return 1
  python3 -c 'import math,sys; n=float(sys.argv[1]); sys.exit(0 if math.isfinite(n) and n > 0 else 1)' "$duration" || { echo "invalid media duration: $video" >&2; return 1; }
  audio=$(ffprobe -v error -select_streams a:0 -show_entries stream=index -of csv=p=0 "$video") || return 1
  {
    echo "video: $(basename "$video")"
    echo "duration: $duration s"
    echo "Timeline alignment uses a ReplayKit callback anchor, not first-sample timestamps."
    echo "Audio thresholds measure signal level; they do not detect speech or intelligibility."
  } > "${prefix}report.txt" || return 1
  if [ -n "$audio" ]; then
    if ! ffmpeg -hide_banner -nostdin -i "$video" -vn -af 'volumedetect,silencedetect=n=-35dB:d=0.4' -f null - > "${prefix}audio-analysis.log" 2>&1; then
      echo "audio analysis failed; see ${prefix}audio-analysis.log" >&2; return 1
    fi
    {
      sed -nE 's/.*((mean|max)_volume: .*)/\1/p' "${prefix}audio-analysis.log"
      echo "Low-level audio intervals (below -35 dB for >= 0.4 s):"
      sed -nE 's/.*(silence_(start|end): .*)/  \1/p' "${prefix}audio-analysis.log"
    } >> "${prefix}report.txt" || return 1
  else
    echo "audio: no audio stream" >> "${prefix}report.txt" || return 1
  fi
  # Eight samples spread over the whole recording, rather than the first 20 s.
  ffmpeg -hide_banner -nostdin -loglevel error -y -i "$video" \
    -vf "fps=8/$duration,scale=220:-1,tile=4x2" -frames:v 1 "${prefix}contact.jpg" || return 1
  echo "analyzed $video -> ${prefix}report.txt"
}

case "${1:-}" in
doctor)
  status=0
  [ "$(uname -s)" = Darwin ] || { echo "capture: requires macOS + Xcode; offline analyze works here"; status=1; }
  for tool in xcrun xcodebuild python3 ffmpeg ffprobe; do
    if command -v "$tool" >/dev/null 2>&1; then echo "$tool: available"; else echo "$tool: missing"; [ "$tool" = ffmpeg ] || [ "$tool" = ffprobe ] || status=1; fi
  done
  echo "DEVICE: ${DEVICE:-unset}; BUNDLE: ${BUNDLE:-unset}"
  echo "Physical-device trust, signing and ReplayKit consent require a device smoke test."
  exit "$status" ;;
build)
  device; need xcodebuild
  projects=(*.xcodeproj)
  build_args=()
  if [ -n "${WORKSPACE:-}" ]; then
    build_args=(-workspace "$WORKSPACE"); default_scheme=$(basename "${WORKSPACE%.xcworkspace}")
  else
    if [ -z "${PROJECT:-}" ]; then
      [ "${#projects[@]}" -eq 1 ] || fail "set PROJECT or WORKSPACE when project selection is ambiguous"
      PROJECT=${projects[0]}
    fi
    build_args=(-project "$PROJECT"); default_scheme=$(basename "${PROJECT%.xcodeproj}")
  fi
  derived=${DERIVED_DATA:-$OUT_ROOT/DerivedData}
  xcodebuild "${build_args[@]}" -scheme "${2:-${SCHEME:-$default_scheme}}" -configuration Debug \
    -destination "id=$DEVICE" -derivedDataPath "$derived" -allowProvisioningUpdates -quiet build
  apps=("$derived"/Build/Products/Debug-iphoneos/*.app)
  if [ -z "${APP:-}" ]; then
    [ "${#apps[@]}" -eq 1 ] || fail "set APP to the intended .app; build output selection is ambiguous"
    APP=${apps[0]}
  fi
  xcrun devicectl device install app --device "$DEVICE" "$APP" -q
  echo "installed $(basename "$APP")" ;;
start)
  device
  duration=${2:-180}; seconds "$duration"
  extra=()
  # Backward-compatible whitespace splitting, without eval or glob expansion.
  if [ -n "${LAUNCH_ARGS:-}" ]; then read -r -a extra <<< "$LAUNCH_ARGS"; fi
  if [ "$#" -gt 2 ]; then
    [ "$3" = -- ] || fail "put -- before extra app arguments"
    shift 3; extra+=("$@")
  fi
  launch_log=$(mktemp "${TMPDIR:-/tmp}/blackbox-launch.XXXXXX")
  for ((i=1; i<=15; i++)); do
    if xcrun devicectl device process launch --terminate-existing --device "$DEVICE" -- "$BUNDLE" \
        -recordSession YES -recordSeconds "$duration" ${extra[@]+"${extra[@]}"} > "$launch_log" 2>&1; then
      rm -f "$launch_log"
      echo "launched: accept ReplayKit consent, exercise the scenario, then leave the app to save"
      exit 0
    fi
    [ "$i" -ne 1 ] || echo "launch refused; retrying while you unlock the phone..." >&2
    [ "$i" -eq 15 ] || sleep 3
  done
  cat "$launch_log" >&2; rm -f "$launch_log"
  fail "launch failed; check device unlock, trust, app installation and arguments" ;;
pull)
  device
  mkdir -p "$OUT_ROOT"
  directory=$(mktemp -d "$OUT_ROOT/$(date +%Y%m%d-%H%M%S)-XXXXXX")
  if ! xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source Documents/recordings --destination "$directory/recordings" -q; then
    fail "recordings copy failed; partial destination retained at $directory"
  fi
  if ! xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
      --domain-identifier "$BUNDLE" --source "$LOGS" --destination "$directory/$(basename "$LOGS")" -q; then
    echo "warning: optional trace copy failed; check $LOGS and device connection" >&2
  fi
  videos=("$directory"/recordings/*.mp4)
  [ "${#videos[@]}" -gt 0 ] || fail "copy returned no recordings/*.mp4; inspect $directory"
  failed=0
  for video in "${videos[@]}"; do analyze "$directory" "$video" || failed=1; done
  echo "$directory"
  exit "$failed" ;;
analyze)
  [ "$#" -ge 2 ] && [ "$#" -le 3 ] || fail "usage: session.sh analyze <session-directory> [video.mp4]"
  analyze "$2" "${3:-}" ;;
-h|--help|'') usage ;;
*) usage >&2; exit 2 ;;
esac
