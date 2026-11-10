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
cutting and promotion for ordinary invocations, including all probing. No
workflow changes production deployment settings.

## Explicit held bootstrap (stable has no write path)

The exception is explicitly named `--held-bootstrap`, supported by the
existing `cut_candidate.py` and `promote_stable.py` entrypoints. Scheduled
workflows select it only when the separate repository variable
`STABLE_HELD_BOOTSTRAP=true`. Without that flag ordinary HOLD remains a
full emergency freeze; an environment variable alone does not change a
direct script invocation. To freeze even bootstrap activity, disable
`STABLE_HELD_BOOTSTRAP` and retain `STABLE_HOLD=true`.

Prerequisites are **all** of `STABLE_HOLD=true`, `STABLE_BATCH_ENABLED=true`,
`STABLE_SOAK_MODE=canary`, a configured HTTPS `STABLE_CANARY_HEALTH_URL`
(no embedded credentials), and `STABLE_SOAK_HOURS>=24`. Provision and check
the dedicated vendor-owned canary's feedback/extensions parity before
activation. Keep batches disabled until those prerequisites are met. Do
not repurpose the 7-Eleven demo or Legacy Pie, change Kobo from main, or
rebuild any customer install. This bootstrap accepts neither force nor
SHA inputs, never clears HOLD, and does not authorize promotion after soak.

The cutter still selects newest first-attempt-green, packaged-boot-checked
main automatically. The observer probes only the canary; no production
soak is claimed. Bootstrap returns after recording evidence, before any
stable selection or promotion. Command-boundary allowlists restrict Git
mutations to candidate/canary observation state and registry writes to
`core-candidate` / `play-candidate` from their corresponding SHA images.
`core-stable`, `play-stable`, stable Git tags and failure-evidence deletion
are forbidden even if accidentally requested from this path.

Bootstrap observation verifies both candidate registry labels against the
Git candidate identity first. This proves channel publication consistency,
not running-install delivery or a completed soak. Acceptance additionally
requires matching running candidate identity and at least **86400 actual
elapsed seconds** of healthy observations; hourly bucket count alone is
insufficient. Exact interval/generation acceptance is a separate safety
gate; do not treat bootstrap's successful exit as acceptance.

The existing explicitly authorized **non-batch hotfix** dispatch (`force=true`,
full SHA) remains available outside batch mode. Batch observation refuses force
and SHA inputs. It skips the observation count, not hold,
configuration or failed-soak checks. Routine release cuts never use it.

## Failure and recovery

A boot-check failure makes a main run ineligible for candidate selection.
A soaking candidate that fails is not promoted; the next daily cut can
select a different eligible main run. A GitHub or registry error fails
closed. Registry tags and Git refs are not one transaction: a partial
candidate-tag write requires inspection/reconciliation before proceeding.
The cutter first atomically creates `refs/release-candidate/pending` with
an absent-ref lease. Competing candidate identities cannot both acquire
it. It then publishes and verifies both candidate image revisions before
atomically committing current/cut refs and removing pending with leases.
Crash, failed registry publication, unverified image labels, or failed final
Git push leaves pending durable; cutting and held observation refuse to
proceed. Same-identity retries can be idempotent; Git rejects competing
identities. Both workflows share the `promote-stable` concurrency group.

Recovery is an explicit operator action under existing deployment approvals:
retain HOLD; read the pending SHA from Git (never choose a new routine SHA),
inspect the corresponding packaged images and failed-candidate evidence,
then reconcile both candidate tags and the current/cut refs to that already
automatically selected identity. Verify both image labels, use expected-ref
leases for the Git transaction and remove pending only after reconciliation.
If identity/evidence cannot be established, stop and retain pending. Do not
delete the marker to bypass an incomplete publication or replace it with a
hand-picked SHA. Stable never moves as part of a cut or reconciliation.
Held observation retains failure refs rather than pruning them. Preserve
failed refs as evidence.

This changes the **core app release channel**, not the install's service
topology. Adding or changing services still requires a separate supported
installer migration mechanism; candidate tags do not solve that design gap.

## Exact candidate generation ledger

New cuts initialize `refs/soak-state/<policy>/<candidate-sha>` atomically
with publication completion. The ref points to a Git commit containing a
versioned JSON message: candidate identity, policy, exact UTC first/last
observation timestamps, independent successful UTC hour buckets and all
failure timestamps/reasons. The candidate commit is its parent, keeping
identity reachable. Observation uses real health responses and verifies
both candidate image revision labels; canary policy never probes production.
A valid health response must report `status=ok` and the full active candidate
commit. Missing/unknown/different identity, malformed/unavailable health,
registry mismatch or rollback from the candidate records a permanent failure,
even if the candidate has never previously answered.

The first healthy observation starts the interval. Completion requires
**at least 86400 elapsed seconds**, at least 24 distinct successful UTC hour
observations (or a higher configured minimum), and no failures. A gap larger
than **90 minutes** between observations, or a backwards clock, permanently
rejects the generation. The hourly schedule therefore permits 30 minutes of
scheduling delay. Twenty-four buckets spanning 23h01m fail. Duplicate runs
in one hour cannot add hours. Candidate cut/tag age never starts the clock.

The observer fetches durable ledger objects on each fresh runner. An atomic
Git push uses expected-ref leases for the ledger and current/pending candidate
refs, committing exact state and hourly evidence together. Racing observers
retry with the originally measured health result against the committed ledger;
they cannot overwrite a concurrent failure or report success before storage
commits. Missing, malformed or unavailable state and failed reads/writes fail
closed. No ledger is recreated from historical hourly refs. Older already-cut
candidates without a ledger require explicit approved reconciliation or a new
automatically selected candidate; never manufacture timestamps for past health.
Failures and their refs are retained, including beyond the former 14-day prune
window; candidate selection excludes failed identities across both policies.

Replacement automatically starts with an empty generation ledger. An existing
ledger cannot be overwritten by a new cut. A policy switch cannot consume the
other policy's ledger or hours; it fails closed pending approved reconciliation.
Held bootstrap always returns after observation; even a completed ledger cannot
move stable. Releasing HOLD/promotion is a separate authorized action. An
observer exit code of zero alone does not prove acceptance: inspect the durable
ledger, `soak_complete`, identity, interval and failure evidence. No real soak
has been established by deterministic clock fixtures.
