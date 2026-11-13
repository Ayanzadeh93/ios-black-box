# Evidence, conclusions, and regression fixtures

## Keep the run inspectable

Retain the scenario, exact app/build/model identifiers, conditions actually observed, raw trace, relevant recording/sidecar, tape metadata/assets if used, and evaluation result. Use a run identifier in filenames or a manifest to connect artifacts. Do not subtract uptimes from different devices or boots; a shared field name does not establish a shared clock origin.

When reporting an issue, include the expected behavior, observed behavior, source file and line or media timestamp, impact, and confidence. Link a specific event to the video moment where possible. ReplayKit's callback anchor is approximate; a nearby event suggests where to investigate and does not prove causality.

An audio report measures level and silence. It does not recognize words, identify speakers, or establish intelligibility. A sensor summary validates structure and asset references. It does not prove calibration, JPEG/depth decode integrity, model correctness, or representative coverage.

Foreground interruption ends the recorder's automatic screen segment. A second segment in the same app process requires an integrated Debug action calling `SessionRecorder.shared.startNextSegment()` after normal recorder setup, after the prior export finishes, and while active, followed by fresh ReplayKit consent. A `true` result accepts the request only; verify callback/save success and resulting artifacts. Preserve one continuous lifecycle/state trace. `session.sh start` terminates/relaunches the app; it must not stand in for same-run capture rearming. Without the hook, identify the missing resumed video and restrict conclusions to the evidence that exists.

## Distinguish verdicts

- **Pass:** configured checks had sufficient valid evidence and met their thresholds. State any separate manual checks and the scope of this run.
- **Fail:** observed evidence violates a criterion. Explain the failed condition and its evidence.
- **Inconclusive:** the run or required evidence is missing, invalid, incomplete, or insufficient to judge. Repair instrumentation/capture or repeat the scenario; do not relabel this as pass.

A run-end marker is necessary for the evaluator's coverage check, but cannot prove the logger observed every relevant event. Recorders can fail, app processes can terminate, and external systems can disagree with the app. Use an independent source when the outcome requires it.

## Preserve the right regression

For a sensor failure, preserve a short sanitized tape plus the production adapter configuration. Assert asset decode, preprocessing, the relevant behavior, and a controlled failing case. Reset state between replays. Compare measured outcomes with justified tolerances and retain the environment; identical inputs alone do not guarantee deterministic model or concurrent pipeline outputs.

For a nonsensor failure, preserve a trace and a minimal fixture or mock that drives the same state transition. A fixture can reproduce a timeout/retry UI path; it cannot establish that the live backend implements idempotency. Keep the appropriate integration test too.

Sensor tape replay samples and transforms input frames. It cannot recreate the original camera exposure control, ARKit tracking state, physical surroundings, operating system scheduling, heat, power state, or live network timing. Real-time scheduling may run late if processing is slower than the recorded interval. Return to the device when the claim depends on those properties.

## Handle captured data deliberately

Use Debug-only capture, test accounts, short recordings, and scenes chosen for the test. Exclude unrelated people and personal material where possible. Avoid secrets and sensitive payloads in traces. Review raw screen/audio/sensor artifacts before sharing; deleting a trace field does not remove information visible in its video.

Document retention for raw recordings and sanitized regression fixtures. Preserve the original privately if needed for debugging; publish only the reviewed fixture appropriate to the repository. Hashes help identify artifact versions but do not redact their contents.
