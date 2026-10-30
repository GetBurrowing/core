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
