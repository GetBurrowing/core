"""Private authorized source-frame comparison against original producer detection."""
import argparse
import hashlib
import json
from pathlib import Path

from clip_agent import opencv_faces

p = argparse.ArgumentParser()
p.add_argument("--frame", type=Path, required=True)
args = p.parse_args()
assert hashlib.sha256(args.frame.read_bytes()).hexdigest() == "87e48745f65b2557045c9e00106795fb83b69424d315cf0143f74d65f4c8a068"
expected = (0.4788947105407715, 0.2711942884657118, 0.14139142036437988,
            0.3488219579060872, 0.9283865094184875)
faces = opencv_faces.detect(args.frame)
assert len(faces) == 1
actual = tuple(getattr(faces[0], k) for k in ("x", "y", "w", "h", "confidence"))
assert all(abs(a - b) < 1e-6 for a, b in zip(actual, expected, strict=True))
print(json.dumps({"original_producer_detector_geometry_match": True,
                  "faces": len(faces), "tolerance": 1e-6,
                  "model_sha256": opencv_faces.MODEL_SHA256}))
