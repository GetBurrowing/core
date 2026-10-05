#!/usr/bin/env python3
"""Generate the Suite iOS colour assets, placeholder icon and launch mark.

Colour values are the Suite web tokens (apps/platform/assets/css/app.css on
origin/main, read 2026-10-04) mapped onto semantic slot names. The slot ->
token table lives in clients/ios/README.md; edit both together.

Icon and launch mark are PLACEHOLDERS (canvas 01a10887 open question 1):
the word "Suite" in Public Sans 800. The real mark is Marlowe's call.

    python3 clients/ios/scripts/generate_assets.py
"""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "ios" / "App" / "App" / "Assets.xcassets"
# Colour slots are shared by the app, the share extension and the widgets.
COLOURS = ROOT / "ios" / "Shared" / "Colors.xcassets"
FONT = ROOT / "ios" / "App" / "App" / "Fonts" / "PublicSans-Variable.ttf"

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


def wordmark(size_px, colour, canvas, field=None, scale=0.26):
    img = Image.new("RGBA", canvas, field or (0, 0, 0, 0))
    font = ImageFont.truetype(str(FONT), int(size_px * scale))
    try:
        font.set_variation_by_axes([800])
    except Exception:
        font.set_variation_by_name("ExtraBold")
    draw = ImageDraw.Draw(img)
    box = draw.textbbox((0, 0), "Suite", font=font)
    w, h = box[2] - box[0], box[3] - box[1]
    draw.text(((canvas[0] - w) / 2 - box[0], (canvas[1] - h) / 2 - box[1]), "Suite", font=font, fill=colour)
    return img


def rgb(hexv):
    h = hexv.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4)) + (255,)


def icons():
    d = ASSETS / "AppIcon.appiconset"
    for f in d.glob("*.png"):
        f.unlink()
    # Any: primary field, black mark. Dark: base-100 dark field, mark in primary.
    # Tinted: the mark alone (iOS tints it).
    wordmark(1024, rgb("#000000"), (1024, 1024), rgb(SLOTS["primary"][1])).convert("RGB").save(d / "AppIcon-1024.png")
    wordmark(1024, rgb(SLOTS["primary"][1]), (1024, 1024), rgb(SLOTS["surface"][1])).convert("RGB").save(d / "AppIcon-1024-dark.png")
    wordmark(1024, (255, 255, 255, 255), (1024, 1024), (0, 0, 0, 255)).convert("L").save(d / "AppIcon-1024-tinted.png")
    write_json(d / "Contents.json", {
        "images": [
            {"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "dark"}],
             "filename": "AppIcon-1024-dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
            {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
             "filename": "AppIcon-1024-tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        ],
        "info": INFO,
    })


def launch_mark():
    # Launch screen: surface field, mark in base-content (no cyan, canvas
    # Layout intent). Template image tinted by the storyboard with onSurface.
    d = ASSETS / "LaunchMark.imageset"
    d.mkdir(parents=True, exist_ok=True)
    for f in d.glob("*.png"):
        f.unlink()
    images = []
    for scale in (1, 2, 3):
        name = f"LaunchMark@{scale}x.png"
        wordmark(160 * scale, (0, 0, 0, 255), (160 * scale, 64 * scale), scale=0.30).save(d / name)
        images.append({"filename": name, "idiom": "universal", "scale": f"{scale}x"})
    write_json(d / "Contents.json", {
        "images": images, "info": INFO,
        "properties": {"template-rendering-intent": "template"},
    })


if __name__ == "__main__":
    colours()
    icons()
    launch_mark()
    print("ok")
