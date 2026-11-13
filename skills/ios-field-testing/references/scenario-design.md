# Designing a field scenario

Choose a task and the smallest set of conditions that can expose its failure. Keep expected behavior separate from event implementation details. Replace profile defaults with the app's requirements and measurements.

| Domain | Task and perturbation | Acceptance evidence | Additional adapter or review |
|---|---|---|---|
| General UI | Start a task, interrupt it, and resume | Visible state; task completion/error events; preserved input | App-specific state instrumentation; resumed capture if foreground loss ends recording |
| Camera/ML | Recognize labeled items while rotating the phone, changing distance, or moving between indoor and outdoor light | Labeled frame outcomes; dropped-frame counters; latency measurements; tape frames | Ground-truth labels, orientation/preprocessing contract, production inference adapter |
| AR | Place an object, interrupt tracking, and reacquire | Tracking state transitions; visible placement stability; pose error if measured | AR session state and calibrated reference; replay cannot reconstruct every live ARKit state |
| Audio | Play an instruction while a new event or interruption arrives | Playback started/completed/cancelled events; actual app-audio segment | Operation IDs, audio interruption reason, listening/intelligibility review |
| Commerce | Lose connectivity during checkout, reconnect, and retry | Recoverable UI, preserved cart, confirmed order and error counts | Test backend/payment environment; independent idempotency and order-state evidence |
| Fitness | Deny motion permission, grant it, begin a session, then pause/resume | Permission state, session transitions, measured samples and UI state | The app's motion/HealthKit integration; device permissions and any external sensor evidence |
| Navigation | Complete a defined indoor or outdoor segment with an intentional interruption | Route/task completion, timely accessible cues, incorrect/repeated instruction events | Location/route adapter, annotated hazards and route ground truth; safe supervised trial setup where appropriate |

The capture templates do not add the domain adapters in the last column. Use recorded app events to bridge those sources where appropriate, with explicit units and clock conversions.

## Write a testable requirement

“Works in the real world” is too broad. Write an observable outcome: “The cart remains available after a failed submission; after one retry the test backend contains exactly one confirmed order.” Then identify which source establishes each clause.

A useful scenario records:

- Initial state and prerequisites: account, permissions, data, network, model/configuration.
- Ordered human actions and the intended perturbation.
- Expected outcome for every meaningful step.
- Numeric thresholds with units, sample floor, and rationale.
- Required artifacts and the manual checks that remain.

An event is trustworthy only if it is emitted after the outcome occurs. A `request.started` record cannot stand in for a successful response. A `speech.enqueued` record cannot prove the utterance was played.

## Select conditions deliberately

Choose relevant axes, then run small focused cases: device/OS, orientation, permissions, connectivity, foreground/background, power/thermal state, sensor capability, scene light, distance, motion, and indoor/outdoor transitions. Do not attempt a large Cartesian product without a reason. Record untested cases as untested.

Test one clean baseline before adding perturbations so the capture and instrumentation can be checked. Keep repeated trials comparable; reset the app/pipeline state and record changes. A short tape of one scene cannot establish performance across all scenes or users.

## Choose a meaningful aggregation

`count` counts records. If duplicate logging is possible, fix instrumentation or add a dedicated uniqueness check. A zero prohibited-event count needs complete observation of the relevant operation.

Use `max` when every observed sample must meet a hard bound. Use `median` for a typical sample and `p95` for the selected percentile over a sufficient sample set. State the number of samples and the measurement boundary, such as request dispatch to confirmed response. Do not pool unrelated event types, units, devices, or builds without justification.

For model accuracy, labels and a denominator are required. A count of emitted predictions is not accuracy. For timing, wall-clock dates and uptime values need an explicit conversion; clocks from separate devices require synchronization evidence.
