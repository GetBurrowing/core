# Stage 1 source validation — 2026-10-30

Runtime: jordan-desktop, Python 3.14.4. These results do not qualify moon.

- Complete canonical helper protocol suite: **158 passed**, 123.42 seconds.
  Command: `python -m pytest -q docs/integrations/clip-readiness/tests`
  before adding the independently executed installer tests below.
- Installer safety tests: **4 passed**, covering busy state lock, changed live
  digest, symlink rejection and preservation of mappings/backup/mode.
- Focused real CLI doctor suite against local htc-clip-tool checkout
  `58960577337d5682761e1538ff4365d4ba0b4e18`: **34 passed, 87 deselected**.
  Command: `python -m pytest -o addopts= -q <checkout>/clip-agent/tests/test_cli.py -k doctor`.
  This uses the real CLI implementation with its existing test fixtures,
  not an actual selected production profile or live backend qualification.
- Mutation probe in an isolated copy: remove `--profile` from doctor argv;
  **all five new readiness cases fail**, including default/selected disagreement,
  derived-profile readiness, mapped appearance and episode model failure.
  The original source remained unchanged and the complete suite passed.
- `ruff check --select E9,F821,F822,F823`, compileall and whitespace checks pass.

Serving runtime qualification: **pending**. No model download, serving-host
doctor, stable serving helper installation, supported retry or production
render is asserted by this evidence. The source receipt remains explicitly
unqualified. Operator bridge requested from Dalton/Scorsese in the task
execution space at 21:29:41 UTC; jordan-desktop has no moon access.

The authoritative failed job was re-read and still records
`CLIP_DOCTOR_FIX: doctor failed (model:base.en)` at 5%. It remains closed and
unchanged. Original-project/source/audio verification follows model readiness.

## Serving discovery and overlay validation — 23:46 UTC

The initial unavailable-host paragraph above records the state at 21:35 UTC,
not the current measurement. Brosnan bridged the actual moon host. It is a
baked **0.7.0** helper and digest-pinned driver, based on CLI build 82ef5132,
not the canonical 0.9.1 source or locally inspected 58960577 checkout.
The complete measured image/driver/helper/MCP hashes and evidence message IDs
are now separated from canonical source provenance in `source-receipt.json`.

Supported import created the absent selected USER profile extending
how-to-computer. Its **large-v3 and silero** models were already present and
verified against the CLI manifest by fetch and deep status. Its real deep
doctor passed **15 pass / 0 warn / 0 fix**. The unprofiled default doctor alone
reports missing base.en; both doctors exit 0, demonstrating why the JSON FIX
count, rather than subprocess status alone, must remain authoritative.
No base.en blob was fetched to hide the wrong-profile check.

Additional local validation on jordan-desktop:

- Full helper + installer + image rebinding suite: **169 passed**, 113.77s.
- Three subsequently added **actual measured driver** integration tests:
  **3 passed**, 2.91s. The real rebinder patches hash-pinned actual driver and
  old helper fixtures, then its real poll/claim/context/forward/reply protocol
  drives helper subprocesses against fake CLI/MCP and a local upload server.
  Karaoke plus selected music at -12 dB completes without transcription;
  model FIX fails before upload; changed helper bytes trigger actual startup
  refusal exit 2. An initial assertion looked for setup-phase logs in a
  test-phase capture; corrected the capture by verifying the pin in the test
  phase. That first run was 2/3 and is not reported as green.
- Syntax/ruff/whitespace remain clean on candidate `907305dd`.

The persistent overlay changes both helper copies and the matching driver
digest pin together and preserves its startup refusal. Actual image build,
in-image full-suite results, idle/locked quadlet switch, two restart durability
checks and postinstall doctor are still pending Brosnan's measured receipt.
Until those arrive, serving_host_qualified remains false and retry unsafe.

## Moon candidate image — 23:49:53 UTC

Brosnan's receipt `01a18f38-4ad8-7000-9c01-77183534893c` verifies the
complete source commit `907305ddcda5fb94be8f62d30c038d192249196d`, archived
into a separate persistent build context with its SOURCE_COMMIT recorded.
The original 0.7.0 build context/image remain available for rollback.

The candidate image (full ID/digest in source-receipt.json) passed **172/172**
in-image tests in 92.6s, exit 0, with network disabled, private scratch
HOME/state and no production environment/token. Its bin/src helpers both
match the pinned 0.9.2 digest. Its actual driver has the corresponding digest
pin and reports 0.9.2; its unchanged trailing `# helper 0.7.0` comment is
historical source provenance, not an advertised CLI capability.

An isolated startup mutation with dummy token/config reached the actual pin
guard and refused a tampered helper with exit 2. Positive control verified
the real helper, reclaimed zero jobs and reached idle polling; timeout 124
then ended that disposable probe. This is a successful positive control,
not a production service shutdown or a completed clip job.

The candidate CLI also ran the real selected-profile deep doctor against a
read-only production data mount and the existing local backend: **15 pass /
0 warn / 0 fix**, exit 0. No state relabel or job mutation was needed.
The live service switch and restart durability receipt are still outstanding.

## Live serving-host qualification — 23:53:07 UTC

Superseding the pending statuses above, Brosnan's live receipt
`01a18f3b-423f-7000-9740-74f5f2c780d9` confirms the actual worker is now on
image `6077c03e25bb467033ce0d94c595577f8ca04367fa078ec7dc96c07953c30b0d`
from source `907305dd`, with the exact 0.9.2 bin/src helper digest and matched
driver pin recorded in source-receipt.json. The CLI stayed 0.9.0 from the
measured file:///opt/clip-agent installation; no new CLI capability is claimed.

The operator confirmed idle, stopped the rootless unit, acquired the actual
host state lock, backed up the quadlet, changed only its Image line, released
the lock, reloaded and started the unit. Three clean starts at 23:50:07,
23:51:02 and 23:51:54 UTC each verified the helper pin, reclaimed **zero** jobs
and reached normal idle polling. Final service state is active/running with
NRestarts=0, demonstrating persistence across --rm/--replace without a
digest-mismatch restart loop.

Before/after sorted state-file digest is identical:
`49700887d0bedaa757e52831088eb3fd22e43f2732e17563c4dcabe50058e0f6`.
Jobs remain empty and the failed job/outbox unchanged. No job was claimed,
retried, rewritten, approved or published, and sibling services were untouched.
The final **live** selected-profile deep doctor again reports **15 pass /
0 warn / 0 fix**, exit 0.

Serving model/preflight/installation readiness is now qualified and a supported
retry can proceed. The actual original-project plus selected-music output is
still the later render-validation stage's responsibility. This receipt does
not claim that render exists or that the whole incident is fixed. The deployed
image intentionally contains its build-time unqualified source receipt;
this post-install repository receipt records the subsequently measured result.
