"""Authorized original-source opening fixture; never claims, approves or publishes jobs.
Run with the qualified tool's Python; --source and --project must be originals.
"""

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

from clip_agent import captions, headline_templates, hooks, render
from clip_agent.config import FONTS_DIR, Config
from clip_agent.manifest import Candidate, load_manifest
from clip_agent.reframe import CropBox, PlanSegment, ReframePlan
from clip_agent.transcribe import load_project_transcript
from PIL import Image


def digest(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--logo", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--face-model", required=True)
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    assert ffmpeg, "FFmpeg is required"
    import cv2

    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    start, duration, w, h = 1479.0, 10.0, 540, 960
    original_state = {
        name: digest(Path(args.project) / name)
        for name in ["project.json", "review.toml"]
    }
    manifest = load_manifest(args.project)
    assert Path(manifest.source.path).resolve() == Path(args.source).resolve()
    transcript = load_project_transcript(args.project, manifest)
    assert transcript is not None
    words = [
        word for word in transcript.words if start <= word.start < start + duration
    ]
    evidence = " ".join(word.text for word in words)
    detector = cv2.FaceDetectorYN.create(args.face_model, "", (1920, 1080), 0.75)
    cap = cv2.VideoCapture(args.source)
    face_boxes = []
    source_fps = cap.get(cv2.CAP_PROP_FPS)
    assert source_fps > 0
    cap.set(cv2.CAP_PROP_POS_MSEC, start * 1000)
    # Every source frame is checked; choose the left-seat full-frame crop only.
    for frame_no in range(round(duration * source_fps)):
        ok, frame = cap.read()
        assert ok
        faces = detector.detect(frame)[1]
        assert faces is not None, f"face missing at {frame_no}"
        matches = [f for f in faces if 150 < f[0] < 500]
        assert matches, f"left face missing at {frame_no}"
        x, y, fw, fh = matches[0][:4]
        assert 20 <= x and x + fw <= 626
        face_boxes.append(
            [
                (float(x) - 20) / 606,
                float(y) / 1080,
                (float(x + fw) - 20) / 606,
                float(y + fh) / 1080,
            ]
        )
    cap.release()
    union = [
        min(b[0] for b in face_boxes),
        min(b[1] for b in face_boxes),
        max(b[2] for b in face_boxes),
        max(b[3] for b in face_boxes),
    ]
    plan = ReframePlan(
        w,
        h,
        [
            PlanSegment(
                0, duration, "crop", [CropBox(20, 0, 606, 1080)], face_box=tuple(union)
            )
        ],
    )
    cfg = Config()
    cfg.audio.normalize = False
    cfg.captions.style = "phrase-pop"
    cfg.captions.uppercase = False
    cfg.captions.max_words = 3
    cfg.captions.font = "Inter-SemiBold.ttf"
    cfg.captions.font_size = 32
    cfg.captions.vpos = 0.72
    cfg.captions.safe_bottom = 0.85
    cfg.captions.safe_top = 0.08
    cfg.captions.hook_title = True
    cfg.captions.hook_title_seconds = 3.5
    cfg.captions.hook_title_logo_path = str(Path(args.logo).resolve())
    cfg.captions.hook_title_logo_sha256 = digest(args.logo)
    cfg.captions.hook_title_face_boxes = [union]
    samples = [
        ("chrome-hook", "Come back."),
        ("neon-broadcast", "I'll save that for next week."),
        ("arcade-punch", "I'll save that for next week. You'll have to come back."),
    ]
    # Deterministic, extractive selection proposals are fixture setup, never a live-model claim.
    proposal = Candidate(
        id="opening-layout-fixture",
        rank=1,
        start=start,
        end=start + duration,
        title=samples[0][1],
        titles=[text for _, text in samples],
    )
    cfg.selection.title_hint += "\nShow voice snapshot 8: entertainment first, comedy and positivity; remaining voice rules incomplete."
    generated = hooks.generate_variants(
        cfg,
        proposal,
        evidence,
        n=3,
        mix={},
        use_brain=False,
        names=set(),
        original=evidence,
    )
    assert [variant.title for variant in generated.variants] == [
        text for _, text in samples
    ]
    tool_info = json.loads(
        subprocess.check_output(
            [str(Path(sys.executable).with_name("clip")), "version", "--json"]
        )
    )
    receipt = {
        "tool": tool_info,
        "headline_policy": {
            "boundary": "hooks.generate_variants",
            "fixture_selection_proposals": True,
            "live_model_generation": False,
            "voice_revision": "8-provisional",
        },
        "logo_sha256": digest(args.logo),
        "font_sha256": digest(FONTS_DIR / "Anton-Regular.ttf"),
        "timing": {"title_exit_s": 3.5, "entrance_s": 0.2, "exit_s": 0.25},
        "python": sys.executable,
        "source_sha256": digest(args.source),
        "source_start": start,
        "duration": duration,
        "face_union": union,
        "modules": {},
        "samples": [],
    }
    for module in [captions, headline_templates]:
        receipt["modules"][module.__name__] = {
            "path": module.__file__,
            "sha256": digest(module.__file__),
        }
    clean = out / "clean-control.mp4"
    render.render_clip(
        args.source,
        clean,
        clip_start=start,
        clip_dur=duration,
        plan=plan,
        caption_track=None,
        config=cfg,
    )

    def decoded(path):
        raw = subprocess.check_output(
            [
                ffmpeg,
                "-v",
                "error",
                "-i",
                str(path),
                "-vf",
                "fps=30",
                "-f",
                "rawvideo",
                "-pix_fmt",
                "rgb24",
                "-",
            ]
        )
        assert len(raw) == w * h * 3 * 300
        return raw

    clean_raw = decoded(clean)
    for style, text in samples:
        assert not hooks.check_variant(
            text, "", "selection", evidence, names=[], original=evidence
        ).problem
        cfg.captions.hook_title_template = style
        cfg.captions.hook_title_emphasis = [len(text.split()) - 1]
        cfg.captions.hook_title_emphasis_text = text
        spec = headline_templates.layout(
            text,
            width=w,
            height=h,
            look=cfg.captions,
            font_path=FONTS_DIR / "Anton-Regular.ttf",
        )
        track = out / (style + ".mov")
        captions.render_caption_track(
            words,
            track,
            width=w,
            height=h,
            style="phrase-pop",
            config=cfg,
            fonts_dir=FONTS_DIR,
            clip_start=start,
            clip_dur=duration,
            hook_title=text,
        )
        video = out / (style + ".mp4")
        render.render_clip(
            args.source,
            video,
            clip_start=start,
            clip_dur=duration,
            plan=plan,
            caption_track=track,
            config=cfg,
        )
        # Compare decoded delivered MP4 pixels with a separately encoded clean control.
        import numpy as np

        actual = (
            np.frombuffer(decoded(video), dtype=np.uint8)
            .reshape(300, h, w, 3)
            .astype(np.int16)
        )
        control = (
            np.frombuffer(clean_raw, dtype=np.uint8)
            .reshape(300, h, w, 3)
            .astype(np.int16)
        )
        top_diff = np.abs(
            actual[:, : round(h * 0.3)] - control[:, : round(h * 0.3)]
        ).mean(axis=(1, 2, 3))
        assert top_diff[45] > 3, (style, "MP4 title absent", float(top_diff[45]))
        assert top_diff[105] < 3, (style, "MP4 title misses 3.5-second exit")
        assert max(top_diff[110:]) < 3, (style, "MP4 title persists")
        assert (
            np.abs(
                actual[150, round(h * 0.6) :] - control[150, round(h * 0.6) :]
            ).mean()
            > 0.5
        ), "MP4 caption absent after exit"
        # Decode actual alpha frames independently from the image/layout implementation.
        raw = subprocess.check_output(
            [
                ffmpeg,
                "-v",
                "error",
                "-i",
                str(track),
                "-f",
                "rawvideo",
                "-pix_fmt",
                "rgba",
                "-",
            ]
        )
        stride = w * h * 4
        count = len(raw) // stride
        assert count == 300, (style, count)
        for n in range(count):
            frame = Image.frombytes("RGBA", (w, h), raw[n * stride : (n + 1) * stride])
            bb = frame.crop((0, round(h * 0.6), w, h)).getbbox()
            assert bb is None or bb[3] - bb[1] <= 48, (style, n, "caption wrapped")
        for index in [0, 3, 6, 45, 98, 104, 105, 150, 299]:
            im = Image.frombytes(
                "RGBA", (w, h), raw[index * stride : (index + 1) * stride]
            )
            title = im.crop((0, 0, w, round(h * 0.3)))
            if index == 0 or index >= 105:
                assert title.getbbox() is None, (style, index, "title persists")
            elif index == 45:
                assert title.getbbox() is not None
                assert im.crop((0, round(h * 0.6), w, h)).getbbox() is not None, (
                    "caption missing during title"
                )
            subprocess.run(
                [
                    ffmpeg,
                    "-v",
                    "error",
                    "-ss",
                    str(index / 30),
                    "-i",
                    str(video),
                    "-frames:v",
                    "1",
                    "-y",
                    str(out / f"{style}-{index}.png"),
                ],
                check=True,
            )
        assert (
            Image.frombytes("RGBA", (w, h), raw[150 * stride : 151 * stride])
            .crop((0, round(h * 0.6), w, h))
            .getbbox()
            is not None
        ), "captions stopped after title"
        receipt["samples"].append(
            {
                "template": style,
                "text": text,
                "font_size": spec["size"],
                "lines": [[word for _, word in line] for line in spec["lines"]],
                "sha256": digest(video),
                "frames": count,
                "mp4_title_diff_hold": float(top_diff[45]),
                "mp4_title_diff_after_max": float(max(top_diff[110:])),
            }
        )
    assert {
        name: digest(Path(args.project) / name) for name in original_state
    } == original_state
    receipt["original_project_unchanged"] = True
    (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")


if __name__ == "__main__":
    main()
