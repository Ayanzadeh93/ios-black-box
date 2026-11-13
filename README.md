<p align="center"><img src="assets/ios-black-box.png" alt="ios-black-box: a flight recorder for your iOS app" width="100%"></p>

# ios-black-box

Turn a real iPhone task into inspectable evidence and a repeatable regression test.

Use these agent skills for any iOS workflow that needs a physical device: camera and ML features, AR, speech, commerce, fitness, accessibility, or indoor and outdoor navigation. Define what success means, record a short session, check the evidence, and preserve the inputs needed to reproduce a failure.

The capture tools remain iOS-specific. They integrate into your Debug app; they do not supply an app, a detector, a backend, or automatic instrumentation for every domain.

## Choose a skill

| Skill | Use it for |
|---|---|
| [ios-field-testing](skills/ios-field-testing/SKILL.md) | Start from a user task, define measurable acceptance criteria, run a field scenario, and produce a pass/fail/inconclusive result with evidence. |
| [ios-black-box](skills/ios-black-box/SKILL.md) | Capture the screen and app audio with ReplayKit, retrieve app traces, and inspect an approximate video timeline. |
| [ios-sensor-tape](skills/ios-sensor-tape/SKILL.md) | Capture supplied camera frames, optional depth, motion, and app events; replay recorded inputs through your own pipeline. |

## Install

From your app's repository:

```bash
npx skills add Ayanzadeh93/ios-black-box \
  --skill ios-field-testing ios-black-box ios-sensor-tape --agent codex
```

The examples below use a source checkout. After installation, resolve each script relative to its installed `SKILL.md`. You can also copy a skill folder into your agent's project skill directory, such as `.agents/skills/` for Codex or `.claude/skills/` for Claude Code. Companion skills must be installed separately when needed.

## Start with a real task

For example: “When checkout loses its connection, show a recoverable state, preserve the cart, and create at most one order after retry.” The app must emit the events needed to verify those outcomes; a recording alone cannot prove a backend order count.

```bash
# Run from this repository's root. No iPhone is needed for scenario authoring.
python3 skills/ios-field-testing/scripts/scenario.py init checkout.json --profile commerce
# Edit the generated task, steps, and acceptance checks for your app.
python3 skills/ios-field-testing/scripts/scenario.py validate checkout.json
```

Other starting profiles are `general`, `camera-ml`, `audio`, and `fitness`. Profiles are editable test plans, not integrations with payments, location, HealthKit, networking, or speech engines.

## Capture on an iPhone

1. Add [SessionRecorder.swift](skills/ios-black-box/templates/SessionRecorder.swift) to your app target and call `SessionRecorder.shared.startIfRequested()` at launch inside `#if DEBUG`.
2. Have the app write JSONL events to `Documents/traces/`, using `ProcessInfo.processInfo.systemUptime` in the `t` field. Include the app/build, scenario, and run identifiers in your evidence.
3. Connect an unlocked iPhone to a Mac with Xcode, then run:

```bash
export DEVICE='<device identifier>' BUNDLE='com.example.app'
skills/ios-black-box/scripts/session.sh doctor
skills/ios-black-box/scripts/session.sh build
skills/ios-black-box/scripts/session.sh start 60
# Accept ReplayKit's prompt, perform the scenario, and let recording stop.
skills/ios-black-box/scripts/session.sh pull
```

Capture produces screen video, the app's audio, clock metadata, and any app traces. Optional `ffmpeg` analysis adds audio levels, silence intervals, and a contact sheet. The microphone stays disabled in the recorder template. Inspect the [capture guide](skills/ios-black-box/SKILL.md) for setup, offline analysis, and failure handling.

If the task leaves the foreground and then resumes, the first screen segment stops. To capture a second segment during the same app run, add a Debug UI action that calls `SessionRecorder.shared.startNextSegment()` after the first export finishes and the app is active, then accept the fresh ReplayKit prompt. A `true` return means the request was accepted, not that recording or saving succeeded; check the resulting artifacts. Retain the continuous app trace across both segments. `session.sh start` terminates and relaunches the app, so use the in-app hook for this case. Without that integration, use the saved trace and explicitly record the missing resumed video.

Evaluate a trace containing only the intended run:

```bash
python3 skills/ios-field-testing/scripts/scenario.py evaluate checkout.json \
  path/to/run-events.jsonl --out result.json
```

Missing evidence must stay visible. A partial trace, an unexecuted step, or an unavailable measurement cannot establish that the task passed. Review the video and any backend evidence alongside the automated checks.

## Preserve a regression

For camera, AR, or sensor features, add the [sensor tape templates](skills/ios-sensor-tape/SKILL.md), offer frames from your existing capture pipeline, then:

```bash
export DEVICE='<device identifier>' BUNDLE='com.example.app'
skills/ios-sensor-tape/scripts/tape.sh start 30 5
# Perform the scenario; duration starts when the recorder starts.
skills/ios-sensor-tape/scripts/tape.sh pull
skills/ios-sensor-tape/scripts/tape.sh validate path/to/tape-directory
```

Replay the tape through your production adapter and assert the behavior that failed. JPEG compression, scaling, preprocessing, model versions, and pipeline state can change outputs; recorded inputs do not guarantee identical model results. For nonsensor tasks, preserve a sanitized event trace and the mocks or fixtures needed to reproduce the same transition.

## Evidence and limits

- ReplayKit's start callback provides an approximate uptime anchor, not the first encoded frame timestamp. Events can be placed near video moments; temporal proximity alone does not prove causality.
- An audio level or silence interval does not identify speech or prove an utterance completed. Use completion/cancellation events and listen to the relevant segment.
- FPS, latency, thermal state, memory, location, network conditions, and domain outcomes require app instrumentation or additional evidence. The tools do not measure them automatically.
- Keep capture short, use test accounts, and inspect recordings and traces before sharing. Screen content and sensor data can contain personal information. See the [field workflow](skills/ios-field-testing/SKILL.md) for an evidence checklist.

## Requirements and validation

Physical capture: macOS, Xcode 16.3+ with Swift 6.1+, an iOS 17+ device, a signed Debug app, and USB access. ReplayKit and sensor permissions must be supported by the app/device. LiDAR depth is optional and requires compatible hardware and an enabled source. `ffmpeg` and `ffprobe` enable media reports.

Scenario evaluation, timeline alignment, and structural tape checks use Python 3.9+ and run without an iPhone. The Swift templates require integration and compilation in your own Xcode project; Python checks do not establish that device capture works.

```bash
python3 -m unittest discover -s tests -v
```

The project began with recordings of an accessibility navigation app. Its workflow now treats that as one field-testing use case among many. Contributions with small, reproducible scenarios and sanitized fixtures are welcome.

MIT © Aydin Ayanzadeh
