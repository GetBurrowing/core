# 2026-08-17 `mix compile --warnings-as-errors` baseline

Task: `01a01041-4013-7936-8991-c6438b69f82d`, stage 1
("Measure the warning population and inventory it").

Ref measured: `1ee9abd06a7f1ac4616ba294e2f3b9de288b77b0`
("Modularize TasksLive: 10,933 → 1,051 lines (90% reduction) + surface-budget
ratchet (#770)"), the tip of `origin/main` at the time of measurement and the
branch point of `task/01a01041-4013-7936-8991-c6438b69f82d`.

Toolchain: **Elixir 1.19.5 (compiled with Erlang/OTP 28)**, local.

**No `lib/` change in this stage.** Its deliverable is this document. Stages 2–6
are compared against the tables here, and stage 7's CI gate is only falsifiable
because these numbers exist.

---

## 0. Why the baseline is the deliverable

The task is "make a compiler flag green". The failure mode is that a later stage
declares victory on a number nobody can reproduce — or, worse, that the
population shrinks because a *different* measurement method was used, not
because a warning was fixed.

| Claim | Evidence that supports it | Evidence that does NOT |
|---|---|---|
| The population is N | The two commands in §1, verbatim, on a `--force` compile from this ref, full output retained | A count quoted from an earlier brief |
| A stage fixed K warnings | The per-category and per-file deltas against §3/§4, plus `--warnings-as-errors` still exiting 1 with a smaller set | A lower total. Totals move when the counting method moves — see §5 |
| The gate is real | `mix compile --force --warnings-as-errors` exits **0** where §2 records exit **1** | `mix test` passing. It has always passed with 92 warnings present |

The specific reasoning error this file exists to prevent is recorded in §5: the
warning *total* and the *number of times a filename appears in the log* are
different quantities, and the second one over-counts by design.

---

## 1. Mandatory commands

Run from `apps/platform` (there is no root `mix.exs`), in a worktree checked out
at the ref above, with `deps` already fetched and compiled, `git status
--porcelain` empty:

```
MIX_ENV=dev  mix compile --force 2>&1 | tee <scratch>/dev.log
MIX_ENV=test mix compile --force 2>&1 | tee <scratch>/test.log
```

Full output is retained. **Never pipe these through `tail`/`head`** — the
warning lines are the entire evidence, and Elixir 1.19 emits each warning as a
6–12 line block (message, source excerpt, `└─` location), so a truncated log
loses whole records rather than trailing ones.

Both logs are **790 lines**, both begin `Compiling 654 files (.ex)`.

---

## 2. The gate today

```
MIX_ENV=dev  mix compile --force --warnings-as-errors   ->  exit 1
MIX_ENV=test mix compile --force --warnings-as-errors   ->  exit 1
```

Both terminate with, verbatim:

```
Compilation failed due to warnings while using the --warnings-as-errors option
```

**Total: 92 project warnings, identical in `MIX_ENV=dev` and `MIX_ENV=test`.**

The count is taken two independent ways off the same log and they agree:

| Method | dev | test |
|---|---|---|
| `grep -c '^ *warning:'` (warning headers) | 92 | 92 |
| `grep -c '└─'` (location footers) | 92 | 92 |

The agreement matters: it establishes that **no warning in this population
carries more than one location**, which is what makes per-warning attribution in
§4 sound.

---

## 3. Category breakdown (identical in both envs)

| Category | Count | Representative message |
|---|---:|---|
| clause-grouping | 45 | `clauses with the same name and arity (number of arguments) should be grouped together, "def execute/3" was previously defined (…:2900)` |
| redefining `@doc` attribute | 14 | `redefining @doc attribute previously set at line 43` |
| unused optional-arg defaults | 8 | `default values for the optional arguments in the private function safe_fail_transcript/2 are never used` |
| missing `@impl` | 6 | `module attribute @impl was not set for function children/0 callback (specified in Platform.Chat.Canvas.Kind)` |
| unreachable clause | 4 | `the following clause will never match:` (2) and `this clause for thread_previews_for_messages/1 cannot match because a previous clause at line 2052 always matches` (2) |
| unused private function | 4 | `function build_external_signal/2 is unused` |
| unused variable | 3 | `variable "user" is unused (if the variable is not meant to be used, prefix it with an underscore)` |
| unused alias/import | 3 | `unused alias Validation` |
| HEEx attribute/form | 3 | see §3.1 |
| undefined-or-private call | 1 | `Platform.ExternalAgents.stamp_last_successful_fire/2 is undefined or private` |
| `&Mix.shell().info/1` capture | 1 | `expected the module in &module.fun/arity to expand to a variable or an atom, got: Mix.shell()` |
| **total** | **92** | |

Note the unreachable-clause row is **two different compiler diagnostics** with
the same remedy class. A stage that greps for only one wording will think it
fixed 2 and leave 2 behind.

### 3.1 The three HEEx warnings, named — `mix compile` DOES reach templates

This is the premise most likely to be doubted, so it is pinned:

1. `lib/platform_web/live/meeting_live.html.heex:1647` —
   `attribute "accent_color" in component …AgentTile.agent_tile/1 must be a :string, got: nil`
   (source: `accent_color={nil}`). An **`.html.heex` file**, i.e.
   `embed_templates` compilation is inside the gate's reach.
2. `lib/platform_web/live/org_memory_live/proposals_pane.ex:172` —
   `Setting the "name" attribute to "id" on an input tag overrides the ID of the corresponding form element.`
3. `lib/platform_web/live/org_memory_live/mobile_shell.ex:695` — same warning,
   same `<input type="hidden" name="id" value={proposal.id} />` shape.

**Scope limit stage 6 must state plainly:** what `mix compile` in `MIX_ENV=test`
does *not* compile is `test/**/*_test.exs`. Those are not on `elixirc_paths`
(`mix.exs:35` gives `:test` the paths `["lib", "test/support"]`); only `mix test`
compiles the `_test.exs` files. So a CI `mix compile --warnings-as-errors` step
gates `lib/` + `test/support/` + templates, and **not** test bodies.

---

## 4. Per-file attribution (dev; test is identical)

Attributed by each warning's own `└─` location line, one warning to one file.
Sums to 92.

| File | Warnings |
|---|---:|
| `lib/platform/federation/tool_surface.ex` | 23 |
| `lib/platform_web/live/chat_live.ex` | 9 |
| `lib/platform/chat.ex` | 8 |
| `lib/platform_web/controllers/livekit_webhook_controller.ex` | 5 |
| `lib/platform_web/live/meeting_live.ex` | 5 |
| `lib/platform/orchestration/heartbeat_scheduler.ex` | 3 |
| `lib/platform_web/live/control_center/onboarding_events.ex` | 3 |
| `lib/platform/chat/canvas/kinds/embed.ex` | 3 |
| `lib/platform/chat/canvas/kinds/image.ex` | 3 |
| `lib/platform/tasks/stacks.ex` | 2 |
| `lib/platform/external_agents/dispatcher.ex` | 2 |
| `lib/platform/push.ex` | 2 |
| `lib/platform/meetings.ex` | 2 |
| `lib/platform_web/controllers/auth_controller.ex` | 2 |
| `lib/mix/tasks/platform/backfill_mentions.ex` | 1 |
| `lib/platform/federation/node_identity.ex` | 1 |
| `lib/platform/meetings/summarizer.ex` | 1 |
| `lib/platform/tasks/task.ex` | 1 |
| `lib/platform/tenancy.ex` | 1 |
| `lib/platform/tasks/plan_engine.ex` | 1 |
| `lib/platform/orchestration/task_router.ex` | 1 |
| `lib/platform/orchestration/prompt_templates.ex` | 1 |
| `lib/platform/chat/agent_responder.ex` | 1 |
| `lib/platform_web/controllers/mcp_controller.ex` | 1 |
| `lib/platform_web/live/chat/canvas_hooks.ex` | 1 |
| `lib/platform_web/live/chat/messages_hooks.ex` | 1 |
| `lib/platform_web/live/chat/presence_hooks.ex` | 1 |
| `lib/platform_web/components/meetings/invite_control.ex` | 1 |
| `lib/platform_web/live/org_memory_live/proposals_pane.ex` | 1 |
| `lib/platform_web/live/org_memory_live/mobile_shell.ex` | 1 |
| `lib/platform_web/live/control_center_live.ex` | 1 |
| `lib/platform_web/live/meeting_live.html.heex` | 1 |
| `lib/platform/chat/canvas/server.ex` | 1 |
| `lib/platform/responsibilities/router.ex` | 1 |
| **total** | **92** |

34 files. The distribution is long-tailed: **one file
(`tool_surface.ex`) holds 25 % of the population**, and 20 files hold exactly
one warning each.

---

## 5. Two corrections to the numbers this task was planned on

Both are drift found by re-measuring rather than inheriting, which the stage
brief required. Neither changes the shape of the work.

### 5.1 The total is **92**, not 93 — the missing one is a *dependency* warning

The 93rd warning in the planning measurement was the single
**deprecated sigil delimiter**. It does not exist in project code at this ref:

```
grep -rEn "~[a-zA-Z]'" lib/      ->  no matches
```

while several dependencies do contain such sigils (`deps/earmark`, `deps/ecto`,
`deps/jason`, …). The planning measurement was taken against a **cold `_build`**,
where `deps.compile` output is interleaved into the same log; this measurement
was taken with deps already compiled. Category counts agree on 11 of 12
categories exactly; the sigil row is the whole difference.

This is the same mechanism the planning notes already recorded for the test env —
16 `Timex.*` struct-update warnings that made a cold `_build/test` read 109
instead of 93. **Dependency warnings are compiled by `deps.compile` and are not
gated by the project's `--warnings-as-errors`.** So they do not belong in the
population at all, and the project baseline is 92.

**Consequence for stage 7:** the CI step must not be measured on a cold build
without separating dep output, or it will report a number no local run
reproduces, in both directions.

### 5.2 The per-file table was over-counted; `tool_surface.ex` is 23, not 43

The planning per-file table (`tool_surface.ex` 43, `chat_live.ex` 16,
`meeting_live.ex` 10, `chat.ex` 9) counts **every appearance of the filename
anywhere in the log**, not one per warning:

| File | mentions anywhere | warnings (own `└─`) |
|---|---:|---:|
| `lib/platform/federation/tool_surface.ex` | 44 | 23 |
| `lib/platform_web/live/chat_live.ex` | 16 | 9 |
| `lib/platform/chat.ex` | 10 | 8 |
| `lib/platform_web/live/meeting_live.ex` | 10 | 5 |

The cause is the clause-grouping diagnostic, whose **message body cites the
earlier definition site** — `… "def execute/3" was previously defined
(lib/platform/federation/tool_surface.ex:2900)` — so each of these warnings
mentions its own file twice. Every clause-grouping warning is double-counted by
a naive filename grep, and clause-grouping is 45 of 92.

§4's numbers are the ones to diff against. A stage that fixes all 23
`tool_surface.ex` warnings and then finds "20 remaining" by grepping the filename
has found the back-references, not surviving warnings.

---

## 6. Enforcement: nothing gates warnings today

- `.github/workflows/ci.yml` is **the only workflow file in the repo**. Its steps
  are: duplicate-migration check, surface line budgets, system packages,
  hex/rebar, deps cache, `mix deps.get`, `mix format --check-formatted`,
  `mix ecto.create` / `mix ecto.migrate`, `mix test` (with a serial retry), and
  the boot-telemetry pair. **There is no compile step.**
- `mix test` does compile in `MIX_ENV=test`, but **without
  `--warnings-as-errors`**. So warnings have never gated anything, which is why
  92 of them accumulated.
- `mix.exs` sets **no** `elixirc_options` and no `warnings_as_errors` anywhere.
  `mix.exs:9` sets only `elixirc_paths: elixirc_paths(Mix.env())`. The single
  existing reference to the flag is the `precommit` alias at `mix.exs:143`
  (`compile --warnings-as-errors`), which **no CI job invokes**.

There is therefore no flag interaction to reconcile: the new CI step stage 7 adds
is the **only** enforcement point, and it starts from exit 1.

---

## 7. Where the population is *not*

Restated from measurement, because the ticket's premises point elsewhere:

- **`test/support/**` emits ZERO warnings** at this ref. The ticket's premise
  that test-only files contribute is false here. (It is still *in scope* of the
  gate per §3.1, so a future `test/support` warning would be caught — it just is
  not part of the 92.)
- **The earlier `ac8d09da` inventory has moved.** `canvas/kinds/image.ex` (3),
  `canvas/kinds/embed.ex` (3) and `chat/presence_hooks.ex` (1) still warn;
  `plan_engine.ex` is down to **1**. The bulk is now `tool_surface.ex`, not those
  files. Do not plan stage order off that inventory.

---

## 8. Real defects found

Warnings are not all cosmetic: some name a real behavioural bug. Stages 2 and 5
fill this section in as they triage.

**Stage 2 triaged the 12 high-signal warnings (A–H below). One real defect:
`push.ex` (G1/G2) — web push is silently inert on a Vault-configured host.
It is REPORTED, NOT FIXED: the honest fix is a behaviour change on the send
path and belongs in its own ticket. Everything else in the set was dead code
or a vestigial parameter, and each deletion carries a comment naming what the
code was for and where the live equivalent is.**

The blunt headline for a reader who only skims: **the two warnings that pointed
at a live behavioural defect were the two nobody flagged as suspicious at
measurement time** (`push.ex`'s unused private functions), and **the one flagged
as "the highest-value finding" — the undefined-or-private call — turned out to be
unreachable.** §8's per-item entries say why in each case.

| # | Warning (file:line) | Category | Real defect? | What it actually breaks |
|---|---|---|---|---|
| A | `responsibilities/router.ex:2462` `Platform.ExternalAgents.stamp_last_successful_fire/2 is undefined or private` | undefined-or-private call | **No — but it read like the worst one** | Nothing. The call sat behind its own `function_exported?/3` guard in the same `cond` clause, so it was never reachable. See A below. |
| B | `chat.ex:2514`, `:2516` `cannot match because a previous clause at line 2052 always matches` | unreachable clause | No | Nothing. The two definitions were byte-identical. |
| C1 | `chat/canvas/server.ex` `{:error, reason}` will never match | unreachable clause | No | Nothing. `:conflict` is the failure channel by ADR-0036 design. |
| C2 | `federation/tool_surface.ex` `{:error, reason}` will never match | unreachable clause | No | Nothing. `Org.Wiki.Search.search/2` is total by design. |
| D | `orchestration/prompt_templates.ex:711` `skills_reference` unused | unused variable | No | Nothing. A third redundant copy of prose that already ships twice. |
| E | `orchestration/task_router.ex:3754` `gate_stage` unused | unused variable | **No — and specifically not a guard failing open** | Nothing. Both arms intentionally open no remediation stage. |
| F | `tenancy.ex:1458` `user` unused | unused variable | No | Nothing. Body needs only `user_id`. |
| G1 | `push.ex:433` `vapid_private_key/0` unused | unused private function | **YES** | Web push is silently inert on a Vault-configured (env-less) host. Reported, NOT fixed. |
| G2 | `push.ex` `vapid_configured?/0` unused | unused private function | **YES (same defect)** | It is the probe that would have shown G1. |
| G3 | `chat/agent_responder.ex:865` `build_external_signal/2` unused | unused private function | No | Nothing. Dead after the refactor that made the agent always present. |
| G4 | `platform_web/live/chat_live.ex:3871` `format_message_date/1` unused | unused private function | No | Nothing. Superseded by `Components.ChatMessage` (chat_message.ex:745). |
| H | `mix/tasks/platform/backfill_mentions.ex:37` `&Mix.shell().info/1` | capture syntax | Minor, real | The capture is not the deferred shell lookup it reads as. Fixed. |

**Population: 92 → 77 (−15).** Fifteen, not thirteen, because B's duplicate block also
carried two clause-grouping warnings (`chat.ex` 8 → 4). Per-file deltas against §4:
`responsibilities/router.ex` 1→0, `chat.ex` 8→4, `chat/canvas/server.ex` 1→0,
`federation/tool_surface.ex` 23→22, `orchestration/prompt_templates.ex` 1→0,
`orchestration/task_router.ex` 1→0, `tenancy.ex` 1→0, `push.ex` 2→0,
`chat/agent_responder.ex` 1→0, `platform_web/live/chat_live.ex` 9→8,
`mix/tasks/platform/backfill_mentions.ex` 1→0. `grep -c '^ *warning:'` and
`grep -c '└─'` both read **77**, so §2's two-method agreement still holds.

### A — the headline finding is that the headline was not a defect

`safe_stamp_last_fire/2` opened with a probe for
`Platform.ExternalAgents.stamp_last_successful_fire/2`, one of the two names the
ADR-0041 M6 planner contracted for. That name was never implemented:
`Platform.ExternalAgents` only READS `last_successful_fire_at` (`fired_within?/3`).
The OTHER name did land — `Responsibilities.Registry.stamp_last_successful_fire/2`
(registry.ex:143) — and is what every real call resolves to.

So this was **not** a live `UndefinedFunctionError` and the `rescue` was **not**
swallowing one in production: the branch body sat behind
`function_exported?(Platform.ExternalAgents, :stamp_last_successful_fire, 2)` in
its own `cond` clause, which is false, so the body was unreachable. (The
`Code.ensure_loaded?/1` conjunct matters — without it, `function_exported?/3`
would be false for a merely-unloaded module and the reasoning would not hold.)

**Remedy:** deleted the dead clause rather than writing the missing function.
Behaviour-preserving by construction. Three tests added in
`test/platform/responsibilities/router_test.exs`, and they assert the stamp
**lands** (a `Repo.get!` reload), because the wrapper's `rescue` returns `:ok` —
a "does not raise" assertion would have passed against the broken name and proved
nothing. One test pins that `ExternalAgents` exports no such function (with the
`Registry` export asserted as anti-vacuity), so a future probe for the dead name
is a test failure rather than a warning nobody reads.

### B — a duplicate, not a fork

`thread_previews_for_messages/1` was defined twice in `Platform.Chat`, ~460 lines
apart. `diff` of the two blocks — docstring, `@spec`, both clause bodies — was
**empty**, so there is no "which one do callers get" behaviour question: they are
the same function. No test asserted the dead pair (nothing could tell them
apart), so nothing needed repointing. Deleted the second copy.

### C — two dead error branches, both callees genuinely total

- `chat/canvas/server.ex handle_call({:apply_patches, …})`: `apply_with_rebase/3`
  returns `{:ok, doc, rev} | {:conflict, payload}` on all three `cond` branches.
  The one genuine failure — `CanvasPatch.apply_many/2` returning `{:error, …}` —
  is deliberately CONVERTED to a classified `{:conflict, …}` in `apply_at_head/3`.
  `:conflict` **is** the failure channel; that is ADR-0036 rebase-or-reject, and
  the public `canvas.patch` tool documents a structured rejection reason rather
  than an error tuple. Branch removed; the callee is not missing a return.
- `federation/tool_surface.ex similar_tasks_for/1`: `Org.Wiki.Search.search/2`'s
  `@spec` (search.ex:147) declares only `{:ok, …}`, the blank-query
  short-circuit returns `{:ok, …}`, and `do_search/2` absorbs every channel
  failure (`Task.async_stream` `:kill_task`, plus `{:error, _} -> []` provider
  arms) so a degraded channel contributes no hits. That is deliberate for an
  advisory search. Branch removed; the `rescue`/`catch` arms that DO fire (a
  provider raise or EXIT) are untouched.

Both removals mean an unexpected shape now raises `CaseClauseError` instead of
being reshaped into `{:error, _}` — hard failure over quiet degradation.

### D — not a dropped interpolation; a third copy of prose that already ships

`skills_reference` was built in `do_default_templates/0` and never used. Restoring
an interpolation would have been wrong twice:

1. `skills_reference` is a **render-time** variable. Template bodies carry a
   literal `{{skills_reference}}` placeholder and declare it in `variables:`;
   `Orchestration.HeartbeatScheduler` supplies the value from its own
   `@skills_reference` (heartbeat_scheduler.ex:76, :358, …) at dispatch time.
   Baking the local in would emit the block **twice** per rendered dispatch and
   break the tests asserting the stored body still holds the placeholder
   (`prompt_templates_test.exs:687`, `:2329`).
2. These strings are the seeded **descriptor** a force-update migration enforces
   from, so freezing prose into them makes it reappear in a live prompt later.

The same prose also sits verbatim in `@federation_preamble`, which reaches every
dispatch through the sibling `{{federation_preamble}}` placeholder. **No template
lost its skills section.** Dead local deleted (not renamed), and a new test
refutes that any dispatch descriptor bakes the prose — with `federation.preamble`
exempted by design, its own content asserted as the anti-vacuity control, and a
positive control that some body does carry the placeholder.

### E — the parameter was vestigial; the guard is not failing open

`replan_after_exhausted_rounds/4` received the failed `gate_stage` and ignored it.
Reading the arms: **both** deliberately open no remediation stage, and the
fallback arm's ARM DECISION comment says so and extends the reasoning to the
`:replanned` success path (the task goes to `planning` and a planner is
dispatched, so the "must have an open stage" invariant does not apply; on the
failure path the plan is dying and a synthesized stage would hand the next
planner an executable stage it never wrote). The review-round bound itself
(`count >= Tasks.max_review_rounds()`, decided in `spend_round_and_route/3`) never
consults the gate stage. **So this is not a guard ignoring an argument — it is a
function that was handed one it has nowhere to put.** Arity shrunk to /3.

The property is now pinned in `task_router_review_round_bound_test.exs` as a
**delta across round 3** (remediation-stage count unchanged), not an absence:
rounds 1–2 bounce and DO synthesize remediation stages on the same plan, so a
plan-scoped absence assertion would be false, and a `%remediat%` pattern would be
vacuous — the stage is named `PlanEngine.remediation_stage_name/0`, "Address the
failed behavioural gate".

### F — the binding, not the parameter

`set_managed_role/3`'s body reaches the membership row through `user_id` alone
(`Repo.get_by(OrgMembership, user_id: …)`, the audit event's `user_id:`, and
`write_managed_membership/5`) and never touches another struct field. Dropped the
`= user` binding rather than prefixing it.

### G — `push.ex` is the real one, and it is NOT fixed here

`vapid_private_key/0` implements the Vault fallback this module's moduledoc
advertises (`"vapid-private-key"`). **Nothing calls it.** `do_send_push/2` reads
`Application.get_env(:web_push_encryption, :vapid_details)` and nothing else, and
`config/runtime.exs:370` populates that key **only when both `VAPID_PUBLIC_KEY`
and `VAPID_PRIVATE_KEY` are set in the environment**.

Consequence on a deployment that holds the keys in Vault rather than env:
`vapid_public_key/0` returns a key, so the client subscription flow works and
the UI reports notifications are on — while every send logs
`"[Push] VAPID keys not configured, skipping push"` and returns
`{:error, :vapid_keys_missing}`. **Web push is silently unconfigured with a
working-looking subscription flow.** `vapid_configured?/0` is the probe that
would have surfaced it, and it was also unused.

Fixing this needs a key resolver on the send path — a behaviour change, so it is
deliberately **not** in this cleanup. Both functions were made **public** with
docs naming the gap (so the compiler stops flagging them without the evidence
being deleted), and `push_test.exs` gains four tests including a
characterisation test that pins the two surfaces DISAGREEING. When the follow-up
lands, that test inverts — it must not be "fixed" by relaxing an assertion.

`build_external_signal/2` and `format_message_date/1` are the opposite: both are
genuinely dead after refactors, with the live implementation identified in a
comment at each deletion site (`/3` with `context.agent` at agent_responder.ex:267;
`Components.ChatMessage` at chat_message.ex:745).

### H — the capture that is not what it reads like

`&Mix.shell().info/1`: capture syntax requires the module position to be a
variable or an atom, and `Mix.shell()` is a call. Replaced with
`fn msg -> Mix.shell().info(msg) end`, which also resolves `Mix.shell()` at log
time — so a shell swapped after option-building (e.g. `Mix.Shell.Quiet`) is
honoured.

Candidates flagged at measurement time as most likely to be real rather than
stylistic, for triage priority — **suspicion, not findings**:

- `Platform.ExternalAgents.stamp_last_successful_fire/2 is undefined or private`
  (undefined-or-private call, 1). A call the compiler cannot resolve is a
  `FunctionClauseError`/`UndefinedFunctionError` at runtime on whatever path
  reaches it.
- The 4 unreachable clauses. A clause that never matches means intended
  behaviour is silently unreachable; the two `cannot match because a previous
  clause … always matches` cases are the sharper pair.
- The 4 unused private functions. Either dead code, or a function the caller was
  meant to reach and does not.
- `meeting_live.html.heex:1647` `accent_color={nil}` against a `:string`
  attribute — a nil reaching a component that declares it cannot be nil.

The 45 clause-grouping and 14 `@doc` warnings are the opposite end: high count,
low risk, and the reason the total is dominated by cosmetics.

---

## 9. Stage 3 — the motion-only stage (44 clause-grouping + 13 `@doc`)

**Population: 77 → 20 (−57).** `grep -c '^ *warning:'` and `grep -c '└─'` both read
**20**, so §2's two-method agreement still holds. `MIX_ENV=dev` and `MIX_ENV=test`
are both 20, preserving the env-parity property. Residual contains **zero**
grouping and **zero** `@doc` entries, and no `@doc`-on-private warning was
introduced. `mix compile --force` exits **0** (warnings remain, so
`--warnings-as-errors` still exits 1 — that is stage 7's job).

Per-file deltas against §4 (grouping+@doc only):
`federation/tool_surface.ex` 22→1, `platform_web/live/chat_live.ex` 8→1,
`platform_web/live/meeting_live.ex` 5→1, `chat.ex` 4→0, `meetings.ex` 2→0,
`tasks/stacks.ex` 2→1, `platform_web/controllers/auth_controller.ex` 2→1,
`platform_web/controllers/livekit_webhook_controller.ex` 5→0,
`platform_web/live/control_center/onboarding_events.ex` 3→1,
`federation/node_identity.ex` 1→0, `tasks/task.ex` 1→0,
`platform_web/controllers/mcp_controller.ex` 1→0,
`chat/canvas_hooks.ex`, `chat/messages_hooks.ex`, `chat/presence_hooks.ex`,
`control_center_live.ex`, `components/meetings/invite_control.ex` each 1→0.

### 9.1 The stage brief's `@doc` premise is INVERTED — the LAST one wins

The brief stated: "the second `@doc` was being discarded by the compiler already,
so the shipped docs are whatever the FIRST one said." **Measured against the
compiled Docs chunk at HEAD, the opposite is true.** Two clean witnesses:

| Function | `@doc`s in source | What HEAD actually ships |
|---|---|---|
| `Federation.NodeIdentity.sign/2` | "binary **nonce**" then "binary **payload**" | **"binary payload"** — the second |
| `PlatformWeb.LivekitWebhookController.handle/2` | six, one per event clause | **"Catch-all for unhandled event types."** — the last |

So a "delete the later duplicate" remedy would have deleted **the docstring that
was actually shipping**, and for a dispatch table the survivor is the catch-all —
the least informative clause in the module. Every case in this stage was merged
deliberately instead; §9.4 records each decision.

### 9.2 Four functions shipped NO docs at all — a real documentation defect

`Chat.search_messages/3`, `Chat.list_recent_agent_actions/1`,
`Chat.delete_canvas/1` and `Tasks.Task.planning_step_changeset/2` all carried
`doc=:none` at HEAD. In each case an accurate, detailed docstring sat in the
source immediately ABOVE the `@doc` of a *neighbouring* function, so it was
consumed by the wrong `{name, arity}` and discarded. The prose existed and was
correct; no reader of `h Platform.Chat.search_messages/3` could see it. Each was
moved onto its own function.

### 9.3 Verification: the Docs chunk is the observable for a motion-only change

`git diff --stat` symmetry catches accidental deletion but not reordering, and
reordering is the hazard. Two stronger checks were used instead:

1. **Pure-permutation assertion** — the multiset of non-blank, right-stripped
   lines is byte-identical before and after, per file. Motion phase alone:
   **4223 insertions / 4223 deletions**, exactly symmetric.
2. **Compiled Docs-chunk diff** — `Code.fetch_docs/1` over every
   `_build/dev/lib/platform/ebin/*.beam` yields one sorted line per
   `{kind, name, arity}` plus moduledoc (**5826 entries**). Motion-only state vs
   HEAD came back **IDENTICAL**, proving the motion moved no documentation. The
   `@doc` phase then shows exactly: 0 lost, 4 gained (§9.2), 3 text changes (§9.4).

Also asserted per file: same-name clause order unchanged, and every
attribute/comment unit still followed by the same `def` head.

### 9.4 What was done with each duplicate `@doc`

| Site | Decision | Why |
|---|---|---|
| `node_identity.ex` `sign/2` | **Kept later**, deleted "nonce" copy | Parameter is `payload`; "nonce" is wrong. Later text was already the shipping one, so docs are unchanged. |
| `tasks/task.ex` | **Moved**, none deleted | The planning-fields doc was being eaten by `review_round_changeset/2`. Reordered so each doc sits on its own function. |
| `chat.ex` ×3 | **Moved**, none deleted | Same shape: `search_messages/3`, `list_recent_agent_actions/1`, `delete_canvas/1` docs stranded above a neighbour. |
| `meetings.ex` `generate_token/2` | **Merged** into one doc | Two genuinely different clauses (`%Room{}`+map vs two binaries), each with an accurate doc. Merged doc describes both clauses; second demoted to a comment naming why. |
| `livekit_webhook_controller.ex` `handle/2` ×5 | **Merged**: one function-level doc + per-clause detail demoted to `#` comments | Six per-clause docs, five discarded. New `@doc` is the event dispatch table; every clause's specific reasoning is preserved verbatim as a comment on that clause. No prose lost. |
| `control_center/onboarding_events.ex` `handle/3` ×2 | Same treatment as above | Three per-clause docs, two discarded. |

### 9.5 Method notes for stage 7 and anyone re-measuring

- **`grep -c 'error:'` cannot see an Elixir compile failure.** Elixir prints
  `== Compilation error in file …`. A mid-stage measurement here read
  "77 → 22, 0 errors" on a build that had **aborted partway**; the count was low
  *because* compilation stopped early, which is indistinguishable from progress.
  **Check the exit code**, and grep `Compilation error`. Extends §5's warning: a
  falling total is not evidence unless the compile that produced it succeeded.
- **Moving the last `def` in a module can carry the module's closing `end`.**
  Relocating that block puts code outside the module
  (`** (ArgumentError) cannot invoke defp/2 outside module`).
- **"Move the clause" is really "move the clause WITH its leading trivia."**
  `@doc`/`@spec`/`attr`/banner comments bind to the next `def` in source order, and
  three things silently break a naive trivia scan: multi-line `@doc """…"""`
  heredocs, multi-line `@spec x ::` continuations and bracket-balanced attributes
  (`@x [ … ]`, closing `]` back at indent 2), and Phoenix `attr(…)`/`slot(…)`
  macros (not `@` attributes at all). Each strands a doc on the wrong function
  while still compiling.
- **Safer motion for a giant dispatch module.** `tool_surface.ex` holds 100
  `execute/3` clauses over 5,400 lines interleaved with per-tool helpers. The
  helpers were moved OUT rather than the clauses moved together, so `execute/3`
  match order is preserved *by construction* rather than by inspection. Same for
  `chat_live.ex` (77 `handle_event/3`), `control_center_live.ex` (55),
  `meeting_live.ex`.
- **One genuine interleaving, and it was not a behaviour question.**
  `Meetings.generate_token` ran `/2`, `/3`, `/2`. Different arities are different
  functions, so no dispatch order exists between them; partitioned by arity,
  stable within each arity. Nothing required a match-order judgement call.
- **Suite:** 26 doctests, 13,490 tests, 3 skipped, 2 excluded, **0 real failures**.
  One flake: `BootTelemetryHandlerDetachAuditTest` "every
  `@known_unqualified_claims` entry still carries an unqualified claim" hit the
  60 s `ExUnit.TimeoutError` inside its source-scanning regex under full-suite IO
  contention, and passes in **12.4 s** when the file is run alone. Known class:
  source-scan audit tests time out under IO contention.

## 10. Stage 4 — defaults, `@impl`, aliases/import, and the sigil that was not there

**20 -> 3.** Both envs agree; the 3 survivors are exactly the HEEx warnings
stage 5 owns. `grep -c '^ *warning:'` and `grep -c '└─'` both read 3, and the
log contains zero `deps/` paths (measured on a warm `_build`, per §5.1).

### 10.1 The 8 unused defaults — arity-set safety, not just `apply/3`

Deleting a `\\ default` deletes an arity: `defp f(a, b \\ x)` defines `f/1` AND
`f/2`, so a capture `&f/1` or an `apply(__MODULE__, :f, [one])` breaks even
though no direct call does. Checked for **all three** shapes on every site —
direct calls, `&name/` captures, and `apply(_, :name, _)` — repo-wide across
`lib/` and `test/`, not just within the defining module. **Zero captures and
zero dynamic applies exist for any of the eight.** Every caller passes the full
arity, so each default was genuinely dead.

| Site | Function | Callers (all full-arity) |
| --- | --- | --- |
| `meetings/summarizer.ex:377` | `safe_fail_transcript/2` | 3 (`:339`, `:345`, `:351`) |
| `orchestration/heartbeat_scheduler.ex:970` | `hardcoded_dispatch_planning/4` | 1 (`:381`) |
| `orchestration/heartbeat_scheduler.ex:1123` | `hardcoded_dispatch_in_progress/4` | 1 (`:486`) |
| `orchestration/heartbeat_scheduler.ex:1164` | `hardcoded_dispatch_in_review/4` | 1 (`:554`) |
| `tasks/plan_engine.ex:1801` | `emit_stage_telemetry/3` | 1 (`:1235`) |
| `external_agents/dispatcher.ex:452` | `post/3` | 1 (`:200`) |
| `external_agents/dispatcher.ex:528` | `request_body/3` | 1 (`:455`) |
| `federation/tool_surface.ex:7458` | `stack_start_planning_payload/6` | 2 (`:5048`, `:5069`) |

Two corrections to the stage brief:

- **`emit_stage_telemetry/3` is in `tasks/plan_engine.ex`, not
  `heartbeat_scheduler.ex`** as the brief states. The three
  `hardcoded_dispatch_*` functions are the heartbeat_scheduler ones.
- `hardcoded_dispatch_planning/4` carried **three** defaults
  (`provider_guidance`, `previous_rejection_reason`, `parent_plans`), so it
  defined `/1../4`; the other seven carried one each.

**Prose that named the deleted arity was corrected**, because a doc naming an
arity the module no longer defines is a described bug: 5 references to
`Summarizer.safe_fail_transcript/1` (in two regression tests and
`test/support/test_quarantine.ex`) and one to `` `request_body/2` `` in
`dispatcher.ex`. All were comments/failure-message prose, not calls and not
`function_exported?` assertions — verified before editing, since a source-scanner
allowlist pinning the literal string would have made the edit load-bearing.

### 10.2 The 6 `@impl` — why only two of sixteen kind modules warned

All six are **genuine callback implementations**; none is an accidental
collision. The discriminating fact is a rule about the warning itself:
**Elixir only demands `@impl` once a module uses `@impl` at least once.**
`image.ex` and `embed.ex` each already carried exactly one (`@impl true` on
`validate_props/1`) and were therefore held to the convention for the rest;
the other 14 kind modules use `@impl` nowhere and so are silent despite also
defining `schema/0` and `render/1`. The warning is about *consistency within
the module*, not about those two modules being unusual.

Per-function verdict and basis (spec in `chat/canvas/kind.ex`):

| Function | Callback | Verdict / basis |
| --- | --- | --- |
| `Image.children/0` | `children() :: child_rule()` | impl. Returns `:none`, a valid `child_rule`. Overrides the `__using__` default, which is `defoverridable`. |
| `Image.schema/0` | `schema() :: map()` | impl. Returns a Draft-7 map. **Not** injected by `__using__`, so every kind must define it. |
| `Image.render/1` | `render(assigns) :: Rendered.t()` | impl. Takes assigns, returns a `~H` render. Not injected. |
| `Embed.children/0` | `children() :: child_rule()` | impl. Same as Image: `:none`, overrides the injected default. |
| `Embed.schema/0` | `schema() :: map()` | impl. Draft-7 map over `srcdoc`/`height`/`width`/`min_scale`. |
| `Embed.render/1` | `render(assigns) :: Rendered.t()` | impl. Returns the sandboxed-iframe `~H` render. |

Annotated as `@impl Platform.Chat.Canvas.Kind` rather than `@impl true`: these
modules also `use Phoenix.Component`, so naming the behaviour records *which*
contract is being honoured. The pre-existing `@impl true` on `validate_props/1`
was left alone (it is correct, and correctly sits on the first clause of a
three-clause function).

### 10.3 The 3 unused alias/import — one bug-shaped, none an actual bug

Each was checked for the `stacks.ex`/`alias Task` shipped-bug shape before
deletion: grep the module for the **bare, unaliased** name, and ask whether the
alias **shadows** a stdlib/framework module such that some call site might be
resolving to the wrong one.

- **`alias Platform.Tasks.{Stage, Validation}` — `stacks.ex:23`.** `Validation`
  appears **nowhere** in the module but the alias line itself; `Stage` has 6
  references and stays. `Validation` shadows no stdlib module. Genuinely
  unreferenced; deleted.
- **The `alias Task` shadow in the same module is still present on line 22, and
  it is benign — verified, not assumed.** Every `Task.` reference in
  `stacks.ex` is `Task.t()` inside a `@spec`, deliberately naming the
  `Platform.Tasks.Task` schema. There is no `Task.async`, `Task.await` or
  `Task.Supervisor` call that could be silently resolving to the schema module.
  Left as-is: it is used, so it emits no warning and is out of this stage's
  scope. Recorded so the next reader does not have to re-derive it.
- **`alias Platform.Accounts` — `auth_controller.ex:4`.** No bare `Accounts.`
  use. The adjacent `alias Platform.Accounts.ExternalAdmission` on line 5 is a
  **different** alias binding the name `ExternalAdmission`, and is unaffected by
  removing line 4 — the thing to check, since a careless grep for `Accounts`
  matches it as a path segment and reads as a live use. Deleted line 4 only.
- **`import PlatformWeb.Chat.CanvasRenderer, only: [canvas_document: 1]` —
  `chat_live.ex:24`.** The dangerous case, because an unused *import* usually
  means a template moved, and HEEx function resolution and the compiler's
  unused-import check do not always agree. `chat_live.ex` defines no `~H` and no
  `embed_templates`; it renders the colocated `chat_live.html.heex`, so its
  imports **are** in scope for that template. `canvas_document` occurs **0
  times** in `chat_live.html.heex`. The panel moved to
  `live/chat/partials.ex` during the ADR-0035 modularization, and that module
  carries **its own** import (`:26`) plus the two call sites (`:1114`, `:1150`);
  the template reaches them through `<.canvas_overlay>`. So the import is
  residue of the move. Deleted, and `chat/canvas_versions_panel_test.exs`
  (the only test touching the panel) plus `chat_live_section_render_test.exs`
  stay green.

### 10.4 Item 4 (deprecated sigil) is a no-op, and §5.1 is why

There was nothing to fix. The 93rd warning the task was planned on is a
**dependency** warning that only appears in a cold `_build`; §5.1 already
established this at stage 1. Re-confirmed independently: a scan for an uppercase
sigil whose body escapes its own closing delimiter finds **0 hits** in
`lib/`, **0** in `test/support/`, and **0** in `deps/` as currently vendored.
The project's `~S(...)` sigils (e.g. `security/scanners/deploy_audit.ex:222`,
`~S(")`) escape nothing and are fine. No delimiter was changed, so the
`:not(...)`-closes-the-sigil hazard was never reached. **The gate cannot see
this class at all**, which is the honest reason it is absent from the residual —
not that it was repaired.

### 10.5 Verification

- `MIX_ENV=dev mix compile --force` -> exit 0, **3** warnings.
- `MIX_ENV=test mix compile --force` -> exit 0, **3** warnings, byte-identical
  residual to dev.
- `mix format --check-formatted` -> exit 0.
- Touched modules' own tests: **863 tests, 0 failures** across the canvas kinds,
  dispatcher, summarizer, auth_controller, stacks, heartbeat_scheduler (6
  files), plan_engine, tool_surface stacks, the two prose-edited regression
  files, and the ChatLive render/canvas-panel tests. Full suite deliberately not
  run — this stage's gate is the two compiles.

---

## 11. Stage 5 — the 3 HEEx warnings, and the before/after pair

Stage 5 ("Correct the HEEx attribute and hidden-input warnings") cleared the
residual 3. All three came out of HEEx compilation, which incidentally proves
`mix compile` reaches `~H` / colocated-template output and therefore that the
stage-6 CI gate covers `.heex` as well as `.ex`.

### 11.1 The before-number is 92, not 93 — and both numbers are real

The stage text asks for the after-number "beside the before-number 93". That 93
is a **cold-`_build` reading**. Reconciled:

| Number | What it counts | When you see it |
|---|---|---|
| **92** | project warnings (`lib/`, `test/support/`) | any build, warm or cold |
| **93** | the same 92 **plus 1 deprecated-sigil warning from `deps/`** | first compile into an empty `_build` only |
| 109 | 92 project + 17 dep warnings, 16 of them `Timex.*` | a cold `MIX_ENV=test` build |

The dep warnings interleave into the same log and are **not** gated by the
project's `--warnings-as-errors`, so they inflate a naive count without ever
affecting the exit code. §5.1 established the mechanism at stage 1; this table
is the reconciliation, recorded so a reader comparing this document to the plan
text is not left to guess which of 92/93/109 is the project population.

**The pair, stated once, unambiguously:**

> **92 project warnings before (93 on a cold build, the extra one from `deps/`)
> -> 0 after.**

Intermediate readings, for anyone bisecting the stages: stage 2 took 92 -> 77,
stage 3 took 77 -> 20, stage 4 took 20 -> 3, stage 5 took 3 -> 0. Stage 3
measured **77** at its start rather than 92 because stages 1-2 had already
cleared 15 — that is not drift.

### 11.2 Counting method, and why a filename grep is wrong

Count `warning:` **headers**, not filename occurrences. The clause-grouping
diagnostic cites the *earlier definition site* inside its own message body, so a
filename grep double-counts it — that is what made `tool_surface.ex` read 43
when the true count was 23. Cross-checking the `warning:` headers against the
`└─` footer lines is the cheap way to catch it; at stage 3 both agreed at 20.

**Gate on the exit code, not on the count.** An *aborted* build emits *fewer*
warnings, which reads as progress; and `grep -c 'error:'` does **not** match
Elixir's `== Compilation error in file ...`, so a count-only check calls a
failed build clean. Stage 3 hit exactly this. Both compiles below are reported
by exit code first.

### 11.3 Item 1 — `accent_color={nil}` in `meeting_live.html.heex`

`attribute "accent_color" ... must be a :string, got: nil`. **Chosen fix: drop
the attribute from the call site.** `agent_tile/1` already declares
`attr :accent_color, :string, default: nil` and its `accent_background_style/1`
maps `nil` onto the documented `bg-base-200` fallback, so omitting the attribute
renders byte-identically to passing `nil` — while a literal `nil` is a type
error against a `:string` attr regardless of that default (the default applies
when the attribute is *absent*, not when it is explicitly `nil`).

**Why the real accent was not wired instead**, since a hardcoded `nil` beside a
typed attr usually is a dropped assign, and this one half is:

- the value is nominally reachable — `MeetingLive` already assigns
  `@agents_by_id :: %{agent_id => %Agent{}}`, and `%Agent{}` carries `:color`,
  which `Platform.Agents.ColorPalette.accent_for/1` resolves;
- but `accent_for/1` returns an **`oklch(...)`** string, and the tile's
  `accent_background_style/1` accepts **hex only** (`~r/^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/`)
  and silently discards anything else.

So passing it would render **no accent at all** — the exact same
`bg-base-200` as today, with a new query in the path and a false impression that
the accent is wired. Making it actually render means widening the component's
validator to accept `oklch()`, i.e. a behaviour change to a shared component,
which this task forbids smuggling into a cleanup.

**Recorded as a real defect, out of scope here:** the meeting agent tile cannot
display per-agent colour identity, because the only accent the app produces is
`oklch` and the only accent the tile accepts is hex. Chat renders the same
palette fine (`chat/presence_hooks.ex:204` injects it as a CSS custom
property). The fix is one of: widen `accent_background_style/1`, or have the
tile take a colour *id* and resolve it itself. Either wants its own ticket and
its own screenshot.

### 11.4 Item 2 — `name="id"` on two hidden inputs

`Setting the "name" attribute to "id" on an input tag overrides the ID of the
corresponding form element`. A genuine LiveView hazard, not cosmetics. Two
sites, both the proposal reject form:

- `lib/platform_web/live/org_memory_live/proposals_pane.ex:172` (desktop table
  expansion row, `#proposal-reject-form-<id>`)
- `lib/platform_web/live/org_memory_live/mobile_shell.ex:695` (mobile card,
  `#m-proposal-reject-form-<id>`)

Both renamed to `name="_id"` as the compiler advises. **A rename of a wire-format
key needs its consumers enumerated, not grepped for in templates**, so:

| Consumer class | Found | Handling |
|---|---|---|
| `handle_event/3` matching `"id"` | `org_memory_live/view.ex:389` `handle_event("reject_proposal", %{"id" => id}, ...)` | remapped to `%{"_id" => id}` |
| `<.form for={...}>` wrapper (would nest the key under a form name) | none — both are bare `<form phx-submit="reject_proposal">` | params stay top-level, so the flat match is correct |
| JS in `assets/js/` submitting or reading the field | none. `phx-hook` in this LiveView appears only on the markdown editor textareas; the sole `"id"` reference under `assets/js/` is `hooks/message_lift.js:52` `clone.removeAttribute("id")`, a DOM-id clone helper unrelated to these forms | no change |
| Controller routes accepting an external POST | none — `/memory/proposals` is `live/3` only; no proposal path in the router or any controller | no change |
| Sibling events also carrying an id | `show_reject_form`, `cancel_reject`, `approve_proposal` — all `phx-value-id`, which is a distinct mechanism from the form field | untouched, still match `"id"` |

Nothing in this flow leaves the LiveView, so the rename is fully coverable by
tests and did not need to be escalated.

### 11.5 Tests, and the mutation probe that makes them non-vacuous

Bar: **observable behaviour identical**. One test per form, each asserting the
proposal is resolved by id from the value the *template* rendered:

- `test/platform_web/live/org_memory_live_test.exs` — extended the existing
  `reject_proposal -> status:rejected + feedback captured` test. It previously
  passed `"id" => proposal.id` into `form/3`, which would have supplied the key
  the handler reads and hidden a broken template. Now it asserts the hidden
  `input[name="_id"][value=...]` exists, refutes any `input[name="id"]` inside
  the form, and submits **feedback only**.
- `test/platform_web/live/org_memory_live_mobile_test.exs` — new test, same
  shape against `#m-proposal-reject-form-<id>`. The mobile card had no reject
  submission coverage at all before this stage.

**Probe:** reverting the handler to `%{"id" => id}` while leaving the templates
on `_id` fails **exactly 2 tests** — one per form. So each test observes its own
form's wire key, and neither is green by construction. Reverted after the probe.

### 11.6 Verification

- `MIX_ENV=dev mix compile --force --warnings-as-errors` -> **exit 0**, 0
  warnings.
- `MIX_ENV=test mix compile --force --warnings-as-errors` -> **exit 0**, 0
  warnings.
- `MIX_ENV=dev mix compile --force` (no flag) -> exit 0, 0 `warning:` headers, 0
  `└─` footers. Warm `_build`, so no dep warnings in the log either.
- `mix format --check-formatted` -> exit 0.
- Touched tests: **73 tests, 0 failures** across `org_memory_live_test.exs`,
  `org_memory_live_mobile_test.exs` and
  `components/meeting/agent_tile_test.exs` (+1 test vs. before). Full suite
  deliberately not run: this stage's gate is the two compiles plus the touched
  LiveView tests, and the box was carrying load ~33 with sibling executors.

---

## 12. Stage 6 — the CI ratchet

### 12.1 What landed

`.github/workflows/ci.yml`, `test` job, a new step between `Install
dependencies` and `Check formatting`:

    - name: Compile with warnings as errors (dev + test)

It runs `mix compile --force --warnings-as-errors` twice, once with
`MIX_ENV=dev` and once with `MIX_ENV=test`, each wrapped in an `if !` with an
`::error::` annotation and `exit 1` — the same inline-shell shape the
duplicate-migration and surface-budget steps already use.

Both envs are required, not belt-and-braces. `mix.exs` puts `test/support` on
`elixirc_paths(:test)` and nowhere else, so a dev-only gate cannot see a warning
in a test helper — and a decorative gate is indistinguishable from a working one
until somebody happens to touch a helper. Stage 6's plant (b) below is the
experiment that separates those two worlds.

The flag is deliberately NOT `warnings_as_errors: true` in `elixirc_options`.
That would red every local `mix compile` and `mix test` mid-edit; the CI flag is
the narrower change with the same ratcheting effect.

### 12.2 Scope of the gate

Covers `lib/**` (dev + test), `test/support/**` (test only), and `.heex` markup
compiled through `~H` / `embed_templates`.

Does **not** cover `test/**/*_test.exs`: those are not on `elixirc_paths`, they
are compiled by `mix test` rather than `mix compile`, so a warning there does
not fail this step. Does **not** cover dependency warnings (e.g. the Timex
struct-update warnings visible in a cold `_build/test`), which come out of
`deps.compile`, not this invocation. Both gaps are named here rather than left
to be rediscovered.

### 12.3 Re-measured baseline — the plan's numbers were stale

The plan says 93 warnings and §1 of this note says 92, both measured at
`1ee9abd0`. `main` has moved a long way since. Re-measured at stage 6 against
`origin/main` = `e1a94c97`:

| Tree | `MIX_ENV=dev` | `MIX_ENV=test` |
| --- | --- | --- |
| `origin/main` `e1a94c97`, no flag | exit 0, **90** `warning:` headers | exit 0, **90** |
| `origin/main` `e1a94c97`, `--warnings-as-errors` | **exit 1** | **exit 1** |
| this branch tip | exit 0, **0** | exit 0, **0** |

An independent agent measured a cold build of `origin/main` at 88; the 90 here
is the same picture two commits later, and corroborates rather than contradicts.

**Gate on the exit code, never on a count.** An aborted Elixir build emits
*fewer* warnings than a complete one, so a falling count reads as progress when
it is the opposite; and `grep -c 'error:'` does not match Elixir's
`== Compilation error in file ...`. Both traps already cost this task a stage.

### 12.4 Correction to §8 G1/G2 — the VAPID finding is superseded

§8 records G1/G2 (`push.ex`'s unused `vapid_private_key/0` and
`vapid_configured?/0`) as a real defect *reported, not fixed*, and stage 2 made
both functions public with docs so the compiler would stop flagging them.

That change is **gone from this branch, correctly.** Upstream `fded7fdb`
("Resolve VAPID credentials through one all-or-nothing resolver") fixed the
underlying defect and made both functions public in the process, so the rebase
onto current `main` resolved `push.ex` and `push_test.exs` entirely in main's
favour and this branch now carries no `push.ex` delta at all. The two warnings
stage 2 preserved as evidence dissolved upstream. Read §8 G1/G2 as history.

### 12.5 Plant-a-warning control

A gate observed only passing has demonstrated nothing — and this task exists
precisely because a gate stopped carrying information. Three warnings were
planted, one at a time, each observed RED, each reverted.

**Where the control ran, and why not in Actions.** The stage brief asks for
three GitHub Actions run ids. That evidence is unreachable under this task's own
constraints: `ci.yml` triggers only on `push` to `main` / `feat/**` / `stack/**`
and on `pull_request` targeting those, so a push to a `task/**` branch starts no
run at all (confirmed — `gh run list --branch task/...` is empty for the pushed
tip), and the stage is instructed not to open a PR and to push to this branch
only. Adding `task/**` to the triggers would make every task branch run full CI,
which is a scope change nobody asked for. So each plant was executed against the
**byte-identical body of the new step** — the same two `if ! MIX_ENV=… mix
compile --force --warnings-as-errors` guards, same `::error::` strings, same
`exit 1` — extracted verbatim from `ci.yml` into a shell script and run from
`apps/platform`, which is the step's `working-directory`. The step body is the
whole mechanism under test; what is genuinely not covered by this substitution
is the YAML wiring (step ordering and the job's `working-directory`), which is
read-verified rather than executed. Stated plainly rather than papered over.

Exit status is the observable in every case — never a warning count.

**(a) Unused variable in a `lib/` module** — `Platform.Tenancy`. Step exit **1**,
failing on the `MIX_ENV=dev` half:

```
     warning: variable "scope" is unused (if the variable is not meant to be used, prefix it with an underscore)
     │
 112 │     scope = org_id
     │     ~~~~~
     │
     └─ lib/platform/tenancy.ex:112:5: Platform.Tenancy.plant_a_unused_variable/1

Compilation failed due to warnings while using the --warnings-as-errors option
::error::mix compile --warnings-as-errors failed in MIX_ENV=dev. ...
```

**(b) Unused variable in `test/support/**`** — `Platform.TestQuarantine`. This is
the only plant that proves the `MIX_ENV=test` half is not decorative, and it
behaved exactly as the asymmetry predicts: the `MIX_ENV=dev` compile passed
(`test/support` is not on `elixirc_paths(:dev)`, so dev cannot see this file at
all) and the step failed on the `MIX_ENV=test` half. Step exit **1**:

```
     warning: variable "registry" is unused (if the variable is not meant to be used, prefix it with an underscore)
     │
 557 │     registry = entries
     │     ~~~~~~~~
     │
     └─ test/support/test_quarantine.ex:557:5: Platform.TestQuarantine.plant_b_unused_variable/1

Compilation failed due to warnings while using the --warnings-as-errors option
::error::mix compile --warnings-as-errors failed in MIX_ENV=test (this env additionally compiles test/support via elixirc_paths(:test)). ...
```

Had the step been written with the dev compile only, this plant would have
sailed through — which is the entire justification for the second invocation.

**(c) Undeclared HEEx attribute on a function component** — an extra
`plant_c_undeclared="yes"` on a `<.icon>` call in `inheritance_pill.ex`. Proves
`.heex` markup compiled through `~H` escalates to an error rather than merely
printing. Step exit **1** on the `MIX_ENV=dev` half:

```
     warning: undefined attribute "plant_c_undeclared" for component PlatformWeb.CoreComponents.icon/1
     │
 174 │       <.icon name="hero-arrow-uturn-left" class="size-3" plant_c_undeclared="yes" />
     │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     │
     └─ lib/platform_web/components/inheritance_pill.ex:174: (file)

Compilation failed due to warnings while using the --warnings-as-errors option
::error::mix compile --warnings-as-errors failed in MIX_ENV=dev. ...
```

All three were reverted; the tree is clean and the step exits 0 on the branch
tip. No failing compile output was truncated through `head`/`tail` — a truncated
compile log is exactly how an aborted build gets misread as a smaller one.
