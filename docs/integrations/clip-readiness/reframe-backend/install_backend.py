"""Build-time only patch of the measured CLI; never run against a live worker."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

EXPECTED = {
    "cli.py": "01b348df26b2b99993c90a1a847335260d62dc0f345f9de0973614f8cc4020ed",
    "shots.py": "813105d2a9c9e81c2aea7da98fdd0ea41d5e7f4157e1c6be48c66aa944de81d5",
    "reframe.py": "0ffcf6e996b91f7b146a9e1c123999cc3ffdf16ba5369f0e102707891b72c1a5",
}
MODEL_SHA = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
ADAPTER_SHA = "a124394aa2c4f06bdfc6df5096f0289cafa52755cb6b07a64b56d96eab803a28"
LICENSE_SHA = "c83b8120c50ccbd4c4f96edf53141bdd566ebb8f8e9227e415326aa1b1aba958"
SHOTS_TEST_SHA = "4e82a25af2bd3109511dba702ae8e4860604fbccb746804138cec1c5346c29ad"
AFTER = {
    "cli.py": "f456a6a1337445a5850eb6591d01d0a2b4dfd7c9ea56bb08be17e999064a733a",
    "shots.py": "a1a61f50e51cffe7432d955c3b3f14ea9e744d3e21c3ab178a6e6feebf8630b1",
}
DOCTOR_ANCHOR = '''    """Seat reframing asked for with no seats set."""
    if cfg.reframe.mode == "seats"'''
DOCTOR_REPLACEMENT = '''    """Check the selected profile's required face backend without weakening other checks."""
    if cfg.reframe.mode == "shots":
        from .shots import face_detection_available
        ready = face_detection_available()
        add("pass" if ready else "fix", "reframe-backend",
            "shots face backend is ready" if ready else
            "shots face backend is not ready; provision the supported local face backend and verified model")
    if cfg.reframe.mode == "seats"'''


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError("CLI_PATCH_CONTRACT_MISMATCH")
    return text.replace(old, new)


def patch_cli(text):
    text = replace_once(text, DOCTOR_ANCHOR, DOCTOR_REPLACEMENT)
    return replace_once(text,
        '"content_free": CONTENT_FREE_VERSION, "headline_review": 1}',
        '"content_free": CONTENT_FREE_VERSION, "headline_review": 1, '
        '"reframe_backend": 1, "reframe_backends": ["vision", "yunet"]}')


def patch_shots(text):
    text = replace_once(text, "def vision_box_to_top_left(",
        '''def face_detection_available() -> bool:
    """The original producer's local YuNet backend, with verified model and real inference."""
    from .opencv_faces import ready
    return vision_available() or ready()


def vision_box_to_top_left(''')
    text = replace_once(text,
        '    except Exception as e:  # noqa: BLE001\n        raise RuntimeError(_VISION_HINT) from e',
        '    except Exception:  # noqa: BLE001\n        from .opencv_faces import detect\n        return detect(image)')
    return replace_once(text, 'if not vision_available():', 'if not face_detection_available():')


def patch_shots_test(text):
    # The refusal now means neither backend is ready, rather than Vision alone.
    return replace_once(text,
        'def test_analyse_shots_without_vision_is_friendly(monkeypatch):\n'
        '    monkeypatch.setattr(shots, "vision_available", lambda: False)',
        'def test_analyse_shots_without_vision_is_friendly(monkeypatch):\n'
        '    monkeypatch.setattr(shots, "face_detection_available", lambda: False)')


def install(roots, bundle):
    roots = [Path(r).resolve() for r in roots]
    # Validate EVERY destination and asset before writing any copy.
    for root in roots:
        for name, expected in EXPECTED.items():
            if sha(root / name) != expected:
                raise RuntimeError("INSTALLED_CLI_BYTES_CHANGED")
        if (root / "opencv_faces.py").exists():
            raise RuntimeError("FACE_BACKEND_ALREADY_PRESENT")
        test = root.parent.parent / "tests" / "test_shots.py"
        if test.is_file() and sha(test) != SHOTS_TEST_SHA:
            raise RuntimeError("UPSTREAM_SHOTS_TEST_BYTES_CHANGED")
    model = bundle / "face_detection_yunet_2023mar.onnx"
    if sha(model) != MODEL_SHA:
        raise RuntimeError("FACE_MODEL_HASH_MISMATCH")
    if sha(bundle / "opencv_faces.py") != ADAPTER_SHA or sha(bundle / "YuNet-LICENSE") != LICENSE_SHA:
        raise RuntimeError("FACE_BACKEND_ASSET_MISMATCH")
    after = {}
    for root in roots:
        for name, patch in (("cli.py", patch_cli), ("shots.py", patch_shots)):
            path = root / name
            replacement = patch(path.read_text())
            if hashlib.sha256(replacement.encode()).hexdigest() != AFTER[name]:
                raise RuntimeError("CLI_PATCH_OUTPUT_MISMATCH")
            path.write_text(replacement)
            after[name] = sha(path)
        shutil.copy2(bundle / "opencv_faces.py", root / "opencv_faces.py")
        model_dir = root / "face_models"
        model_dir.mkdir(exist_ok=False)
        shutil.copy2(model, model_dir / model.name)
        shutil.copy2(bundle / "YuNet-LICENSE", model_dir / "YuNet-LICENSE")
        after["opencv_faces.py"] = sha(root / "opencv_faces.py")
        assert sha(root / "reframe.py") == EXPECTED["reframe.py"]
        test = root.parent.parent / "tests" / "test_shots.py"
        if test.is_file():
            test.write_text(patch_shots_test(test.read_text()))
    return {"reframe_backend": 1, "after_sha256": after, "model_sha256": MODEL_SHA,
            "planner_unchanged": True, "serving_host_qualified": False}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--module-root", type=Path, required=True)
    p.add_argument("--source-root", type=Path, required=True)
    args = p.parse_args()
    print(json.dumps(install([args.module_root, args.source_root], Path(__file__).parent)))
