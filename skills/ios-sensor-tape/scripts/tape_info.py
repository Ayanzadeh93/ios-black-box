#!/usr/bin/env python3
"""Summarize a sensor tape: duration, counts, achieved rates, size per minute."""
import json, os, sys, collections

tape = sys.argv[1]
meta = json.load(open(os.path.join(tape, "meta.json")))
rows = [json.loads(l) for l in open(os.path.join(tape, "index.jsonl")) if l.strip()]
kinds = collections.Counter(r["kind"] for r in rows)
ts = sorted(r["t"] for r in rows)
dur = (ts[-1] - ts[0]) if len(ts) > 1 else 0
size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(tape) for f in fs)
frames = [r for r in rows if r["kind"] == "frame"]
fps = len(frames) / dur if dur else 0
print(f"{os.path.basename(tape.rstrip('/'))}: {dur:.1f}s, {len(frames)} frames ({fps:.1f} fps), "
      f"{sum(1 for r in frames if 'depth' in r)} depth maps, {kinds.get('imu', 0)} imu, "
      f"{kinds.get('event', 0)} events | {size/1e6:.1f} MB ({size/1e6/(dur/60):.1f} MB/min)" if dur else
      f"{tape}: empty tape")
if frames:
    print(f"  frame size {frames[0]['w']}x{frames[0]['h']}, stopped: {meta.get('reason', 'still recording?')}")
