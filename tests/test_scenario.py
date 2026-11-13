import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "skills/ios-field-testing/scripts/scenario.py"
SPEC = importlib.util.spec_from_file_location("scenario", SCRIPT)
scenario = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(scenario)


def events(*middle, end=True):
    rows = [{"type": "scenario.start", "t": 100, "scenario_id": "commerce-task"}]
    rows.extend({"type": "checkout.completed", "t": 101 + i, "scenario_id": "commerce-task", **extra}
                for i, extra in enumerate(middle))
    if end:
        rows.append({"type": "scenario.end", "t": 110, "scenario_id": "commerce-task"})
    return list(enumerate(rows, 1))


class ScenarioTests(unittest.TestCase):
    def setUp(self):
        self.plan = scenario.new_plan("commerce")

    def run_plan(self, rows):
        return scenario.evaluate(scenario.validate(self.plan), rows, "run.jsonl")

    def test_profiles_are_valid(self):
        for profile in scenario.PROFILES:
            with self.subTest(profile=profile):
                scenario.validate(scenario.new_plan(profile))

    def test_complete_task_passes_with_source_evidence(self):
        result = self.run_plan(events({}))
        self.assertEqual(result["status"], "pass")
        self.assertEqual(result["criteria"][0]["evidence"][0]["line"], 2)

    def test_duplicate_completion_fails_exactly_once_check(self):
        self.assertEqual(self.run_plan(events({}, {}))["status"], "fail")

    def test_truncated_capture_does_not_pass(self):
        result = self.run_plan(events({}, end=False))
        self.assertEqual(result["status"], "inconclusive")
        self.assertFalse(result["coverage"]["complete"])

    def test_empty_capture_and_missing_outcome_inconclusive(self):
        for rows in ([], events()):
            self.assertEqual(self.run_plan(rows)["status"], "inconclusive")

    def test_declared_absence_needs_complete_window(self):
        self.plan["acceptance"][0].update(event="checkout.duplicate", target=0, minSamples=0)
        self.assertEqual(self.run_plan(events({}))["status"], "pass")
        self.assertEqual(self.run_plan(events({}, end=False))["status"], "inconclusive")

    def test_other_scenario_is_excluded(self):
        self.assertEqual(self.run_plan(events({}, {"scenario_id": "other"}))["status"], "pass")

    def test_backward_clock_or_duplicate_boundaries_inconclusive(self):
        backwards = events({"t": 90})
        duplicate = events({})
        duplicate.insert(1, (1, dict(duplicate[0][1])))
        for rows in (backwards, duplicate):
            self.assertEqual(self.run_plan(rows)["status"], "inconclusive")

    def test_metrics_and_missing_numeric_values(self):
        check = self.plan["acceptance"][0]
        check.update(metric="p95", field="latency_ms", op="<=", target=200)
        result = self.run_plan(events({"latency_ms": 80}, {"latency_ms": 250}))
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["criteria"][0]["value"], 250)
        self.assertEqual(self.run_plan(events({}))["status"], "inconclusive")
        self.assertEqual(scenario.metric_value("median", [1, 4, 9, 2]), 3)

    def test_filters_distinguish_booleans_from_numbers(self):
        self.plan["acceptance"][0]["where"] = {"verified": True}
        self.assertEqual(self.run_plan(events({"verified": 1}))["status"], "inconclusive")
        self.assertEqual(self.run_plan(events({"verified": True}))["status"], "pass")

    def test_malformed_events_are_rejected_with_line(self):
        for content in ('[]', '{"t":NaN}', '{"type":"x","t":true,"scenario_id":"x"}',
                        '{"type":"x","t":1,"scenario_id":"x","t":2}', '{'):
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, "line 1"):
                scenario.read_events(content.encode())

    def test_invalid_schema_and_misspelled_checks_rejected(self):
        for change in ({"metric": "average"}, {"minSamples": True}, {"minSample": 100},
                       {"target": float("inf")}, {"field": "ignored"}, {"target": -1}):
            with self.subTest(change=change):
                plan = scenario.new_plan("commerce")
                plan["acceptance"][0].update(change)
                with self.assertRaises(ValueError):
                    scenario.validate(plan)

    def test_cli_exit_codes_provenance_and_overwrite_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plan, trace, output = root / "scenario.json", root / "events.jsonl", root / "result.json"
            command = [sys.executable, str(SCRIPT)]
            created = subprocess.run(command + ["init", str(plan), "--profile", "commerce"], capture_output=True)
            self.assertEqual(created.returncode, 0, created.stderr)
            self.assertEqual(subprocess.run(command + ["init", str(plan)], capture_output=True).returncode, 2)
            for rows, expected in ((events({}), 0), (events({}, {}), 1), (events({}, end=False), 2)):
                trace.write_text("\n".join(json.dumps(row) for _, row in rows) + "\n")
                run = subprocess.run(command + ["evaluate", str(plan), str(trace), "--out", str(output)], capture_output=True)
                self.assertEqual(run.returncode, expected, run.stderr)
                report = json.loads(output.read_text())
                self.assertEqual(len(report["inputs"]["eventsSha256"]), 64)
            original = plan.read_bytes()
            blocked = subprocess.run(command + ["evaluate", str(plan), str(trace), "--out", str(plan)], capture_output=True)
            self.assertEqual(blocked.returncode, 2)
            self.assertEqual(plan.read_bytes(), original)
            output.write_text('{"status":"pass"}')
            trace.write_text('broken JSON\n')
            invalid = subprocess.run(command + ["evaluate", str(plan), str(trace), "--out", str(output)], capture_output=True)
            self.assertEqual(invalid.returncode, 2)
            self.assertEqual(json.loads(output.read_text())["status"], "inconclusive")
            self.assertIn("error", json.loads(output.read_text()))


if __name__ == "__main__":
    unittest.main()
