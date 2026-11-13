#!/usr/bin/env python3
"""Plan and evaluate instrumented iOS field tasks. Python 3.9+, no dependencies.

Exit 0: pass/valid/init; 1: measured acceptance failure; 2: invalid/inconclusive.
An evaluation is evidence about its configured checks, not release certification.
"""
import argparse
import hashlib
import json
import math
import operator
import sys
from pathlib import Path

OPS = {"<=": operator.le, ">=": operator.ge, "==": operator.eq,
       "<": operator.lt, ">": operator.gt}
METRICS = {"count", "median", "p95", "min", "max"}
PROFILES = {
    "general": ("Complete the primary task after an interruption", "task.completed", None, 1),
    "camera-ml": ("Recognize the target under changed lighting and orientation", "inference.completed", "latency_ms", 200),
    "audio": ("Finish app audio after an interruption and resume", "utterance.completed", None, 1),
    "commerce": ("Recover one checkout after losing connectivity", "checkout.completed", None, 1),
    "fitness": ("Resume a workout after permission and foreground changes", "workout.resumed", None, 1),
}


def finite(value):
    return (type(value) in (int, float) and
            (type(value) is int or math.isfinite(value)))


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant: {value}")


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def decode(data):
    return json.loads(data, parse_constant=reject_constant, object_pairs_hook=object_pairs)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def validate(plan):
    require(isinstance(plan, dict), "scenario must be an object")
    require(type(plan.get("schemaVersion")) is int and plan["schemaVersion"] == 1,
            "schemaVersion must be 1")
    for field in ("id", "title", "goal", "profile"):
        require(nonempty(plan.get(field)), f"{field} must be a nonempty string")
    require(isinstance(plan.get("context"), dict), "context must be an object")
    require(isinstance(plan.get("steps"), list) and plan["steps"], "steps must be a nonempty list")
    ids = set()
    for step in plan["steps"]:
        require(isinstance(step, dict), "each step must be an object")
        for field in ("id", "action", "expected"):
            require(nonempty(step.get(field)), f"step {field} must be a nonempty string")
        require(step["id"] not in ids, f"duplicate step id: {step['id']}")
        ids.add(step["id"])
    checks = plan.get("acceptance")
    require(isinstance(checks, list) and checks, "acceptance must be a nonempty list")
    ids = set()
    allowed = {"id", "description", "event", "where", "metric", "field", "op", "target", "minSamples"}
    for check in checks:
        require(isinstance(check, dict), "each acceptance check must be an object")
        require(not (set(check) - allowed), f"unknown acceptance fields: {sorted(set(check) - allowed)}")
        for field in ("id", "description", "event"):
            require(nonempty(check.get(field)), f"acceptance {field} must be a nonempty string")
        require(check["id"] not in ids, f"duplicate acceptance id: {check['id']}")
        ids.add(check["id"])
        require(check.get("metric") in METRICS, f"invalid metric for {check['id']}")
        require(check.get("op") in OPS, f"invalid op for {check['id']}")
        require(finite(check.get("target")), f"target must be finite for {check['id']}")
        minimum = check.get("minSamples", 1)
        require(type(minimum) is int and minimum >= 0, "minSamples must be a nonnegative integer")
        if check["metric"] != "count":
            require(nonempty(check.get("field")), "numeric metric requires a field")
            require(minimum >= 1, "numeric metric requires minSamples >= 1")
        else:
            require("field" not in check, "count does not accept field")
            require(type(check["target"]) is int and check["target"] >= 0,
                    "count target must be a nonnegative integer")
        where = check.get("where", {})
        require(isinstance(where, dict), "where must be an object of scalar equalities")
        for key, value in where.items():
            require(nonempty(key) and (value is None or type(value) in (str, bool) or finite(value)),
                    "where values must be finite JSON scalars")
    return plan


def new_plan(profile):
    goal, event, field, target = PROFILES[profile]
    check = {"id": "primary-task", "description": goal, "event": event,
             "metric": "p95" if field else "count", "op": "<=" if field else "==",
             "target": target, "minSamples": 1}
    if field:
        check["field"] = field
    return {"schemaVersion": 1, "id": profile + "-task", "title": goal, "goal": goal,
            "profile": profile,
            "context": {"appBuild": "REPLACE", "device": "REPLACE", "environment": "REPLACE",
                        "thresholds": "Example only: agree task-specific limits before capture"},
            "steps": [
                {"id": "baseline", "action": "Start the task and emit scenario.start", "expected": "Task is available"},
                {"id": "variation", "action": "Apply the profile variation in a controlled setting", "expected": "App reports its state and recovers"},
                {"id": "complete", "action": "Complete the task and emit scenario.end", "expected": "The primary task outcome is recorded"}],
            "acceptance": [check]}


def read_events(data):
    result = []
    for number, line in enumerate(data.decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = decode(line)
            require(isinstance(row, dict), "event must be an object")
            require(nonempty(row.get("type")), "event type must be a nonempty string")
            require(finite(row.get("t")) and row["t"] >= 0, "t must be finite nonnegative uptime seconds")
            require(nonempty(row.get("scenario_id")), "scenario_id must be a nonempty string")
        except ValueError as error:
            raise ValueError(f"events line {number}: {error}") from error
        result.append((number, row))
    return result


def same_scalar(left, right):
    # JSON booleans should not match the number 1; int and float numbers may match.
    return ((finite(left) and finite(right)) or type(left) is type(right)) and left == right


def metric_value(metric, values):
    if metric == "count":
        return len(values)
    ordered = sorted(values)
    if metric == "min":
        return ordered[0]
    if metric == "max":
        return ordered[-1]
    if metric == "p95":
        return ordered[math.ceil(0.95 * len(ordered)) - 1]
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else ordered[middle - 1] / 2 + ordered[middle] / 2


def evaluate(plan, rows, source):
    selected = [(n, row) for n, row in rows if row["scenario_id"] == plan["id"]]
    starts = [(n, row) for n, row in selected if row["type"] == "scenario.start"]
    ends = [(n, row) for n, row in selected if row["type"] == "scenario.end"]
    reasons = []
    if len(starts) != 1 or len(ends) != 1:
        reasons.append("require exactly one scenario.start and one scenario.end for this scenario_id")
    elif starts[0][0] >= ends[0][0] or starts[0][1]["t"] > ends[0][1]["t"]:
        reasons.append("scenario boundaries are reversed")
    if any(b[1]["t"] < a[1]["t"] for a, b in zip(selected, selected[1:])):
        reasons.append("scenario timestamps move backwards; use one device clock and ordered logging")
    window = []
    if not reasons:
        first, last = starts[0][1]["t"], ends[0][1]["t"]
        window = [(n, row) for n, row in selected
                  if starts[0][0] <= n <= ends[0][0] and first <= row["t"] <= last]
    results = []
    for check in plan["acceptance"]:
        matched = [(n, row) for n, row in window if row["type"] == check["event"] and
                   all(key in row and same_scalar(row[key], value)
                       for key, value in check.get("where", {}).items())]
        result = {"id": check["id"], "description": check["description"], "status": "inconclusive",
                  "metric": check["metric"], "op": check["op"], "target": check["target"],
                  "sampleCount": len(matched), "value": None,
                  "evidence": [{"source": str(source), "line": n, "t": row["t"]} for n, row in matched[:20]],
                  "evidenceTruncated": len(matched) > 20}
        if reasons:
            result["reason"] = "capture boundaries or ordering are incomplete"
        elif len(matched) < check.get("minSamples", 1):
            result["reason"] = "insufficient matching samples"
        elif check["metric"] != "count" and any(not finite(row.get(check["field"])) for _, row in matched):
            result["reason"] = f"matching event has missing or non-finite {check['field']}"
        else:
            values = [row.get(check.get("field")) for _, row in matched]
            value = metric_value(check["metric"], values)
            result["value"] = value
            result["status"] = "pass" if OPS[check["op"]](value, check["target"]) else "fail"
        results.append(result)
    states = {r["status"] for r in results}
    status = "fail" if "fail" in states else "inconclusive" if "inconclusive" in states else "pass"
    return {"schemaVersion": 1, "scenario_id": plan["id"], "status": status,
            "coverage": {"complete": not reasons, "reasons": reasons, "matchingEvents": len(window),
                         "boundaries": [{"source": str(source), "line": n, "t": r["t"], "type": r["type"]}
                                        for n, r in starts + ends]},
            "criteria": results,
            "limits": ["Verdict covers configured instrumented checks only; review screen/audio and task observations separately.",
                       "Complete markers establish a declared window, not proof that all app events were logged.",
                       "p95 uses nearest rank; small samples do not establish production reliability."]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="create an editable task plan; refuses overwrite")
    init.add_argument("path", type=Path)
    init.add_argument("--profile", choices=PROFILES, default="general")
    valid = commands.add_parser("validate", help="validate a task plan")
    valid.add_argument("scenario", type=Path)
    run = commands.add_parser("evaluate", help="evaluate checks against JSONL app events")
    run.add_argument("scenario", type=Path)
    run.add_argument("events", type=Path)
    run.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "evaluate" and args.out:
            require(args.out.resolve() not in (args.scenario.resolve(), args.events.resolve()),
                    "--out must not overwrite an input")
        if args.command == "init":
            plan = validate(new_plan(args.profile))
            with args.path.open("x", encoding="utf-8") as output:
                output.write(json.dumps(plan, indent=2, allow_nan=False) + "\n")
            print(args.path)
            return 0
        scenario_data = args.scenario.read_bytes()
        plan = validate(decode(scenario_data))
        if args.command == "validate":
            print(f"valid: {plan['id']} ({len(plan['acceptance'])} checks)")
            return 0
        event_data = args.events.read_bytes()
        report = evaluate(plan, read_events(event_data), args.events)
        report["inputs"] = {"scenario": str(args.scenario), "events": str(args.events),
                            "scenarioSha256": hashlib.sha256(scenario_data).hexdigest(),
                            "eventsSha256": hashlib.sha256(event_data).hexdigest()}
        content = json.dumps(report, indent=2, allow_nan=False) + "\n"
        if args.out:
            args.out.write_text(content, encoding="utf-8")
        else:
            print(content, end="")
        return {"pass": 0, "fail": 1, "inconclusive": 2}[report["status"]]
    except (OSError, ValueError, TypeError, OverflowError) as error:
        print(f"error: {error}", file=sys.stderr)
        # A prior pass must not remain the result of a newly invalid run.
        if args.command == "evaluate" and args.out:
            try:
                if args.out.resolve() not in (args.scenario.resolve(), args.events.resolve()):
                    args.out.write_text(json.dumps({"schemaVersion": 1, "status": "inconclusive",
                                                   "error": str(error),
                                                   "inputs": {"scenario": str(args.scenario),
                                                              "events": str(args.events)}}, indent=2) + "\n",
                                        encoding="utf-8")
            except (OSError, ValueError, RuntimeError):
                pass  # The original diagnostic and nonzero exit remain authoritative.
        return 2


if __name__ == "__main__":
    sys.exit(main())
