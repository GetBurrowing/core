# Preserve the original Linux shots face backend

The first real original-project/music validation failed before producing media:
the serving CLI's shots mode required macOS Vision, while the selected-profile
deep doctor still reported 15 pass / 0 warn / 0 fix. This is an additional measured
runtime prerequisite, separate from the original wrong-profile model failure and
the subsequently restored original-project mapping. Do not retry until qualified.

The original producer actually ran on Linux with a local OpenCV YuNet adapter in
checkout `58960577337d5682761e1538ff4365d4ba0b4e18`: OpenCV headless 5.0.0.93,
NumPy 2.5.4, no Vision, local detector available. This overlay restores that same
detector, model, confidence threshold, NMS threshold, sample geometry and normalized
face-box contract. It adds exact model verification and a real native-inference
doctor check. It changes neither the framing planner (`reframe.py` stays byte
identical), the selected shots mode, candidates, source, edit list nor other doctor
checks. It does not install unrelated headline/template or caption changes.

The model's measured SHA256 and size match the official
[OpenCV Zoo model pointer](https://raw.githubusercontent.com/opencv/opencv_zoo/main/models/face_detection_yunet/face_detection_yunet_2023mar.onnx).
The adjacent MIT license is preserved, per the project's
[model license](https://raw.githubusercontent.com/opencv/opencv_zoo/main/models/face_detection_yunet/LICENSE).
The bundled model is verified at build and before inference, never downloaded while
processing customer media. The exact producer OpenCV distribution is installed
from hash-pinned official PyPI Linux wheels; the measured base's NumPy 2.5.4 must
already match. No model is adopted on presence or size alone.

`install_backend.py` is a **candidate-image build step**, not a live installer.
It refuses changed imported/source CLI, shots or planner hashes and verifies every
destination before writing. It preserves the existing helper/driver startup pin.
`htc-linux-shots-readiness-v1.patch` is the readable reproducible source diff.
The CLI keeps its genuine distribution/version/source identity and advertises
only the added `reframe_backend: 1` supported contract; readiness still comes from
the actual selected/combined profile's doctor. Missing native module, wrong model
or inference failure produces `reframe-backend` FIX, which the helper must refuse.
Modes that do not need this detector retain their existing checks. No global
readiness bypass, silent fit/center/seats fallback or source substitution is allowed.

## Build and qualify

From `docs/integrations/clip-readiness`, build against the exact measured live
0.9.2 image (full ID below), preserving it for rollback:

```
podman build -f reframe-backend/Containerfile \
  --build-arg BASE_IMAGE=6077c03e25bb467033ce0d94c595577f8ca04367fa078ec7dc96c07953c30b0d \
  -t localhost/clip-runner:0.9.2-face-readiness .
```

In the candidate image, run `python3 -m pytest -q /tmp/clip-reframe-backend/test_backend.py`
and the complete existing helper suite with isolated HOME/state, no network and
no production token/config. The backend suite exercises actual native inference,
missing/tampered model, missing/broken backend, selected-profile doctor and preserved
transcription checks. Run the upstream shots tests separately; any failure is a
failure, not a waived flake. The existing helper digest/tamper guard remains intact.
The source patch updates the one existing "without Vision" refusal test to
disable both supported backends; a missing Vision module alone no longer means
shots is unavailable. Run it with `PYTHONPATH=/opt/clip-agent python3 -m pytest
-o addopts='' -q /opt/clip-agent/tests/test_shots.py
/tmp/clip-reframe-backend/test_backend.py`. Locally the combined run passed 39
tests with two explicitly macOS/Vision-only cases skipped. The pre-update test
failed as expected when the real local detector was available; this was a changed
backend contract, not a flake.

Run `verify_geometry.py --frame <private authorized source frame>` in that same
image. The fixture is supplied privately rather than committed as customer media.
Its SHA256 and independently measured original producer face box/confidence are
pinned in the script; matching within 1e-6 proves detector geometry, not full render
fidelity. A real original-project karaoke/music render and frame/audio comparison
are still required. Do not call a passing doctor or native test a successful render.

After candidate tests, deep selected-profile doctor and pin checks pass, switch
only the quadlet image reference while idle/stopped and holding its real state lock;
retain the original-source read-only bind and every other config/mount unchanged.
Verify clean startup/pin, actual imported module/model hashes, normal polling and
a second clean restart. Re-run the deep doctor in the live image. Then run the
guarded local validator on its disposable project copy under the real lock.
No closed-job mutation, forged claim/enqueue/attribution, approval or publish calls.

## Measured inputs and regression evidence

- Imported/source `cli.py`: `01b348df26b2b99993c90a1a847335260d62dc0f345f9de0973614f8cc4020ed`.
- Imported/source `shots.py`: `813105d2a9c9e81c2aea7da98fdd0ea41d5e7f4157e1c6be48c66aa944de81d5`.
- Unchanged `reframe.py`: `0ffcf6e996b91f7b146a9e1c123999cc3ffdf16ba5369f0e102707891b72c1a5`.
- Face model: `8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4`, 232589 bytes.
- Original producer adapter: `0d34328bb7173dbedfdd1c64243bcf953ebff3a1e57ecf238007301c0af49689`.
- Removing the new doctor branch makes the literal selected-profile regression
  fail with missing `reframe-backend` (exit 1); restored code passes.

These are source/native-control measurements. Serving installation and real output
must have their own measured receipt before readiness/recovery is claimed.
