---
name: ios-black-box
description: Capture and inspect real iPhone Debug app sessions using screen video, app audio, app event traces, and an approximate video timeline. Use for physical-device reproduction, field recordings, speech or UI review, and investigation of instrumented performance or lifecycle failures in any iOS app.
---

# Black Box: capture a real iOS session

Use a short recording to inspect what the app displayed and played, together with the events it logged. This works for any iOS task, including camera, AR, commerce, fitness, accessibility, and indoor or outdoor workflows. For task design and acceptance checks, use the companion `ios-field-testing` skill.

Resolve `scripts/` and `templates/` relative to this `SKILL.md`. Run capture commands from the app's project directory.

## Establish the evidence needed

Identify the task, build, device, scenario, and run. Define what the recording can show and what needs instrumentation. For example, video can show a retry state; a backend response or domain event must establish whether an order was duplicated.

Use test accounts and short captures. Screen video, event text, and app audio may contain private information. Inspect and sanitize artifacts before sharing. Keep the recorder and sensitive tracing behind `#if DEBUG`.

## Integrate once per app

1. Add `templates/SessionRecorder.swift` to the app target.
2. At launch:

   ```swift
   #if DEBUG
   SessionRecorder.shared.startIfRequested()
   #endif
   ```

3. Write relevant app events as JSON Lines in `Documents/traces/`. Use `t: ProcessInfo.processInfo.systemUptime`, an event `type`, and the identifiers needed to associate events with the run and operation. Keep authorization headers, secrets, payment data, and unrelated personal text out of traces.
4. Log completion and failure outcomes, not only attempted work. Performance, memory, thermal, network, location, and domain metrics are available only when your app records them.

## Capture

```bash
export DEVICE='<identifier>' BUNDLE='com.example.app'
scripts/session.sh doctor
scripts/session.sh build
scripts/session.sh start 60
# Accept the iOS recording prompt and perform the scenario.
scripts/session.sh pull
```

The template disables the microphone. Recording stops at the time limit or when the app leaves the foreground. Let it save before terminating the app; killing the process can lose the recording. `start` retries launches while the device is locked, but launch success does not prove the recorder started or produced a valid file.

Automatic capture starts once per app launch. After normal `startIfRequested()` setup, a task that resumes after an interruption can use an in-app Debug action calling `SessionRecorder.shared.startNextSegment()` while the app is active and after the previous export finishes. It still requires `-recordSession YES`. Accept the fresh ReplayKit prompt; a `false` return means no request started. A `true` return means the request was accepted, and ReplayKit can still fail or be denied; verify the resulting artifacts. Keep one continuous app trace across segment sidecars. Do not run `session.sh start` to resume capture inside the same run: it terminates and relaunches the app. If no rearm action is integrated, retain trace/manual evidence and mark the resumed screen segment unavailable.

Set `PROJECT` and an explicit build scheme when automatic discovery is unsuitable. `LOGS` changes the app-container trace directory; `TIME_FIELD` changes the trace timestamp field. `OUT` changes the local artifact root. `LAUNCH_ARGS` supplies simple additional launch tokens; inspect the script's usage before passing values containing spaces.

## Inspect

1. Verify that the expected recording, sidecar, and trace files exist. Missing recording or invalid metadata blocks video analysis. Missing app events limits the conclusions that can be drawn.
2. Read the media report and timeline, then inspect the video moments they identify. Audio analysis reports signal levels and silence, not recognized speech.
3. Use `source` and `source_line` from the timeline to return to the original event. Alignment rejects malformed or untimed records by default. `align.py --skip-invalid` is an explicit salvage mode; disclose skipped rows and do not treat an incomplete trace as proof of success.
4. Compare the observed result with the scenario's acceptance criteria. Only compute performance statistics from suitable recorded measurements, with units, sample count, and aggregation stated.

The start callback records `systemUptime` after ReplayKit starts recording. It is an **approximate** media anchor, not the first encoded video timestamp. The alignment is useful for locating moments. A nearby event is a candidate explanation, not evidence by itself that it caused an interruption or UI change.

For an existing local capture, use offline analysis:

```bash
scripts/session.sh analyze path/to/session-directory
# If it contains several videos, select one explicitly:
scripts/session.sh analyze path/to/session-directory path/to/session.mp4
```

A single-video session writes `report.txt`, `contact.jpg` (eight samples across the recording), `audio-analysis.log`, and `timeline.csv` in the session directory when the required tools/evidence are available. For multiple videos, offline analysis requires an explicit selection and output names use that video's stem as a prefix; `pull` processes each video separately. Media analysis needs `ffmpeg` and `ffprobe`; alignment needs Python 3 and traces. Offline analysis does not require `DEVICE` or `BUNDLE`.

## Report with evidence

For each issue, state the expected behavior, observed behavior, artifact and timestamp or trace line, impact, and confidence. Separate observation from a suspected cause. Include capture failures and incomplete evidence. A quiet recording is not evidence that an app had no bugs.

## Device notes

- Unlock the phone past the lock screen before launching.
- ReplayKit can be unavailable or fail to save. Inspect its logged errors and the retrieved files.
- QuickTime's “iPhone Camera” source uses Continuity Camera and may take the camera away from the app.
- `devicectl --console` exposes standard output; `os.Logger` messages may need Console.app.
- Keep model assets available in fresh worktrees; if the app uses Git LFS, check that files are real assets before building.
