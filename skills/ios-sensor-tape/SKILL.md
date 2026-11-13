---
name: ios-sensor-tape
description: Capture supplied camera frames, optional LiDAR depth, device motion, and app events on an iPhone, then replay recorded inputs through an app's test adapter. Use for physical-device camera, AR, ML, motion, and sensor regressions, indoor or outdoor scene testing, and comparisons between pipeline or model versions.
---

# Sensor Tape: preserve field inputs for regression tests

Record a short real-device scene or task, then replay the saved inputs through your own pipeline. Use this for camera quality, AR interactions, fitness motion, accessibility, object recognition, and other sensor-dependent features. It is a capture/replay template, not a navigation engine or a recorder for every device sensor.

Resolve `scripts/` and `templates/` relative to this `SKILL.md`. For acceptance criteria and nonsensor tasks, use the companion `ios-field-testing` skill.

## Tape contents

```text
tape-<id>/
  meta.json       schema, device, OS, requested settings, clock, start/stop
  index.jsonl     frame | imu | event records with uptime timestamps
  frames/         sampled JPEG camera images
  depth/          optional LZFSE-compressed Float32 depth in metres
```

The index records arrival order; replay sorts by timestamp. Frame and motion timestamps must strictly increase within their respective streams; app event timestamps may repeat. Use `ProcessInfo.processInfo.systemUptime` for app events. Camera source timestamps must use that same clock or be converted explicitly; wall time from another device cannot be subtracted from uptime.

## Integrate

1. Add `templates/SensorTape.swift` to the Debug app target and `templates/TapePlayer.swift` to the test target.
2. At launch, inside `#if DEBUG`, call `SensorTape.shared.startIfRequested()`.
3. Offer frames from the app's existing capture callback. For ARKit:

   ```swift
   #if DEBUG
   SensorTape.shared.offer(frame.capturedImage,
                           depth: (frame.smoothedSceneDepth ?? frame.sceneDepth)?.depthMap,
                           at: frame.timestamp)
   #endif
   ```

4. Record the decisions or labels needed to compare with a replay:

   ```swift
   SensorTape.shared.event("prediction", ["label": label], at: frame.timestamp)
   ```

5. Supply the app's required usage descriptions and permissions. Motion uses `NSMotionUsageDescription`; camera access belongs to the app's capture pipeline. The recorder does not request GPS, HealthKit, Bluetooth, network payload, or biometric capture for you.

Record model/build versions and the live preprocessing contract: orientation, mirroring, image scaling/cropping, normalization, thresholds, and any required camera intrinsics. Preserve calibration and frame/depth alignment evidence if the pipeline depends on them. These are integration requirements, not metadata this template automatically reconstructs.

## Capture and validate

```bash
export DEVICE='<identifier>' BUNDLE='com.example.app'
scripts/tape.sh doctor
scripts/tape.sh start 30 5
# Perform the scenario, then leave the app or wait for the limit.
scripts/tape.sh pull
scripts/tape.sh validate path/to/tape-directory
```

The duration starts at recorder activation, including sessions that receive no camera frames. `firstFrameUptime` remains a separate anchor. `-tapeScale 1` requests full resolution; use `LAUNCH_ARGS` for additional simple launch tokens. Start with short, low-rate captures and inspect their actual size and achieved frame rate.

Backgrounding finalizes the sensor tape; temporary inactive permission prompts do not. Prepare camera/motion permissions before the measured run when they are not the scenario under test. Camera frames can be dropped while encoding is busy. The event/motion writer has no bounded backlog or drop accounting, so keep captures short and do not infer live pipeline FPS from the sampled tape rate.

`tape.sh info <directory> [--json]` summarizes a local tape without a device; `tape.sh validate <directory> [--json]` also requires a finalized, nonempty recording. Finalized event-only or motion-only tapes are valid when they suit the task. Structural validation checks metadata, finite timestamps, sample fields, and referenced assets. It cannot establish JPEG decode success, valid compressed depth contents, sensor calibration, or whether a scene is representative. Decode assets in the app/test environment before accepting a tape as a regression fixture.

## Replay through the production adapter

```swift
let tape = try TapePlayer(url: tapeURL)
for sample in tape.frames {
    let buffer = try tape.pixelBuffer(for: sample)  // decoded 32BGRA
    let depth = try tape.depth(for: sample)        // optional depth data
    // Apply the app's orientation/preprocessing and feed its pipeline.
}
```

Use the test runner configuration appropriate to your Xcode target. The supplied example reads `SENSOR_TAPE`; if using `xcodebuild`, pass `TEST_RUNNER_SENSOR_TAPE=/path/to/tape` and verify the variable reaches the test process.

Add three kinds of checks:

1. **Integrity:** index and schema are valid, the required streams exist, and every required image/depth asset decodes.
2. **Behavior:** assert the expected outcome, sequence, timing tolerance, or labeled accuracy for this scenario. Reset state and control dependencies between runs.
3. **Sensitivity:** introduce a controlled change or known failing fixture and verify that the assertion fails. A test that never observes its target output does not protect the behavior.

Recorded images are sampled, JPEG-compressed, and possibly scaled. They differ from live pixel buffers. Equal replay inputs do not guarantee identical ML output across hardware, OS/model versions, concurrency, or unreset pipeline state. Use tolerances where justified and report the comparison environment.

Real-time replay schedules samples against elapsed replay time. Expensive callbacks may make replay late; it does not recreate the camera's hardware timing, backpressure, thermal state, or the operating system's scheduler.

## Interpret and retain

Compare against live decision events only after verifying the preprocessing and model contract. A mismatch can come from capture transformations, state, timing, thresholds, or changed code; it does not identify the cause by itself.

Keep a small, sanitized fixture set that covers the task's relevant conditions: orientation, light, motion, permission denial, interruptions, hardware capabilities, and indoor/outdoor transitions as applicable. Use test scenes without unrelated people or private material, inspect before sharing, and define retention for raw recordings.

Depth is present only when the app supplies it from a supported enabled source. Missing depth is acceptable for a camera-only scenario and blocks any test that requires depth. Large dense model outputs and device-specific behavior need validation on the target device.
