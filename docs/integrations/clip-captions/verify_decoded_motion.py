"""Independent pixel measurements of decoded temporal frames, not config acceptance.

First run verify_temporal_frames.py with the qualified tool's Python. This reads
its decoded frames and fails if entries/pill motion collapse to an instant cut.
"""

import json
import sys
from itertools import pairwise
from pathlib import Path

import numpy as np
from PIL import Image


def measure(path):
    a = np.array(Image.open(path).convert("RGBA"))
    text = (
        (a[:, :, 0] > 210) & (a[:, :, 1] > 210) & (a[:, :, 2] > 210) & (a[:, :, 3] > 0)
    )
    ys, _ = np.where(text)
    alpha = a[:, :, 3][text]
    violet = (
        (a[:, :, 0] > 80)
        & (a[:, :, 0] < 150)
        & (a[:, :, 1] < 110)
        & (a[:, :, 2] > 200)
        & (a[:, :, 3] > 220)
    )
    yp, xp = np.where(violet)
    # Type-on text alpha-composites over its scrim; measure decoded red intensity
    # as well as alpha. Teal underline red is only 46 and cannot satisfy this.
    max_red = int(a[:, :, 0].max())
    red_alpha = int(a[:, :, 3][a[:, :, 0] == max_red].max())
    return {
        "max_red": max_red,
        "brightest_red_alpha": red_alpha,
        "text_max_alpha": int(alpha.max()) if len(alpha) else 0,
        "text_y_centroid": float((ys * alpha).sum() / alpha.sum())
        if len(alpha)
        else None,
        "violet_bounds": [int(xp.min()), int(yp.min()), int(xp.max()), int(yp.max())]
        if len(xp)
        else None,
    }


def main():
    root = Path(sys.argv[1])
    times = (0.0, 0.033, 0.067, 0.1, 0.2, 0.4, 0.433, 0.467, 0.5, 0.6)
    result = {
        style: {str(t): measure(root / f"{style}-{t:.3f}.png") for t in times}
        for style in ("type-on", "focus-word", "editorial-punch")
    }
    entry = result["type-on"]
    assert (
        entry["0.0"]["max_red"] < entry["0.033"]["max_red"] < entry["0.067"]["max_red"]
    )
    assert entry["0.033"]["brightest_red_alpha"] < entry["0.1"]["brightest_red_alpha"]
    pill = result["focus-word"]
    boxes = [pill[str(t)]["violet_bounds"] for t in (0.4, 0.433, 0.467, 0.6)]
    assert all(boxes)
    assert all(a[0] < b[0] and a[2] < b[2] for a, b in pairwise(boxes))
    widths = [b[2] - b[0] + 1 for b in boxes]
    assert widths[0] < widths[1] < widths[-1], "pill width did not ease"
    entrance = result["editorial-punch"]
    alpha = [entrance[str(t)]["text_max_alpha"] for t in (0.033, 0.067, 0.1, 0.2)]
    assert 0 < alpha[0] < alpha[1] < alpha[2] < alpha[3] == 255
    assert (
        entrance["0.033"]["text_y_centroid"]
        > entrance["0.067"]["text_y_centroid"]
        > entrance["0.1"]["text_y_centroid"]
    )
    for style in result:
        assert Image.open(root / f"{style}-2.400.png").getbbox() is None
    (root / "decoded-measurements.json").write_text(json.dumps(result, indent=2) + "\n")
    print(
        "PASS: decoded intermediate alpha/intensity, pill position+width, rise, cleared gap"
    )


if __name__ == "__main__":
    main()
