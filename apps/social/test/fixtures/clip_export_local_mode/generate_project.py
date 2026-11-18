"""Builds a tiny SYNTHETIC local-mode clip-tool project (no real media, no guest content).

Usage: python generate_project.py PROJECT_DIR

Three candidates: one cut and not approved, one approved (the tool's approval is a set of content
hashes and names nobody), and one with no rendered file (the exporter must skip it). The "videos"
are a few ASCII bytes: the exporter only hashes and sizes them.
"""
import sys
from pathlib import Path

from clip_agent.config import Config
from clip_agent.manifest import Candidate, ProjectManifest, SourceInfo, save_manifest

project = Path(sys.argv[1])
(project / "candidates").mkdir(parents=True, exist_ok=True)
(project / "final").mkdir(parents=True, exist_ok=True)

files = {
    "01_Synthetic-clip-one": b"synthetic clip one: not a real video, bytes for hashing only\n",
    "02_Synthetic-clip-two": b"synthetic clip two: not a real video, bytes for hashing only, a little longer\n",
}
for stem, data in files.items():
    (project / "candidates" / f"{stem}.mp4").write_bytes(b"cut")
    (project / "final" / f"{stem}.mp4").write_bytes(data)
    (project / "final" / f"{stem}.srt").write_bytes(b"1\n00:00:00,000 --> 00:00:01,000\nsynthetic\n")


def cand(**kw):
    base = dict(rank=1, start=10.0, end=40.0, title="Synthetic clip", speakers=["Speaker A"], clip_type="other")
    base.update(kw)
    return Candidate(**base)


manifest = ProjectManifest(
    name="synthetic-ep",
    source=SourceInfo(path="/synthetic/source.mp4", fingerprint="synthetic", probe={"duration": 600.0}),
    config_resolved=Config().model_dump(mode="json"),
    config_layers={"privacy": {"mode": "local"}},
    candidates=[
        cand(id="0000000001", filename="01_Synthetic-clip-one.mp4", status="cut", start=10.0, end=40.5),
        cand(id="0000000002", rank=2, filename="02_Synthetic-clip-two.mp4", status="approved", start=60.0, end=95.25,
             approval={"source": "s", "edl": "e", "captions": "c", "packaging": "p"}),
        cand(id="0000000003", rank=3, filename="03_Synthetic-clip-three.mp4", status="cut", start=120.0, end=150.0),
    ],
)
save_manifest(project, manifest)
