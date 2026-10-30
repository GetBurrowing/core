#!/usr/bin/env python3
"""Render authorized source comparisons through the pinned CLI and canonical helper.

Copies an existing project before editing its supported review.toml. No source
project writes, Social claims/completions, approvals or publication. The helper
uses a local artifact sink here; live upload/claim protocol is tested separately.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def snapshot(path):
    return {
        str(p.relative_to(path)): digest(p)
        for p in sorted(path.rglob("*"))
        if p.is_file()
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clip", type=Path, required=True)
    parser.add_argument("--helper", type=Path, required=True)
    parser.add_argument("--source-project", type=Path, required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--source-id", required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--duration", type=float, default=10.8)
    args = parser.parse_args()
    if not 8 <= args.duration <= 12:
        parser.error("duration must be 8–12 seconds")
    root = Path(__file__).resolve().parents[4]
    artifact = json.loads(
        (root / "docs/integrations/clip-captions/artifact.json").read_text()
    )
    helper_artifact = json.loads(
        (root / "docs/integrations/clip-captions/runner-artifact.json").read_text()
    )
    helper_path = args.helper.resolve()
    assert digest(helper_path) == helper_artifact["helper_sha256"]
    spec = importlib.util.spec_from_file_location("clip_runner", helper_path)
    helper = importlib.util.module_from_spec(spec)
    sys.modules["clip_runner"] = helper
    spec.loader.exec_module(helper)
    run = args.workspace.resolve()
    run.mkdir(mode=0o700, parents=True, exist_ok=False)
    source = args.source_project.resolve()
    before = snapshot(source)
    project = run / "source-project-copy"
    project.mkdir()
    for p in source.glob("*.json"):
        shutil.copy2(p, project / p.name)
    shutil.copytree(source / "candidates", project / "candidates")
    # Finals are retained separately before any finalize can prune them.
    if (source / "final").exists():
        shutil.copytree(source / "final", run / "retained-original-deliveries")
    home = run / "tool-home"
    (home / "profiles").mkdir(parents=True)
    profile = home / "profiles/burrow-caption-comparison.toml"
    profile.write_text("""extends = "how-to-computer"
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
    os.environ.update(CLIP_AGENT_HOME=str(home), CLIP_NO_CONTENT="1")
    for key in (
        "CODEX_SUITE_MCP_BEARER",
        "CLIP_RUNNER_TOKEN",
        "SUITE_TOKEN",
        "BURROW_TOKEN",
        "BURROW_API_TOKEN",
        "CF_ACCESS_CLIENT_ID",
        "CF_ACCESS_CLIENT_SECRET",
    ):
        os.environ.pop(key, None)
    cli = str(args.clip.resolve())
    identity = json.loads(subprocess.check_output([cli, "version", "--json"]))
    renderer = identity["caption_renderer"]
    assert identity["caption_treatments"] == 1
    assert (
        renderer["sha256"]
        == artifact["installed_source_sha256"]["clip-agent/src/clip_agent/captions.py"]
    )
    assert (
        renderer["temporal_sha256"]
        == artifact["installed_source_sha256"][
            "clip-agent/src/clip_agent/dynamic_captions.py"
        ]
    )

    def call(*argv):
        r = subprocess.run([cli, *map(str, argv)], capture_output=True, check=False)
        with (run / "cli-private.log").open("ab") as log:
            log.write(r.stdout + r.stderr)
        if r.returncode:
            raise RuntimeError(f"CLI {argv[0]} failed; private diagnostic retained")

    call("review", project, "--overwrite", "--profile", "burrow-caption-comparison")
    review = helper.ReviewFile((project / "review.toml").read_text())
    selected = review.by_id(args.candidate)
    assert selected is not None and not selected.alternate
    start = selected.start
    end = min(selected.end, start + args.duration)
    assert end - start >= 8
    for entry in review.entries:
        review.set_fields(entry, decision="approve" if entry is selected else "reject")
    (project / "review.toml").write_text(review.text())

    class Client:
        def progress(self, *a, **kw):
            pass

        def request(self, *a, **kw):
            raise AssertionError("Comparison must not request remote assets")

    renders = []
    try:
        for style in ("type-on", "focus-word", "editorial-punch"):
            job = {
                "id": "comparison-" + style,
                "kind": "rerender",
                "clip_id": "comparison",
                "profile_id": "comparison",
                "payload": {
                    "clip_user_profile": "burrow-caption-comparison",
                    "candidate_id": args.candidate,
                    "source_id": args.source_id,
                    "appearance": True,
                    "base_render_id": "comparison-base",
                    "expected_rev": 2,
                    "in_s": start,
                    "out_s": end,
                    "look": {"cap": {"style": style}},
                    "closing_video": {"enabled": False, "audio": "keep"},
                },
            }
            runner = helper.Runner(
                Client(),
                state_dir=run / "runner",
                clip_bin=cli,
                uploader=lambda *a: "local-comparison-artifact",
                install_signal_handlers=False,
            )
            runner._job = job
            runner.context = {
                "project_id": "comparison",
                "base_render_id": "comparison-base",
            }
            runner.project_path = str(project)
            result = helper._render(
                runner, job, project, args.candidate, regenerate=True
            )
            delivery = run / (style + ".mp4")
            shutil.copy2(runner.output, delivery)
            shutil.copy2(
                runner.output.with_stem(runner.output.stem + "_clean"),
                run / (style + "-clean.mp4"),
            )
            probe = json.loads(
                subprocess.check_output(
                    [
                        "ffprobe",
                        "-v",
                        "error",
                        "-show_entries",
                        "format=duration:stream=width,height,r_frame_rate,codec_name",
                        "-of",
                        "json",
                        str(delivery),
                    ]
                )
            )
            duration = float(probe["format"]["duration"])
            assert 8 <= duration <= 12, (style, duration)
            video = next(s for s in probe["streams"] if "width" in s)
            assert video["width"] * 16 == video["height"] * 9
            renders.append(
                {
                    "style": style,
                    "file": delivery.name,
                    "sha256": digest(delivery),
                    "bytes": delivery.stat().st_size,
                    "ffprobe": probe,
                    "applied_source_start_s": runner.review_entry["start"],
                    "applied_source_end_s": runner.review_entry["end"],
                    "content_free_result": result,
                }
            )
            assert not list((home / "profiles").glob("*-job-*"))
            print(style + " rendered and decoded", flush=True)
    finally:
        assert snapshot(source) == before, "Original project/deliveries changed"
    receipt = {
        "schema": "caption-comparison/1",
        "pending_review": True,
        "source_id": args.source_id,
        "candidate_id": args.candidate,
        "requested_start_s": start,
        "requested_end_s": end,
        "source_snapshot_sha256": hashlib.sha256(
            json.dumps(before, sort_keys=True).encode()
        ).hexdigest(),
        "original_project_unchanged": True,
        "helper_sha256": digest(helper_path),
        "executable": cli,
        "executable_sha256": digest(args.clip),
        "cli_identity": identity,
        "renders": renders,
        "scope": "Real CLI and canonical helper render path; local artifact sink, no live claim/upload/completion or publication",
    }
    (run / "receipt-private.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
