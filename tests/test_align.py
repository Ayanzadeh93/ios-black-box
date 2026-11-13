"""Regression checks for trace integrity, clock semantics and evidence links."""
import csv
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills/ios-black-box/scripts/align.py"
SPEC = importlib.util.spec_from_file_location("align", SCRIPT)
ALIGN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ALIGN)


class AlignTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.sidecar = self.directory / "session.json"
        self.trace = self.directory / "events.jsonl"
        self.output = self.directory / "timeline.csv"
        self.write_clock()

    def write_clock(self, **updates):
        clock = dict(clock="systemUptime", startUptime=100, stopUptime=110, video="session.mp4")
        clock.update(updates)
        self.sidecar.write_text(json.dumps(clock))

    def run_align(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.sidecar), str(self.trace),
                               "--out", str(self.output), *args], capture_output=True, text=True)

    def test_preserves_outside_events_and_source_lines(self):
        self.trace.write_text('\n{"t": 112, "type": "late"}\n{"t": 99, "type": "early"}\n'
                              '{"t": 102, "type": "first", "text": "comma, newline\\nvalue"}\n'
                              '{"t": 102, "type": "second"}\n')
        result = self.run_align()
        self.assertEqual(result.returncode, 0, result.stderr)
        with self.output.open(newline="") as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual([row["type"] for row in rows], ["early", "first", "second", "late"])
        self.assertEqual([row["in_video"] for row in rows], ["0", "1", "1", "0"])
        self.assertEqual(rows[1]["source_line"], "4")
        self.assertEqual(rows[1]["source"], str(self.trace))
        self.assertIn("approximate", result.stderr)
        self.assertIn("comma, newline\nvalue", rows[1]["summary"])

    def test_invalid_rows_fail_without_creating_output(self):
        invalid_rows = ['not json', '[]', 'null', '{"t": true}', '{"t": NaN}',
                        '{"t": Infinity}', '{"t": "102"}', '{"t": -1}',
                        '{"type": "missing time"}', '{"t": 102, "type": {}}',
                        '{"t": ' + '9' * 400 + '}']
        for row in invalid_rows:
            with self.subTest(row=row):
                self.trace.write_text('{"t": 101}\n' + row + '\n')
                result = self.run_align()
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"{self.trace}:2:", result.stderr)
                self.assertFalse(self.output.exists())

    def test_partial_output_requires_explicit_opt_in(self):
        self.trace.write_text('{"t": 101}\ninvalid\n')
        result = self.run_align("--skip-invalid")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("1 skipped", result.stderr)
        self.assertIn("skipped", result.stderr)
        self.assertTrue(self.output.exists())

    def test_rejects_invalid_clock_and_preserves_old_output(self):
        self.trace.write_text('{"t": 101}\n')
        self.output.write_text("old result")
        for fields in [dict(clock="unix"), dict(startUptime=True), dict(stopUptime=99),
                       dict(startUptime=float("nan")), dict(stopUptime=float("inf")),
                       dict(startUptime=-1)]:
            with self.subTest(fields=fields):
                self.write_clock(**fields)
                result = self.run_align()
                self.assertEqual(result.returncode, 1)
                self.assertEqual(self.output.read_text(), "old result")

    def test_empty_trace_is_not_a_successful_timeline(self):
        self.trace.write_text("\n")
        result = self.run_align()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.output.exists())

    def test_custom_timestamp_field_and_legacy_sidecar(self):
        self.sidecar.write_text('{"startUptime":100,"stopUptime":110}')
        self.trace.write_text('{"uptime":101,"event":"request.end"}\n')
        result = self.run_align("--field", "uptime")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("request.end", self.output.read_text())

    def test_input_cannot_be_overwritten(self):
        self.trace.write_text('{"t": 101}\n')
        before = self.trace.read_text()
        result = self.run_align("--out", str(self.trace))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.trace.read_text(), before)

    def test_scalar_sidecar_reports_clean_error(self):
        self.sidecar.write_text('[]')
        self.trace.write_text('{"t": 101}\n')
        result = self.run_align()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
