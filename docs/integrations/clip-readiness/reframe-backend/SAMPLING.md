# Reproduce the original delivery's face-sampling clock

The first successful native render was technically valid (source/music/karaoke,
full decode, 1080×1920, 53.428375 seconds) but failed the original-framing comparison:
about five seconds shifted horizontally by roughly 92 output pixels. It is not
production recovery and is not safe to promote as unchanged framing.

Supported config reads prove the original producer and serving profile have the
same framing settings after the separate profile restoration. Read-only analysis
of the authorized original source isolates the cause: upstream changed dense face
sampling between the original producer's 58960577 and the serving 82ef5132. At two
samples/second, the old extractor seeks an additional 0.25 seconds; the corrected
current extractor does not. This changes the face positions sampled for two
adjacent camera shots. The source window, four shot boundaries, detector, model,
thresholds and framing planner need not change.

| Source-relative span | Original crop x | Current aligned crop x | Explicit legacy phase crop x |
| --- | ---: | ---: | ---: |
| 0–23.039 | 736 | 736 | 736 |
| 23.039–24.582 | 582 | 556 | 582 |
| 24.582–28.002 | 790 | 736 | 790 |
| 28.002–53.87 | 534 | 534 | 534 |

All crops are y=0,w=606,h=1080 in the original 1920×1080 source. The explicit
legacy sampling phase reproduces every original crop and normalized face box
exactly in the read-only native control. This is a causal control, not an MP4
comparison or production completion.

## Narrow supported compatibility setting

The additive CLI patch adds a validated USER-profile field:
`reframe.face_sampling = "aligned" | "legacy-half-step"`. **The default remains
aligned.** Explicit legacy-half-step reproduces the known original producer's
sampling clock. Scene detection, shot boundaries, the current framing planner,
frame-grid projection and every readiness/model/privacy check remain unchanged.
Invalid values fail configuration validation. The CLI advertises the genuine
installed `reframe_sampling: 1` contract and its two supported values. There is
no silent fallback or global rollback to an older planner.

The existing HTC USER profile may opt into legacy-half-step solely to preserve
its verified original producer policy. This keeps shots mode and all current
renderer preferences/models/inference/privacy settings; no built-in profile is
edited. Other profiles keep aligned unless they explicitly opt in. The helper
already passes the selected/effective profile to doctor, review and finalize,
so no helper/driver or job-payload rewrite is needed.

## Candidate and serving qualification

Build from the full measured face-backend image only:

```
podman build -f reframe-backend/Containerfile.sampling \
  --build-arg BASE_IMAGE=78b3f50fa3ce627134568195ec0c68a369e885cf76ee1846d02b0771b902c40b \
  -t localhost/clip-runner:0.9.2-original-sampling .
```

`install_sampling.py` verifies all imported/source config/CLI/shots/planner bytes
before any write and pins the resulting hashes. Its readable source diff is
`htc-original-face-sampling-v1.patch`. No dependencies or model bytes change.

In the isolated candidate run the complete helper suite and:
`PYTHONPATH=/opt/clip-agent python3 -m pytest -o addopts='' -q
/opt/clip-agent/tests/test_shots.py /tmp/clip-reframe-sampling/test_backend.py
/tmp/clip-reframe-sampling/test_sampling.py`. Locally this is 43 passed, two
macOS-only tests skipped. Literal tests pin aligned and legacy source sampling
arguments, default aligned, invalid-value refusal and installed capability.
Removing the compatibility branch (forcing phase zero) makes the unchanged literal
legacy test fail (2403.01/53.87 observed instead of 2403.26/53.62, exit 1), while
the aligned test still passes; restored code passes both. No surviving mutant was
counted as a pass.
`verify_original_plan.py --source <private original> --profile <selected>` performs
read-only native analysis with an explicit validated legacy override and asserts
all four independently recorded original crop boxes. It reads no project manifest
or transcript and writes no project/job state.

After candidate tests, native plan/geometry, deep selected doctor and pin controls
pass, switch the image while idle/stopped and holding the actual state lock.
Preserve every mount/config and the prior image for rollback; verify clean starts
and actual imported hashes. Before opting the selected USER profile in, export and
back it up, verify it still matches the measured four-key profile SHA256
`d5076bd2dba61e123ae450e7317e95a5cf19ce82f788bef913aee5120138029b`, and import
the same four keys plus `reframe.face_sampling="legacy-half-step"` through the
supported CLI. Refuse concurrent changes. Revalidate the profile, verify unchanged
shots/fallback/caption/speech/model/brain/privacy/publish values, and run the full
deep selected/effective doctor again.

**Rollback must restore the backed-up four-key USER profile before starting an
older image that does not understand face_sampling.** Never leave an unsupported
profile behind or disable its validation.

Then rerun the guarded local original-project/music validator on a new disposable
copy under the real lock. Repeat the full decode, audio and temporal karaoke checks,
and specifically compare all 120 formerly shifted frames with the immutable original.
Do not promote the first technically valid but shifted render. Only after the real
framing comparison passes may a human enqueue a fresh supported production retry.
Closed jobs, user attribution, approval and publication stay untouched.
