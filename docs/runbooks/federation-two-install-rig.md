# Two-install federation rig

Proves install-to-install federation (ADR 0054) end to end: two real Suite
installs on the test-rig host pair, share one channel, exchange messages both ways, catch up
after one goes offline, and stop talking after a unilateral revoke. Task
`01a199b2`.

Every step drives the real protocol entry points (`Platform.Federation.Peers.*`,
`Platform.Chat.*`) on the running server node through the rig's `rpc`
subcommand. v1 has no admin UI or HTTP API for peers (ADR 0054 section 7), so
there is nothing else to drive. No script writes peer, shared-space or cursor
rows with `Repo` directly.

## What it is

`scripts/federation-two-install-rig.sh` starts two `MIX_ENV=dev` installs,
`dev-fed-a-01a199b2` and `dev-fed-b-01a199b2`, on the podman network `dev`.
Each has its own database on `dev-postgres` (`fed_a_01a199b2`,
`fed_b_01a199b2`), its own source copy, its own uploads volume and two podman
secrets (`VAULT_MASTER_KEY`, Erlang cookie).

`scripts/federation_rig/*.exs` are evaluated on the install's node
(`rpc <a|b> <file.exs> [args]`). Each prints one `RIG <json>` line of ids,
statuses and timestamps. The rig passes through only those lines; the dev
install's debug log goes to `$RIG_OUT/rpc-<x>.log`.
`apps/platform/test/platform/federation/peers/two_install_rig_contract_test.exs`
fails CI when a `Platform.*` function one of them calls is renamed or changes
arity.

| Script | Where | Entry point |
| --- | --- | --- |
| `identity.exs` | either | `InstallIdentity.ensure!/0`: install_id, kid, fingerprint |
| `pair_propose.exs <B url>` | A | `Peers.propose/2` |
| `pair_accept.exs <A install_id> <A fingerprint>` | B | asserts the fingerprint, then `Peers.accept/2` |
| `share.exs` | A | `Chat.create_space/1`, `Chat.add_participant/2`, `Peers.share_space/2` |
| `post.exs <text>` | either | `Chat.post_message/2` |
| `list.exs` | either | peers, fingerprints, shared rows and cursors, messages, links, `PeerConnection.status/1` |
| `revoke.exs` | A | `Peers.revoke(peer, notify: false)` |

## Why plain http, and why dev and not release images

There is no TLS in the rig and no new dev allowance. `PEER_FEDERATION_ALLOW_HTTP`
already exists. `Platform.Federation.Peers.Config.allow_http?/0` honours it only
when `:platform, :env` is not `:prod`, and `config_test.exs` pins that it is
refused in prod. When it is on, `Client.check_url/1` skips the SSRF
private-address check and the IP pinning. The rig needs that because both peers
sit on private podman addresses, which the prod guard refuses. A release runs
`:prod`, so the rig cannot use release images.

`VAULT_MASTER_KEY` is pinned per install from a podman secret. Outside prod,
`runtime.exs` generates a random vault key on every boot, and the install's
Ed25519 signing key lives in `Platform.Vault`. Without the pin, an install that
restarts can no longer decrypt its own key.

The Erlang distribution (`--sname fed_<x>`, the cookie) is operator control
inside one container only. The two installs never talk to each other over it;
they talk only over signed HTTP envelopes.

## Prerequisites

- Run it on the test-rig host, never on a production host. `RIG_HOST` (required,
  no default) names the test-rig host's short hostname; the script refuses to
  run when `hostname -s` differs.
- `RIG_PG_PASSWORD_FILE` is the env file holding `DEV_PG_PASS` for the test
  rig's dev-postgres. There is no default.
- A core checkout of the branch to test, for example a clone from
  the test rig's core mirror.
- A cold `up` takes about 4-6 minutes, because both installs fetch and compile
  everything. A later `start` takes about 20 s. `RIG_OUT` defaults to
  `~/testruns/rig-01a199b2`.

## The sequence

Run from the checkout, with `R=scripts/federation-two-install-rig.sh`. Use
`RIG_KEEP=1` on `up`; without it, `up` tears the rig down when it exits.

```bash
export RIG_HOST=<test-rig short hostname>
export RIG_PG_PASSWORD_FILE=<env file holding DEV_PG_PASS>
RIG_KEEP=1 $R up . .                       # both 200, fingerprints printed
$R rpc a identity.exs                      # note A's install_id and fingerprint
$R rpc b identity.exs
$R rpc a pair_propose.exs http://dev-fed-b-01a199b2:4000
$R rpc b list.exs                          # pending_inbound, A's fingerprint
$R rpc b pair_accept.exs <A install_id> <A fingerprint>
$R rpc a share.exs                         # prints both space ids
$R rpc a post.exs "a->b 1"
$R rpc b post.exs "b->a 1"
sleep 15; $R rpc a list.exs; $R rpc b list.exs
$R stop b
$R rpc a post.exs "offline 1"   # then 2 and 3, 2 s apart
$R rpc a list.exs                          # cursor still at "a->b 1"; failures
podman restart dev-fed-a-01a199b2          # A's in-memory queue is lost
$R start b
$R rpc b list.exs                          # poll: "offline 1..3" arrive in order
$R rpc a post.exs "pre-revoke a"; $R rpc b post.exs "pre-revoke b"   # positive control
$R rpc a revoke.exs
$R rpc a post.exs "post-revoke a"; $R rpc b post.exs "post-revoke b"
sleep 120; $R rpc a list.exs; $R rpc b list.exs
podman logs dev-fed-a-01a199b2 2>&1 | grep 'inbox refused reason=peer_revoked'
$R down                                    # prints the empty listings
```

A message ingested from the peer is stored once with its own local id. Its
author is a system participant named `<remote author> (via <peer>)` and its
`metadata.source` is `federation_inbound`. It has a `federation_message_links`
row mapping the remote id. Its content is the peer's text inside Ingest's
external-content wrapper.

## Where the catch-up cursor lives (correction to the ticket's wording)

The cursor is on the **sending** side. It is
`federation_shared_spaces.outbound_cursor_message_id` on the sender's row: A's
owner row for messages A posts, B's replica row for messages B posts. It
advances only when the peer answers 2xx with `"ok": true`. A `PeerConnection`
replays from it on every start, so when B is offline, **A replays to B from A's
cursor**. B does not "catch up from its cursor".

The rig proves the replay is durable. A is restarted while B is down, so A's
in-memory queue is gone and only the cursor carries the gap.

`PeerConnection` backs off up to 60 s and opens its breaker after 5 consecutive
failures. Allow about 90 s after B returns before you call a message missing.
In the measured run the three messages landed about 50 s after B answered
again: B back 01:57:03Z, arrivals 01:57:53-54Z. In an earlier unrecorded run
it was about 2 s. The gap is the connection's backoff, not B.

## Revoke is unilateral

`revoke.exs` uses `notify: false`, so B is never told. A marks the peer and its
shared rows `revoked` and stops its `PeerConnection`. A sends nothing more, and
A's inbox refuses every envelope from B with `403`
(`inbox refused reason=peer_revoked`). B still considers the peer active. Its
connection keeps retrying, its breaker opens, and B's cursor stays at the last
message A accepted.

## Teardown

`down` removes both containers, drops both databases, removes the four secrets,
the two uploads volumes and the source copies. It then prints the listings and
fails if any is not empty. The listings match the rig's own names exactly. A
bare `01a199b2` filter also matches this task's `core-test-*` containers and
`platform_test_*` databases. Measured: a concurrent test run made a bare-filter
teardown report a leftover. If you check by hand with `--filter name=01a199b2`,
expect those while a test run is going. `$RIG_OUT` keeps only `rig.log` and
`rpc-<x>.log`.

## Measured run

On the test-rig host, 2026-11-02, from a fresh clone of `task/01a199b2-b20c-7000-a5b5-f55e7ecfdf5d`
at `9677ec071` (the scripts as committed). Driver output is in the execution
space of task 01a199b2. All times are UTC. A message id is the id on the
install named in its column.

**Up.** Started at 01:48:49. Both installs answered 200 at 01:55:26, and each
reached the other over `dev` at 01:55:27.

| Install | install_id | fingerprint |
| --- | --- | --- |
| A | `01a199f7-f327-7000-8376-2bab61f31907` | `3c22c1b5875dc19cd04e47100c5d283aedf8e238af045b3ce5d7ec65063f0fa9` |
| B | `01a199f7-f551-7000-a75b-e574180ad973` | `6c04977c73dbb302dd75125b59f0321e94497a6f91b11c1a53a77f7169e8c8d8` |

**Pair.**
- Propose: A's peer row `01a199f8-03db-7000-9002-2d9215944f6c` was
  `pending_outbound` at 01:55:30.396.
- B's row `01a199f8-05b6-7000-b39b-98fb4435035c` was `pending_inbound`, holding
  A's fingerprint `3c22c1b5…`.
- `pair_accept.exs` matched that fingerprint, and both rows were `active` at
  01:55:32.120.

**Share.**
- A's space `01a199f8-1424-7000-8cb2-8f7c6f57e25a` is the owner row.
- B's replica is `01a199f8-150e-7000-a519-7d60609d5b12`.

**Both ways.** Each message is stored once on each side, with one link row.

| Message | origin id, inserted_at | far-side id, inserted_at, source |
| --- | --- | --- |
| `a->b 1` (A) | `01a199f8-16f9-7000-89b2-6ec779067ceb` 01:55:35.289 | B `01a199f8-183f-7000-a8a8-fffbcedcc272` 01:55:35.616, `federation_inbound` |
| `b->a 1` (B) | `01a199f8-18c2-7000-8e77-f5d4d66b1376` 01:55:35.746 | A `01a199f8-19d1-7000-892d-a5a1fb7c281c` 01:55:36.017, `federation_inbound` |

The far-side author was the system participant `Rig user 01a199f7 (via
dev-fed-<x>-01a199b2)`. Both installs' ids start `01a199f7` because UUIDv7 is
time-ordered, so the 8-character label is the same on both sides.

**Offline catch-up.**
- B stopped at 01:55:53.
- A posted three messages while B was down.
- At 01:56:06 A's cursor was still `01a199f8-16f9…` (`a->b 1`). Its connection
  showed 3 consecutive failures (`{:transport, :nxdomain}`) and a queue of 2.
- A restarted at 01:56:06 and was back at 01:56:21. Its cursor was unchanged,
  and its new connection had re-queued from the cursor.
- B answered 200 again at 01:57:03.
- The three messages arrived on B in id order, one link row each.
- A's cursor advanced to `01a199f8-7307…` (`offline 3`). A could still sign
  after its restart.

| Message | A id, inserted_at | B id, inserted_at (arrival) |
| --- | --- | --- |
| `offline 1` | `01a199f8-5fa2-7000-a5ea-fd91ba66307f` 01:55:53.891 | `01a199fa-340e-7000-bf3a-2ab54f4d26d3` 01:57:53.807 |
| `offline 2` | `01a199f8-6984-7000-9309-c404e8236b08` 01:55:56.421 | `01a199fa-35bc-7000-a733-505fb6020b7c` 01:57:54.237 |
| `offline 3` | `01a199f8-7307-7000-aca6-5d89f637412d` 01:55:58.856 | `01a199fa-377c-7000-97b8-359844e66efe` 01:57:54.685 |

**Revoke.**
- Positive control: `pre-revoke a` (A `01a199fa-442c…`) reached B as
  `01a199fa-45eb…` at 01:57:58.380. `pre-revoke b` (B `01a199fa-47d0…`) reached
  A as `01a199fa-49fd…` at 01:57:59.421.
- `revoke.exs` ran at 01:58:16.151. A's peer row and shared row became
  `revoked` with `revoked_by: local`, and A had no PeerConnection.
- `post-revoke a` (A `01a199fa-8eb1-7000-8d8a-54b252e8c156`, 01:58:17.009)
  never reached B, and no new link row appeared.
- `post-revoke b` (B `01a199fa-91cb-7000-8a87-9889e9452cdd`, 01:58:17.803)
  never reached A.
- After 120 s, B's connection to A showed breaker `open`, 8 consecutive
  failures, last error `{:http_status, 403}`. A's log held 8
  `inbox refused reason=peer_revoked` lines. B's cursor stayed at
  `01a199fa-47d0…` (`pre-revoke b`).

**Down.**
- Ran at 02:00:19-02:00:37. Every rig listing was empty.
- Independent checks were also empty: `podman ps -a --filter name=01a199b2`,
  `podman volume ls | grep 01a199b2`, `podman secret ls | grep 01a199b2` and
  `psql -lqt | grep 01a199b2`.
- `$RIG_OUT` held only the logs, and there was no rig process left.
- dev-postgres kept the same start time.
- The `dev-platform-*` count was 72 just before and 72 just after the `down`.
  It had been 73 when the run started: another agent's container went away
  while the run was going. Nothing in the rig touches those names.
