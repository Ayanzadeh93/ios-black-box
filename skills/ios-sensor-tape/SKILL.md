---
name: ios-sensor-tape
description: Record the real world once on an iPhone (camera frames, LiDAR depth, device motion and app events on one clock) and replay it in tests forever. Use when a camera, AR, ML or sensor feature works in the simulator but misbehaves on a device, when the user wants a real-world regression test, wants to replay a walk/scene through their pipeline, or wants to compare a model change against recorded reality.
---

# Sensor Tape: record the real world once, replay it in tests forever

The simulator has no camera, no LiDAR and no motion. A sensor tape brings them into your tests: walk a real scene once, then replay those exact frames through your pipeline on every run.

## A tape

```
tape-<time>/
  meta.json     device, OS, fps, scale, clock, start/stop/firstFrame uptime
  index.jsonl   one line per sample, time-sorted on replay: frame | imu | event
  frames/       000001.jpg ...           (camera, subsampled + downscaled)
  depth/        000001.f32.lzfse ...     (Float32 metres, when LiDAR is on)
```

Everything uses `ProcessInfo.systemUptime`, the same clock as [ios-black-box](../ios-black-box), so tapes line up with its videos and timelines.

## Setup (once per app)

1. Add `templates/SensorTape.swift` to the app target, and `templates/TapePlayer.swift` to the test target.
2. At launch, inside `#if DEBUG`: `SensorTape.shared.startIfRequested()`
3. Wherever frames arrive (e.g. `ARSessionDelegate`), inside `#if DEBUG`:
   ```swift
   SensorTape.shared.offer(frame.capturedImage,
                           depth: (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap,
                           at: frame.timestamp)
   ```
4. Optional: log what your live pipeline decided, so replays can be compared with it:
   `SensorTape.shared.event("tracks", ["labels": labels], at: frame.timestamp)`
5. Motion needs `NSMotionUsageDescription` in Info.plist.

## Record and pull

```bash
export DEVICE=<udid> BUNDLE=com.you.app
scripts/tape.sh start 30 5      # 30 s of camera at 5 fps; the clock starts at the first frame
#   ...walk the scene, then leave the app...
scripts/tape.sh pull            # → .blackbox/tapes/tape-*/ + a one-line summary each
```

Options: `-tapeScale 1` keeps full resolution (about 4× bigger); `LAUNCH_ARGS` adds your own flags.

## Replay in a test

```swift
let tape = try TapePlayer(url: tapeURL)
for sample in tape.frames {
    let buffer = try tape.pixelBuffer(for: sample)   // 32BGRA, ready for Vision / Core ML
    let depth  = try tape.depth(for: sample)         // optional (width, height, metres)
    // feed your pipeline; compare with the recorded "tracks" events if you logged them
}
```

Pass the tape path with `TEST_RUNNER_SENSOR_TAPE=/path/to/tape` (Xcode passes it to the test as `SENSOR_TAPE`).

Write three tests for every tape:
1. **Well-formed:** frames exist, timestamps ascend, images decode.
2. **Deterministic:** replay twice and the outputs are identical.
3. **Has teeth:** a deliberately changed setting (e.g. a higher confidence threshold) produces a *different* output. Without this, "deterministic" proves nothing.

## Reading results

- Compare replay output with the live `tracks` events at the same timestamps: a gap means something differs between live and test (orientation, threshold, preprocessing).
- Diff two model versions on the same tape to see exactly which frames changed.
- Keep a few short tapes of hard scenes (low light, clutter, glass, stairs) in the repo as regression tests.

## Gotchas

- **Saved frames keep the camera's landscape buffer.** Replay with the same orientation the live path uses (ARKit portrait apps: `.right`).
- **Depth maps are only saved when LiDAR depth is on.** A camera-only session records frames without depth.
- **Size:** full-resolution 1920×1440 frames at about 4 fps measured roughly 70 MB per minute; the default half scale should be about a quarter of that. Keep tapes short and focused.
- **`devicectl` swallows app arguments that look like its own flags.** `tape.sh` passes `--` before the bundle ID.
- **The simulator's Core ML can zero large model outputs.** Detection outputs replay fine; assert values from large dense outputs (depth models) only on device.
