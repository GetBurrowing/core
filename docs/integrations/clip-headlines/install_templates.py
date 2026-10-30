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
    ]
    for patch in patches:
        run("git", "-C", target, "apply", "--check", "-", input=patch)
        run("git", "-C", target, "apply", "-", input=patch)
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
    )
    renderer = info["headline_template_renderer"]
    path = Path(renderer["path"])
    assert (
        path.is_relative_to(target)
        and hashlib.sha256(path.read_bytes()).hexdigest() == renderer["sha256"]
    )
    receipt = {
        "upstream": UPSTREAM,
        "caption_core": CAPTION_CORE,
        "asset_directory": str(packaged_assets),
        "patch_sha256": [hashlib.sha256(x).hexdigest() for x in patches],
        "install": info,
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
