"""Build-only opt-in compatibility for the measured original face-sampling clock."""
import argparse
import hashlib
import json
from pathlib import Path

EXPECTED = {
    "config.py": "e6d423ed0034b79cd15ac3290681b3ec17e27125d51d7d252551cb5aecf186fa",
    "cli.py": "f456a6a1337445a5850eb6591d01d0a2b4dfd7c9ea56bb08be17e999064a733a",
    "shots.py": "a1a61f50e51cffe7432d955c3b3f14ea9e744d3e21c3ab178a6e6feebf8630b1",
    "reframe.py": "0ffcf6e996b91f7b146a9e1c123999cc3ffdf16ba5369f0e102707891b72c1a5",
}
AFTER = {
    "config.py": "93da311b2760c1b11428a846d97e9c8f141625ef9868863cc9bb3690134287a4",
    "cli.py": "3c87feb43445e3f55e043409592286679de2aabb282025417991343f3237a7d1",
    "shots.py": "d82e736b48c61ca536c3bf4b325f5e60568097cf9c44c86e545fca84185cebd6",
}


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError("SAMPLING_PATCH_CONTRACT_MISMATCH")
    return text.replace(old, new)


def patch_config(text):
    return replace_once(text, '    mode: Literal["off", "seats", "shots", "split", "fit", "center"] = "off"',
        '    mode: Literal["off", "seats", "shots", "split", "fit", "center"] = "off"\n'
        '    # Opt in only to reproduce a verified older delivery; current sampling stays the default.\n'
        '    face_sampling: Literal["aligned", "legacy-half-step"] = "aligned"')


def patch_shots(text):
    return replace_once(text,
        '        frames = extract_frames_dense(src, start, dur, Path(tmp), timeout=timeout)',
        '        # Preserve an explicitly selected original delivery sampling clock, without\n'
        '        # changing scene cuts, the planner, output projection or current defaults.\n'
        '        phase = 0.5 / DENSE_FPS if rf.face_sampling == "legacy-half-step" else 0.0\n'
        '        frames = extract_frames_dense(src, start + phase, max(0.0, dur - phase),\n'
        '                                      Path(tmp), timeout=timeout)')


def patch_cli(text):
    return replace_once(text, '"reframe_backend": 1, "reframe_backends": ["vision", "yunet"]}',
        '"reframe_backend": 1, "reframe_backends": ["vision", "yunet"], '
        '"reframe_sampling": 1, "reframe_sampling_modes": ["aligned", "legacy-half-step"]}')


def install(roots):
    roots = [Path(r) for r in roots]
    for root in roots:
        for name, expected in EXPECTED.items():
            if hashlib.sha256((root / name).read_bytes()).hexdigest() != expected:
                raise RuntimeError("SAMPLING_BASE_BYTES_CHANGED")
    after = {}
    for root in roots:
        for name, patch in (("config.py", patch_config), ("cli.py", patch_cli), ("shots.py", patch_shots)):
            path = root / name
            replacement = patch(path.read_text())
            if hashlib.sha256(replacement.encode()).hexdigest() != AFTER[name]:
                raise RuntimeError("SAMPLING_PATCH_OUTPUT_MISMATCH")
            path.write_text(replacement)
            after[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        assert hashlib.sha256((root / "reframe.py").read_bytes()).hexdigest() == EXPECTED["reframe.py"]
    return {"reframe_sampling": 1, "default": "aligned", "planner_unchanged": True,
            "after_sha256": after, "serving_host_qualified": False}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--module-root", type=Path, required=True)
    ap.add_argument("--source-root", type=Path, required=True)
    args = ap.parse_args()
    print(json.dumps(install([args.module_root, args.source_root])))
