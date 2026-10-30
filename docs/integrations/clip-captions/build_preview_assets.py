"""Build representative picker media with the pinned actual CLI and public review API.

Use a disposable workspace. Source project/candidates are copied before review.
Nothing in the original project is edited, approved, scheduled or published.
Content-bearing CLI diagnostics remain only in the disposable workspace.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--clip", type=Path, required=True)
parser.add_argument("--source-project", type=Path, required=True)
parser.add_argument("--candidate", required=True)
parser.add_argument("--workspace", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--manifest", type=Path, required=True)
parser.add_argument("--source-id", required=True)
parser.add_argument("--duration", type=float, default=3.8)
args = parser.parse_args()
if not 3 <= args.duration <= 4:
    parser.error("duration must be between 3 and 4 seconds")
ROOT = Path(__file__).resolve().parent
RUN = args.workspace.resolve()
RUN.mkdir(parents=True, exist_ok=False)
sys.path.insert(0, str(ROOT / "runner"))
from clip_runner import ReviewFile

CLI = args.clip.resolve()
project = RUN / "project"
source = args.source_project.resolve()
home = RUN / "tool-home"
(home / "profiles").mkdir(parents=True, exist_ok=True)
(home / "profiles/caption-picker.toml").write_text("""extends = "how-to-computer"
[brain]
backend = "ollama"
[privacy]
mode = "local"
[publish]
enabled = false
[reframe]
mode = "fit"
width = 360
height = 640
fallback = "center"
[captions]
hook_title = false
[output]
require_approval = true
video_crf = 23
[audio]
normalize = false
[outro]
path = ""
[music]
path = ""
""")
env = {**os.environ, "CLIP_AGENT_HOME": str(home), "CLIP_NO_CONTENT": "1"}
# The renderer has no reason to inherit the control-plane credentials.
for key in (
    "CODEX_SUITE_MCP_BEARER",
    "CLIP_RUNNER_TOKEN",
    "SUITE_TOKEN",
    "BURROW_TOKEN",
):
    env.pop(key, None)
identity = json.loads(subprocess.check_output([str(CLI), "version", "--json"], env=env))
artifact = json.loads((ROOT / "artifact.json").read_text())
renderer = identity.get("caption_renderer", {})
assert identity.get("caption_treatments") == 1, "Unqualified caption CLI"
assert (
    renderer.get("sha256")
    == artifact["installed_source_sha256"]["clip-agent/src/clip_agent/captions.py"]
)
assert (
    renderer.get("temporal_sha256")
    == artifact["installed_source_sha256"][
        "clip-agent/src/clip_agent/dynamic_captions.py"
    ]
)
assert {
    "plain",
    "phrase-pop",
    "karaoke",
    "type-on",
    "focus-word",
    "editorial-punch",
} <= set(identity.get("caption_styles", []))


def call(*args):
    r = subprocess.run(
        [str(CLI), *map(str, args)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    with (RUN / "preview-cli-private.log").open("a") as f:
        f.write(r.stdout + r.stderr)
    if r.returncode:
        raise RuntimeError("CLI " + str(args[0]) + " failed; local diagnostic retained")


if not project.exists():
    project.mkdir()
    for p in source.glob("*.json"):
        shutil.copy2(p, project / p.name)
    shutil.copytree(source / "candidates", project / "candidates")
call("review", project, "--overwrite", "--profile", "caption-picker")
r = ReviewFile((project / "review.toml").read_text())
selected = next(e for e in r.entries if e.fields.get("id") == args.candidate)
for e in r.entries:
    r.set_fields(
        e,
        decision="approve" if e is selected else "reject",
        **({"end": selected.start + args.duration} if e is selected else {}),
    )
(project / "review.toml").write_text(r.text())
call("review", project, "--apply", "--profile", "caption-picker")
call("review", project, "--overwrite", "--profile", "caption-picker")
r = ReviewFile((project / "review.toml").read_text())
for e in r.entries:
    r.set_fields(
        e, decision="approve" if e.fields.get("id") == args.candidate else "reject"
    )
(project / "review.toml").write_text(r.text())
call("review", project, "--apply", "--profile", "caption-picker")
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
assets = []
for style in [
    "plain",
    "phrase-pop",
    "karaoke",
    "type-on",
    "focus-word",
    "editorial-punch",
]:
    call(
        "finalize",
        project,
        "--profile",
        "caption-picker",
        "--captions",
        style,
        "--regenerate",
    )
    f = next(p for p in (project / "final").glob("*.mp4") if "_clean" not in p.stem)
    dst = out / (style + ".mp4")
    shutil.copy2(f, dst)
    info = json.loads(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=duration:stream=width,height",
                "-of",
                "json",
                str(dst),
            ]
        )
    )
    dur = float(info["format"]["duration"])
    assert 3 <= dur <= 4.1
    for phase, t in [("entry", 0.1), ("mid", 1.5), ("hold", min(3.2, dur - 0.1))]:
        subprocess.run(
            [
                "ffmpeg",
                "-y",
                "-v",
                "error",
                "-ss",
                str(t),
                "-i",
                str(dst),
                "-frames:v",
                "1",
                "-q:v",
                "3",
                str(out / (style + "-" + phase + ".jpg")),
            ],
            check=True,
        )
    assets.append(
        {
            "style": style,
            "duration_s": dur,
            "sha256": hashlib.sha256(dst.read_bytes()).hexdigest(),
            "bytes": dst.stat().st_size,
        }
    )
    print(style, "rendered", flush=True)
manifest = {
    "version": 1,
    "cli_version": identity["version"],
    "renderer_contract": "caption-treatments/1",
    "source_episode": args.source_id,
    "candidate_id": args.candidate,
    "excerpt_start_s": selected.start,
    "requested_end_s": selected.start + args.duration,
    "privacy": "Existing authorized source excerpt. Generated with isolated copy and public review/finalize CLI; original project unchanged. No social approval or publication.",
    "assets": assets,
}
args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
