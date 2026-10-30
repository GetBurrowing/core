"""Verify the exact invoked clip CLI against the packaged caption source digests."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clip", required=True)
    parser.add_argument("--checkout", type=Path, required=True)
    args = parser.parse_args()
    artifact = json.loads(Path(__file__).with_name("artifact.json").read_text())
    result = subprocess.run(
        [args.clip, "version", "--json"],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    version = json.loads(result.stdout)
    assert version.get("caption_treatments") == 1, "missing caption_treatments:1"
    assert version.get("headline_review") == 1, "missing headline-review/1"
    assert version.get("caption_styles") == [
        "none",
        "plain",
        "phrase-pop",
        "karaoke",
        "type-on",
        "focus-word",
        "editorial-punch",
    ]
    root = args.checkout.resolve()
    for relative, expected in artifact["installed_source_sha256"].items():
        assert hashlib.sha256((root / relative).read_bytes()).hexdigest() == expected, (
            relative
        )
    # These paths come from the modules actually imported by this CLI process,
    # rather than distribution metadata or its unchanged version label.
    report = version["caption_renderer"]
    for key, file, digest_key in [
        ("path", "captions.py", "sha256"),
        ("temporal_path", "dynamic_captions.py", "temporal_sha256"),
    ]:
        relative = "clip-agent/src/clip_agent/" + file
        assert Path(report[key]).resolve() == root / relative, (
            "CLI imports a different checkout"
        )
        assert report[digest_key] == artifact["installed_source_sha256"][relative], (
            "CLI imports different source"
        )
    for setting in ["music.enabled", "outro.path", "outro.audio"]:
        subprocess.run(
            [args.clip, "config", "get", setting],
            capture_output=True,
            check=True,
            timeout=30,
        )
    print(
        json.dumps(
            {
                "verified": True,
                "cli": str(Path(args.clip).resolve()),
                "checkout": str(root),
                "version": version["version"],
                "caption_treatments": 1,
                "headline_review": 1,
            }
        )
    )


if __name__ == "__main__":
    main()
