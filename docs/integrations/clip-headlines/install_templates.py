"""Install a dedicated exact combined renderer. Refuses to mutate an existing target."""

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

UPSTREAM = "82ef5132b926fed33a80a304364fdda14335c2d5"
CAPTION_CORE = "d17048339c6cbbe95794ad748393c4724dffb410"


def run(*args, **kw):
    return subprocess.check_output(list(map(str, args)), **kw)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--target", required=True)
    p.add_argument("--core", required=True)
    args = p.parse_args()
    target = Path(args.target).resolve()
    core = Path(args.core).resolve()
    if target.exists():
        raise SystemExit("Target exists; choose a new dedicated checkout")
    here = Path(__file__).resolve().parent
    manifest = json.loads((here / "assets-manifest.json").read_text())
    for asset in manifest["assets"]:
        assert (
            hashlib.sha256((here / asset["path"]).read_bytes()).hexdigest()
            == asset["sha256"]
        )
    # Caption prerequisite is sourced from its immutable Core commit, never another operator checkout.
    run("git", "-C", core, "cat-file", "-e", CAPTION_CORE + "^{commit}")
    run(
        "git",
        "clone",
        "--quiet",
        "--no-checkout",
        "https://github.com/JackEFoster/htc-clip-tool",
        target,
    )
    run("git", "-C", target, "checkout", "--quiet", "--detach", UPSTREAM)
    patches = [
        (here / "htc-headline-review-v1.patch").read_bytes(),
        run(
            "git",
            "-C",
            core,
            "show",
            CAPTION_CORE
            + ":docs/integrations/clip-captions/htc-caption-treatments-v1.patch",
        ),
        (here / "htc-headline-templates-v1.patch").read_bytes(),
        (here / "htc-headline-linux-prerequisites-v1.patch").read_bytes(),
    ]
    for index, patch in enumerate(patches):
        # Zero-context prerequisite is bound to the exact pinned base/preceding patches.
        flags = ["--unidiff-zero"] if index == 3 else []
        run("git", "-C", target, "apply", *flags, "--check", "-", input=patch)
        run("git", "-C", target, "apply", *flags, "-", input=patch)
    model = here / "models/face_detection_yunet_2023mar.onnx"
    model_sha256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
    assert hashlib.sha256(model.read_bytes()).hexdigest() == model_sha256
    installed_model = (
        target / "clip-agent/src/clip_agent/models/face_detection_yunet_2023mar.onnx"
    )
    installed_model.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(model, installed_model)
    shutil.copy2(
        here / "models/YuNet-LICENSE", installed_model.parent / "YuNet-LICENSE"
    )
    weight = target / "clip-agent/src/clip_agent/fonts/weights/Inter-ExtraBold.ttf"
    weight.parent.mkdir(parents=True)
    weight.write_bytes(
        run(
            "git",
            "-C",
            core,
            "show",
            CAPTION_CORE + ":docs/integrations/clip-captions/fonts/Inter-ExtraBold.ttf",
        )
    )
    shutil.copy2(here / "fonts/Inter-Regular.ttf", target / "clip-agent/src/clip_agent/fonts/Inter-Regular.ttf")
    run("uv", "venv", "--python", "3.14", target / ".venv")
    packaged_assets = target / "headline-assets"
    packaged_assets.mkdir()
    shutil.copy2(
        here / "assets-manifest.json", packaged_assets / "assets-manifest.json"
    )
    for asset in manifest["assets"]:
        dest = packaged_assets / asset["path"]
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(here / asset["path"], dest)
    for name in [
        "Anton-OFL.txt",
        "Inter-OFL.txt",
        "SOURCES.txt",
        "UPSTREAM-NOTICE.txt",
    ]:
        shutil.copy2(here / "fonts" / name, packaged_assets / "fonts" / name)
    python = target / ".venv/bin/python"
    run(
        "uv",
        "pip",
        "install",
        "--python",
        python,
        "-r",
        here / "requirements-headline-linux-py314.txt",
    )
    run(
        "uv",
        "pip",
        "install",
        "--python",
        python,
        "--no-deps",
        "-e",
        str(target / "clip-agent"),
    )
    info = json.loads(run(target / ".venv/bin/clip", "version", "--json"))
    assert (
        info["headline_templates"] == 1
        and info["headline_review"] == 1
        and info["caption_treatments"] == 1
        and "subtle" in info["caption_styles"]
    )
    renderer = info["headline_template_renderer"]
    path = Path(renderer["path"])
    assert (
        path.is_relative_to(target)
        and hashlib.sha256(path.read_bytes()).hexdigest() == renderer["sha256"]
    )
    imported = json.loads(
        run(
            python,
            "-c",
            "import importlib,json,hashlib; names=['captions','cli','headline_templates','reframe','shots','pipeline','opencv_faces','packaging_assets','subtle_captions']; print(json.dumps({n:{'path':(m:=importlib.import_module('clip_agent.'+n)).__file__,'sha256':hashlib.sha256(open(m.__file__,'rb').read()).hexdigest()} for n in names}))",
        )
    )
    assert all(
        Path(item["path"]).resolve().is_relative_to(target)
        for item in imported.values()
    )
    receipt = {
        "upstream": UPSTREAM,
        "imported_modules": imported,
        "caption_core": CAPTION_CORE,
        "asset_directory": str(packaged_assets),
        "patch_sha256": [hashlib.sha256(x).hexdigest() for x in patches],
        "install": info,
        "face_model_sha256": model_sha256,
        "runtime_modules": {
            name: hashlib.sha256(
                (target / "clip-agent/src/clip_agent" / name).read_bytes()
            ).hexdigest()
            for name in (
                "opencv_faces.py",
                "reframe.py",
                "shots.py",
                "pipeline.py",
                "cli.py",
            )
        },
    }
    (target / "headline-install-receipt.json").write_text(
        json.dumps(receipt, indent=2) + "\n"
    )
    print(
        json.dumps(
            {"status": "installed", "executable": str(target / ".venv/bin/clip")}
        )
    )


if __name__ == "__main__":
    main()
