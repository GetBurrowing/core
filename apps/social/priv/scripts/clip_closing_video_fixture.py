#!/usr/bin/env python3
"""TEST ONLY real renderer fixture. No customer media, network model or Burrow account.

Run with the compatible clip Python environment (numpy, Pillow and clip_agent).
The seeded proposal/transcript is fixture setup; all process/review/finalize commands
and the canonical helper's download/profile/render path execute unpatched.
"""

import argparse
import hashlib
import http.server
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--clip", required=True, type=Path)
    parser.add_argument("--tool-source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.environ["CLIP_AGENT_HOME"] = str(output / "tool-home")
    os.environ["CLIP_NO_CONTENT"] = "1"
    for key in (
        "CLIP_RUNNER_TOKEN",
        "BURROW_TOKEN",
        "BURROW_API_TOKEN",
        "CF_ACCESS_CLIENT_ID",
        "CF_ACCESS_CLIENT_SECRET",
    ):
        os.environ.pop(key, None)
    sys.path.insert(0, str(args.tool_source.resolve() / "clip-agent/src"))
    import clip_agent.config
    import numpy as np
    from clip_agent.config import load_config
    from clip_agent.manifest import (
        Candidate,
        ProjectManifest,
        SourceInfo,
        StageState,
        fingerprint,
        save_manifest,
    )

    helper_sha256 = hashlib.sha256(args.helper.read_bytes()).hexdigest()
    spec = importlib.util.spec_from_file_location("clip_runner", args.helper.resolve())
    helper = importlib.util.module_from_spec(spec)
    sys.modules["clip_runner"] = helper
    spec.loader.exec_module(helper)
    clip = str(args.clip.resolve())
    calls = []

    def cli(*argv):
        proc = subprocess.run(
            [clip, *map(str, argv)], check=False, capture_output=True, text=True
        )
        calls.append({"argv": list(map(str, argv)), "exit": proc.returncode})
        if proc.returncode:
            (output / "last-cli-error.txt").write_text(proc.stdout + proc.stderr)
            raise RuntimeError(f"fixture CLI {argv[0]} failed: {proc.returncode}")
        return proc.stdout

    def ffmpeg(*argv):
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, argv)],
            check=True,
        )

    def probe(path):
        return json.loads(
            subprocess.check_output(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_format",
                    "-show_streams",
                    "-of",
                    "json",
                    str(path),
                ]
            )
        )

    def frame(path, sec):
        raw = subprocess.check_output(
            [
                "ffmpeg",
                "-loglevel",
                "error",
                "-ss",
                str(sec),
                "-i",
                str(path),
                "-frames:v",
                "1",
                "-f",
                "rawvideo",
                "-pix_fmt",
                "rgb24",
                "-",
            ]
        )
        return np.frombuffer(raw, dtype=np.uint8).reshape((640, 360, 3)).astype(float)

    def tone(path, sec, hz):
        raw = subprocess.check_output(
            [
                "ffmpeg",
                "-loglevel",
                "error",
                "-ss",
                str(sec),
                "-t",
                "0.5",
                "-i",
                str(path),
                "-vn",
                "-f",
                "f32le",
                "-ac",
                "1",
                "-ar",
                "48000",
                "-",
            ]
        )
        samples = np.frombuffer(raw, dtype=np.float32)
        return float(
            2
            * abs(
                np.sum(
                    samples * np.exp(-2j * np.pi * hz * np.arange(len(samples)) / 48000)
                )
            )
            / len(samples)
        )

    source = output / "source-test-only.mp4"
    ffmpeg(
        "-f",
        "lavfi",
        "-i",
        "color=c=0x202020:s=360x640:r=30:d=5",
        "-f",
        "lavfi",
        "-i",
        "sine=frequency=440:duration=5:sample_rate=48000",
        "-c:v",
        "libx264",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-shortest",
        source,
    )
    assets = {}
    for ident, color in [("A", "red"), ("B", "blue")]:
        path = output / f"closing-TEST-ONLY-{ident}.mp4"
        ffmpeg(
            "-f",
            "lavfi",
            "-i",
            f"color=c={color}:s=360x640:r=30:d=1.2",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=997:duration=1.2:sample_rate=48000",
            "-vf",
            f"drawbox=x=30:y=450:w=60:h=40:color=white:t=fill,drawtext=text='TEST ONLY {ident}':fontcolor=white:fontsize=34:x='30+20*sin(t*6)':y=70",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            path,
        )
        assets["closing-" + ident] = path
    song = output / "music-TEST-ONLY.wav"
    ffmpeg("-f", "lavfi", "-i", "sine=frequency=773:duration=8:sample_rate=48000", song)
    assets["music"] = song
    profile = output / "fixture-profile.toml"
    profile.write_text(
        'extends = "how-to-computer"\n[brain]\nbackend="ollama"\n[privacy]\nmode="local"\n'
        '[reframe]\nmode="off"\nwidth=360\nheight=640\n'
        '[selection]\naudio_features=false\n[speakers]\nenabled=false\n[editing]\npunch="off"\n[captions]\nstyle="plain"\nhook_title=true\n'
        "size_frac=0.05\n[output]\nrequire_approval=true\n"
        + "clips_root="
        + json.dumps(str(output / "tool-home/clips"))
        + "\n[publish]\nenabled=false\n"
    )
    cli("profile", "import", profile, "--name", "burrow-fixture", "--force", "--yes")
    config = load_config(profile="burrow-fixture")
    assert hasattr(config, "outro") and hasattr(config.outro, "path")
    assert config.outro.audio in ("keep", "mute")
    version = json.loads(cli("version", "--json"))
    assert version.get("headline_review") == 1, "headline-review/1 required"
    project = output / "tool-home/clips/closing-fixture"
    (project / "candidates").mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, project / "candidates/01_fixture.mp4")
    text = "We shipped the app and the team celebrated"
    tokens = [
        {
            "text": " " + word,
            "offsets": {"from": i * 500, "to": i * 500 + 450},
            "p": 1.0,
        }
        for i, word in enumerate(text.split())
    ]
    (project / "fixture.json").write_text(
        json.dumps(
            {
                "transcription": [
                    {"text": text, "offsets": {"from": 0, "to": 4500}, "tokens": tokens}
                ]
            }
        )
    )
    candidate = Candidate(
        id="abc123",
        rank=1,
        start=0,
        end=5,
        title="We shipped the app",
        titles=["We shipped the app"],
        filename="01_fixture.mp4",
        status="cut",
        cut_fingerprint="fixture-cut",
    )
    manifest = ProjectManifest(
        name=project.name,
        source=SourceInfo(
            path=str(source),
            fingerprint=hashlib.sha256(source.read_bytes()).hexdigest(),
            probe={"duration": 5.0, "fps": 30.0},
        ),
        config_resolved=config.model_dump(mode="json"),
        transcript_cache_key="fixture",
        caption_style="none",
        candidates=[candidate],
    )
    # Seed valid cache identities through upstream helpers, so resume proves
    # the real CLI pipeline can reuse this deterministic transcript/proposal.
    from clip_agent import pipeline
    from clip_agent.transcribe import load_cached_transcript

    tc = config.transcription
    transcribe_fp = fingerprint(
        "transcribe",
        "sha256:" + manifest.source.fingerprint,
        tc.model_dump(
            mode="json", exclude=None if tc.initial_prompt else {"initial_prompt"}
        ),
    )
    transcript = load_cached_transcript(
        project, "fixture", source=str(source), model=tc.model
    )
    assert transcript is not None
    select_fp = pipeline._select_fingerprint(
        config,
        pipeline._transcript_content_id(transcript),
        pipeline._prompt_fingerprint(config),
        config.selection.count,
    )
    manifest.stages = {
        "transcribe": StageState(status="done", input_fingerprint=transcribe_fp),
        "select": StageState(status="done", input_fingerprint=select_fp),
    }
    save_manifest(project, manifest)
    # The supported process/resume path runs, with the deterministic proposal and
    # transcript supplied above, rather than a live model or hidden output reuse.
    cli(
        "process",
        source,
        "--project",
        project.name,
        "--profile",
        "burrow-fixture",
        "--resume",
    )
    cli("review", project, "--overwrite", "--profile", "burrow-fixture")
    project2 = output / "tool-home/clips/closing-fixture-two"
    shutil.copytree(project, project2, dirs_exist_ok=True)
    review = project / "review.toml"
    review.write_text(
        review.read_text().replace('decision = "pending"', 'decision = "approve"')
    )
    cli("review", project, "--apply", "--profile", "burrow-fixture")

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            path = assets.get(self.path.removeprefix("/"))
            if path is None:
                self.send_error(404)
                return
            assert "Authorization" not in self.headers
            self.send_response(200)
            self.end_headers()
            self.wfile.write(path.read_bytes())

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    requests = []
    current = {}

    class Client:
        def progress(self, *args, **kw):
            pass

        def request(self, tool, args, **kw):
            assert tool == "social_clip_job_source"
            requests.append(dict(args))
            closing = args["asset"] == "closing_video"
            key = current["file_id"] if closing else "music"
            path = assets[key]
            return {
                "file_id": key,
                "project_id": "fixture-project",
                "content_type": "video/mp4" if closing else "audio/wav",
                "byte_size": path.stat().st_size,
                "content_hash": hashlib.sha256(path.read_bytes()).hexdigest(),
                "max_bytes": 200 * 1024 * 1024,
                "url": f"http://127.0.0.1:{server.server_address[1]}/{key}",
            }

    state = output / "runner"
    renders = []
    try:
        for index, (name, ident, audio, enabled, operation) in enumerate(
            [
                ("clip1-A-keep", "A", "keep", True, None),
                ("clip2-A-mute", "A", "mute", True, None),
                ("replacement-B", "B", "mute", True, None),
                ("disabled", "B", "keep", False, None),
                ("headline", "A", "keep", True, "headline"),
                ("caption", "A", "mute", True, "caption"),
                ("music", "A", "mute", True, "music"),
            ]
        ):
            asset = assets["closing-" + ident]
            current.clear()
            current.update(
                enabled=enabled,
                file_id="closing-" + ident,
                audio=audio,
                project_id="fixture-project",
                content_type="video/mp4",
                byte_size=asset.stat().st_size,
                content_hash=hashlib.sha256(asset.read_bytes()).hexdigest(),
            )
            active_project = project2 if index == 1 else project
            clip_id = "clip2" if index == 1 else "clip1"
            payload = {
                "clip_user_profile": "burrow-fixture",
                "candidate_id": "abc123",
                "source_id": "fixture-source",
                "base_render_id": "fixture-base",
                "expected_rev": 2,
                "in_s": 0.0,
                "out_s": 5.0,
                "closing_video": dict(current),
                "appearance": True,
                "clip_overrides": {
                    "mapped": {"captions.style": "plain"},
                    "unmapped": [],
                },
            }
            if operation == "headline":
                payload["headline"] = {
                    "consumer": "edit",
                    "requested_headline": "The team celebrated",
                }
            if operation == "caption":
                payload["fix"] = {
                    "operation": "caption_word",
                    "caption_fixes": {
                        "position": 0,
                        "original": "We",
                        "replacement": "They",
                    },
                }
                payload["caption_fixes"] = [
                    {"word_index": 0, "original": "We", "replacement": "They"}
                ]
            if operation == "music":
                payload["music"] = {
                    "enabled": True,
                    "file_id": "music",
                    "level_db": -36,
                }
            job = {
                "id": "closing-" + name,
                "kind": "rerender",
                "clip_id": clip_id,
                "profile_id": "fixture-profile",
                "payload": payload,
            }
            runner = helper.Runner(
                Client(),
                state_dir=state,
                clip_bin=clip,
                uploader=lambda *args: "fixture-file",
                install_signal_handlers=False,
            )
            runner._job = job
            runner.context = {
                "project_id": "fixture-project",
                "base_render_id": "fixture-base",
                "headline_voice": {
                    "revision": "fixture",
                    "direction": "Test-only fixture",
                },
            }
            runner.headline_capability = True
            runner.project_path = str(active_project)
            result = helper._render(
                runner, job, active_project, "abc123", regenerate=True
            )
            delivery, clean = output / (name + ".mp4"), output / (name + "-clean.mp4")
            shutil.copy2(runner.output, delivery)
            shutil.copy2(runner.output.with_stem(runner.output.stem + "_clean"), clean)
            measured = float(probe(delivery)["format"]["duration"])
            expected = 6.2 if enabled else 5.0
            assert abs(measured - expected) <= 1 / 30 + 0.001, (
                name,
                measured,
                expected,
            )
            source_sound = tone(delivery, 1.0, 440)
            assert source_sound > 0.01, (name, "source sound lost")
            evidence = {
                "name": name,
                "duration_s": measured,
                "expected_s": expected,
                "source_440hz_amplitude": source_sound,
                "result": result,
                "sha256": hashlib.sha256(delivery.read_bytes()).hexdigest(),
            }
            if enabled:
                before, after, final = (
                    frame(delivery, 4.95),
                    frame(delivery, 5.1),
                    frame(delivery, 6.1),
                )
                assert abs(before.mean() - after.mean()) > 5, "no visible seam"
                channel = 0 if ident == "A" else 2
                assert (
                    after[:, :, channel].mean() > 200
                    and final[:, :, channel].mean() > 200
                )
                suffix_diff = float(np.abs(after - frame(clean, 5.1)).mean())
                assert (
                    float(np.abs(frame(delivery, 1.0) - frame(clean, 1.0)).mean()) > 0.1
                ), "no visible source captions/headline to check"
                assert suffix_diff < 2, (
                    name,
                    "captions/headline continue onto closing",
                    suffix_diff,
                )
                reference_diff = float(np.abs(final - frame(asset, 1.1)).mean())
                assert reference_diff < 4, (
                    name,
                    "final pattern mismatch",
                    reference_diff,
                )
                # Every decoded frame: one continuous closing interval, beginning
                # at frame150 and ending at frame185. An extra append fails count.
                raw = subprocess.check_output(
                    [
                        "ffmpeg",
                        "-v",
                        "error",
                        "-i",
                        str(delivery),
                        "-vf",
                        "scale=12:20",
                        "-f",
                        "rawvideo",
                        "-pix_fmt",
                        "rgb24",
                        "-",
                    ]
                )
                frames = (
                    np.frombuffer(raw, dtype=np.uint8)
                    .reshape((-1, 20, 12, 3))
                    .astype(float)
                )
                mask = frames[:, :, :, channel].mean(axis=(1, 2)) > 180
                assert not mask[:150].any() and mask[150:].all() and len(mask) == 186, (
                    name,
                    "double/missing append",
                )
                closing_tone = tone(delivery, 5.3, 997)
                assert closing_tone > 0.01 if audio == "keep" else closing_tone < 0.0001
                evidence.update(
                    closing_997hz_amplitude=closing_tone,
                    suffix_delivery_clean_mae=suffix_diff,
                    final_asset_mae=reference_diff,
                    closing_frames=int(mask.sum()),
                )
                ffmpeg(
                    "-ss",
                    "4.95",
                    "-i",
                    delivery,
                    "-frames:v",
                    "1",
                    output / (name + "-before.png"),
                )
                ffmpeg(
                    "-ss",
                    "5.1",
                    "-i",
                    delivery,
                    "-frames:v",
                    "1",
                    output / (name + "-after.png"),
                )
                ffmpeg(
                    "-ss",
                    "6.1",
                    "-i",
                    delivery,
                    "-frames:v",
                    "1",
                    output / (name + "-end.png"),
                )
            assert not list(state.rglob("closing.video")) and not list(
                state.rglob("closing.part")
            )
            assert not list((output / "tool-home/profiles").glob("*-job-*"))
            if operation == "headline":
                assert (
                    np.abs(
                        frame(delivery, 1.0)[:230]
                        - frame(output / "clip1-A-keep.mp4", 1.0)[:230]
                    ).mean()
                    > 0.1
                ), "headline did not change"
            if operation == "caption":
                assert (
                    np.abs(
                        frame(delivery, 0.2)[300:]
                        - frame(output / "headline.mp4", 0.2)[300:]
                    ).mean()
                    > 0.1
                ), "caption did not change"
            renders.append(evidence)
            print(json.dumps(evidence), flush=True)
        # Hash-correct bytes with a fake video MIME must still fail in the real
        # supported CLI before upload; Core would reject these at selection too.
        bad = output / "invalid-TEST-ONLY.mp4"
        bad.write_bytes(b"not a real video container")
        assets["invalid"] = bad
        current.clear()
        current.update(
            enabled=True,
            file_id="invalid",
            audio="mute",
            project_id="fixture-project",
            content_type="video/mp4",
            byte_size=bad.stat().st_size,
            content_hash=hashlib.sha256(bad.read_bytes()).hexdigest(),
        )
        job["id"] = "closing-invalid"
        job["payload"].pop("music", None)
        job["payload"]["closing_video"] = dict(current)

        def forbidden_upload(*args):
            raise AssertionError("invalid media reached uploader")

        runner = helper.Runner(
            Client(),
            state_dir=state,
            clip_bin=clip,
            uploader=forbidden_upload,
            install_signal_handlers=False,
        )
        runner._job = job
        runner.context = {"project_id": "fixture-project"}
        runner.project_path = str(project)
        try:
            helper._render(runner, job, project, "abc123", regenerate=True)
        except helper.ClipError as error:
            invalid_code = error.code
        else:
            raise AssertionError("invalid video rendered")
        assert not list(state.rglob("closing.video")) and not list(
            state.rglob("closing.part")
        )
        assert not list((output / "tool-home/profiles").glob("*-job-*"))
    finally:
        server.shutdown()
        server.server_close()
    source_hashes = {
        name: hashlib.sha256(
            (args.tool_source / "clip-agent/src/clip_agent" / name).read_bytes()
        ).hexdigest()
        for name in ("config.py", "render.py", "cli.py", "review.py", "headline.py")
    }
    source_diff = subprocess.check_output(
        ["git", "-C", str(args.tool_source), "diff", "--binary"]
    )
    revision = subprocess.check_output(
        ["git", "-C", str(args.tool_source), "rev-parse", "HEAD"], text=True
    ).strip()
    receipt = {
        "test_only": True,
        "executable": clip,
        "python": sys.executable,
        "imported_module": clip_agent.config.__file__,
        "source_revision": revision,
        "cli_version": version,
        "source_file_sha256": source_hashes,
        "source_patch_sha256": hashlib.sha256(source_diff).hexdigest(),
        "executable_sha256": hashlib.sha256(args.clip.read_bytes()).hexdigest(),
        "helper_sha256": helper_sha256,
        "seeded": "Deterministic transcript/proposal, no customer media; real process/resume/review/finalize",
        "renders": renders,
        "calls": calls,
        "source_requests": requests,
        "invalid_video_failure": invalid_code,
    }
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2))
    print(
        "PASS: seven real CLI renders, decoded seams/final frames, duration, source sound, closing keep/mute"
    )


if __name__ == "__main__":
    main()
