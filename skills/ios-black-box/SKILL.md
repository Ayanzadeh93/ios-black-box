---
name: ios-black-box
description: A flight recorder for iOS apps. Records real iPhone sessions — screen video with the app's own audio plus the app's event log — pulls them over USB, and turns them into a timeline of what the app showed, said and did. Use when the user wants to see or hear their app on a physical device instead of the simulator, capture a field session as video, review speech/audio output, or measure on-device FPS, latency, thermal and memory from real runs.
---

# Black Box — a flight recorder for your iOS app

The simulator guesses about cameras, sensors, speech timing and heat. The phone knows.
Black Box records what really happened on the device, then reads it back.

## Output

```
.blackbox/<timestamp>/
  recordings/session-*.mp4   screen + app audio (ReplayKit; the mic is never recorded)
  recordings/session-*.json  clock sidecar: uptime at recording start/stop
  traces/*.jsonl             the app's own event log, if it writes one
  report.txt                 duration, audio level, speech/silence spans
  contact.jpg                one frame every 2.5 s
  timeline.csv               every log event on the video clock (video_s, type, summary)
```

## Setup (once per app)

1. Copy `templates/SessionRecorder.swift` into the app target.
2. In `application(_:didFinishLaunchingWithOptions:)`:
   ```swift
   #if DEBUG
   SessionRecorder.shared.startIfRequested()
   #endif
   ```
3. Recommended: have the app write JSON Lines (one event per line: decisions, utterances, timings) to `Documents/traces/`, with a `t` field set to `ProcessInfo.processInfo.systemUptime`. Then `pull` puts every event on the video's clock (`timeline.csv`), and a cut-off utterance lines up with the event that interrupted it. A different field name works via `TIME_FIELD=`.

## Run

```bash
export DEVICE=<udid>       # xcrun devicectl list devices
export BUNDLE=com.you.app
scripts/session.sh build   # signed Debug build + install
scripts/session.sh start 60   # accept the iOS prompt, use the app, then leave it
scripts/session.sh pull    # recordings + traces + report + contact sheet
```

Extra launch flags (for example, to turn on your trace): `LAUNCH_ARGS="-myTrace YES"`.

## Analyze: numbers first, pixels last

1. `report.txt`: is there audio, and how much of the session is speech?
2. `timeline.csv`: walk it in order. An `interrupted` that lands on the same `video_s` as a new event is that event cutting it off. Then the trace: count events by type. For every utterance, did it finish or get cut off? Look for duplicates, back-to-back interruptions and long silences.
3. Performance: frame ms, FPS, thermal state and memory, as median **and** p95.
4. `contact.jpg`, then only the video moments `timeline.csv` points to (`ffmpeg -ss <video_s>`).

Report each finding as: **what happened → evidence (timestamp, log line) → likely cause.**

## Gotchas

- **Locked phone means the launch is refused.** Awake isn't enough; the phone must be past the lock screen. `start` retries for 45 s.
- **`devicectl capture screen-record` is unsupported on many iPhones**, and a screenshot takes about 2.5 s. That's why the recorder lives inside the app.
- **The video saves when recording stops**, either by leaving the app or at the time limit. Killing the app from Xcode loses it.
- **`--console` shows stdout only.** `os.Logger` output appears in Console.app.
- **QuickTime's "iPhone Camera" source is Continuity Camera.** It takes the phone's camera away from your app; it isn't screen mirroring.
- **Screenshots capture whatever is on screen.** Keep your app in front and delete anything personal.
- **Fresh git worktrees can contain LFS pointers instead of models.** Run `git lfs checkout` before building.
