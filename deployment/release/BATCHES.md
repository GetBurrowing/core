# Delayed stable batches

This mechanism is inactive until `STABLE_BATCH_ENABLED=true`. Do not enable
it until a vendor-owned rehearsal install exists, its configuration has
been checked against production (including extensions and feedback), and
the production deployment owner has selected the soak policy.

The daily `cut-candidate.yml` workflow automatically selects the newest
successful first-attempt main CI run whose **two core architectures and
Play image actually passed packaged boot checks**. It accepts no SHA input.
It moves only `core-candidate` and `play-candidate`. It holds an active
candidate until it is stable or has failed, and cuts at most once per UTC
day. Main merges and edge image publication can continue independently.

The rehearsal install must follow `day2.upgrade_channel = "candidate"`,
not `edge`: edge follows every merge and cannot hold the batch. Candidate
uses the existing updater, meeting hold, health gate and rollback rules.
This is a vendor testing channel; customers remain on stable. An existing
updater must be upgraded to one that recognizes candidate before changing
its channel. Cloud's pinned installer must consume this version before it
can provision such an install. Do not rebuild an existing client to obtain it.

## Select one policy before activation

Set `STABLE_SOAK_MODE` explicitly:

| Value | Runtime evidence | Deployment requirement |
| --- | --- | --- |
| `both` | Production and canary healthy on the same candidate | Production deployment owner holds the candidate on production too |
| `canary` | Canary healthy on the candidate; makes no production-soak claim | Production may follow main; canary must match its relevant configuration |

The default is the existing `both` policy. Canary-only evidence is stored
under separate `soak-canary` / `soak-fail-canary` refs, so changing policy
cannot reuse hours from the other policy. Rollbacks and probe failures
disqualify the candidate under the selected policy. Switching policy is a
release-policy decision, not an automatic reaction to a failure.

Configure `STABLE_PROD_HEALTH_URL` (required in both mode),
`STABLE_CANARY_HEALTH_URL`, `STABLE_SOAK_HOURS=24`, then activate batches.
Batch promotion refuses a value below 24. Promotion uses only the current
candidate and real successful hourly observations, never tag age or a
historical revision that happened to pass. `STABLE_HOLD=true` freezes both
cutting and promotion. No workflow changes production deployment settings.

The existing explicitly authorized **hotfix** dispatch (`force=true`, full
SHA) remains available. It skips the observation count, not hold,
configuration or failed-soak checks. Routine release cuts never use it.

## Failure and recovery

A boot-check failure makes a main run ineligible for candidate selection.
A soaking candidate that fails is not promoted; the next daily cut can
select a different eligible main run. A GitHub or registry error fails
closed. Registry tags and Git refs are not one transaction: a partial
candidate-tag write requires inspection/reconciliation before proceeding;
stable never moves as part of the cut. Preserve failed refs as evidence.

This changes the **core app release channel**, not the install's service
topology. Adding or changing services still requires a separate supported
installer migration mechanism; candidate tags do not solve that design gap.
