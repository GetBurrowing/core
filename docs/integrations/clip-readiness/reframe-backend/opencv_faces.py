"""Local YuNet face boxes for the existing shot planner on non-macOS hosts.

Provision the OpenCV Zoo YuNet model before running; inference never downloads
models or sends images over the network.
"""

import hashlib
import os
from functools import lru_cache
from pathlib import Path

MODEL_SHA256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"


def model_path() -> Path:
    return Path(
        os.environ.get("CLIP_FACE_MODEL", str(Path(__file__).parent / "face_models/face_detection_yunet_2023mar.onnx"))
    ).expanduser()


def available() -> bool:
    try:
        import cv2

        return (
            hasattr(cv2, "FaceDetectorYN")
            and model_path().is_file()
            and hashlib.sha256(model_path().read_bytes()).hexdigest() == MODEL_SHA256
        )
    except (ImportError, OSError):
        return False


@lru_cache(maxsize=1)
def _detector(path: str):
    import cv2

    cv2.setNumThreads(1)
    return cv2.FaceDetectorYN.create(path, "", (640, 640), 0.85, 0.3, 5000)


def ready() -> bool:
    """Verify imports, exact model bytes and a real inference without network I/O."""
    if not available():
        return False
    try:
        import numpy as np

        detector = _detector(str(model_path()))
        detector.setInputSize((640, 640))
        detector.detect(np.zeros((640, 640, 3), dtype=np.uint8))
    except Exception:  # noqa: BLE001 -- a failed native backend must become doctor FIX
        return False
    return True


def detect(image: str | Path):
    if not available():
        raise RuntimeError("FACE_MODEL_MISSING_OR_MISMATCH: provision the pinned YuNet model")
    import cv2

    from .shots import Face

    pixels = cv2.imread(str(image))
    if pixels is None:
        raise RuntimeError("Face detection could not decode the input image")
    height, width = pixels.shape[:2]
    detector = _detector(str(model_path()))
    detector.setInputSize((width, height))
    _, rows = detector.detect(pixels)
    if rows is None:
        return []
    faces = []
    for row in rows:
        x, y, w, h = map(float, row[:4])
        x0, y0 = max(0.0, x), max(0.0, y)
        x1, y1 = min(float(width), x + w), min(float(height), y + h)
        if x1 > x0 and y1 > y0:
            faces.append(Face(x0 / width, y0 / height, (x1 - x0) / width, (y1 - y0) / height, float(row[14])))
    return faces
