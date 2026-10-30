#!/usr/bin/env python3
"""Fake `clip` for tests. Installed on PATH as `clip`.

Emulates the parts of htc-clip-tool 0.9's CLI the runner uses (argv shapes as in
clip_agent/cli.py): version/doctor --json, config get, project info --json,
process --project NAME, review [--overwrite|--apply], finalize, profile
path|import|use. Projects live in $FAKE_CLIP_HOME/clips/<name>, user profiles in
$FAKE_CLIP_HOME/profiles, the built-in how-to-computer in $FAKE_CLIP_HOME/builtin.

FAKE_CLIP_LOG     JSONL file; each call appends {"argv", "env" (CLIP_* vars), and for
                  review/apply/import the file text seen}
FAKE_CLIP_SCRIPT  JSON file: {"<key>": {"stdout": ..., "exit": n, "sleep": s}} where <key>
                  is review_apply | review | project_info | config_get | profile_<sub> | argv[0].
                  A non-zero exit prints stdout and exits with no side effects.
FAKE_PRIVACY      cloud (default) | local; FAKE_PRIVACY_INFERRED=1 marks it inferred
FAKE_CLIP_VERSION default 0.9.3; FAKE_CONTENT_FREE default 2
"""

import json
import os
import shutil
import sys
import time
import tomllib
from pathlib import Path

BUILTIN = ("how-to-computer", "how-to-computer-local", "podcast", "podcast-local")

REVIEW_FIXTURE = """# clip-agent review for project 'NAME'.
# For each clip set decision = "approve" or "reject" ("pending" = undecided).

[[clip]]
id = "c1aaaaaaaa"
title = "Secret Title One"
decision = "pending"
start = 100.000
end = 130.000
# file: 01_secret-title-one.mp4 · rank 1 · 30.0s · story
# says: secret transcript words one
# transcript = "corrected caption text (optional)"
edl = "none"   # no edit list — leave as is
captions = "1111111111111111"   # the captions as listed — leave as is
packaging = "aaaaaaaaaaaaaaaa"   # the packaging shown above — leave as is
note = ""

[[clip]]
id = "c2bbbbbbbb"
title = "Secret Title Two"
decision = "pending"
start = 300.000
end = 345.000
# file: 02_secret-title-two.mp4 · rank 2 · 45.0s · insight
# says: secret transcript words two
# transcript = "corrected caption text (optional)"
edl = "none"   # no edit list — leave as is
captions = "2222222222222222"   # the captions as listed — leave as is
packaging = "bbbbbbbbbbbbbbbb"   # the packaging shown above — leave as is
note = ""

[[clip]]
id = "c3cccccccc"
title = "Secret Title Three"
decision = "reject"
start = 500.000
end = 540.000
# file: 03_secret-title-three.mp4 · rank 3 · 40.0s · story
edl = "none"   # no edit list — leave as is
captions = "3333333333333333"   # the captions as listed — leave as is
packaging = "cccccccccccccccc"   # the packaging shown above — leave as is
note = ""

# ==============================================================================
# ALTERNATES — proposed but NOT cut (beyond the clip count, or left out by the re-rank).
# ==============================================================================

[[clip]]
id = "a1dddddddd"
title = "Secret Alternate"
decision = "pending"
start = 10.000
end = 40.000
# file: (not cut) · rank 4 · 30.0s · story
edl = "none"   # no edit list — leave as is
captions = "4444444444444444"   # the captions as listed — leave as is
packaging = "dddddddddddddddd"   # the packaging shown above — leave as is
note = ""
"""


def key(argv):
    if not argv:
        return ""
    if argv[0] == "review":
        return "review_apply" if "--apply" in argv else "review"
    if argv[0] in ("project", "profile", "config") and len(argv) > 1:
        return f"{argv[0]}_{argv[1]}"
    return argv[0]


def home():
    return Path(os.environ.get("FAKE_CLIP_HOME", "/nonexistent-fake-clip-home"))


def opt(argv, name):
    return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else None


def project_dir(ref):
    return Path(ref) if "/" in ref else home() / "clips" / ref


def profile_file(name):
    if name in BUILTIN:
        return home() / "builtin" / f"{name}.toml"
    return home() / "profiles" / f"{name}.toml"


def die(code="FAKE_ERROR", status=1):
    print(json.dumps({"ok": False, "error": {"code": code}}))
    sys.exit(status)


def emulate(argv, extra):
    k = key(argv)
    privacy = os.environ.get("FAKE_PRIVACY", "cloud")
    if k == "version":
        return {
            "version": os.environ.get("FAKE_CLIP_VERSION", "0.9.3"),
            "content_free": int(os.environ.get("FAKE_CONTENT_FREE", "2")),
            "python": "3.12",
            "headline_review": int(os.environ.get("FAKE_HEADLINE_CAPABILITY", "1")),
        }
    if k == "hooks":
        request_path = Path(opt(argv, "--request"))
        request = json.loads(request_path.read_text())
        extra["headline_request"] = request
        extra["request_mode"] = request_path.stat().st_mode & 0o777
        d = project_dir(argv[2])
        path = d / "review.toml"
        if "--check-applied" not in argv:
            title = request.get("requested_headline") or ({"c1aaaaaaaa": "The demo finally worked", "c2bbbbbbbb": "We fixed the wrong button", "c3cccccccc": "The tiny bug won again"}.get(request["candidate_id"]) if os.environ.get("FAKE_EPISODE_THREE") else "secret transcript words two")
            if os.environ.get("FAKE_HEADLINE_UNBACKED"):
                die("HEADLINE_UNBACKED")
            text = path.read_text()
            rows = text.split("[[clip]]")
            for i, row in enumerate(rows):
                if f'id = "{request["candidate_id"]}"' in row:
                    import re
                    row = re.sub(r"(?m)^headline = .*\n", "", row)
                    rows[i] = row + "\nheadline = " + json.dumps(title) + "\n"
            path.write_text("[[clip]]".join(rows))
        else:
            applied = tomllib.loads((d / "applied.toml").read_text())
            target = next(c for c in applied["clip"] if c["id"] == request["candidate_id"])
            if "headline" not in target:
                die("HEADLINE_OUTPUT_UNSUPPORTED")
        return {"version": 1, "candidate_id": request["candidate_id"],
                "source_id": request["source"]["id"], "start": request["source"]["start"],
                "end": request["source"]["end"], "voice_revision": request["voice"]["revision"],
                "base_render_id": request["base_render_id"], "backed": True,
                "status": "applied" if "--check-applied" in argv else "prepared"}
    if k == "doctor":
        outcomes = json.loads(os.environ.get("FAKE_DOCTOR_PROFILES", "{}"))
        result = outcomes.get(opt(argv, "--profile") or "default")
        if result is not None:
            return result
        return {
            "checks": [{"check": "ffmpeg", "status": "pass", "message": "ok"}],
            "summary": {"pass": 1, "warn": 0, "fix": 0},
        }
    if k == "config_get":
        if argv[2] == "outro.audio":
            return os.environ.get("FAKE_OUTRO_AUDIO", "unsupported")
        if argv[2] == "music.enabled":
            return os.environ.get("FAKE_MUSIC_ENABLED", "false")
        if argv[2] == "captions.style":
            return os.environ.get("FAKE_CAPTION_STYLE", "phrase-pop")
        if argv[2] == "effective_privacy_mode":
            return privacy
        return os.environ.get("FAKE_PRIVACY_EXPLICIT", privacy)
    if k == "process":
        name = opt(argv, "--project")
        d = home() / "clips" / name
        d.mkdir(parents=True, exist_ok=True)
        state = d / "applied.toml"
        if state.exists():
            text = state.read_text().replace('# file: (not cut)', '# file: 04_secret-title-a1dddddddd.mp4')
            state.write_text(text)
        (d / "project.json").write_text(json.dumps({"profile": opt(argv, "--profile")}))
        return "Processed."
    if k == "project_info":
        d = project_dir(argv[-1])
        if not (d / "project.json").exists():
            die("PROJECT_NOT_FOUND")
        prof = json.loads((d / "project.json").read_text()).get("profile")
        return {
            "name": d.name,
            "path": str(d),
            "profile": prof,
            "privacy_mode": privacy,
            "privacy_mode_inferred": os.environ.get("FAKE_PRIVACY_INFERRED") == "1",
            "candidates": {"pending": 3, "alternate": 1, "total": 4},
            "require_approval": True,
        }
    if k == "review":
        d = project_dir(argv[1])
        path = d / "review.toml"
        if path.exists() and "--overwrite" not in argv:
            die("REVIEW_EXISTS")
        state = d / "applied.toml"
        text = state.read_text() if state.exists() else REVIEW_FIXTURE.replace("NAME", d.name)
        if os.environ.get("FAKE_EPISODE_THREE"):
            text = text.replace('decision = "reject"', 'decision = "pending"')
        if os.environ.get("FAKE_EPISODE_ZERO"):
            text = "# no picks\n"
        path.write_text(text)
        extra["written"] = text
        return f"Review file: {path}"
    if k == "review_apply":
        path = project_dir(argv[1]) / "review.toml"
        text = path.read_text()
        tomllib.loads(text)  # clip parses it
        (path.parent / "applied.toml").write_text(text)
        extra["applied"] = text
        return "Applied review: 1 approved"
    if k == "finalize" and os.environ.get("FAKE_SKIP_RENDER"):
        return "Nothing rendered"
    if k == "finalize":
        d = project_dir(argv[1])
        doc = tomllib.loads((d / "review.toml").read_text())
        final = d / "final"
        final.mkdir(exist_ok=True)
        n = 0
        for i, c in enumerate(doc.get("clip", []), 1):
            if c.get("decision") == "approve":
                stem = f"0{i}_secret-title-{c['id']}"
                stem = {1: "01_secret-title-one", 2: "02_secret-title-two", 3: "03_secret-title-three"}.get(
                    i, stem
                )
                (final / f"{stem}.mp4").write_bytes(
                    b"VIDEO:" + c["id"].encode() + b":" + str(c["start"]).encode()
                )
                (final / f"{stem}_clean.mp4").write_bytes(b"CLEAN")
                (final / f"{stem}.srt").write_text("1\nsecret caption\n")
                n += 1
        return f"Wrote {3 * n} files to final/:"
    if k == "profile_path":
        p = profile_file(argv[2])
        if not p.exists():
            die("PROFILE_NOT_FOUND")
        return str(p)
    if k == "profile_import":
        src, name = Path(argv[2]), opt(argv, "--name")
        if name in BUILTIN:
            die("BUILTIN_PROFILE")
        text = src.read_text()
        doc = tomllib.loads(text)
        if not profile_file(doc.get("extends", "")).exists():
            die("EXTENDS_NOT_FOUND")
        target = home() / "profiles" / f"{name}.toml"
        if target.exists() and "--force" not in argv:
            die("PROFILE_EXISTS")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, target)
        extra["imported"] = text
        return f'Imported profile "{name}"'
    if k == "profile_use":
        if not profile_file(argv[2]).exists():
            die("PROFILE_NOT_FOUND")
        return f'Using profile "{argv[2]}"'
    return {"ok": True}


def main():
    argv = sys.argv[1:]
    script = {}
    path = os.environ.get("FAKE_CLIP_SCRIPT")
    if path and os.path.exists(path):
        with open(path) as fh:
            script = json.load(fh)
    spec = script.get(key(argv), {})
    extra = {}
    log = os.environ.get("FAKE_CLIP_LOG")

    def write_log():
        if log:
            env = {k: v for k, v in os.environ.items() if k.startswith(("CLIP_", "FAKE_", "BURROW_", "CF_ACCESS_"))}
            with open(log, "a") as fh:
                fh.write(json.dumps({"argv": argv, "env": env, "pid": os.getpid(), **extra}) + "\n")

    if spec.get("sleep"):
        time.sleep(spec["sleep"])
    if spec.get("exit"):
        write_log()
        out = spec.get("stdout", {"ok": False})
        print(out if isinstance(out, str) else json.dumps(out))
        sys.exit(spec["exit"])
    try:
        out = emulate(argv, extra)
    except SystemExit:
        write_log()
        raise
    write_log()
    out = spec.get("stdout", out)
    print(out if isinstance(out, str) else json.dumps(out))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
