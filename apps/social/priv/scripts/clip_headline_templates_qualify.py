"""Real canonical-helper qualification against a private copy of an original project.

Only fixture setup seeds a candidate; all edits/approval/finalization use the CLI.
The local client/uploader records receipts; it cannot publish or mutate Burrow.
"""

import argparse
import copy
import functools
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


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def contract(template, seconds=1.0):
    # Independent literals: do not derive these expectations from the helper under test.
    return {
        "version": 1,
        "revision": 1,
        "template": template,
        "renderer_sha256": "b36d7ec515da07e5e432d1eca57c639ecc6007126cc68110d1bb367c99b45d84",
        "assets": {
            "logo_sha256": "7cbddeac97ad8fe3aa53e867cf0e5648329f500e528f2302e1b2ebcba8bf767f",
            "font_sha256": "a4ba3a92350ebb031da0cb47630ac49eb265082ca1bc0450442f4a83ab947cab",
            "provenance": "assets-manifest.json; HTC-only authorized logo; OFL font",
        },
        "timing": {
            "entrance_s": 0.2,
            "hold_s": round(seconds - 0.45, 6),
            "exit_s": 0.25,
            "total_s": seconds,
        },
        "emphasis": [],
        "emphasis_text": None,
    }


def layout_matrix(output, logo, faces):
    from clip_agent import headline_templates
    from clip_agent.config import FONTS_DIR, Config
    from PIL import Image

    cfg = Config()
    look = cfg.captions
    look.safe_top, look.safe_side, look.safe_right = 0.08, 0.08, 0.12
    look.hook_title_logo_path = str(logo)
    look.hook_title_logo_sha256 = digest(logo)
    look.hook_title_face_boxes = faces
    cases = {
        "short": "Come back.",
        "long": "I'll save that for next week. You'll have to come back.",
        "unbroken": "A" * 120,
        "unicode": "café déjà vu",
        "unsupported-unicode": "\U0001f600",
    }
    results = []
    for style in ("chrome-hook", "neon-broadcast", "arcade-punch"):
        for name, text in cases.items():
            look.hook_title_template = style
            path = output / f"matrix-{style}-{name}.png"
            error = None
            try:
                spec = headline_templates.render(
                    text, path, width=540, height=960, look=look, fonts_dir=FONTS_DIR
                )
            except ValueError as exc:
                error = str(exc)
            if name == "unbroken":
                assert error == "HEADLINE_LAYOUT_SHORTEN_TEXT" and not path.exists()
            elif name == "unsupported-unicode":
                assert error == "HEADLINE_GLYPH_UNSUPPORTED" and not path.exists()
            else:
                assert error is None, (style, name, error)
                # Decode actual PNG pixels; never just trust returned layout bounds.
                im = Image.open(path).convert("RGBA")
                box = im.getbbox()
                assert (
                    box
                    and box[0] >= 43
                    and box[1] >= 77
                    and box[2] <= 475
                    and box[3] <= 279
                )
                spec = headline_templates.layout(
                    text,
                    width=540,
                    height=960,
                    look=look,
                    font_path=FONTS_DIR / "Anton-Regular.ttf",
                )
                assert [
                    word for line in spec["lines"] for _, word in line
                ] == text.split()
            results.append(
                {
                    "template": style,
                    "case": name,
                    "error": error,
                    "sha256": digest(path) if path.exists() else None,
                }
            )
    return results


def codec_speech_match(reference, mixed):
    """Verify speech independently of a known 220 Hz fixture bed and AAC phase.

    A second AAC pass can move the waveform by ~1 ms. The hard 2 ms search
    window cannot hide a source trim or an audiovisual sync error.
    """
    import numpy as np

    count = min(len(reference), len(mixed))
    frequencies = np.fft.rfftfreq(count, 1 / 16000)
    keep = (frequencies < 205) | (frequencies > 235)
    a = np.fft.irfft(np.fft.rfft(reference[:count]) * keep, n=count)
    b = np.fft.irfft(np.fft.rfft(mixed[:count]) * keep, n=count)
    matches = []
    for lag in range(-32, 33):
        x = a[max(0, lag) : min(count, count + lag)]
        y = b[max(0, -lag) : min(count, count - lag)]
        corr = float(np.corrcoef(x, y)[0, 1])
        gain = float(np.dot(x, y) / np.dot(x, x))
        matches.append((corr, lag, gain))
    corr, lag, gain = max(matches)
    assert corr > 0.995 and abs(lag) < 32 and 0.95 < gain < 1.05, (corr, lag, gain)
    return {"correlation": corr, "delay_ms": -lag / 16, "gain": gain}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--helper", required=True, type=Path)
    p.add_argument("--project", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--assets", required=True, type=Path)
    p.add_argument("--model-dir", required=True, type=Path)
    p.add_argument("--ollama-endpoint", default="http://127.0.0.1:11438")
    p.add_argument("--generation", action="store_true")
    p.add_argument(
        "--smoke",
        action="store_true",
        help="One real Chrome edit, disabled render, and fail-closed probes",
    )
    p.add_argument(
        "--verify-existing",
        action="store_true",
        help="Recheck completed private fixture outputs without rerendering",
    )
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=args.verify_existing)
    os.environ["CLIP_AGENT_HOME"] = str(out / "tool-home")
    os.environ["CLIP_NO_CONTENT"] = "1"
    os.environ["CLIP_RUNNER_HEADLINE_ASSETS"] = str(args.assets.resolve())
    os.environ.pop("CLIP_RUNNER_TOKEN", None)
    spec = importlib.util.spec_from_file_location("clip_runner", args.helper)
    helper = importlib.util.module_from_spec(spec)
    sys.modules["clip_runner"] = helper
    spec.loader.exec_module(helper)
    import cv2
    import numpy as np
    from clip_agent import (
        captions,
        headline_templates,
        opencv_faces,
        pipeline,
        reframe,
        render,
        shots,
    )
    from clip_agent.config import load_config
    from clip_agent.manifest import load_manifest, save_manifest
    from clip_agent.transcribe import load_project_transcript

    clip = str(Path(sys.executable).with_name("clip"))
    commands = []

    def cli(*argv):
        result = subprocess.run(
            [clip, *map(str, argv)], check=False, capture_output=True, text=True
        )
        commands.append({"command": str(argv[0]), "exit": result.returncode})
        if result.returncode:
            (out / "private-cli-error.txt").write_text(result.stdout + result.stderr)
            raise RuntimeError(f"{argv[0]} failed; inspect private-cli-error.txt")
        return result.stdout

    originals = {
        name: digest(args.project / name) for name in ("project.json", "review.toml")
    }
    source_manifest = load_manifest(args.project)
    source = Path(source_manifest.source.path)
    transcript = load_project_transcript(args.project, source_manifest)
    assert transcript is not None and source.exists()
    assert (
        digest(source)
        == "a56d9f934de436211d92c2e9a5688cd9b6c8f0c52527d25c6c3d3b7f5fd66d91"
    )
    candidate = next(c for c in source_manifest.candidates if c.id == "facb5784c2")
    assert candidate.start <= 1502.0 and 1504.0 <= candidate.end
    home = out / "tool-home"
    (home / "models").mkdir(parents=True, exist_ok=args.verify_existing)
    for name in ("ggml-base.en.bin", "ggml-silero-v5.1.2.bin"):
        link = home / "models" / name
        if not link.exists():
            link.symlink_to((args.model_dir / name).resolve())
    profile = out / "qualification.toml"
    profile.write_text(f"""extends = "how-to-computer"
[privacy]
mode="local"
[brain]
backend="ollama"
ollama_model="qwen2.5:7b"
ollama_endpoint={json.dumps(args.ollama_endpoint)}
[reframe]
mode="shots"
width=540
height=960
fallback="center"
[editing]
punch="off"
[captions]
style="phrase-pop"
font="Inter-SemiBold.ttf"
font_size=32
size_frac=0.033
max_words=3
uppercase=false
vpos=0.74
safe_top=0.08
safe_bottom=0.88
hook_title=true
[audio]
normalize=false
[output]
require_approval=true
[publish]
enabled=false
""")
    cli(
        "profile",
        "import",
        profile,
        "--name",
        "burrow-qualification",
        "--force",
        "--yes",
    )
    cfg = load_config(profile="burrow-qualification")
    project = home / "clips/htc-original-qualification"
    (project / "candidates").mkdir(parents=True, exist_ok=args.verify_existing)
    cache = args.project / (source_manifest.transcript_cache_key + ".json")
    shutil.copy2(cache, project / cache.name)
    # Fixture preparation only; use the existing original candidate id and source.
    fixture = source_manifest.model_copy(deep=True)
    fixture.name = project.name
    fixture.config_resolved = cfg.model_dump(mode="json")
    fixture.config_layers = cfg.model_dump(mode="json")
    fixture.profile = "burrow-qualification"
    seeded = candidate.model_copy(deep=True)
    seeded.start, seeded.end = 1502.0, 1504.0
    seeded.edited_start = seeded.edited_end = None
    seeded.edl = seeded.edl_hash = None
    seeded.filename, seeded.status, seeded.alternate = "01_original.mp4", "cut", False
    seeded.title, seeded.titles = "Google", ["Google"]
    seeded.approval = None
    fixture.candidates = [seeded]
    fixture.caption_style = "phrase-pop"
    save_manifest(project, fixture)
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-ss",
            "1502",
            "-i",
            str(source),
            "-t",
            "2",
            "-c",
            "copy",
            "-y",
            str(project / "candidates/01_original.mp4"),
        ],
        check=True,
    )
    cli("review", project, "--overwrite", "--profile", "burrow-qualification")
    # Synthetic media qualifies music/closing combination, not HTC branding or content.
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=220:duration=4",
            "-y",
            str(out / "test-bed.wav"),
        ],
        check=True,
    )
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "lavfi",
            "-i",
            "color=c=green:s=540x960:r=30:d=1",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-y",
            str(out / "test-close.mp4"),
        ],
        check=True,
    )

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_args):
            pass

    served = out / "served-fixture-assets"
    served.mkdir(mode=0o700, exist_ok=args.verify_existing)
    for name in ("test-bed.wav", "test-close.mp4"):
        shutil.copy2(out / name, served / name)
    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Quiet, directory=str(served))
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    urls = f"http://127.0.0.1:{server.server_port}"
    uploaded = []

    class Client:
        def progress(self, *_args, **_kwargs):
            pass

        def complete(self, _job, result):
            self.result = result
            (out / (_job + "-completion.json")).write_text(
                json.dumps(result, indent=2) + "\n"
            )

        def fail(self, _job, message, code):
            self.failure = {"code": code, "message": message}

        def request(self, name, params, **_kwargs):
            assert name == "social_clip_job_source"
            music = params["asset"] == "music"
            path = out / ("test-bed.wav" if music else "test-close.mp4")
            return {
                "file_id": "music" if music else "closing",
                "project_id": "fixture-project",
                "content_type": "audio/wav" if music else "video/mp4",
                "byte_size": path.stat().st_size,
                "content_hash": digest(path),
                "max_bytes": 50 * 1024 * 1024,
                "url": urls + "/" + path.name,
            }

    client = Client()

    def upload(runner, job):
        target = out / (job["id"] + ".mp4")
        shutil.copy2(runner.output, target)
        uploaded.append(target)
        return "fixture-file-" + job["id"]

    class LoggedRunner(helper.Runner):
        def clip(self, step, argv, **kwargs):
            commands.append(
                {
                    "step": step,
                    "command": argv[0],
                    "profile": argv[argv.index("--profile") + 1]
                    if "--profile" in argv
                    else None,
                }
            )
            return super().clip(step, argv, **kwargs)

    runner = LoggedRunner(
        client,
        state_dir=out / "state",
        clip_bin=clip,
        uploader=upload,
        install_signal_handlers=False,
    )
    runner.clips.put(
        "fixture-clip",
        {
            "project": project.name,
            "path": str(project),
            "tool_clip_id": "facb5784c2",
            "profile_id": "fixture-profile",
        },
    )
    base = {
        "clip_user_profile": "burrow-qualification",
        "candidate_id": "facb5784c2",
        "source_id": "GES6h4843C4",
        "in_s": 1502.0,
        "out_s": 1504.0,
        "base_render_id": "fixture-base",
        "expected_rev": 2,
    }
    context = {
        "clip_rev": 1,
        "clip_next_rev": 2,
        "base_render_id": "fixture-base",
        "project_id": "fixture-project",
        "headline_voice": {
            "revision": "8-provisional",
            "direction": "Entertainment first, comedy and positivity; remaining show voice rules incomplete.",
        },
    }
    receipts = []

    def run(name, payload, kind="rerender"):
        job = {
            "id": name,
            "kind": kind,
            "clip_id": "fixture-clip",
            "profile_id": "fixture-profile",
            "payload": {**base, **payload},
        }
        before = len(uploaded)
        if args.verify_existing:
            result = json.loads((out / (name + "-completion.json")).read_text())
            uploaded.append(out / (name + ".mp4"))
        else:
            outcome = runner.run_job(job, copy.deepcopy(context))
            assert outcome["status"] == "done", (
                outcome,
                getattr(client, "failure", None),
            )
            assert len(uploaded) == before + 1
            result = client.result
        if payload.get("headline_template"):
            receipt = result["headline_render"]
            assert receipt["template"] == payload["headline_template"]["template"]
            assert (
                receipt["renderer_sha256"]
                == "b36d7ec515da07e5e432d1eca57c639ecc6007126cc68110d1bb367c99b45d84"
            )
            assert (
                receipt["assets"]["logo_sha256"]
                == "7cbddeac97ad8fe3aa53e867cf0e5648329f500e528f2302e1b2ebcba8bf767f"
            )
            assert receipt["timing"] == {
                "entrance_s": 0.2,
                "hold_s": 0.55,
                "exit_s": 0.25,
                "total_s": 1.0,
            }
            assert receipt["output_sha256"] == digest(uploaded[-1])
        receipts.append(
            {"name": name, "result": result, "sha256": digest(uploaded[-1])}
        )
        return result

    try:
        first = run(
            "chrome-edit",
            {
                "headline_template": contract("chrome-hook"),
                "headline": {"consumer": "edit", "requested_headline": "Google"},
            },
        )
        wording = first["headline_render"]["content"]
        if not args.smoke:
            for style in ("neon-broadcast", "arcade-punch"):
                run(
                    style,
                    {
                        "headline_template": contract(style),
                        "headline_base": wording,
                        "appearance": True,
                        "look": {"cap": {"style": "phrase-pop"}},
                    },
                )
            # Replay the exact old wording after a conflicting mutable edit and default change.
            run(
                "mutable-edit",
                {
                    "headline_template": contract("chrome-hook"),
                    "headline": {
                        "consumer": "edit",
                        "requested_headline": "To a lesser degree",
                    },
                },
            )
            profile.write_text(
                profile.read_text().replace(
                    "hook_title=true",
                    'hook_title=true\nhook_title_template="arcade-punch"',
                )
            )
            cli(
                "profile",
                "import",
                profile,
                "--name",
                "burrow-qualification",
                "--force",
                "--yes",
            )
            replay = run(
                "queued-chrome-replay",
                {
                    "headline_template": contract("chrome-hook"),
                    "headline_base": wording,
                    "appearance": True,
                    "look": {"cap": {"style": "phrase-pop"}},
                },
            )
            assert replay["headline_render"]["content"] == wording
            assert digest(out / "chrome-edit.mp4") == digest(
                out / "queued-chrome-replay.mp4"
            )
            for style in (
                "plain",
                "karaoke",
                "type-on",
                "focus-word",
                "editorial-punch",
            ):
                run(
                    "caption-" + style,
                    {
                        "headline_template": contract("chrome-hook"),
                        "headline_base": wording,
                        "appearance": True,
                        "look": {"cap": {"style": style}},
                    },
                )
            run(
                "disabled",
                {
                    "appearance": True,
                    "look": {
                        "title": {"enabled": False},
                        "cap": {"style": "phrase-pop"},
                    },
                    "clip_overrides": {
                        "mapped": {"captions.hook_title": False},
                        "unmapped": [],
                    },
                },
            )
            close = out / "test-close.mp4"
            run(
                "music-closing",
                {
                    "headline_template": contract("chrome-hook"),
                    "headline_base": wording,
                    "appearance": True,
                    "look": {"cap": {"style": "phrase-pop"}},
                    "music": {"enabled": True, "file_id": "music", "level_db": -24},
                    "closing_video": {
                        "enabled": True,
                        "file_id": "closing",
                        "project_id": "fixture-project",
                        "content_type": "video/mp4",
                        "byte_size": close.stat().st_size,
                        "content_hash": digest(close),
                        "audio": "mute",
                    },
                },
            )
            if args.generation:
                run(
                    "new-clip",
                    {
                        "headline_template": contract("chrome-hook"),
                        "episode_job_id": "fixture-parent",
                        "expected_rev": 1,
                    },
                    kind="new_clip",
                )
                run(
                    "regenerate",
                    {
                        "headline_template": contract("chrome-hook"),
                        "fix": {"operation": "regenerate_headline"},
                    },
                )
        negative_probes = []
        if args.smoke:
            run(
                "disabled",
                {
                    "appearance": True,
                    "look": {
                        "title": {"enabled": False},
                        "cap": {"style": "phrase-pop"},
                    },
                    "clip_overrides": {
                        "mapped": {"captions.hook_title": False},
                        "unmapped": [],
                    },
                },
            )

            def refused(name, payload, code):
                count = len(uploaded)
                outcome = runner.run_job(
                    {
                        "id": name,
                        "kind": "rerender",
                        "clip_id": "fixture-clip",
                        "profile_id": "fixture-profile",
                        "payload": {**base, **payload},
                    },
                    copy.deepcopy(context),
                )
                assert outcome["status"] == "failed" and outcome["code"] == code, (
                    outcome,
                    getattr(client, "failure", None),
                )
                assert len(uploaded) == count and not (out / (name + ".mp4")).exists()
                negative_probes.append({"name": name, "code": code, "upload": False})

            refused(
                "unsafe-fit",
                {
                    "headline_template": contract("chrome-hook"),
                    "headline_base": wording,
                    "appearance": True,
                    "look": {"cap": {"style": "phrase-pop"}},
                    "clip_overrides": {
                        "mapped": {"captions.safe_top": 0.28},
                        "unmapped": [],
                    },
                },
                "HEADLINE_LAYOUT_SHORTEN_TEXT",
            )
            wrong = out / "wrong-assets"
            shutil.copytree(args.assets, wrong, dirs_exist_ok=args.verify_existing)
            (wrong / "assets/htc-official-logo-crop.png").write_bytes(
                b"wrong logo bytes"
            )
            os.environ["CLIP_RUNNER_HEADLINE_ASSETS"] = str(wrong)
            try:
                refused(
                    "wrong-asset",
                    {
                        "headline_template": contract("chrome-hook"),
                        "headline_base": wording,
                        "appearance": True,
                    },
                    "HEADLINE_ASSET_MISMATCH",
                )
            finally:
                os.environ["CLIP_RUNNER_HEADLINE_ASSETS"] = str(args.assets.resolve())
        assert originals == {name: digest(args.project / name) for name in originals}
        assert not list((home / "profiles").glob("*-job-*"))
        assert not list((out / "state/tmp").rglob("*.toml"))
        assert not list((out / "state/tmp").rglob("headline-request*"))
        # Independent original-source reference with the measured crop used by actual CLI.
        cfg.captions.hook_title_template = "chrome-hook"
        plan = reframe.plan_reframe(
            [],
            clip_start=1502,
            clip_dur=2,
            src_w=1920,
            src_h=1080,
            config=cfg,
            src=source,
            src_start=1502,
        )
        assert all(s.layout == "crop" and s.face_box for s in plan.segments)
        render.render_clip(
            source,
            out / "source-control.mp4",
            clip_start=1502,
            clip_dur=2,
            plan=plan,
            caption_track=None,
            config=cfg,
        )

        def frames(path):
            # Native source is NTSC 24000/1001. Normalize samples for timing
            # comparisons without claiming that the encoded video is 30 fps.
            raw = subprocess.check_output(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-i",
                    str(path),
                    "-vf",
                    "fps=30",
                    "-f",
                    "rawvideo",
                    "-pix_fmt",
                    "bgr24",
                    "-",
                ]
            )
            stride = 960 * 540 * 3
            assert len(raw) % stride == 0
            return list(np.frombuffer(raw, dtype=np.uint8).reshape(-1, 960, 540, 3))

        control = frames(out / "source-control.mp4")
        off_cfg = cfg.model_copy(deep=True)
        off_cfg.captions.hook_title = False
        off_plan = reframe.plan_reframe(
            [],
            clip_start=1502,
            clip_dur=2,
            src_w=1920,
            src_h=1080,
            config=off_cfg,
            src=source,
            src_start=1502,
        )
        render.render_clip(
            source,
            out / "disabled-control.mp4",
            clip_start=1502,
            clip_dur=2,
            plan=off_plan,
            caption_track=None,
            config=off_cfg,
        )
        off_control = frames(out / "disabled-control.mp4")

        def pcm(path, start=0, seconds=2):
            return np.frombuffer(
                subprocess.check_output(
                    [
                        "ffmpeg",
                        "-v",
                        "error",
                        "-ss",
                        str(start),
                        "-i",
                        str(path),
                        "-t",
                        str(seconds),
                        "-ar",
                        "16000",
                        "-ac",
                        "1",
                        "-f",
                        "f32le",
                        "-",
                    ]
                ),
                dtype="<f4",
            )

        speech = pcm(out / "source-control.mp4")
        assert len(speech) >= 31000 and float(np.sqrt(np.mean(speech**2))) > 0.005
        decoded = []
        # Every delivered frame during title entrance/hold/exit gets a fresh face check.
        names = (
            ("chrome-edit", "disabled")
            if args.smoke
            else (
                "chrome-edit",
                "neon-broadcast",
                "arcade-punch",
                "queued-chrome-replay",
                "disabled",
                "music-closing",
            )
        )
        for name in names:
            actual = frames(out / (name + ".mp4"))
            native = json.loads(
                subprocess.check_output(
                    [
                        "ffprobe",
                        "-v",
                        "error",
                        "-count_frames",
                        "-select_streams",
                        "v:0",
                        "-show_entries",
                        "stream=nb_read_frames,r_frame_rate,duration,width,height",
                        "-of",
                        "json",
                        str(out / (name + ".mp4")),
                    ]
                )
            )["streams"][0]
            assert native["r_frame_rate"] == "24000/1001"
            assert int(native["nb_read_frames"]) == (
                72 if name == "music-closing" else 48
            )
            assert (native["width"], native["height"]) == (540, 960)
            assert len(actual) == (90 if name == "music-closing" else 60)
            audio = pcm(out / (name + ".mp4"))
            assert abs(len(audio) - len(speech)) <= 1024
            n_audio = min(len(audio), len(speech))
            correlation = float(np.corrcoef(audio[:n_audio], speech[:n_audio])[0, 1])
            codec_match = None
            if name == "music-closing":
                codec_match = codec_speech_match(speech, audio)
            else:
                assert correlation > 0.999, (name, correlation)
            if name == "disabled":
                top_diff = [
                    float(np.abs(a[:288].astype(float) - b[:288].astype(float)).mean())
                    for a, b in zip(actual, off_control)
                ]
                assert max(top_diff) < 3, "disabled output still has an opening title"
                assert (
                    np.abs(
                        actual[15][600:].astype(float)
                        - off_control[15][600:].astype(float)
                    ).mean()
                    > 0.3
                )
                cv2.imwrite(str(out / "disabled-hold.png"), actual[15])
            if name != "disabled":
                diffs = [
                    float(np.abs(a[:288].astype(float) - b[:288].astype(float)).mean())
                    for a, b in zip(actual, control)
                ]
                assert diffs[15] > 3 and diffs[31] < 3 and max(diffs[32:60]) < 3, (
                    name,
                    diffs[15],
                    max(diffs[32:60]),
                )
                assert (
                    np.abs(
                        actual[15][600:].astype(float) - control[15][600:].astype(float)
                    ).mean()
                    > 0.3
                )
                assert (
                    np.abs(
                        actual[45][600:].astype(float) - control[45][600:].astype(float)
                    ).mean()
                    > 0.3
                )
                for n, im in enumerate(actual[:60]):
                    delta = np.abs(
                        im[:288].astype(np.int16) - control[n][:288].astype(np.int16)
                    ).max(axis=2)
                    yy, xx = np.where(delta > 80)
                    if len(xx):
                        # Eight decoded pixels allow H.264 ringing; static RGBA
                        # matrix bounds above use the exact no-tolerance margins.
                        assert (
                            xx.min() >= 35
                            and xx.max() <= 483
                            and yy.min() >= 69
                            and yy.max() <= 287
                        ), (name, n, "unsafe decoded title extent")
                    path = out / "face-check.png"
                    cv2.imwrite(str(path), im)
                    faces = opencv_faces.detect(path)
                    assert len(faces) == 1, (name, n, "face missing")
                    f = faces[0]
                    assert (
                        (0.29 if n < 30 else 0) <= f.y
                        and f.y + f.h < 0.91
                        and 0 <= f.x < f.x + f.w <= 1
                    ), (name, n, f)
                cv2.imwrite(str(out / (name + "-hold.png")), actual[15])
                cv2.imwrite(str(out / (name + "-exit.png")), actual[35])
            if name == "music-closing":
                # Exactly one second of the green test card, after two seconds speech.
                green = [
                    i
                    for i, im in enumerate(actual)
                    if im[480, 270, 1] > 70
                    and im[480, 270, 1] > im[480, 270, 0] * 2
                    and im[480, 270, 1] > im[480, 270, 2] * 2
                ]
                assert (
                    green and abs(green[0] - 60) <= 1 and abs(len(green) - 30) <= 1
                ), green
                assert green == list(range(green[0], green[-1] + 1)), green
                tail = pcm(out / "music-closing.mp4", start=2.1, seconds=0.8)
                assert len(tail) >= 12000
                tail_fft = np.fft.rfft(tail)
                tail_hz = np.fft.rfftfreq(len(tail), 1 / 16000)
                energy = np.abs(tail_fft) ** 2
                # Closing audio mute does not disable the independent music bed.
                # The fixture card has no SFX; only its 220 Hz music may continue.
                bed_share = float(
                    energy[(tail_hz > 205) & (tail_hz < 235)].sum() / energy.sum()
                )
                assert bed_share > 0.95 and float(np.sqrt(np.mean(tail**2))) < 0.01
                codec_match["closing_bed_share"] = bed_share
            decoded.append(
                {
                    "name": name,
                    "frames": len(actual),
                    "sample_fps": 30,
                    "native": native,
                    "speech_correlation": correlation,
                    "speech_codec_match": codec_match,
                    "face_checks": 60 if name != "disabled" else 0,
                    "title_face_checks": 30 if name != "disabled" else 0,
                }
            )
        matrix = layout_matrix(
            out,
            args.assets / "assets/htc-official-logo-crop.png",
            [[0.1, 0.32, 0.9, 0.86]],
        )
        doctors = [c for c in commands if c.get("command") == "doctor"]
        if not args.verify_existing:
            assert any(c.get("profile") == "burrow-qualification" for c in doctors)
            assert any("-job-" in (c.get("profile") or "") for c in doctors)
        result = {
            "runtime": "isolated-linux-runtime",
            "verified_existing_outputs": args.verify_existing,
            "helper_sha256": digest(args.helper),
            "tool": json.loads(cli("version", "--json")),
            "modules": {
                m.__name__: {"path": m.__file__, "sha256": digest(m.__file__)}
                for m in (
                    captions,
                    headline_templates,
                    opencv_faces,
                    pipeline,
                    reframe,
                    shots,
                )
            },
            "source_sha256": digest(source),
            "source_span": [1502, 1504],
            "original_candidate_id": candidate.id,
            "original_candidate_span": [candidate.start, candidate.end],
            "original_project_unchanged": True,
            "receipts": receipts,
            "decoded": decoded,
            "negative_probes": negative_probes,
            "layout_matrix": matrix,
            "commands": commands,
            "live_generation_exercised": args.generation,
            "publication": False,
        }
        (out / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
        print(
            json.dumps(
                {
                    "status": "passed",
                    "renders": len(uploaded),
                    "matrix_cases": len(matrix),
                }
            )
        )
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
