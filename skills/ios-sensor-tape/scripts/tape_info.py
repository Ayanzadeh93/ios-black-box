#!/usr/bin/env python3
"""Inspect a sensor tape without requiring Apple frameworks or Python packages.

Default: concise summary. --json: structured report. --validate: additionally
require a finalized, nonempty recording. Media decoding remains a replay check.
"""
import argparse
from collections import Counter
import json
import math
from pathlib import Path
import sys


def finite_number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def positive_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def strict_json(text):
    def reject_constant(value):
        raise ValueError(f"nonfinite JSON constant {value}")

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key {key!r}")
            result[key] = value
        return result

    return json.loads(text, parse_constant=reject_constant, object_pairs_hook=unique_object)


def inspect_tape(directory, require_complete=False):
    """Return evidence and errors; invalid rows never silently disappear."""
    root = Path(directory).resolve()
    errors, warnings = [], []
    result = {"tape": str(root), "valid": False, "finalized": False,
              "sample_count": 0, "counts": {}, "sample_duration_s": 0.0,
              "capture_duration_s": None, "frame_fps": None, "bytes": 0,
              "depth_maps": 0, "depth_expected_raw_bytes": 0,
              "checks": {"asset_files": "existence and nonempty bytes",
                         "image_decode": "not performed",
                         "lzfse_decode_and_raw_size": "not performed"},
              "errors": errors, "warnings": warnings}
    if not root.is_dir():
        errors.append("tape directory does not exist")
        return result
    try:
        meta = strict_json((root / "meta.json").read_text(encoding="utf-8"))
        if not isinstance(meta, dict):
            raise ValueError("expected a JSON object")
    except (OSError, UnicodeError, ValueError) as exc:
        errors.append(f"meta.json: {exc}")
        meta = None
    if meta is not None:
        if type(meta.get("schema")) is not int or meta["schema"] != 1:
            errors.append("meta.json: unsupported schema (expected 1)")
        if meta.get("clock") != "systemUptime":
            errors.append("meta.json: unsupported clock (expected systemUptime)")
        start, stop = meta.get("startUptime"), meta.get("stopUptime")
        if not finite_number(start) or start < 0:
            errors.append("meta.json: startUptime must be finite and nonnegative")
        if stop is not None:
            if not finite_number(stop) or stop < 0:
                errors.append("meta.json: stopUptime must be finite and nonnegative")
            elif finite_number(start):
                if stop < start:
                    errors.append("meta.json: stopUptime precedes startUptime")
                else:
                    result["capture_duration_s"] = stop - start
                    result["finalized"] = True
        if not result["finalized"]:
            (errors if require_complete else warnings).append(
                "meta.json: recording is not finalized (no valid stopUptime)")
        if meta.get("state") == "failed":
            errors.append("meta.json: recorder state is failed")
        elif meta.get("state") not in (None, "recording", "complete"):
            errors.append("meta.json: unsupported recorder state")
        elif require_complete and meta.get("state") == "recording":
            errors.append("meta.json: recorder state is still recording")
        for key in ("fps", "maxSeconds", "scale"):
            if key in meta and (not finite_number(meta[key]) or meta[key] <= 0):
                errors.append(f"meta.json: {key} must be finite and positive")
        for key in ("firstFrameUptime", "durationSeconds"):
            if key in meta and (not finite_number(meta[key]) or meta[key] < 0):
                errors.append(f"meta.json: {key} must be finite and nonnegative")
        if finite_number(meta.get("scale")) and meta["scale"] > 1:
            errors.append("meta.json: scale must not exceed 1")
        for key in ("frames", "depthMaps"):
            if key in meta and (not isinstance(meta[key], int)
                                or isinstance(meta[key], bool) or meta[key] < 0):
                errors.append(f"meta.json: {key} must be a nonnegative integer")

    def asset_path(value, label):
        if not isinstance(value, str) or not value or "\\" in value:
            errors.append(f"{label}: expected a relative asset path")
            return None
        relative = Path(value)
        if relative.is_absolute() or ".." in relative.parts:
            errors.append(f"{label}: asset path escapes tape directory")
            return None
        try:
            candidate = (root / relative).resolve()
        except (OSError, RuntimeError, ValueError) as exc:
            errors.append(f"{label}: cannot resolve asset path: {exc}")
            return None
        try:
            candidate.relative_to(root)
        except ValueError:
            errors.append(f"{label}: asset symlink escapes tape directory")
            return None
        try:
            if not candidate.is_file() or candidate.stat().st_size == 0:
                errors.append(f"{label}: missing or empty asset {value}")
                return None
        except OSError as exc:
            errors.append(f"{label}: cannot inspect asset {value}: {exc}")
            return None
        return candidate

    counts, last_by_stream = Counter(), {}
    timestamps, frame_timestamps = [], []
    previous_arrival_t, arrival_disorder = None, 0
    try:
        with (root / "index.jsonl").open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                label = f"index.jsonl:{line_number}"
                try:
                    row = strict_json(line)
                except ValueError as exc:
                    errors.append(f"{label}: malformed JSON: {exc}")
                    continue
                if not isinstance(row, dict):
                    errors.append(f"{label}: expected a JSON object")
                    continue
                t, kind = row.get("t"), row.get("kind")
                if kind not in ("frame", "imu", "event"):
                    errors.append(f"{label}: unsupported sample kind {kind!r}")
                    continue
                counts[kind] += 1
                if not finite_number(t) or t < 0:
                    errors.append(f"{label}: t must be finite and nonnegative")
                else:
                    timestamps.append(t)
                    if previous_arrival_t is not None and t < previous_arrival_t:
                        arrival_disorder += 1
                    previous_arrival_t = t
                    if kind in ("frame", "imu"):
                        if kind in last_by_stream and t <= last_by_stream[kind]:
                            errors.append(f"{label}: {kind} timestamps must strictly increase")
                        last_by_stream[kind] = t
                    if kind == "frame":
                        frame_timestamps.append(t)
                if kind == "frame":
                    asset_path(row.get("file"), f"{label}.file")
                    for key in ("w", "h"):
                        if not positive_integer(row.get(key)):
                            errors.append(f"{label}: {key} must be a positive integer")
                    if any(key in row for key in ("depth", "dw", "dh")):
                        result["depth_maps"] += 1
                        depth_file = asset_path(row.get("depth"), f"{label}.depth")
                        if not positive_integer(row.get("dw")) or not positive_integer(row.get("dh")):
                            errors.append(f"{label}: dw and dh must be positive integers")
                        else:
                            expected = row["dw"] * row["dh"] * 4
                            result["depth_expected_raw_bytes"] += expected
                            if depth_file and depth_file.suffix == ".f32":
                                if depth_file.stat().st_size != expected:
                                    errors.append(f"{label}: raw depth size must be {expected} bytes")
                                warnings.append(f"{label}: raw .f32 depth needs an adapter; TapePlayer expects LZFSE")
                elif kind == "imu":
                    for key, length in (("q", 4), ("rot", 3), ("acc", 3), ("grav", 3)):
                        vector = row.get(key)
                        if (not isinstance(vector, list) or len(vector) != length
                                or not all(finite_number(value) for value in vector)):
                            errors.append(f"{label}: {key} must contain {length} finite numbers")
                elif not isinstance(row.get("name"), str) or not row["name"].strip():
                    errors.append(f"{label}: event name must be a nonempty string")
    except (OSError, UnicodeError) as exc:
        errors.append(f"index.jsonl: {exc}")

    result["counts"] = dict(counts)
    result["sample_count"] = sum(counts.values())
    if timestamps:
        result["sample_duration_s"] = max(timestamps) - min(timestamps)
        result["first_sample_uptime"] = min(timestamps)
        result["last_sample_uptime"] = max(timestamps)
    else:
        (errors if require_complete else warnings).append("index.jsonl: no timestamped samples")
    if len(frame_timestamps) >= 2:
        frame_span = max(frame_timestamps) - min(frame_timestamps)
        if frame_span > 0:
            rate = (len(frame_timestamps) - 1) / frame_span
            if math.isfinite(rate):
                result["frame_fps"] = rate
            else:
                errors.append("index.jsonl: frame timestamps imply a nonfinite rate")
    if arrival_disorder:
        warnings.append(f"{arrival_disorder} arrival-order timestamp decreases; replay must stable-sort by t")
    if meta is not None:
        for key, actual in (("frames", counts["frame"]), ("depthMaps", result["depth_maps"])):
            if key in meta and meta[key] != actual:
                errors.append(f"meta.json: {key}={meta[key]!r}, index contains {actual}")
        if meta.get("writeErrors") or meta.get("lastError"):
            errors.append("meta.json: recorder reported write errors; inspect writeErrors/lastError")
        if timestamps and finite_number(meta.get("startUptime")):
            if min(timestamps) < meta["startUptime"]:
                warnings.append("samples precede recorder start; confirm sensor timestamps use systemUptime")
        if timestamps and finite_number(meta.get("stopUptime")):
            if max(timestamps) > meta["stopUptime"]:
                warnings.append("samples follow recorder stop; confirm event timestamps and clock")
    try:
        for path in root.rglob("*"):
            if path.is_file() and not path.is_symlink():
                result["bytes"] += path.stat().st_size
    except OSError as exc:
        warnings.append(f"could not measure all tape files: {exc}")
    result["valid"] = not errors
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tape", help="directory containing meta.json and index.jsonl")
    parser.add_argument("--json", action="store_true", help="write a structured JSON report")
    parser.add_argument("--validate", action="store_true", help="also require a finalized, nonempty tape")
    args = parser.parse_args(argv)
    report = inspect_tape(args.tape, require_complete=args.validate)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True, allow_nan=False))
    else:
        counts, fps = report["counts"], report["frame_fps"]
        rate = f"{fps:.1f} fps" if fps is not None else "fps unavailable"
        state = "finalized" if report["finalized"] else "not finalized"
        print(f"{Path(args.tape).name}: {report['sample_duration_s']:.1f}s sample span, "
              f"{counts.get('frame', 0)} frames ({rate}), {report['depth_maps']} depth maps, "
              f"{counts.get('imu', 0)} imu, {counts.get('event', 0)} events | "
              f"{report['bytes'] / 1e6:.1f} MB | {state}")
        if report["sample_count"] == 0:
            print("  empty tape")
        for warning in report["warnings"]:
            print(f"  warning: {warning}")
        for error in report["errors"]:
            print(f"  error: {error}", file=sys.stderr)
        print("  asset bytes checked; JPEG decoding and LZFSE decoded-size checks require replay")
    return 0 if report["valid"] else 1


if __name__ == "__main__":
    sys.exit(main())
