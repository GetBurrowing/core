# ADR 0056: Supporting Customer Installs

- **Status:** Proposed
- **Date:** 2026-10-07
- **Owners:** Team
- **Task:** 01a11718-eb39-7001-bc5c-4541b6921863
- **Extends:** [ADR 0054](0054-install-to-install-federation.md) (a `support` relationship kind on
  its trust model; not superseded)
- **Related:** [ADR 0053](0053-install-manifest-and-renderers.md), [ADR 0014](0014-agent-federation-and-external-runtimes.md)

## Context

Every customer runs an owned install (ADR 0053). When one of them breaks, the vendor has no
sanctioned way to look at it. This ADR designs three paths:

- **A.** Support over install federation, for when the customer install is up.
- **B.** An out-of-band path through the installer CLI, for when it is not.
- **C.** What support may and may not do for native agents on a single-host (Hetzner) install.

**Why a new ADR and not an addendum to 0054.** 0054's first slice has shipped:
`Platform.Federation.Peers.*` is on origin/main (`install_identity.ex`, `inbound.ex`,
`ingest.ex`, `peer_connection.ex`, and `federation_well_known_controller.ex`). Amending 0054's
Decision text would rewrite the record of what that slice implemented. Section B is by
definition the path for when federation is down, and section C depends on task 01a10322
(native agents), not on 0054, so an addendum would put two of three sections under an ADR they
do not extend. 0054 and 0055 both use an `Extends:` header instead of editing their parents,
and this ADR does the same. 0054 is not edited.

**Correction: there is no `suite_install doctor` today.** The ticket asked section B to build
on "the existing setup/doctor commands". Measured on origin/main `1b2fdaef4`:

- `deployment/installer/suite_install/__main__.py` has `validate`, `services`, `render` and
  `redact`, and dispatches `setup` and `proof` to their own modules.
- `setup/cli.py` has `init`, `status`, `run`, `secret` and `teardown`.
- `proof_mac.py` has `init`, `ports`, `ram`, `arch`, `memory`, `files`, `meetings`, `livekit`
  and `grep-transcript`.
- The only `doctor` is `suite doctor` in the separate suite-cli repo
  (`docs/burrow/installs.md:32`). It checks an agent machine's connection and harness wiring,
  not an install.

So section B **defines** a new `suite_install doctor` subcommand, composed from functions that
already exist. It is not a parallel tool: section B.2 names the existing function behind each
of its fields.

**Not experimentable.** This is design capture with no variant population. It decides trust
boundaries and consent rules, which are not tuned by measurement. Its tunables (heartbeat
interval, request expiry, retention) are reliability and policy config.

### Terms

- **Capability bundle**: an entry in `agent_runtimes.allowed_bundles`, naming a set of MCP
  tools a runtime may call (ADR 0014, `Platform.Agents.AgentRuntime`). This ADR adds one, named
  `support_diagnostics`.
- **Diagnostic report**: the artefact support reads: health, versions, error logs and
  redacted config. It is never called a "bundle" in this ADR, so the word "bundle" always means
  a capability bundle.
- **Vendor**: the party that publishes Burrow and offers support. **Vendor install**: the
  install its support staff and support agent work from. **Customer install**: the install
  being supported.
- **Vendor-authored text**: any text whose content the vendor controls: a support agent's
  message, a remediation proposal's rationale, a field in a signed request, a file the vendor
  ships for the customer to run.

## Decision

### A. Support over install federation (customer install is up)

#### A.1 The `support` relationship kind

A support relationship is a 0054 relationship row with `kind = "support"`. Every 0054 rule
applies unchanged: Ed25519 install keys held in `Platform.Vault`, propose then accept with an
out-of-band fingerprint comparison, per-relationship trust, and revocation that the revoking
install enforces on its own. A peer relationship is `kind = "peer"`. The differences:

| | peer | support |
|---|---|---|
| Who proposes | either install | **only the customer install**. A vendor install never proposes, and a customer install refuses an inbound `relationship.propose` whose `kind` is `support`. |
| Who accepts | the other install's admin | the vendor install |
| Who can revoke | either side, unilaterally (0054 s1) | **the customer admin, unilaterally**, as 0054. The vendor may also end it from its side; that only stops the vendor sending. |
| Shared spaces | any space either side shares | **exactly one**, the support space (A.2) |
| Agents | owner mints an `AgentRuntime` by hand (0054 s5) | the customer install mints one support runtime when the relationship becomes `active` (A.3) |

Revoking a support relationship, in one transaction on the customer install: sets the row to
`revoked`, deactivates the support runtime, and removes the support agent from the support
space. Then the best-effort `relationship.revoke` notice goes out, as in 0054.

#### A.2 The support space

The support space is **owned by the customer install**. Per 0054 s3 the owner assigns
canonical ids and order, and its copy is the truth. The vendor install holds a replica.

- It is created by the customer install when the relationship becomes `active`, and it is the
  only space shared under that relationship.
- Its participants are: customer users the customer admin adds, and the support agent. **A
  customer agent can never be a participant.** Adding one is refused at the participant layer,
  including through `Chat.reinvite_and_pin_mentioned/1`, so a mention cannot summon one.
- Revocation leaves the customer's copy in place, read-only. The customer decides whether to
  delete it.

#### A.3 The vendor support agent's identity and capability grant

The vendor support agent runs on the vendor's side. On the customer install it is an
**`AgentRuntime`** (0054 s5, ADR 0014), connected through the existing `/runtime/ws` socket:

- The customer install mints it when the relationship becomes `active`, and sends the raw
  runtime token to the vendor's inbox in one signed `support.runtime_grant` envelope. This is
  brokered provisioning, which 0054 s5 deferred for peers; it is in scope here only for the
  `support` kind, because a support token handed over in a chat message would be replicated
  into the vendor's copy of the support space. The token is never posted in any space.
- Its `allowed_bundles` is **exactly** `["support_diagnostics"]`. A runtime minted by a support
  relationship refuses every change to that list. `support_diagnostics` is grantable to no
  other runtime and is never in `@default_allowed_bundles`.
- Its agent can be a participant of the support space and of no other space.

The `support_diagnostics` capability bundle holds read tools that return parts of the
diagnostic report (A.4), plus one tool that writes a remediation proposal (A.7):

- `support_health`, `support_versions`, `support_error_log`, `support_config_redacted`;
- `support_native_agents` (section C);
- `support_remediation_propose` (A.7).

It holds no messaging tool, no task, plan or memory tool, no tool that reads chat history, and
no tool that names a space other than the support space. Replies reach the support space only
through the runtime socket's ordinary reply path.

#### A.4 Diagnostic contents

The same fields as the doctor's report (B.2), read live from the running app:

- **Health**: core's boot time, Repo reachability, supervisor tree up/down for the named
  subsystems, router lease counts by state (counts only, no task text), and
  disk free.
- **Versions**: core image digest, migration version, installer version, module set (ADR 0055),
  and for native agents the pins from section C.
- **Recent error logs**: error-level lines from the last 24 hours, capped at 500 lines. Each line
  keeps its message's first line and stacktrace. A crash report's `Last message` and `State`
  sections are dropped, because process state can hold message bodies. Every line then passes
  through the secret redactor.
- **Config**: every environment and manifest key, with secrets **redacted by name, never by
  value**, in the installer's `<secret:NAME>` convention (`suite_install/secrets.py`
  `placeholder/1`). Redaction is structural first: any key the manifest or registry declares as
  a secret (the `{secret:NAME}` references the renderer writes, for example
  `ENCRYPTION_KEY`) is emitted as `<secret:NAME>` whatever its value. Then `secrets.redact`
  runs over the whole text as a second layer, so a secret value that appears under an
  undeclared key is still replaced.

The report never contains a secret value, a message body, a user's name or email, a task
description, a memory page, or a file.

#### A.5 What the support agent can never do

1. **Read secrets.** No tool in `support_diagnostics` reads `Platform.Vault`, an env value
   declared secret, an agent's env file, or a runtime token. The config tool emits names only.
2. **Read message bodies outside the support space.** No tool reads chat history, and the
   agent is a participant of no other space.
3. **Write data, except as scoped below.** "Write" means any insert, update or delete on the
   customer install, or any action with an effect outside the app. The support agent has
   exactly two writes, and neither changes customer data:
   - posting a message in the support space, through the runtime reply path;
   - inserting a remediation proposal row (A.7), which does nothing until a customer admin
     approves it.
   Every other write is refused. Any effect a remediation has is the customer admin's write,
   executed by the customer install under that admin's approval.
4. **Dispatch a customer agent**, by any route (A.8).
5. Hold any other capability bundle, join any other space, or propose a relationship.

#### A.6 Audit on the customer side

Every call the support runtime makes is recorded on the customer install in the existing
`audit_events` table (`Platform.Audit.Event`), before the tool returns:

| Field | Value |
|---|---|
| `event_type` | `support.tool_call`, `support.remediation_proposed`, `support.remediation_decided`, `support.remediation_executed`, `support.relationship_changed` |
| `actor_type`, `actor_id` | `agent` and the support agent's id; for decisions, `user` and the approving admin's id |
| `resource_type`, `resource_id` | the tool name or `remediation_proposal`, and its id |
| `action` | the tool name or remediation action |
| `metadata` | `relationship_id`, `runtime_id`, a sha256 of the request arguments, the byte size of the response, and the outcome atom. Never the response itself. |

The customer install's org admins can read these rows, on a "Support access" panel and through
the existing audit read path. The support agent cannot: no `support_diagnostics` tool reads
`audit_events`. Rows outlive the relationship and are not deleted on revocation.

#### A.7 Remediation: allowed, per action, with customer consent

Remediation is allowed, from a **closed list** of actions with no free-text parameters:

- restart a native agent (`AgentHost.restart_agent/1`, 01a10322 stage 2);
- release a stuck orchestration lease;
- restart one federation `PeerConnection`.

Nothing on the list sends text to an agent, edits a file, changes a capability bundle, or
changes config.

The consent mechanism:

1. The support agent calls `support_remediation_propose` with an action from the list, its
   typed parameters (an agent id, a lease id, a peer id) and a rationale. The customer install
   writes a `support_remediation_proposals` row with `status = "pending"`, a random 16-byte
   nonce, `expires_at` = insert time + 1 hour, and `digest` = sha256 over the canonical JSON of
   (action, parameters, nonce, relationship id).
2. **Who approves:** a customer **admin user**. Never an agent, and never the support agent.
3. **On what surface:** an approval card in the support space, rendered by the customer
   install from the row, and shown with Approve and Decline only to admins. The rationale is
   shown as quoted, untrusted text. The card is a customer-install UI element, not a message
   from the vendor.
4. **What is signed:** the approval binds the row's `digest`. It is recorded server-side under
   the admin's authenticated session: approver user id, time, and the digest they saw. The
   install's own server-side check is the authority. No vendor key is involved, because the
   decision is made and enforced on one install.
5. **Expiry:** the customer install refuses to approve or run a proposal after `expires_at`.
6. **Replay protection:** status moves `pending → approved → executed` (or `declined` or
   `expired`) under a row lock, exactly once. Execution re-computes the digest and refuses a
   mismatch. An approved proposal runs once and can never run again; a second request is a new
   row with a new nonce, and needs a new approval.

#### A.8 Prompt-injection path: vendor-authored text never dispatches a customer agent

On the `full_machine` profile (01a10322 stage 3) native agents have `NOPASSWD` sudo over the
host. Any route by which vendor-authored text can dispatch a customer native agent is
therefore root over the customer install.

**0054 s6 does not cover the support agent.** That rule keys on
`metadata["source"] == "federation_inbound"`, which only the peer ingest sets. A support agent
joins as an `AgentRuntime`, and `RuntimeChannel` stamps every runtime reply with
`"source" => "external_runtime"`, which `AttentionRouter` routes like any other agent message.

**The rule this ADR picks:**

1. **The support runtime's messages are untrusted inbound.** For a runtime minted by a support
   relationship, `RuntimeChannel` stamps `metadata["source"] = "support_inbound"`. The stamp is
   applied **after** every runtime-supplied key, so the runtime cannot override it (today
   `reply_additions` are merged over the base metadata). `support_inbound` joins
   `AttentionRouter`'s `@untrusted_inbound_sources`, next to `email_inbound` and
   `federation_inbound`, so `untrusted_inbound?/1` returns true and no agent decision is made.
   This is the existing predicate, not a parallel clause.
2. **No customer agent is in the support space** (A.2), so there is no agent to route to even
   if layer 1 regressed.
3. **No support tool reaches an agent.** `support_diagnostics` has no tool that creates a task,
   assigns a phase, posts in another space or sends text to a runtime, and the remediation list
   carries no text.
4. **The remediation rationale is display-only.** It is rendered to the approving admin and is
   never passed to an agent as input.

The falsifier is a test: a support runtime posts a message that mentions a customer agent
and is shaped like an instruction, and no `AgentResponder.respond` follows, no participant is
added, and no task is created. The positive control is the same message from an ordinary
runtime, which does route.

**What this does not bound.** A customer person who copies vendor-authored text into a space
where their own agent listens has made their own decision. No mechanism here stops that, and
the support space's UI states it.

### B. When federation is down: out-of-band telemetry and self-rescue

The path for an install whose app is not up. Everything here runs on the **host**, through
the installer CLI, without core.

#### B.1 Opt-in telemetry and heartbeat

**Default: OFF.** This is consistent with the installer's existing rule,
`registry.py:540`: "Data sovereignty: no third-party heartbeat by default." The manifest's
reserved `[day2] phone_home` key (ADR 0053 s6; default `false`) becomes the switch.

- **What is sent**, every 15 minutes, by a host timer (systemd on single-host, a LaunchAgent on
  Mac) running `suite_install doctor heartbeat`: `install_id`, installer version, core image
  digest, each container's state (running, exited, restarting) and restart count, disk free
  percentage, core's last successful boot time, and error-line counts by category. No log text,
  no config, no user or message counts, no hostnames beyond the install's own base URL.
- **Where:** one HTTPS endpoint, `[day2] phone_home_url`, which defaults to the vendor's
  endpoint and can point at any other.
- **Authentication:** each heartbeat is signed with the doctor key (B.3).
- **Retention:** the vendor keeps heartbeats for 30 days and then deletes them.
- **Off switch:** `phone_home = false` and a re-render, or `suite_install doctor telemetry off`,
  which disables the timer at once. Turning it off sends one final signed
  `telemetry.withdrawn` notice; the vendor deletes that install's heartbeats on receipt.

#### B.2 `suite_install doctor` and its diagnostic report

A new subcommand of `suite_install`, composed from what exists:

| Report field | Reuses |
|---|---|
| Install step state | `setup status --json` (`setup/cli.py` `status_doc/1`), where the install was made by `setup` |
| Enabled container set | `services` (`registry.enabled_containers/1`) |
| Manifest validity | `validate` (`validate.py` `validate/1`) |
| Data-plane checks (ports, RAM, arch, memory, files, meetings, LiveKit) | the `proof` subcommands, where the target has them (today they are written for the Mac target, `proof_mac.py`; single-host equivalents are a follow-up) |
| Rendered config, redacted | `redact` (`render.redact_dir/2`), plus the structural by-name pass in A.4 |
| Log text, redacted | `secrets.redact/2` |
| Output scrub, second layer | the setup CLI's `_emit/3` scrubber, which redacts every secret value the process knows of before printing |
| Migrations status | new; see B.4 |
| Container states, image ids, disk | new; read from the container runtime and `df` |

`suite_install doctor report --out <file>` writes the diagnostic report (the same fields as
A.4) and its detached signature. The customer can read every byte before anything is sent.

**Upload on request:** `suite_install doctor report --upload <slot-url>` uploads it to a
one-time upload slot the vendor creates for that support case. The slot URL is the
destination's authentication; the doctor-key signature is the source's. Upload asks for
interactive confirmation after printing the report path and size, unless `--yes` is passed by
a person at the terminal or the upload was approved on the rescue page (B.5).

#### B.3 Signing-key custody: the doctor key

0054 keeps the install's federation key in `Platform.Vault`. A down app cannot read it, and the
CLI must not read it either. Decrypting it on the host would need Postgres and
`VAULT_MASTER_KEY`, and would copy the federation trust root out of the Vault, which 0054 s1
forbids.

**A doctor report is signed by a separate Ed25519 doctor key.**

- The installer generates it at render time and keeps it on the host, in the install
  directory's `secrets/` (0600, owned by root), beside `secrets.env`.
- Its public half goes into core's environment as `DOCTOR_PUBLIC_KEY`. When a support
  relationship is proposed, the `relationship.propose` envelope carries it, so the vendor
  install learns it over a channel the customer install's federation key authenticated. An
  install with no support relationship gives its fingerprint out of band, printed by
  `suite_install doctor key`.
- It signs over the domain-separation prefix `"suite-doctor/1\n"`. Federation envelopes use
  `"suite-federation/1\n"` (0054 s2), so a stolen doctor key cannot forge a federation envelope,
  and a federation key cannot forge a report.
- Rotation: `suite_install doctor key rotate`, and the new public key is re-announced when the
  app is next up.

#### B.4 Self-rescue actions with the app down

- **Restart services:** `docker compose restart` (or the Mac target's equivalent) for one
  named container or all of them.
- **Roll back to the previous image.** Measured: renders do not pin image digests. The
  single-host golden `compose.yaml` refers to tags such as `suite-core:core` and
  `caddy:2`, so "previous" does not exist unless something records it. A new
  `suite_install update` therefore writes, **before every pull**, each service's running
  repo digest to `image-history.json` in the install directory (non-secret, 0600, the last 5
  entries per service). `suite_install rescue rollback [<service>]` writes a
  `compose.rollback.yaml` override that pins `image: <repo>@sha256:<previous digest>` and
  restarts. `rescue free-disk` never prunes an image named in `image-history.json`. Rolling
  back core past a migration is refused when the migrations status (below) shows a migration
  newer than the target image's last one, because down-migrations are not run automatically.
- **Migrations status:** runs `Ecto.Migrator.migrations/2` through a new
  `Platform.Release.migration_status/0` (today `Platform.Release` has `migrate/0` only) in a
  one-off core container with `bin/platform eval`. This needs Postgres up, not the app. It is
  read-only.
- **Free disk:** prunes dangling images and build cache, rotates container logs, and reports
  the largest volumes. It never deletes a volume or a recorded rollback image.
- **Rotate a stuck lease: moved to app-up only.** A lease is orchestration database state
  that the router rehydrates on boot. Writing it directly while the app is down bypasses the
  router's invariants, and a stuck lease does not stop the app from booting. With the app up it
  is remediation action 2 in A.7, and the admin UI's existing controls.

| Action | Local only or remote-triggerable | Authentication | Consent |
|---|---|---|---|
| Diagnostic report: produce | local only | root on the host | the person running it |
| Diagnostic report: upload | remote-triggerable | request: Ed25519 signature by the vendor's support-request key, pinned at opt-in (B.5). Upload: the doctor-key signature on the report, and the one-time slot URL. | a customer admin approves that request id on the rescue page (B.5), or runs `doctor approve <id>` on the host. The request expires 1 hour after `issued_at`, and its id is single-use. |
| Restart services | remote-triggerable | the same signed request | the same per-request approval, expiry and single use |
| Roll back to the previous image | remote-triggerable | the same signed request, naming the service and the target digest from `image-history.json` | the same per-request approval; the rescue page shows the current and target digests before Approve |
| Migrations status | local only (its output is in every report) | root on the host | the person running it |
| Free disk | local only, because it deletes files | root on the host | the person running it |
| Rotate a stuck lease | not in B; app-up only (A.7) | admin session on the customer install | A.7's per-action approval |
| Telemetry on or off | local only | root on the host, or a manifest change | the person running it |

#### B.5 How a remote request reaches a down install, and how it is approved

There is no inbound channel to a down install. A request travels in the **response to a
heartbeat**, so remote requests exist only while telemetry is on.

- **The request**: JSON with `request_id` (UUIDv7), `install_id`, `action`, typed parameters,
  `issued_at` and `expires_at` (at most 1 hour later), signed with the vendor's support-request
  key (Ed25519, its own `kid`, prefix `"suite-support-request/1\n"`). The customer pins that
  public key when it turns telemetry on. A request with a bad signature, another `install_id`,
  an expired window or a `request_id` already in the local `rescue/used-requests` log is
  dropped and logged.
- **Nothing runs on arrival.** A valid request is written to `rescue/pending/` and waits.
- **The rescue page** is the consent surface when core is down, so a customer never needs a
  terminal (the capability principle of 01a10322). A small host-side `suite-rescue` service,
  reached through Caddy at `/_rescue`, lists pending requests and offers Approve and Decline.
  It is authenticated with a rescue code shown once at install hand-over and stored on the host
  only as a bcrypt hash. It offers the closed action list above and nothing else: no shell, no
  file view, no config edit.
- On approval the request id is appended to `rescue/used-requests` before the action runs, and
  the action's outcome is reported in the next heartbeat.

### C. Native agents on a single-host (Hetzner) install

This builds on task 01a10322's approved plan v2. Stage 1 is on its branch
(`Platform.Agents.NativeAgents`, `Federation.provision_agent_runtime/3`). Stages 2-6 are
planned. Stage numbers below refer to that plan.

#### C.1 What the vendor can see, through A and B

- **Runtime health:** each native agent's `AgentHost.status/1` state (stage 2): `starting`,
  `running`, `stopped`, `crashed` or `needs_login`, with `observed_at` and the host's reported
  profile (`full_machine` or `contained`, stage 3). Through `support_native_agents` (A.3) and
  in the doctor report.
- **Supervisor restarts:** the systemd state of each `suite-agent@<agent_id>.service` unit
  (stage 2), its restart count and last exit code.
- **Log tail:** agent-host's own log, and the **lifecycle lines** systemd writes for each unit
  (start, stop, exit status). **Not** the agent process's output, its tmux pane, or stage 6's
  "Recent output". Those carry whatever the agent read or wrote, including message bodies from
  other spaces and login prompts.
- **Version pinning:** the pins in `services/agent-host/versions.env` (stage 3) for the Claude
  Code CLI, the Codex CLI and suite-cli, and the agent-host image digest.

#### C.2 What the vendor can do

- Propose a restart of one native agent, through A.7. The customer admin approves it, and core
  runs `AgentHost.restart_agent/1`.
- Request a service restart or an agent-host image rollback through B.5, approved on the
  rescue page.
- Tell the customer, in the support space, which version to pin, or to re-run login. Changing a
  pin happens only through a released installer or agent-host version that the customer applies.

#### C.3 What the vendor must not do

- Read or edit an agent's files (stage 5). `.claude/settings.json` can define hooks, and on
  `full_machine` an edit there is root on the host.
- Read an agent's env file, its runtime token, or an API key stored for it in the Vault
  (stage 6).
- Create, start, stop or delete a native agent, change its capability bundles, or send text to
  it.
- See the agent's pane or output.
- Touch the login flow, as below.

#### C.4 Claude account login

Claude account login must complete through Anthropic's own flow. The vendor never collects, stores, relays or intermediates Claude.ai credentials, login codes or session tokens. Support may tell a customer to re-run login; it must never perform the login.

Support assistance never touches the login flow. It can see that an agent is in `needs_login`,
and it can tell the customer to log in again. No support tool, remediation action, rescue
request or diagnostic field carries a login URL, a login code or a token.

The paste-back relay in 01a10322's approved plan v2, stage 6, which passes a Claude login code
typed into Burrow to the agent's pane through suite-cli or agent-host, is incompatible with this
ADR and is being resolved in 01a10322 (decision pending).

#### C.5 SSH keys in cloud-init

**The vendor places no SSH key in a customer install's cloud-init.** The rendered
`authorized_keys` holds only keys the customer supplies, or none. Every vendor action goes
through A or B, where it is audited and consented. Task 01a10315 (Hetzner one-click) currently
says "SSH stays available for us"; it must follow this rule instead. Power users may still add
their own key.

#### C.6 When the vendor holds the hosting account

01a10315 allows the server to sit in the vendor's own Hetzner account, with billing passed
through. In that case the provider console, rescue mode, volume snapshots and the API token are
**outside every guarantee in this ADR**. Whoever holds the account can read the disk. The
guarantees here bound the support channel (A and B) only, not the hosting relationship. A
customer who needs the stronger guarantee hosts the server in their own account.

## Considered and rejected

**SSH or VPN access for the vendor.** A shell or a network path into the host is root, or a
step from it, over everything on the install, with no per-action consent and no audit row on
the customer side. It also bypasses every boundary in sections A and C: a shell can read the
Vault master key, agent env files and the login state. The support channel is deliberately
narrower than a shell, so that a customer can grant it without trusting the vendor with the
machine.

**A shared Erlang cluster.** ADR 0054 s8 rejects Erlang distribution between installs: the
cookie is effectively root on every connected node, and nodes form a full mesh by default.
That reasoning applies with more force here, because one vendor node would be meshed with
every customer it supports, and one compromised customer could reach the others.

**Always-on telemetry.** It contradicts the installer's data-sovereignty rule
(`registry.py:540`) and ADR 0053's `phone_home = false` default. It would also make the
heartbeat's response, which carries remote requests (B.5), a standing inbound channel on every
install whether or not its owner wanted support. Opt-in keeps that channel limited to installs
that asked for it.

## Follow-up tickets

Each is one buildable slice, filed as a backlog task by stage 2 of this ADR's task (see the
header). Each ticket opens with a falsifier and names its dependencies by task id.

1. **Support relationship kind and support space**: the `kind` column, customer-only propose,
   the single owner-held support space, the no-customer-agent participant rule, and the
   `support.runtime_grant` envelope. (ticket: [01a11722-ddd7-7001-a781-c371b96cac8a](/tasks/01a11722-ddd7-7001-a781-c371b96cac8a))
2. **`support_diagnostics` capability bundle and customer-side audit**: the read tools, the
   one-space and fixed-bundle rules for support runtimes, the `support_inbound` source stamp in
   `RuntimeChannel` and `@untrusted_inbound_sources`, and the `audit_events` rows and Support
   access panel. Depends on 1. (ticket: [01a11723-4e1c-7001-9a8f-ff4e60c9d0ab](/tasks/01a11723-4e1c-7001-9a8f-ff4e60c9d0ab))
3. **Per-action remediation consent**: `support_remediation_proposals`, the approval card, the
   closed action list, digest binding, expiry and single execution. Depends on 2. (ticket: [01a11723-e81f-7001-931a-cc3b75d0b56a](/tasks/01a11723-e81f-7001-931a-cc3b75d0b56a))
4. **`suite_install doctor` and its signed diagnostic report**: the doctor key, the report
   composed from existing installer functions, `Platform.Release.migration_status/0`, and
   upload to a one-time slot. (ticket: [01a11723-0a28-7001-b6da-f41fed7afbf4](/tasks/01a11723-0a28-7001-b6da-f41fed7afbf4))
5. **Opt-in telemetry, signed remote requests and the rescue page**: `[day2] phone_home`, the
   heartbeat timer, the support-request key pin, `rescue/pending` and `used-requests`, and the
   `suite-rescue` page. Depends on 4. (ticket: [01a11723-7faf-7001-be60-46c33dcaf806](/tasks/01a11723-7faf-7001-be60-46c33dcaf806))
6. **Local self-rescue actions**: `suite_install update` with `image-history.json`,
   `rescue rollback`, `rescue free-disk`, and service restart. Depends on 4. (ticket: [01a11723-a61f-7001-861d-9670addd8bd7](/tasks/01a11723-a61f-7001-861d-9670addd8bd7))
7. **Native-agent support view**: `support_native_agents` and the doctor's native-agent fields,
   built on `AgentHost.status/1` and `versions.env`, with lifecycle-only log lines. Depends on 2,
   on 4 for the doctor fields, and on 01a10322 stages 2 and 3. (ticket: [01a11724-17c0-7001-8547-c5556ef6a886](/tasks/01a11724-17c0-7001-8547-c5556ef6a886))

## Consequences

- The `support` kind reuses 0054's trust root and envelope. The only new key material is the
  host-held doctor key, and on the vendor side the support-request key.
- `@untrusted_inbound_sources` gains `support_inbound`. Any future source of vendor-authored text
  joins that predicate instead of adding a clause.
- The diagnostic report's redaction and the rule that vendor-authored text never dispatches a
  customer agent are the two guarantees a customer relies on. Each has a falsifier test named
  in its slice.
- A customer who never turns on telemetry and never proposes a support relationship gets no
  vendor path at all, by design. Support then depends on the customer running the doctor and
  sending the report.
