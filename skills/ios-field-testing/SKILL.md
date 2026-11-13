---
name: ios-field-testing
description: Turn any real-world iOS user task into a measurable field scenario, choose screen/audio or sensor capture, evaluate instrumented acceptance criteria, and preserve a regression fixture. Use when extending device tests beyond indoor navigation, planning indoor or outdoor trials, investigating camera/AR/audio/commerce/fitness workflows, or deciding whether a physical-device task passed with adequate evidence.
---

# iOS Field Testing

Start with the task a person needs to complete. Define observable outcomes, collect the evidence those outcomes require, and distinguish a failed task from an incomplete test. The workflow applies across iOS app domains; the companion capture tools remain iOS-specific.

Resolve this skill's `scripts/` relative to this file. Resolve companion skill scripts relative to their own `SKILL.md`; do not assume sibling installation folders exist. Install `ios-black-box` for screen/app-audio capture and `ios-sensor-tape` when recorded sensor inputs are useful.

## 1. Define one task and its boundaries

Use repository context and the user's request to identify the app, intended user outcome, available instrumentation, and environment. Continue with reasonable defaults for routine choices. Ask only for information that changes the task or the validity of the result.

Write a concrete goal such as “Retry a failed checkout while preserving the cart and producing one confirmed order” or “Recognize the labeled objects outdoors after rotating the phone.” Choose a short scenario that isolates the suspected failure. Indoor navigation is one possible task, alongside camera, AR, audio, commerce, fitness, and other device workflows.

Define the initial state, ordered human actions, expected visible behavior, and measurable acceptance criteria. Include build/model versions, device/OS, permissions, connectivity, power/thermal conditions, and relevant scene conditions. Distinguish recorded observations from settings that were merely requested.

Start with a profile:

```bash
python3 scripts/scenario.py init scenario.json --profile general
# Other profiles: camera-ml, audio, commerce, fitness.
# Edit the generated task, context, steps, events, and thresholds.
python3 scripts/scenario.py validate scenario.json
```

Profiles supply editable starting points. Their thresholds are examples, not product requirements or scientifically calibrated defaults. Read [scenario design](references/scenario-design.md) for domain examples and [the scenario contract](references/scenario-contract.md) for exact fields.

## 2. Connect acceptance criteria to real evidence

For every check, identify the evidence source and instrumentation needed before recording. The evaluator supports event counts and numeric `min`, `max`, `median`, and `p95` measurements; it does not infer outcomes from video, execute the human steps, or understand the app's domain semantics.

Have the app emit a JSONL trace containing only the intended run. Every event needs `type`, a finite nonnegative uptime `t`, and the scenario's `scenario_id`. Bracket the run with exactly one `scenario.start` and one `scenario.end`. Emit the end marker after the scenario's work settles, then flush the trace including that marker before export; it must not be an unconditional launch timer that hides unfinished work.

```jsonl
{"type":"scenario.start","t":100.0,"scenario_id":"checkout-retry"}
{"type":"order.confirmed","t":103.2,"scenario_id":"checkout-retry","order_count":1,"latency_ms":420}
{"type":"scenario.end","t":104.0,"scenario_id":"checkout-retry"}
```

Use `ProcessInfo.processInfo.systemUptime` for app traces and the same device clock for related measurements. A start/end pair establishes a bounded trace window, not that every required event was logged. Check that the instrumentation observes the actual operation, including errors and completion.

Use screen/app-audio capture for UI, playback, and lifecycle evidence. Use a sensor tape when the failure depends on camera/depth/motion inputs. For payment, server state, GPS, HealthKit, Bluetooth, or other domain outcomes, add the app-specific adapters and independent evidence needed; these skills do not capture those sources automatically.

## 3. Run a controlled field scenario

Keep recorder code and sensitive tracing in Debug builds. Use test accounts and a short capture; inspect screen content and scene contents before recording. Preserve only the data needed to reproduce and judge the task.

1. Run the companion capture tool's `doctor` command and integrate its template into the app.
2. Record device/build/scenario identifiers, the initial state, and the planned perturbation.
3. Start capture, perform the steps, and record deviations such as a denied permission, an interrupted run, or changed connectivity.
4. Let recording stop and save. Retrieve the artifacts; verify they exist and belong to the same run.
5. Validate the trace, sidecar, and tape structure before interpreting results. Decode required sensor assets in the target test environment.

Try conditions that matter to the task: indoor/outdoor transitions, bright or low light, rotation, motion, foreground loss, permission denial, connectivity loss/recovery, and device capability differences. Do not imply that all these conditions were exercised because a profile lists them.

A foreground-loss scenario ends the automatic screen segment. Preserve explicit lifecycle events and the continuous app trace. To record the resumed phase without terminating the task, integrate an in-app Debug action calling `SessionRecorder.shared.startNextSegment()` after normal recorder setup, after the first export finishes, and while the app is active; accept the fresh ReplayKit prompt. A `true` return accepts the request only, so verify callback/save success and resulting artifacts. `session.sh start` terminates and relaunches the app and cannot resume a continuous same-process run. If that hook is unavailable or fails, mark the resumed screen evidence missing and use the other stated evidence; do not invent a second segment.

## 4. Evaluate and inspect

```bash
python3 scripts/scenario.py evaluate scenario.json run-events.jsonl --out result.json
```

The result includes criteria, sample counts, source lines, coverage, and hashes of the inputs. Exit codes are `0` for pass, `1` for fail, and `2` for inconclusive or invalid input. Read the result and diagnostics; do not reduce an inconclusive exit to “no failures.” Keep the original scenario and trace beside the result.

A count of zero may establish absence only with an explicit `minSamples: 0`, a complete run window, and instrumentation capable of recording the prohibited event. Missing required samples, malformed values, missing end markers, and truncated runs cannot establish success.

Inspect the relevant media and trace lines. ReplayKit uses an approximate callback-based video anchor, so temporal proximity is a lead, not proof of causality. Silence detection does not recognize speech. The numeric evaluator cannot prove that a person understood an announcement or that the UI met an accessibility requirement; include a manual or specialist check where needed.

Treat the verdict as applying to the executed scenario and observed evidence. Broader reliability needs representative cases and repetitions, not a single successful run.

## 5. Preserve the failure as a regression

For camera/AR/sensor tasks, replay the validated tape through the production preprocessing and pipeline adapter. Reset state, record model/hardware versions, assert the outcome that failed, and verify the assertion detects a controlled bad result. JPEG sampling/scaling changes the live inputs; equal tape inputs do not guarantee identical outputs across environments.

For nonsensor tasks, save sanitized event traces and deterministic fixtures/mocks for the relevant state transition. Backend effects, scheduling, thermal behavior, permissions, and hardware still require appropriate integration or physical-device tests. See [evidence and replay](references/evidence-and-replay.md).

## Deliver the result

Report the task, tested build/device/conditions, criteria with observed values and sample counts, and artifact/line/timestamp evidence. State the verdict as **pass**, **fail**, or **inconclusive**, identify unexecuted steps and missing sources, and separate observations from suspected causes. Include the reproducible command or regression fixture and any target-device validation still needed.
