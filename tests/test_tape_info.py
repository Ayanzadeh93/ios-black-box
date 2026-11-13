"""Behavioral checks for malformed field recordings and portable inspection."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills/ios-sensor-tape/scripts/tape_info.py"
SHELL = ROOT / "skills/ios-sensor-tape/scripts/tape.sh"
SPEC = importlib.util.spec_from_file_location("tape_info", SCRIPT)
tape_info = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tape_info)


class TapeInfoTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.tape = Path(self.temporary.name) / "tape-test"
        self.tape.mkdir()
        (self.tape / "frames").mkdir()
        (self.tape / "depth").mkdir()
        self.meta = {"schema": 1, "clock": "systemUptime", "startUptime": 100,
                     "stopUptime": 110, "frames": 0, "depthMaps": 0}
        self.rows = [{"t": 101, "kind": "event", "name": "scan.completed"}]
        self.save()

    def save(self):
        (self.tape / "meta.json").write_text(json.dumps(self.meta), encoding="utf-8")
        (self.tape / "index.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in self.rows), encoding="utf-8")

    def inspect(self, complete=True):
        self.save()
        return tape_info.inspect_tape(self.tape, require_complete=complete)

    def frame(self, t=101, name="frames/000001.jpg"):
        # Existence is the portable check. Decode verification belongs to Swift
        # tests; deliberately do not call these arbitrary bytes a valid image.
        (self.tape / name).write_bytes(b"image bytes requiring replay decode")
        return {"t": t, "kind": "frame", "file": name, "w": 320, "h": 240}

    def assertInvalid(self, substring):
        report = self.inspect()
        self.assertFalse(report["valid"], report)
        self.assertTrue(any(substring in error for error in report["errors"]), report)

    def test_event_only_recording_is_not_empty(self):
        report = self.inspect()
        self.assertTrue(report["valid"], report)
        self.assertEqual(report["sample_count"], 1)
        self.assertEqual(report["sample_duration_s"], 0)
        self.assertEqual(report["capture_duration_s"], 10)
        self.assertIsNone(report["frame_fps"])

    def test_imu_only_recording_is_valid(self):
        self.rows = [{"kind": "imu", "t": 102, "q": [1, 0, 0, 0],
                      "rot": [0, 0, 0], "acc": [0, 0, 0], "grav": [0, 0, -1]}]
        self.assertTrue(self.inspect()["valid"])

    def test_missing_or_empty_recording_fails_strict_validation(self):
        self.rows = []
        self.assertInvalid("no timestamped samples")
        self.assertTrue(self.inspect(complete=False)["valid"])
        self.rows = [{"kind": "event", "t": 101, "name": "started"}]
        del self.meta["stopUptime"]
        self.assertInvalid("not finalized")
        self.assertTrue(self.inspect(complete=False)["valid"])

    def test_malformed_rows_keep_line_evidence(self):
        self.save()
        with (self.tape / "index.jsonl").open("a") as handle:
            handle.write('{"kind": "frame",\n')
        report = tape_info.inspect_tape(self.tape, require_complete=True)
        self.assertFalse(report["valid"])
        self.assertIn("index.jsonl:2: malformed JSON", report["errors"][0])

    def test_non_object_or_unknown_kind_is_rejected(self):
        for row in ([], {"kind": "gps", "t": 102}, {"kind": [], "t": 102}):
            with self.subTest(row=row):
                self.rows = [row]
                self.assertFalse(self.inspect()["valid"])

    def test_nonfinite_bool_and_negative_timestamp_is_rejected(self):
        for value in (True, -1, 10 ** 400):
            with self.subTest(value=value):
                self.rows[0]["t"] = value
                self.assertInvalid("finite and nonnegative")

    def test_nonfinite_constants_and_duplicate_keys_anywhere_are_rejected(self):
        for text in ('{"kind":"event","t":101,"name":"sample","payload":{"score":NaN}}',
                     '{"kind":"event","t":101,"name":"sample","payload":{"score":Infinity}}',
                     '{"kind":"event","t":101,"t":102,"name":"sample"}'):
            with self.subTest(text=text):
                (self.tape / "index.jsonl").write_text(text + "\n", encoding="utf-8")
                report = tape_info.inspect_tape(self.tape, require_complete=True)
                self.assertFalse(report["valid"])
                self.assertTrue(any("malformed JSON" in error for error in report["errors"]))
        self.save()
        (self.tape / "meta.json").write_text(
            '{"schema":1,"clock":"systemUptime","startUptime":100,"custom":{"x":NaN}}',
            encoding="utf-8")
        self.assertFalse(tape_info.inspect_tape(self.tape)["valid"])

    def test_missing_asset_dimensions_and_counter_mismatch(self):
        self.rows = [self.frame()]
        self.meta["frames"] = 1
        self.assertTrue(self.inspect()["valid"])
        (self.tape / "frames/000001.jpg").unlink()
        self.assertInvalid("missing or empty asset")
        self.rows = [self.frame()]
        self.rows[0]["w"] = True
        self.assertInvalid("w must be a positive integer")
        self.rows[0]["w"] = 320
        self.meta["frames"] = 2
        self.assertInvalid("index contains 1")

    def test_paths_cannot_escape_through_traversal_or_symlink(self):
        self.rows = [{"kind": "frame", "t": 102, "file": "../outside.jpg", "w": 1, "h": 1}]
        self.meta["frames"] = 1
        self.assertInvalid("escapes tape")
        outside = Path(self.temporary.name) / "outside.jpg"
        outside.write_bytes(b"secret")
        (self.tape / "frames/link.jpg").symlink_to(outside)
        self.rows[0]["file"] = "frames/link.jpg"
        self.assertInvalid("symlink escapes")

    def test_unresolvable_asset_paths_report_errors(self):
        self.rows = [{"kind": "frame", "t": 102, "file": "frames/\u0000.jpg", "w": 1, "h": 1}]
        self.meta["frames"] = 1
        self.assertInvalid("cannot resolve asset path")
        link = self.tape / "frames/loop.jpg"
        link.symlink_to(link)
        self.rows[0]["file"] = "frames/loop.jpg"
        self.assertInvalid("cannot resolve asset path")

    def test_stream_regression_fails_but_interleaved_arrival_order_warns(self):
        self.rows = [self.frame(t=103), {"t": 102, "kind": "event", "name": "observed"}]
        self.meta["frames"] = 1
        report = self.inspect()
        self.assertTrue(report["valid"], report)
        self.assertTrue(any("arrival-order" in warning for warning in report["warnings"]))
        self.rows.append(self.frame(t=101, name="frames/000002.jpg"))
        self.meta["frames"] = 2
        self.assertInvalid("frame timestamps must strictly increase")
        self.rows[-1]["t"] = 103
        self.assertInvalid("frame timestamps must strictly increase")

    def test_frame_rate_uses_frame_span_not_unrelated_events(self):
        self.rows = [self.frame(t=102), self.frame(t=104, name="frames/000002.jpg"),
                     {"t": 1000, "kind": "event", "name": "late"}]
        self.meta["frames"] = 2
        report = self.inspect()
        self.assertEqual(report["frame_fps"], 0.5)

    def test_depth_shape_and_raw_byte_size(self):
        row = self.frame()
        row.update(depth="depth/000001.f32", dw=2, dh=2)
        self.rows = [row]
        self.meta.update(frames=1, depthMaps=1)
        (self.tape / row["depth"]).write_bytes(bytes(15))
        self.assertInvalid("raw depth size must be 16")
        (self.tape / row["depth"]).write_bytes(bytes(16))
        report = self.inspect()
        self.assertTrue(report["valid"], report)
        self.assertEqual(report["depth_expected_raw_bytes"], 16)
        self.assertEqual(report["checks"]["lzfse_decode_and_raw_size"], "not performed")
        row["dw"] = 0
        self.assertInvalid("dw and dh must be positive integers")

    def test_schema_clock_and_failed_recording(self):
        self.meta["clock"] = "wall"
        self.assertInvalid("unsupported clock")
        self.meta["clock"] = "systemUptime"
        self.meta["state"] = "failed"
        self.assertInvalid("recorder state is failed")
        self.meta["state"] = "complete"
        self.meta["schema"] = 2
        self.assertInvalid("unsupported schema")

    def test_invalid_imu_and_event_schema(self):
        self.rows[0]["name"] = ""
        self.assertInvalid("event name")
        self.rows = [{"kind": "imu", "t": 102, "q": [1, 0, 0, 0],
                      "rot": [0, 0, 0], "acc": [0, 0, 0], "grav": [0, 0, "nan"]}]
        self.assertInvalid("grav must contain 3 finite numbers")

    def test_json_cli_and_shell_wrapper_have_usable_exit_codes(self):
        process = subprocess.run([sys.executable, str(SCRIPT), str(self.tape), "--validate", "--json"],
                                 capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(json.loads(process.stdout)["valid"])
        self.rows = []
        self.save()
        process = subprocess.run(["bash", str(SHELL), "validate", str(self.tape), "--json"],
                                 capture_output=True, text=True)
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertFalse(json.loads(process.stdout)["valid"])

    def test_shell_rejects_bad_start_numbers_before_needing_device(self):
        environment = os.environ.copy()
        environment.pop("DEVICE", None)
        environment.pop("BUNDLE", None)
        for number in ("nan", "0", "-2", "bad", "inf", "86401"):
            with self.subTest(number=number):
                process = subprocess.run(["bash", str(SHELL), "start", number, "5"],
                                         capture_output=True, text=True, env=environment)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("finite positive numbers", process.stderr)

    def test_shell_rejects_unsupported_capture_rate(self):
        process = subprocess.run(["bash", str(SHELL), "start", "30", "241"],
                                 capture_output=True, text=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("fps <= 240", process.stderr)

    def test_shell_preserves_explicit_launch_arguments_without_execution(self):
        fake_bin = Path(self.temporary.name) / "bin"
        fake_bin.mkdir()
        argument_file = Path(self.temporary.name) / "args.json"
        fake_xcrun = fake_bin / "xcrun"
        fake_xcrun.write_text(
            '#!/usr/bin/env python3\nimport json, os, sys\n'
            'if sys.argv[1:2] == ["--find"]:\n    sys.exit(0)\n'
            'with open(os.environ["TAPE_TEST_ARGUMENT_FILE"], "w") as handle:\n'
            '    json.dump(sys.argv[1:], handle)\n', encoding="utf-8")
        fake_xcrun.chmod(0o755)
        environment = os.environ.copy()
        environment.update(PATH=str(fake_bin) + os.pathsep + environment["PATH"],
                           DEVICE="test-device", BUNDLE="com.example.app",
                           LAUNCH_ARGS="-trace YES", TAPE_TEST_ARGUMENT_FILE=str(argument_file))
        literal = "$(touch SHOULD_NOT_EXIST)"
        process = subprocess.run(["bash", str(SHELL), "start", "30", "5", "--",
                                  "-scenario", "checkout with spaces", "-literal", literal],
                                 capture_output=True, text=True, env=environment,
                                 cwd=self.temporary.name)
        self.assertEqual(process.returncode, 0, process.stderr)
        arguments = json.loads(argument_file.read_text())
        self.assertEqual(arguments[-6:], ["-trace", "YES", "-scenario", "checkout with spaces",
                                         "-literal", literal])
        self.assertFalse((Path(self.temporary.name) / "SHOULD_NOT_EXIST").exists())


if __name__ == "__main__":
    unittest.main()
