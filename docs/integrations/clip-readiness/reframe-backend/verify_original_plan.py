"""Read-only original-source analysis; no project manifests, edits or job calls."""
import argparse
import hashlib
import json
from pathlib import Path

from clip_agent import reframe, shots
from clip_agent.config import load_config

ap = argparse.ArgumentParser()
ap.add_argument("--source", type=Path, required=True)
ap.add_argument("--profile", required=True)
args = ap.parse_args()
assert hashlib.sha256(args.source.read_bytes()).hexdigest() == "a56d9f934de436211d92c2e9a5688cd9b6c8f0c52527d25c6c3d3b7f5fd66d91"
cfg = load_config(profile=args.profile, overrides={"reframe": {"face_sampling": "legacy-half-step"}})
assert cfg.reframe.mode == "shots"
ss = shots.analyse_shots(args.source, 2403.01, 53.87, cfg)
plan = reframe.plan_shots(ss, 53.87, 1920, 1080, cfg)
actual = [(s.start, s.end, s.layout, [(b.x, b.y, b.w, b.h) for b in s.boxes]) for s in plan.segments]
assert actual == [
    (0.0, 23.039, "crop", [(736, 0, 606, 1080)]),
    (23.039, 24.582, "crop", [(582, 0, 606, 1080)]),
    (24.582, 28.002, "crop", [(790, 0, 606, 1080)]),
    (28.002, 53.87, "crop", [(534, 0, 606, 1080)]),
]
print(json.dumps({"original_producer_shot_plan_match": True, "segments": len(plan.segments),
                  "sampling": cfg.reframe.face_sampling, "planner_unchanged": True}))
