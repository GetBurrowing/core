# Selected-profile render readiness

Task `01a18eb4-1d04-7000-a0eb-60dd5c747a59`, stage 1.

This is the canonical `burrow-clip-runner` helper and its complete protocol
suite, materialized for reproducible installation. It is not another renderer.
`source-receipt.json` pins the original 0.9.1 source and this 0.9.2 revision;
the patch can be applied to the original pinned helper. No CLI capabilities
are added or inferred from a version string.

**Measured live predecessor differs:** Brosnan's serving-host discovery at
23:42 UTC found a baked helper **0.7.0**, not canonical 0.9.1. The source
receipt distinguishes canonical provenance from that measured predecessor.
Its source patch is not a patch against the live 0.7.0 image. Use the complete
pinned helper plus the verified image/driver replacement below for that host.

0.9.2 checks the explicitly selected USER profile, creating it through the
supported profile import if absent. After assembling music, closing video and
look overrides, it checks that combined disposable profile before applying
review or finalizing. Finalize and review always receive the effective profile.
Every doctor FIX still fails; all model/backend/FFmpeg/privacy checks remain.
Doctor check names survive as safe error codes; its messages never leave the
subprocess boundary. Original-project mapping, exact candidate, fresh-output,
music, closing-video, caption qualification and privacy behavior are retained.

## Reproduce

Run `python -m pytest -q docs/integrations/clip-readiness/tests` with pytest
installed. Tests are fake CLI/protocol evidence, not serving-host qualification.
Run `python -m compileall -q docs/integrations/clip-readiness` and
`git diff --check` for syntax/whitespace checks. Do not modify unrelated CI flakes.

## Serving-host qualification and installation

Read the full `social-video-runner-handoff` and `burrow-clip-runner` skills.
Re-read the authoritative failed job first: if its error is not
`CLIP_DOCTOR_FIX: doctor failed (model:base.en)`, stop this model prescription
and re-derive from its actual error. Generic source/audio copy is not evidence.
The model on a different workstation is not serving-host readiness.

On the **actual serving runtime**, identify the live service/session, OS user,
HOME, CLIP_BIN, imported module path, checkout commit, effective USER profile,
models directory, helper digest and state-directory ownership. Do not dump the
service environment or credentials. Run each command as that serving user with
the same executable and environment as the worker:

```
"$CLIP_BIN" version --json
"$CLIP_BIN" config get transcription.models_dir --profile "$RENDER_PROFILE"
"$CLIP_BIN" models fetch --profile "$RENDER_PROFILE"
"$CLIP_BIN" models status --deep --profile "$RENDER_PROFILE"
"$CLIP_BIN" doctor --json --deep --profile "$RENDER_PROFILE"
```

The actual selected profile inherits large-v3 plus silero from how-to-computer;
the default profile alone requires the missing base.en. Create the missing USER
profile through supported profile import with `extends = "how-to-computer"`,
then fetch/verify its actual selected models. Do not install base.en merely to
mask checking the wrong profile. Preserve full doctor for the selected profile.

The existing installer/modelstore verifies model hashes. Do not copy an
unverified model, modify packaged how-to-computer, skip doctor, or overwrite
live state/helper. The locally inspected CLI checkout was
`58960577337d5682761e1538ff4365d4ba0b4e18`: cli.py doctor accepts --profile and
--deep, models fetch uses modelstore adoption/fetch verification, and finalize
uses the supported original project without transcription. Doctor has **no
operation-specific readiness option** there. Therefore this helper retains
full doctor and requires model provisioning even for appearance-only renders;
do not add a transcription bypass based solely on finalize's implementation.
Recheck these contracts against the measured serving checkout before acting.

For helper installation, quiesce the agent's job polling first, then acquire
the existing state directory's `runner.lock` nonblocking (the helper exports
`runner_lock`). Refuse installation if busy. Verify the new helper digest
against the receipt, preserve the old helper outside its live path, atomically
replace only the helper, and keep the lock through replacement. Do not replace
state.json or claims. Run `version`, the complete fake suite, and the real
selected-profile doctor before resuming polling. Update only genuine installed
helper/capability metadata; 0.9.2 does not establish newer caption CLI support.

The tracked installer implements that replacement contract, preserving a
digest-named backup and refusing a busy runner or changed installed bytes:

```
python install_helper.py --state-dir "$CLIP_RUNNER_HOME" \
  --helper-path "$INSTALLED_HELPER" --expected-current-sha256 "$MEASURED_HELPER_SHA256"
```

Use the measured real worker state directory. A different directory's lock
does not protect a live worker. Installation prints `host_qualified: false`;
it does not replace model/CLI qualification or restart the polling agent.

## Persistent serving image and driver pin

The measured moon worker uses a `--rm --replace` rootless podman container and
Restart=always. Its driver pins the baked helper digest and exits 2 on a
mismatch. An in-container helper overwrite is therefore both nonpersistent and
incompatible with startup. **Do not use install_helper.py inside this image.**

Obtain the complete measured base image ID and driver SHA256 from the serving
operator; prefixes in the discovery receipt are intentionally insufficient.
Build the tracked Containerfile with that exact image as its base, preserving
its installed CLI, entrypoint and all other contents. The build-time rebinder
verifies the old driver and helper bytes, requires exactly one literal
HELPER_SHA256 assignment matching the old helper, verifies the replacement
against the receipt, and changes only that startup pin. It never disables the
driver's digest check. Unexpected bytes/contracts fail the build.

```
podman build -f Containerfile -t localhost/clip-runner:0.9.2-readiness \
  --build-arg BASE_IMAGE="$MEASURED_FULL_IMAGE_ID" \
  --build-arg EXPECTED_DRIVER_SHA256="$MEASURED_FULL_DRIVER_SHA256" \
  --build-arg EXPECTED_HELPER_SHA256=c55f6ceb913004ddfc3e947407847c2d768d78d4a40c081106fba97a8a066999 .
```

Run helper version/digest checks and CLI capability/profile/deep doctor checks
in the candidate image before switching the service; test startup pin refusal
with an intentionally mismatched helper in an isolated disposable candidate,
never the serving image. Do not start its real polling driver as a test worker.
While the old driver is idle, stop its existing unit, take its actual state
lock from the host, and update only the authoritative quadlet image reference
to the measured newly built image, preserving all mounts/config and old image
for rollback. Reload systemd; release the lock before starting the existing
unit. Verify the restarted container image ID, imported CLI identity, helper
and driver digests, successful digest gate and normal idle polling. Restart it
again to prove the change survives --rm/--replace. Record state mapping digest
before/after; no jobs may be claimed merely to qualify installation. If the
base image or authoritative driver/build context is managed in another repo,
record its actual location and upstream this same pin change there instead of
leaving an untracked runtime-only patch. Do not invent an upstream commit from
the CLI's null commit field.

Record sanitized actual command results, executable/import identity, checkout,
model verification and helper digest in a serving-host receipt before marking
readiness qualified. The checked-in source receipt deliberately starts with
`serving_host_qualified: false`; source tests alone must never flip that field.

After model readiness, inspect the exact original project/candidate through
supported project info and the helper mapping API under its lock, then verify
the selected music file identity and -12 dB gain. Never guess a source, render
the captioned delivery again, rewrite a closed job, forge a claim or alter
internal manifests. Resume through supported retry only; if enqueue is human
only, report exactly when retry is safe after host qualification. Keep all
outputs awaiting human review; no approval, scheduling or publication. A real
original-project plus selected-music output must be recorded in the later
render validation stage before describing the incident as fixed.
