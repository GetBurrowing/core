"""Decode source-comparison frames beside their clean renders and assert safe bounds.

Reads only supported final delivery MP4/SRT outputs. No project manifest or
transcript cache parsing. Text stays local; the receipt contains timestamps only.
"""

import argparse
import json
import re
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def frame(path, t):
    raw = subprocess.check_output(
        [
            "ffmpeg",
            "-v",
            "error",
            "-ss",
            str(t),
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
    return np.frombuffer(raw, dtype=np.uint8).reshape(640, 360, 3)


def seconds(s):
    h, m, s = s.replace(",", ".").split(":")
    return int(h) * 3600 + int(m) * 60 + float(s)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    args = parser.parse_args()
    root = args.workspace
    srt = next((root / "source-project-copy/final").glob("*.srt")).read_text()
    intervals = re.findall(r"(\d\d:\d\d:\d\d,\d{3}) --> (\d\d:\d\d:\d\d,\d{3})", srt)
    starts = [seconds(a) for a, _ in intervals]
    # Last decodable frame starts before the container duration; keep clear of
    # its exclusive end, including when AAC padding outlasts the last video PTS.
    times = sorted(
        {
            0.0,
            0.05,
            0.1,
            0.15,
            1.5,
            4.2,
            6.0,
            9.5,
            10.2,
            *(round(max(0, t + d), 3) for t in starts for d in (-0.05, 0, 0.05, 0.1)),
        }
    )
    contact_times = (0.1, 0.15, 1.5, 1.76, 4.2, 6.0, 9.6, 10.2)
    board = Image.new("RGB", (360 * len(contact_times), 670 * 3), "#202020")
    draw = ImageDraw.Draw(board)
    evidence = {"schema": "caption-comparison-frames/1", "times_s": times, "styles": {}}
    for row, style in enumerate(("type-on", "focus-word", "editorial-punch")):
        checks = []
        for t in times:
            shown = frame(root / (style + ".mp4"), t)
            clean = frame(root / (style + "-clean.mp4"), t)
            changed = (
                np.max(np.abs(shown.astype(float) - clean.astype(float)), axis=2) > 55
            )
            ys, _ = np.where(changed)
            outside = changed.copy()
            outside[396:501] = False
            assert not outside.any(), (style, t, "caption pixels outside safe band")
            checks.append(
                {
                    "timestamp_s": t,
                    "changed_pixels": int(changed.sum()),
                    "y_bounds": [int(ys.min()), int(ys.max())] if len(ys) else None,
                }
            )
        assert any(c["changed_pixels"] > 100 for c in checks[:5]), "first words missing"
        assert checks[-1]["changed_pixels"] > 100, "last words missing"
        for col, t in enumerate(contact_times):
            im = Image.fromarray(frame(root / (style + ".mp4"), t))
            board.paste(im, (col * 360, row * 670 + 30))
            draw.text(
                (col * 360 + 8, row * 670 + 8), f"{style} / {t:.3f}s", fill="white"
            )
        evidence["styles"][style] = checks
    board.save(root / "frame-comparison.jpg", quality=85)
    (root / "frame-checks.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print("PASS: first/last words and pre/on/mid/post phrase frames stay in safe band")


if __name__ == "__main__":
    main()
