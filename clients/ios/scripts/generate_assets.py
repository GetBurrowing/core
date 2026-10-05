#!/usr/bin/env python3
"""Generate the Suite iOS colour assets and launch mark.

Colour values are the Suite web tokens (apps/platform/assets/css/app.css on
origin/main, read 2026-10-04) mapped onto semantic slot names. The slot ->
token table lives in clients/ios/README.md; edit both together.

The app icons (AppIcon.appiconset) are the Burrow arch, committed as
finished art; the launch mark is cut from them.

    python3 clients/ios/scripts/generate_assets.py
"""
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "ios" / "App" / "App" / "Assets.xcassets"
# Colour slots are shared by the app, the share extension and the widgets.
COLOURS = ROOT / "ios" / "Shared" / "Colors.xcassets"

# slot: (light, dark), sRGB hex. oklch tokens converted with the CSS Color 4
# OKLab matrices; see README for the source token of each.
SLOTS = {
    "primary": ("#4EDAEB", "#06D5ED"),       # primary: oklch(82% 0.12 207) / #06D5ED
    "onPrimary": ("#000000", "#000000"),     # primary-content
    "accent": ("#06D5ED", "#06D5ED"),        # accent (app.css, both themes)
    "surface": ("#FFFFFF", "#171B25"),       # base-100
    "surfaceMuted": ("#F2F2F2", "#000306"),  # base-200
    "onSurface": ("#000000", "#EEEEEE"),     # base-content
    "muted": ("#5A5355", "#958D8F"),         # neutral text: oklch(45% .01 0) / oklch(65% .01 0)
    "border": ("#D7D7D7", "#232A38"),        # edge
    "destructive": ("#F1383E", "#F1383E"),   # error: oklch(63% 0.22 25)
}

INFO = {"author": "xcode", "version": 1}


def comp(hexv):
    h = hexv.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    return {"color-space": "srgb", "components": {
        "alpha": "1.000", "red": f"0x{r:02X}", "green": f"0x{g:02X}", "blue": f"0x{b:02X}"}}


def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n")


def colours():
    for slot, (light, dark) in SLOTS.items():
        write_json(COLOURS / f"{slot}.colorset" / "Contents.json", {
            "colors": [
                {"idiom": "universal", "color": comp(light)},
                {"idiom": "universal", "color": comp(dark),
                 "appearances": [{"appearance": "luminosity", "value": "dark"}]},
            ],
            "info": INFO,
        })


def launch_mark():
    # Launch screen: the Burrow arch in its orange gradient on the surface
    # field (white / charcoal), cut from the committed app icons: the tinted
    # icon is the arch's mask, the dark icon holds its gradient on charcoal.
    # The app icons themselves are hand-made art, not generated here.
    icon_dir = ASSETS / "AppIcon.appiconset"
    mask = Image.open(icon_dir / "AppIcon-1024-tinted.png").convert("L")
    dark = Image.open(icon_dir / "AppIcon-1024-dark.png").convert("RGB")
    bg = dark.getpixel((4, 4))
    box = mask.getbbox()
    mask, dark = mask.crop(box), dark.crop(box)
    arch = Image.new("RGBA", mask.size)
    px, mp, dp = arch.load(), mask.load(), dark.load()
    for y in range(mask.size[1]):
        for x in range(mask.size[0]):
            a = mp[x, y]
            if a == 0:
                continue
            # Un-blend the anti-aliased edge from the charcoal field.
            f = a / 255
            c = dp[x, y]
            px[x, y] = tuple(max(0, min(255, round((c[i] - (1 - f) * bg[i]) / f))) for i in range(3)) + (a,)
    d = ASSETS / "LaunchMark.imageset"
    d.mkdir(parents=True, exist_ok=True)
    for f in d.glob("*.png"):
        f.unlink()
    images = []
    for scale in (1, 2, 3):
        name = f"LaunchMark@{scale}x.png"
        arch.resize((120 * scale, 76 * scale), Image.LANCZOS).save(d / name)
        images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
    write_json(d / "Contents.json", {
        "images": images, "info": INFO,
        "properties": {"template-rendering-intent": "original"},
    })


if __name__ == "__main__":
    colours()
    launch_mark()
    print("ok")
