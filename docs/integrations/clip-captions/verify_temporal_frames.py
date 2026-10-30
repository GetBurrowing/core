"""TEST ONLY: decode real temporal alpha tracks, then composite light/dark footage.
Fixture words/source are synthetic; the renderer and FFmpeg are unmodified.
This is stage-1 temporal evidence, not the authorized-source samples of stage 5.
"""

import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

from clip_agent import captions
from clip_agent.config import FONTS_DIR, Config
from clip_agent.models import Word

ffmpeg = shutil.which("ffmpeg")
assert ffmpeg, "ffmpeg is required"
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
words = [
    Word(t, s, e)
    for t, s, e in [
        ("Most", 0, 0.3),
        ("people", 0.4, 0.7),
        ("skip", 0.8, 1.1),
        ("backups.", 1.2, 1.6),
        ("Keep", 3.3, 3.6),
        ("them", 3.7, 4),
        ("safe.", 4.1, 4.5),
    ]
]
receipt = {
    "test_only": True,
    "module": captions.__file__,
    "python": sys.executable,
    "styles": {},
}
for style in ["type-on", "focus-word", "editorial-punch"]:
    mov = out / (style + ".mov")
    captions.render_caption_track(
        words,
        mov,
        width=360,
        height=640,
        style=style,
        config=Config(),
        fonts_dir=FONTS_DIR,
        clip_start=0,
        clip_dur=5,
    )
    raw = subprocess.check_output(
        [
            ffmpeg,
            "-v",
            "error",
            "-i",
            str(mov),
            "-f",
            "rawvideo",
            "-pix_fmt",
            "rgba",
            "-",
        ]
    )
    n = 360 * 640 * 4
    from PIL import Image

    timestamps = [0, 0.033, 0.067, 0.1, 0.2, 0.4, 0.433, 0.467, 0.5, 0.6, 1.5, 2.4, 4.5]
    hashes = []
    for t in timestamps:
        i = round(t * 30)
        frame = raw[i * n : (i + 1) * n]
        im = Image.frombytes("RGBA", (360, 640), frame)
        im.save(out / f"{style}-{t:.3f}.png")
        hashes.append(hashlib.sha256(frame).hexdigest())
        if im.getbbox():
            assert 396 <= im.getbbox()[1] < im.getbbox()[3] <= 500
        if t == 2.4:
            assert im.getbbox() is None, "gap does not clear"
    # At least one intermediate phase changes actual decoded frames.
    assert len(set(hashes[:6])) > 2 if style != "focus-word" else hashes[5] != hashes[8]
    for color in ["white", "0x121212"]:
        mp4 = out / f"{style}-{color}.mp4"
        subprocess.run(
            [
                ffmpeg,
                "-y",
                "-v",
                "error",
                "-f",
                "lavfi",
                "-i",
                f"color=c={color}:s=360x640:r=30:d=5",
                "-i",
                str(mov),
                "-filter_complex",
                "[0:v][1:v]overlay=shortest=1",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                str(mp4),
            ],
            check=True,
        )
    receipt["styles"][style] = {
        "track_sha256": hashlib.sha256(mov.read_bytes()).hexdigest(),
        "frames": dict(zip(map(str, timestamps), hashes)),
        "frame_count": len(raw) // n,
    }
(out / "receipt.json").write_text(json.dumps(receipt, indent=2))
