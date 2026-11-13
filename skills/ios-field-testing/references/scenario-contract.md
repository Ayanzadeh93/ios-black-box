# Scenario and trace contract

`scenario.py` uses Python 3.9+ and its standard library. Scenario authoring and event evaluation do not require macOS or a connected device.

```bash
python3 scripts/scenario.py init task.json --profile commerce
python3 scripts/scenario.py validate task.json
python3 scripts/scenario.py evaluate task.json run-events.jsonl --out result.json
```

`init` refuses to overwrite an existing file. Supported profiles are `general`, `camera-ml`, `audio`, `commerce`, and `fitness`. Always edit example thresholds and event names for the app.

## Scenario

```json
{
  "schemaVersion": 1,
  "id": "checkout-retry",
  "title": "Recover checkout after connectivity loss",
  "goal": "Preserve the cart and confirm one order after retry.",
  "profile": "commerce",
  "context": {
    "build": "replace-with-build-id",
    "device": "replace-with-device-and-OS",
    "connectivity": "test-controlled disconnect, then reconnect"
  },
  "steps": [
    {
      "id": "retry",
      "action": "Submit checkout offline, reconnect, then retry once.",
      "expected": "Cart remains available and one order is confirmed."
    }
  ],
  "acceptance": [
    {
      "id": "confirmed-once",
      "description": "Exactly one confirmation is observed in this scenario.",
      "event": "order.confirmed",
      "metric": "count",
      "op": "==",
      "target": 1,
      "minSamples": 1
    },
    {
      "id": "latency",
      "description": "Confirmed requests meet the app's chosen latency budget.",
      "event": "request.completed",
      "where": {"operation": "checkout"},
      "metric": "max",
      "field": "latency_ms",
      "op": "<=",
      "target": 2000,
      "minSamples": 1
    }
  ]
}
```

The `2000` ms threshold is illustrative. A single request cannot characterize population latency. Use a meaningful sample floor and representative repetitions for that purpose.

`schemaVersion` is `1`. Use a unique nonempty `id` for the scenario. `title` and `goal` describe the task; `profile` labels the starting domain. `context` is an object for human-readable run conditions and identifiers. `steps` contains objects with `id`, `action`, and `expected`; the CLI validates their shape, but does not execute or independently verify them.

Each `acceptance` entry has a unique `id`, `description`, event name, `metric`, comparison `op`, finite numeric `target`, and optional `minSamples`. A count target must be a nonnegative integer. Numeric metrics also require a top-level numeric event `field`; count checks do not accept `field`. Optional `where` selects top-level event fields by scalar equality. Boolean values do not match numbers; numeric `1` and `1.0` do match. Supported metrics are `count`, `min`, `max`, `median`, and `p95`; comparisons are `<`, `<=`, `==`, `>=`, and `>`.

`minSamples` defaults to `1`. Numeric metrics require at least one sample. A count check may explicitly set `minSamples: 0` to test the absence of a prohibited event. That requires complete coverage and trusted instrumentation; absence in an incomplete log is not proof.

## Trace

Write one JSON object per line. Events require:

- `type`: nonempty event name matching the criterion's `event`.
- `t`: finite nonnegative seconds on the device's uptime clock.
- `scenario_id`: equal to the scenario's `id`.
- Any fields needed by `where` or a numeric metric.

Include exactly one `scenario.start` and one `scenario.end`, ordered by line and time. Timestamps for the selected scenario must not move backwards in the trace. Events outside the boundary lines and uptime window do not contribute to checks. Use one trace per execution; merge or split app files deliberately before evaluation so duplicate markers or unrelated runs do not become ambiguous. Rows for a different scenario ID are not counted.

```jsonl
{"type":"scenario.start","t":100.0,"scenario_id":"checkout-retry"}
{"type":"request.completed","t":102.0,"scenario_id":"checkout-retry","operation":"checkout","latency_ms":420}
{"type":"order.confirmed","t":103.0,"scenario_id":"checkout-retry"}
{"type":"scenario.end","t":104.0,"scenario_id":"checkout-retry"}
```

The evaluator computes nearest-rank `p95`: sort the `n` values and select rank `ceil(0.95 * n)`, using one-based ranks. `median` is the middle value, or the average of the two middle values. Counts describe matched records, not unique orders, people, operations, or device frames unless instrumentation ensures that meaning.

It does not join requests to responses, deduplicate retries, check arbitrary event ordering, compare strings semantically, or infer per-operation success. Add suitable instrumentation, preprocess into a defined event, or write a dedicated test for those contracts. An `order.confirmed` event alone cannot establish the state of the payment processor or backend.

## Results

Results retain criterion statuses, computed values, sample counts, evidence file/line references, run coverage, and SHA-256 provenance for the inputs. Evidence lists include the first 20 matched records per criterion, with `evidenceTruncated` indicating additional matches. Keep the exact input files; a hash identifies bytes, not whether the instrumentation or ground truth was correct.

A required metric with missing or nonfinite numeric fields is inconclusive. Missing/duplicate run boundaries and incomplete runs are inconclusive. Invalid scenario or trace input produces a diagnostic and exit code `2`; when `--out` is writable and does not alias an input, it also writes an inconclusive error result so a previous pass does not remain stale. Inspect stderr and the exit code if output cannot be written. A valid evaluated failure exits `1`; a pass exits `0`.

Automated pass applies only to the configured event checks. Manual steps, visible UX, audio intelligibility, sensor calibration, and external side effects still need their stated evidence.
