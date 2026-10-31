#!/usr/bin/env python3
"""Authorized local validation only; no job, upload, approval or publish calls.

Require the original source at its recorded path before finalize can silently
fall back to a previously cut candidate. Paths and CLI output stay private.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SOURCE_SHA = "a56d9f934de436211d92c2e9a5688cd9b6c8f0c52527d25c6c3d3b7f5fd66d91"
MUSIC_SHA = "5966eb0b7347ee5fb4f3012742d8aac84d39c99798c633ef4bd766e783c7610b"
HELPER_SHA = "0a5c4e0bb84c208c492682fda5b6ccb6d79d9bf306602d411362502a15e175c4"
CANDIDATE = "c8bedfe6da"


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def require_bytes(path, expected):
    if not Path(path).is_file() or digest(path) != expected:
        raise RuntimeError("INPUT_MISSING_OR_HASH_MISMATCH")


def require_doctor(doc):
    checks = doc.get("checks")
    if not isinstance(checks, list) or not checks:
        raise RuntimeError("DOCTOR_INVALID")
    if any(str(c.get("status", "")).lower() == "fix" for c in checks):
        raise RuntimeError("DOCTOR_FIX")
    if any(str(c.get("status", "")).lower() not in ("pass", "warn", "ok") for c in checks):
        raise RuntimeError("DOCTOR_INVALID")
    return {"pass": sum(str(c["status"]).lower() in ("pass", "ok") for c in checks),
            "warn": sum(str(c["status"]).lower() == "warn" for c in checks), "fix": 0}


def require_candidate(entry):
    if (entry is None or entry.fields.get("id") != CANDIDATE or entry.alternate
            or abs(entry.start - 2403.01) > 0.001 or abs(entry.end - 2456.88) > 0.001):
        raise RuntimeError("ORIGINAL_CANDIDATE_MISMATCH")


def main():
    ap = argparse.ArgumentParser()
    for key in ("project", "source", "music", "helper", "output_dir"):
        ap.add_argument("--" + key.replace("_", "-"), type=Path, required=True)
    ap.add_argument("--clip-bin", default="/usr/local/bin/clip")
    ap.add_argument("--profile", required=True)
    args = ap.parse_args()
    require_bytes(args.source, SOURCE_SHA)
    require_bytes(args.music, MUSIC_SHA)
    require_bytes(args.helper, HELPER_SHA)
    spec = importlib.util.spec_from_file_location("qualified_readiness_helper", args.helper)
    helper = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = helper
    spec.loader.exec_module(helper)
    env = {k: v for k, v in os.environ.items() if not (
        "TOKEN" in k or "SECRET" in k or k.startswith(("CF_ACCESS", "BURROW_")))}
    env["CLIP_NO_CONTENT"] = "1"
    args.output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    steps = []

    def call(step, argv, as_json=False):
        result = subprocess.run([args.clip_bin, *map(str, argv)], env=env,
                                capture_output=True, text=True, check=False)
        steps.append({"step": step, "exit": result.returncode})
        if result.returncode:
            raise RuntimeError("CLI_STEP_FAILED:" + step)
        return json.loads(result.stdout) if as_json else result.stdout

    before = helper.ReviewFile((args.project / "review.toml").read_text()).by_id(CANDIDATE)
    require_candidate(before)
    before_edl = before.fields.get("edl")
    info = call("project_info", ["project", "info", "--json", args.project], True)
    if info.get("privacy_mode") != "local" or info.get("candidates", {}).get("total") != 9:
        raise RuntimeError("ORIGINAL_PROJECT_MISMATCH")
    selected_doctor = require_doctor(call("selected_doctor", ["doctor", "--json", "--deep",
                                    "--profile", args.profile], True))
    temporary = args.profile + "-readiness-" + str(time.time_ns())
    helper._check_profile_name(temporary)
    profile_file = args.output_dir / "private-profile.toml"
    profile_file.write_text(helper.profile_toml(args.profile, {
        "captions.style": "karaoke", "music.enabled": True,
        "music.path": str(args.music), "music.level_db": -12.0, "outro.path": ""}))
    profile_file.chmod(0o600)
    try:
        call("profile_import", ["profile", "import", profile_file, "--name", temporary,
                                "--force", "--yes"])
        combined_doctor = require_doctor(call("combined_doctor", ["doctor", "--json", "--deep",
                                         "--profile", temporary], True))
        call("review_export", ["review", args.project, "--overwrite", "--profile", temporary])
        review = helper.ReviewFile((args.project / "review.toml").read_text())
        entry = review.by_id(CANDIDATE)
        require_candidate(entry)
        if entry.fields.get("edl") != before_edl:
            raise RuntimeError("ORIGINAL_EDL_CHANGED")
        review.set_fields(entry, decision="approve")
        (args.project / "review.toml").write_text(review.text())
        call("review_apply", ["review", args.project, "--apply", "--profile", temporary])
        call("review_refresh", ["review", args.project, "--overwrite", "--profile", temporary])
        applied = helper.ReviewFile((args.project / "review.toml").read_text()).by_id(CANDIDATE)
        require_candidate(applied)
        if applied.fields.get("decision") != "approve":
            raise RuntimeError("REVIEW_NOT_APPLIED")
        started = time.time_ns()
        call("finalize", ["finalize", args.project, "--profile", temporary,
                          "--captions", "karaoke", "--regenerate"])
        output = args.project / "final" / (applied.file_stem + ".mp4")
        if not output.is_file() or output.stat().st_mtime_ns < started:
            raise RuntimeError("FRESH_OUTPUT_MISSING")
        decode = subprocess.run(["ffmpeg", "-v", "error", "-i", str(output),
                                 "-f", "null", "-"], capture_output=True, check=False)
        if decode.returncode:
            raise RuntimeError("OUTPUT_DECODE_FAILED")
        probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries",
            "format=duration:stream=width,height,codec_type", "-of", "json", str(output)],
            capture_output=True, text=True, check=True)
        media = json.loads(probe.stdout)
        video = next(s for s in media["streams"] if s.get("codec_type") == "video")
        receipt = {"validation": "real_authorized_local_original_project_render",
            "production_completion": False, "candidate_id": CANDIDATE,
            "source_sha256": SOURCE_SHA, "music_file_id": "01a18eb0-ce90-7000-a470-ed04b1ba9a14",
            "music_sha256": MUSIC_SHA, "music_gain_db": -12.0, "captions": "karaoke",
            "selected_doctor": selected_doctor, "combined_doctor": combined_doctor,
            "output_sha256": digest(output), "output_bytes": output.stat().st_size,
            "duration_s": float(media["format"]["duration"]), "width": video["width"],
            "height": video["height"], "decode_exit": decode.returncode,
            "steps": steps, "process_or_transcribe_called": False}
        (args.output_dir / "local-render-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt))
    finally:
        profile_file.unlink(missing_ok=True)
        # Same supported path lookup and narrowly scoped cleanup as the helper.
        installed = Path(call("profile_path", ["profile", "path", temporary]).strip())
        if installed.name != temporary + ".toml" or "clip_agent" in installed.parts:
            raise RuntimeError("PROFILE_CLEANUP_FAILED")
        installed.unlink(missing_ok=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 -- sanitize any private CLI/path failure at this boundary
        # No CLI stderr, paths, private profile contents or stack traces.
        print(json.dumps({"validation_failed": True, "exception_type": type(exc).__name__}), file=sys.stderr)
        sys.exit(1)
