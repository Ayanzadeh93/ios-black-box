"""Host command tests with fake USB tools and generated, nonprivate media."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "skills/ios-black-box/scripts/session.sh"


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="blackbox test ")
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        self.env.update(PATH=str(self.bin) + os.pathsep + self.env["PATH"],
                        DEVICE="test-device", BUNDLE="com.example.test")
        self.env.pop("LAUNCH_ARGS", None)
        self.env.pop("LOGS", None)
        self.log = self.directory / "arguments.json"
        self.env["MOCK_LOG"] = str(self.log)

    def mock(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    def run_session(self, *args, **kwargs):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                               cwd=self.directory, capture_output=True, text=True, **kwargs)

    def fixture(self, video="session.mp4"):
        recordings = self.directory / "recordings"
        traces = self.directory / "traces"
        recordings.mkdir(exist_ok=True)
        traces.mkdir(exist_ok=True)
        (recordings / video).touch()
        (recordings / video).with_suffix(".json").write_text(
            json.dumps(dict(clock="systemUptime", startUptime=100, stopUptime=110)))
        (traces / "events.jsonl").write_text('{"t":101,"type":"request.end"}\n')
        return recordings / video

    def test_duration_rejected_before_launch(self):
        self.mock("xcrun", 'raise RuntimeError("must not launch")\n')
        for value in ["0", "-1", "nan", "1.5", "3601", "999999999999999999999"]:
            with self.subTest(value=value):
                result = self.run_session("start", value)
                self.assertEqual(result.returncode, 1)
                self.assertIn("seconds must", result.stderr)
                self.assertNotIn("must not launch", result.stderr)

    def test_launch_keeps_literal_extra_arguments(self):
        self.mock("xcrun", 'import json,os,sys\nopen(os.environ["MOCK_LOG"],"w").write(json.dumps(sys.argv[1:]))\n')
        result = self.run_session("start", "30", "--", "-scenario", "checkout retry", "$(touch bad)")
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(self.log.read_text())
        self.assertEqual(arguments[-3:], ["-scenario", "checkout retry", "$(touch bad)"])
        self.assertFalse((self.directory / "bad").exists())
        self.assertIn("launched", result.stdout)

    def test_required_pull_failure_is_visible(self):
        self.mock("xcrun", 'import sys\nprint("USB disconnected",file=sys.stderr)\nsys.exit(3)\n')
        result = self.run_session("pull")
        self.assertEqual(result.returncode, 1)
        self.assertIn("USB disconnected", result.stderr)
        self.assertIn("recordings copy failed", result.stderr)

    def test_multiple_videos_require_explicit_choice(self):
        self.fixture("first.mp4")
        self.fixture("second.mp4")
        result = self.run_session("analyze", str(self.directory))
        self.assertEqual(result.returncode, 1)
        self.assertIn("multiple videos", result.stderr)
        self.assertFalse((self.directory / "timeline.csv").exists())

    def test_invalid_trace_cannot_be_reported_as_analyzed(self):
        self.fixture()
        (self.directory / "traces/events.jsonl").write_text('bad json\n')
        result = self.run_session("analyze", str(self.directory))
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("analyzed", result.stdout)
        self.assertFalse((self.directory / "report.txt").exists())

    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg unavailable")
    def test_offline_analysis_of_silent_video_needs_no_device(self):
        video = self.fixture()
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "color=c=blue:s=160x120:r=10", "-t", "1",
                        "-c:v", "mpeg4", str(video)], check=True, capture_output=True)
        self.env.pop("DEVICE")
        self.env.pop("BUNDLE")
        result = self.run_session("analyze", str(self.directory))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no audio stream", (self.directory / "report.txt").read_text())
        self.assertTrue((self.directory / "contact.jpg").stat().st_size > 0)
        self.assertIn("source_line", (self.directory / "timeline.csv").read_text())


    @unittest.skipUnless(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg unavailable")
    def test_selected_video_has_distinct_outputs_and_audio_signal_metrics(self):
        self.fixture("other.mp4")
        video = self.fixture("selected.mp4")
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "color=c=red:s=160x120:r=10",
                        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                        "-t", "1", "-c:v", "mpeg4", "-c:a", "aac", str(video)],
                       check=True, capture_output=True)
        result = self.run_session("analyze", str(self.directory), "selected.mp4")
        self.assertEqual(result.returncode, 0, result.stderr)
        report = (self.directory / "selected-report.txt").read_text()
        self.assertIn("mean_volume:", report)
        self.assertIn("do not detect speech", report)
        self.assertTrue((self.directory / "selected-contact.jpg").stat().st_size > 0)
        self.assertTrue((self.directory / "selected-timeline.csv").is_file())
        self.assertFalse((self.directory / "timeline.csv").exists())

    def test_help_and_doctor_do_not_require_device_environment(self):
        self.env.pop("DEVICE")
        self.env.pop("BUNDLE")
        result = self.run_session("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("analyze", result.stdout)
        result = self.run_session("doctor")
        self.assertIn("DEVICE: unset", result.stdout)
        self.assertNotIn("set DEVICE", result.stderr)


if __name__ == "__main__":
    unittest.main()
