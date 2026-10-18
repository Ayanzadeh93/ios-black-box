#!/usr/bin/env python3
"""Put app events on the video's clock.

usage: align.py <session-*.json sidecar> <trace.jsonl>... [--field t] [--out timeline.csv]

Each trace line is a JSON object whose `--field` (default "t") is
ProcessInfo.systemUptime. The sidecar from SessionRecorder holds the uptime at
recording start/stop, so video_s = t - startUptime. Events outside the
recording are kept with in_video=0 so nothing silently disappears.
"""
import argparse, csv, json, sys

SKIP = {"type", "kind", "event"}


def summary(row: dict, field: str) -> str:
    parts = []
    for key in ("text", "outcome", "reason", "severity", "pattern", "message", "name"):
        if key in row and row[key] not in (None, ""):
            parts.append(f"{key}={row[key]}")
    if not parts:
        parts = [f"{k}={v}" for k, v in row.items()
                 if k not in SKIP and k != field and not isinstance(v, (dict, list))][:4]
    return " ".join(parts)[:160]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("sidecar")
    ap.add_argument("traces", nargs="+")
    ap.add_argument("--field", default="t")
    ap.add_argument("--out", default="-")
    a = ap.parse_args()

    clock = json.load(open(a.sidecar))
    start, stop = float(clock["startUptime"]), float(clock["stopUptime"])
    rows = []
    for path in a.traces:
        for line in open(path):
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            t = ev.get(a.field)
            if not isinstance(t, (int, float)):
                continue
            kind = ev.get("type") or ev.get("kind") or ev.get("event") or "event"
            rows.append((t - start, int(start <= t <= stop), kind, summary(ev, a.field)))
    rows.sort()

    out = sys.stdout if a.out == "-" else open(a.out, "w", newline="")
    w = csv.writer(out)
    w.writerow(["video_s", "in_video", "type", "summary"])
    for v, inside, kind, text in rows:
        w.writerow([f"{v:.3f}", inside, kind, text])
    inside = sum(r[1] for r in rows)
    print(f"aligned {inside}/{len(rows)} events onto {clock.get('video', 'video')} "
          f"({stop - start:.1f}s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
