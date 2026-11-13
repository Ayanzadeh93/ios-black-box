#!/usr/bin/env python3
"""Map app events to an approximate ReplayKit video clock, preserving evidence.

Trace timestamps must use the same device/boot and systemUptime seconds as the
sidecar. ReplayKit's start-completion callback is not the first media sample;
this mapping cannot establish sample-accurate audio/video synchronization.
"""
import argparse
import csv
import json
import math
from pathlib import Path
import sys

SKIP = {"type", "kind", "event"}


def finite_number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def summary(row, field):
    parts = []
    for key in ("text", "outcome", "reason", "severity", "pattern", "message", "name"):
        if key in row and row[key] not in (None, ""):
            parts.append(f"{key}={row[key]}")
    if not parts:
        parts = [f"{key}={value}" for key, value in row.items()
                 if key not in SKIP and key != field and not isinstance(value, (dict, list))][:4]
    return " ".join(parts)[:160]


def load_rows(sidecar, traces, field, skip_invalid=False):
    with open(sidecar, encoding="utf-8") as handle:
        clock = json.load(handle)
    if not isinstance(clock, dict):
        raise ValueError("sidecar must be a JSON object")
    if clock.get("clock", "systemUptime") != "systemUptime":
        raise ValueError("sidecar clock must be systemUptime seconds")
    start, stop = clock.get("startUptime"), clock.get("stopUptime")
    if not finite_number(start) or not finite_number(stop) or start < 0 or stop < start:
        raise ValueError("sidecar requires finite startUptime <= stopUptime, both >= 0")
    rows, problems = [], []
    for path in traces:
        with open(path, encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                    if not isinstance(event, dict):
                        raise ValueError("event must be a JSON object")
                    timestamp = event.get(field)
                    if not finite_number(timestamp) or timestamp < 0:
                        raise ValueError(f"{field!r} must be finite systemUptime seconds >= 0")
                    kind = next((event[key] for key in ("type", "kind", "event")
                                 if event.get(key) not in (None, "")), "event")
                    if not isinstance(kind, str):
                        raise ValueError("event type/kind/event must be a string")
                    rows.append((timestamp - start, int(start <= timestamp <= stop), kind,
                                 summary(event, field), str(path), line_number))
                except (ValueError, TypeError) as error:
                    problems.append(f"{path}:{line_number}: {error}")
    if problems and not skip_invalid:
        detail = "\n".join(problems[:20])
        raise ValueError(f"invalid trace rows ({len(problems)}); no timeline written:\n{detail}")
    for problem in problems[:20]:
        print(f"warning: skipped {problem}", file=sys.stderr)
    if len(problems) > 20:
        print(f"warning: {len(problems) - 20} additional invalid rows skipped", file=sys.stderr)
    if not rows:
        raise ValueError("no valid timestamped events found; no timeline written")
    # Preserve input order for equal timestamps, rather than sorting by event text.
    rows.sort(key=lambda row: row[0])
    return clock, rows, len(problems)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sidecar")
    parser.add_argument("traces", nargs="+")
    parser.add_argument("--field", default="t")
    parser.add_argument("--out", default="-")
    parser.add_argument("--skip-invalid", action="store_true",
                        help="explicitly allow partial timelines; skipped rows are reported")
    args = parser.parse_args(argv)
    try:
        if args.out != "-":
            output = Path(args.out).resolve()
            if output in {Path(path).resolve() for path in [args.sidecar] + args.traces}:
                raise ValueError("output must not overwrite a sidecar or trace")
        clock, rows, skipped = load_rows(args.sidecar, args.traces, args.field, args.skip_invalid)
        out = sys.stdout if args.out == "-" else open(args.out, "w", newline="", encoding="utf-8")
        try:
            writer = csv.writer(out)
            writer.writerow(["video_s", "in_video", "type", "summary", "source", "source_line"])
            for video_s, inside, kind, text, source, line in rows:
                writer.writerow([f"{video_s:.3f}", inside, kind, text, source, line])
        finally:
            if out is not sys.stdout:
                out.close()
        inside = sum(row[1] for row in rows)
        print(f"aligned {inside}/{len(rows)} events ({skipped} skipped) onto "
              f"{clock.get('video', 'video')} ({clock['stopUptime'] - clock['startUptime']:.1f}s)",
              file=sys.stderr)
        print("warning: video_s uses an approximate ReplayKit callback anchor; verify visual/audio "
              "markers before making subsecond timing claims", file=sys.stderr)
        return 0
    except (OSError, ValueError, TypeError) as error:
        print(f"align: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
