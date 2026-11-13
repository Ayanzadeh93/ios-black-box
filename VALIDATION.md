# Validation of the field-testing extension

## Executed in the development environment

- All 48 Python unit/integration tests passed on Linux with Python 3.12.
- Both shell scripts passed `bash -n`; project Python parsed with Python 3.9 syntax.
- All three skills passed the installed skill-creator metadata validator.
- The Vercel CLI installed and listed `find-skills`, `skill-creator`, and all three
  repository skills for Codex in this project's `.agents/skills/` directory.
- Offline media tests generated and analyzed real synthetic video, including
  a silent video and a video with AAC tone audio, using ffmpeg/ffprobe.
- Mocked device commands checked capture arguments and visible copy failures.

The tests cover strict trace/clock validation, source-line evidence, output
overwrite guards, exact event counts, missing capture boundaries, numeric
metrics, tape schema/assets, failed recordings, unsafe paths, and launch bounds.

## Scenario smoke runs

Independent agent runs exercised the new workflow and the original skill
baseline on commerce retry, outdoor fitness interruption, and camera rotation.
The new workflow generated schema-valid task plans and ran the supplied
commerce fixtures through the evaluator:

| Synthetic trace | Expected and observed result | Exit |
|---|---|---|
| `commerce-pass.jsonl` | pass: one completion in a complete window | 0 |
| `commerce-fail.jsonl` | fail: two completions, lines 2 and 3 | 1 |
| `commerce-truncated.jsonl` | inconclusive: missing end marker | 2 |

Both workflows identified the synthetic checkout outcomes correctly. The new
workflow packages scenario authoring, validation, verdicts and provenance into
reusable tools. Assertions requiring its JSON plan format favor that packaged
workflow; these single smoke runs are not a statistical comparison of models or
proof of field reliability.

The workflow review identified a second-recording gap after lock/unlock. The
recorder now has an explicit `startNextSegment()` Debug integration hook; the
resumed-capture instructions require that hook, completion of the prior save,
and fresh consent. Relaunching the app is not a substitute for capturing one
continuous workout run.

Prompts and synthetic input fixtures are retained in
[`evals/`](skills/ios-field-testing/evals/evals.json). They contain no device,
customer, payment, health, or real scene data.

## CI and remaining target checks

The workflow runs portable checks on Linux/macOS and typechecks the three core
Swift templates with Swift 6 against the iOS simulator SDK. Consult the actual
workflow run for its result; local Python tests do not establish Swift type
correctness. `TapeReplayTests.swift` still requires replacing `YourApp` and
connecting a real production pipeline in the consuming app.

No physical iPhone was attached during this development task. App signing,
ReplayKit consent/export/rearm, permission and lock transitions, background
persistence, camera/depth alignment, and actual model outputs still require
integration and short physical-device smoke tests. A generic task plan cannot
establish backend, GPS, HealthKit, or other external outcomes without their
declared instrumentation and independent evidence.
