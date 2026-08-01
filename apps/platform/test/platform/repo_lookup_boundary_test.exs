defmodule Platform.RepoLookupBoundaryTest do
  @moduledoc """
  The checked-in classification of every `Repo.get`-family lookup in
  `apps/platform/lib`, plus the assertion that turns it into a standing
  gate.

  ## Read this before you "fix" a failure here

  This file exists because the same defect landed three times in one
  session, each time fixed at exactly one site: PR #613 (`ecc8acc7`),
  task `019fa11d-1f6a`, and stages 1-2 of task `019fa129`. The defect is
  that `Repo.get(Schema, id)` **raises** `Ecto.Query.CastError` on a
  malformed id instead of returning `nil`, so `get_thing/1` functions
  whose `@spec` promises `| nil` are not total.

  If this test fails, the scanner found a `Repo.get`-family call that is
  not in `@inventory`. Do not delete the entry to make it green —
  classify the new site:

    * `:safe_internal` — the id provably cannot be malformed. **Requires
      a concrete reason naming the mechanism**: which struct field it is
      read from, which query selected it, which guard already cast it,
      or which primary-key type makes a cast impossible. "internal" is
      not a reason and `test "no :safe_internal reason is a placeholder"`
      rejects it.
    * `:must_cast` — the id can arrive from an agent, an MCP tool
      payload, a webhook body, a LiveView `params` map, a channel
      message or a URL path segment. Guard it with
      `Platform.UUID.valid?/1` and keep the site's existing not-found
      return value.
    * `:flagged_sibling_owned` — `:must_cast`, but the file belongs to an
      in-flight sibling task. Record it, do not edit it.

  ## Classification rules, stated so they are checkable

  1. **Aggregation.** A key is `{path, call_kind, schema_alias}` and may
     cover several calls. It takes the classification of its **most
     exposed** call. `platform/tasks/stacks.ex :get "Stack"` covers 17
     calls; one boundary-reachable call makes the key `:must_cast`.
  2. **Conservative default.** Where provenance could not be established
     with confidence, the key is `:must_cast`. The cost of that error is
     a redundant guard; the cost of the opposite error is a 500 on a
     request path.
  3. **Primary-key type counts as a mechanism.** `Platform.Roles.Role`
     is `@primary_key {:key, :string}`, so `Repo.get(Role, key)` cannot
     raise a cast error at all. That is a concrete `:safe_internal`
     reason, and it is the only schema in the `Repo.get` inventory with
     a non-UUID PK.

  ## Two failure modes, not one

  A bare `Ecto.UUID.cast/1` guard fails differently depending on what
  flows downstream, and stage 4 needs different tests for each:

    * **raise-exposed** — the guard is used as a boolean and the
      *original* value is passed on. `Ecto.UUID.cast/1` hex-encodes a
      raw 16-byte binary and returns `{:ok, _}`, so a 16-character slug
      clears the guard, then the strict `Platform.Types.UUIDv7` PK
      rejects it inside `Repo` → `Ecto.Query.CastError`.
    * **fabricated-value-exposed** — the `{:ok, casted}` output is used.
      No raise; the 16-byte binary is silently hex-encoded into a
      well-formed but *invented* UUID which is then persisted or
      compared. `assert_raise`-shaped tests will never see this one.

  ## Evidence that the whole class keeps recurring

  Three `rescue`-based workarounds for this exact raise were live on
  `main` when this inventory was written: `meetings.ex:675`,
  `meetings.ex:1798`, and the bare `rescue _` at
  `tasks/review_requests.ex:474`. Each masked a lookup that should have
  been guarded.

  Stage 5 collapsed the third one, and what it found there is the
  general lesson rather than a local detail: **the rescue was hiding a
  behaviour bug, not only a crash.** `requester_display_name/1` returned
  `submitted_by` from its rescue clause, so an agent-filed review
  rendered as the raw slug `"higgins"` instead of the agent's display
  name. The output was wrong on the COMMON path and nothing looked
  broken. Guarding the arm did not just stop a raise — it made the
  `get_by(slug:)` branch reachable for the first time.

  The fourth workaround this class produced — `human_approver/1`, an
  `Ecto.UUID.cast/1` pre-filter written by the ADR-0046 member-5
  executor — is NOT on `main` (`git grep -n human_approver origin/main`
  is empty); it lives only on that unmerged branch. Collapsing it
  belongs to whoever merges it, not to this task.
  """

  use ExUnit.Case, async: true

  alias Platform.Support.RepoLookupScan

  # Files owned by in-flight sibling tasks (019f9d80, 019fa003, 019fa06a
  # and the unmerged ADR-0046 stack). Recorded, never edited by this task.
  # The ADR-0046 stack has now MERGED, so "in-flight" no longer describes it.
  # The prefixes stay because what they encode is still true and still useful:
  # these files belong to nine members of reviewed work whose lookups were
  # classified but deliberately not rewritten by the boundary-hardening task.
  # Anything moved off this list must be re-classified on its own merits, not
  # silently downgraded to :safe_internal.
  @sibling_owned_prefixes [
    "platform/orchestration/task_router.ex",
    "platform/tasks.ex",
    "platform/tasks/task.ex",
    # Added at the ADR-0046 merge — same stack, same rule.
    "platform/tasks/architecture_rejection.ex",
    "platform/tasks/plan_rejection.ex",
    "platform/design/",
    "platform/responsibilities.ex",
    "platform/responsibilities/"
  ]

  # {relative_path, call_kind, schema_alias, call_count, classification, reason}
  @inventory [
    # ── Mix tasks ──────────────────────────────────────────────────────
    {"mix/tasks/platform/backfill_stack_deploy_cascade.ex", :get, "Stack", 1, :safe_internal,
     "stack_id is either selected by the task's own `distinct: s.id` query or handed in as `--stack-id`; a Mix task raising lands in the operator's terminal, not on a request path"},
    {"mix/tasks/platform/stacks_reprocess_rollup_pr.ex", :get, "Stack", 1, :safe_internal,
     "`resolve_stack/2` reads `--stack-id` out of the task's own OptionParser opts; same operator-terminal blast radius"},
    # ── Accounts ───────────────────────────────────────────────────────
    {"platform/accounts.ex", :get, "User", 1, :safe_internal,
     "guarded by `Platform.UUID.valid?/1` in stage 2 of task 019fa129; `Accounts.get_user/1` is total and returns nil for `\"system\"`, `\"system:auto\"` and agent slugs"},
    {"platform/accounts.ex", :get_by, "User", 1, :safe_internal,
     "keyed `oidc_sub:`, a plain string column holding the OIDC provider's subject; no UUID type on either side of the comparison"},
    # ── Agents ─────────────────────────────────────────────────────────
    {"platform/agents/agent_server.ex", :ecto_uuid_cast, "-", 1, :safe_internal,
     "`uuid_string?/1` carries the `String.length(value) == 36` prefix, so it is the strict form — the only correct copy of the predicate on main outside `Platform.UUID`"},
    {"platform/agents/agent_server.ex", :get, "Agent", 3, :safe_internal,
     "two calls sit behind `uuid_string?/1` (`fetch_agent/1`, `resolve_slug/1`); the third reads `state.agent_id`, which the GenServer set from a loaded `%Agent{}` at start"},
    {"platform/agents/agent_server.ex", :get, "Session", 1, :safe_internal,
     "session_id is minted by `Agents.Orchestration` and echoed back into the server's own `handle_call`; it is never a caller-chosen string"},
    {"platform/agents/agent_server.ex", :get_by, "Agent", 1, :safe_internal,
     "keyed `slug:`, a string column — this is the non-UUID branch of `fetch_agent/1`"},
    {"platform/agents/config.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "fetch_agent/1's predicate is now Platform.UUID.valid?/1, so a 16-character agent slug takes the slug branch instead of clearing a bare cast and raising against Agent's strict UUIDv7 PK. Reverting it to Ecto.UUID.cast/1 reintroduces an unclassified :ecto_uuid_cast key here AND drops this count — two failures naming this file"},
    {"platform/agents/config.ex", :get, "Agent", 1, :safe_internal,
     "reached only via fetch_agent/1's Platform.UUID.valid?/1 branch, so the value is a canonical 36-character uuid by construction; a slug takes the Repo.get_by(Agent, slug:) branch"},
    {"platform/agents/config.ex", :get_by, "Agent", 1, :safe_internal,
     "keyed `slug:`, an `agents.slug` string column — the non-UUID branch of `fetch_agent/1`, reached only when the bare cast above rejects the value"},
    {"platform/agents/historian_dispatcher.ex", :get, "Agent", 1, :safe_internal,
     "agent_id comes from `Roles.agent_id_for_role(\"historian\")`, i.e. a `role_assignments.agent_id` column selected out of the DB"},
    {"platform/agents/historian_dispatcher.ex", :get_by, "Chat.Participant", 1, :safe_internal,
     "`participant_id` is derived deterministically from space_id by `ensure_system_participant/1`; `participant_type` is a literal"},
    {"platform/agents/memory_context.ex", :get_by, "WorkspaceFile", 2, :safe_internal,
     "`agent_id` is `agent.id` off a loaded `%Agent{}` at all four callers (Agents.Config, Agents.Orchestration, WorkspaceBootstrap, ControlCenter.WorkspaceEvents); `file_key` is a string column"},
    {"platform/agents/orchestration.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "fetch_agent/1's predicate is now Platform.UUID.valid?/1. This is the function stage 4's brief named as the shape to MIRROR: the branch structure was always right, only the predicate was broken"},
    {"platform/agents/orchestration.ex", :get, "Agent", 1, :safe_internal,
     "reached only via fetch_agent/1's Platform.UUID.valid?/1 branch; slugs take the Repo.get_by(Agent, slug:) branch instead"},
    {"platform/agents/orchestration.ex", :get_by, "Agent", 3, :safe_internal,
     "keyed `slug:` and `workspace_id:` + `slug:`; workspace_id is `agent.workspace_id` off a loaded struct at both callers"},
    {"platform/agents/router.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "the third copy of fetch_agent/1's predicate, now Platform.UUID.valid?/1. The router resolves agent identifiers straight off dispatch payloads, where slugs are the common case"},
    {"platform/agents/router.ex", :get, "Agent", 1, :safe_internal,
     "reached only via fetch_agent/1's Platform.UUID.valid?/1 branch; slugs take the Repo.get_by(Agent, slug:) branch instead"},
    {"platform/agents/router.ex", :get_by, "Agent", 1, :safe_internal,
     "keyed `slug:`, an `agents.slug` string column; string comparison cannot raise a cast error regardless of what the router was handed"},
    {"platform/agents/workspace_bootstrap.ex", :get!, "Agent", 1, :safe_internal,
     "`agent.id` read off the `%Agent{}` `upsert_agent!/1` just returned in the same function"},
    {"platform/agents/workspace_bootstrap.ex", :get_by, "Agent", 2, :safe_internal,
     "keyed `slug:` from the parsed workspace config file, a string column"},
    # ── Architecture (ADR-0046, task 019fa61c) ─────────────────────────
    {"platform/architecture/stage_audit.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "`resolve_stage/1`'s binary clause. `StageAudit.read/1` is the question every other module asks about `stages.architecture_audit`, and a later stage exposes it behind an MCP tool taking a caller-supplied `stage_id` — so the guard is here from the start rather than added once the tool ships. Count 1 -> 2 with stage 5: `audit_rows/1` guards `coverage/1`'s `project_id` before it reaches `where: t.project_id == ^project_id`, returning an empty coverage rather than raising Ecto.Query.CastError. The classification is unchanged because the guard, not the caller, is what makes the lookup safe — and `coverage/1` is the read an operator reaches for while chasing a responsibility that has gone silent, so raising on a fat-fingered id would send them after a second bug"},
    {"platform/architecture/stage_audit.ex", :get, "Stage", 2, :safe_internal,
     "both in `resolve_stage/1`: the `%Stage{}` clause re-reads by the PK off a loaded struct (deliberate — see `read/1`'s @doc on stale structs), and the binary clause is reached only through the Platform.UUID.valid?/1 branch above, returning nil for a malformed id in line with `read/1`'s `:none`"},
    # ── Changelog ──────────────────────────────────────────────────────
    {"platform/changelog.ex", :get, "ChangelogEntry", 1, :safe_internal,
     "Changelog.get_entry/1 checks Platform.UUID.valid?/1 first and returns nil for a malformed id, matching its documented `| nil` contract"},
    # ── Chat ───────────────────────────────────────────────────────────
    {"platform/chat.ex", :get, "Agent", 2, :safe_internal,
     "both remaining calls go through resolve_agent/1, which checks Platform.UUID.valid?/1 and falls back to Repo.get_by(Agent, slug:) — so an MCP-supplied agent slug resolves instead of raising. The four dm/group/roster call sites were rewritten onto that helper"},
    {"platform/chat.ex", :get, "Attachment", 1, :safe_internal,
     "Chat.get_attachment/2 checks Platform.UUID.valid?/1 before Repo.get, so an MCP-supplied attachment id that is not a uuid returns nil"},
    {"platform/chat.ex", :get, "Canvas", 2, :safe_internal,
     "get_canvas/2 and get_canvas_with_deleted/2 both check Platform.UUID.valid?/1 first, so the canvas_get / canvas_describe tool arguments cannot raise"},
    {"platform/chat.ex", :get, "Message", 3, :safe_internal,
     "Chat.get_message/2 checks Platform.UUID.valid?/1 first; the other two read r.message_id / message_id off rows already loaded in the same function"},
    {"platform/chat.ex", :get, "Participant", 4, :safe_internal,
     "every call takes a participant id read off a loaded struct — `message.participant_id`, `r.message_id`'s reaction row, `p.participant_id`; `get_participant/1`'s only in-repo callers (agent_responder.ex, active_agent_hooks.ex) pass `message.participant_id`"},
    {"platform/chat.ex", :get, "Platform.Accounts.User", 1, :safe_internal,
     "`sponsor_email_for/2` destructures `%Task{sponsor_user_id: sponsor_id}` in the head, so the id is a column off a loaded task row"},
    {"platform/chat.ex", :get, "Platform.Tasks.Task", 2, :safe_internal,
     "task_id is read from the execution space's own `metadata[\"task_id\"]`, written by `Orchestration.ExecutionSpace` from a persisted task PK. Residual risk is a hand-corrupted metadata blob, not a request-path input"},
    {"platform/chat.ex", :get, "Space", 6, :safe_internal,
     "guarded at the source: Chat.get_space/2 checks Platform.UUID.valid?/1 before Repo.get, so the PR #613 site now returns nil for a channel slug. ensure_dm_send_allowed/2 was switched from Repo.get/2 to that guarded getter; space_for_path_segment/1 (task 019fabe8) takes the same Platform.UUID.valid?/1 branch before Repo.get and falls back to get_space_by_slug/2 otherwise; the remaining calls read space_id off a loaded %Message{} or off the space's own metadata"},
    {"platform/chat.ex", :get, "Thread", 2, :safe_internal,
     "Chat.get_thread/1 checks Platform.UUID.valid?/1 first; reply_to_thread/3's lookup is reached with a thread_id that getter already resolved"},
    {"platform/chat.ex", :get_by, "Participant", 2, :safe_internal,
     "get_agent_participant/2 checks Platform.UUID.valid?/1 on BOTH space_id and participant_id (both :binary_id columns), and add_agent_participant/3 checks space_id before delegating to do_add_agent_participant/3"},
    {"platform/chat.ex", :get_by, "Pin", 1, :safe_internal,
     "do_unpin_message/2 checks Platform.UUID.valid?/1 on the phx-value- message_id before reaching the :binary_id-keyed lookup, returning the existing {:error, :not_found}"},
    {"platform/chat.ex", :get_by, "Platform.Accounts.User", 1, :safe_internal,
     "keyed `email:`, a string column — the `@mention` pin-target resolver"},
    {"platform/chat.ex", :get_by, "Platform.Agents.Agent", 1, :safe_internal,
     "keyed `slug:`, a string column — the `@mention` pin-target resolver"},
    {"platform/chat.ex", :get_by, "Thread", 2, :safe_internal,
     "keyed `parent_message_id:`, supplied by `create_thread_for_message/3` from a `%Message{}` already loaded by the caller"},
    {"platform/chat/agent_responder.ex", :get, "Agent", 2, :safe_internal,
     "`participant.participant_id` off a loaded `%Participant{}`, and `agent_id` off the responder's own resolved context"},
    {"platform/chat/agent_responder.ex", :get, "TaskRecord", 1, :safe_internal,
     "task_id is read from the execution space's `metadata[\"task_id\"]`, same provenance as chat.ex's Task lookups"},
    {"platform/chat/attachment_reaper.ex", :get, "Attachment", 1, :safe_internal,
     "the reaper sweeps ids it just selected from `chat_attachments` in the same function"},
    {"platform/chat/attachments/tool_handlers.ex", :get, "Attachment", 3, :safe_internal,
     "finalize_pending/2 checks Platform.UUID.valid?/1 before delegating to do_finalize_pending/3; the other two read existing_id off an %Attachment{} or off the dedup query in the same function"},
    {"platform/chat/attention_router.ex", :get, "Message", 1, :safe_internal,
     "message_id arrives in the router's own `handle_info` cast, broadcast by `Chat.create_message/1` with the PK it just inserted"},
    {"platform/chat/attention_router.ex", :get, "Space", 1, :safe_internal,
     "space_id comes off the `%Message{}` the router just loaded"},
    {"platform/chat/attention_router.ex", :get, "TaskRecord", 1, :safe_internal,
     "task_id read from the execution space's `metadata[\"task_id\"]`"},
    {"platform/chat/canvas/server.ex", :get, "Canvas", 1, :safe_internal,
     "`do_persist/1` uses the canvas_id the `CanvasServer` was started with, which `Chat.get_canvas/1` already resolved to a row"},
    {"platform/chat/canvas_access.ex", :get, "Canvas", 1, :safe_internal,
     "fetch_for_viewer/3 checks Platform.UUID.valid?/1 on the /canvases/:id URL path segment before the lookup, folding a malformed id into the existing {:error, :not_found}"},
    {"platform/chat/dispatch_membership.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "resolve_space/1 and resolve_agent/1 each guard with Platform.UUID.valid?/1 before their lookups. Both ids arrive verbatim off dispatch payloads (meeting transcript rows, TaskRouter context maps, the intent queue) and agent_id is routinely a slug, so a bare Ecto.UUID.cast/1 would hex-encode a 16-character slug, clear the guard, and raise against the strict UUIDv7 PK — on a best-effort path whose contract is always-:ok"},
    {"platform/chat/dispatch_membership.ex", :get, "Agent", 1, :safe_internal,
     "reached only through resolve_agent/1's Platform.UUID.valid?/1 branch, so the value is a canonical 36-character uuid by construction; a slug takes the Repo.get_by(Agent, slug:) branch"},
    {"platform/chat/dispatch_membership.ex", :get, "Space", 1, :safe_internal,
     "reached only through resolve_space/1's Platform.UUID.valid?/1 branch; a non-UUID space_id returns {:skip, :invalid_space_id} without touching Repo"},
    {"platform/chat/dispatch_membership.ex", :get_by, "Agent", 1, :safe_internal,
     "keyed `slug:`, an `agents.slug` string column — the non-UUID branch of resolve_agent/1, reached only when the guard above rejects the value"},
    {"platform/chat/freeze_policy.ex", :get_by, "Participant", 1, :safe_internal,
     "resolve_actor/2 checks Platform.UUID.valid?/1 on assignee_id — routinely \"system\" or an agent slug — before the :binary_id-keyed lookup, keeping nil as the not-found value"},
    {"platform/chat/messages/edit.ex", :get, "Participant", 1, :safe_internal,
     "`message.frozen_by_participant_id` destructured off a loaded `%Message{}`"},
    {"platform/chat/sidebar.ex", :get, "Section", 1, :safe_internal,
     "update_section/2 checks Platform.UUID.valid?/1 on the phx-value- section_id, folding a malformed id into the existing {:error, :not_found}"},
    # ── Design (sibling-owned, ADR-0046) ───────────────────────────────
    {"platform/design/brand.ex", :platform_uuid_guard, "-", 1, :flagged_sibling_owned,
     "`fetch_project/1`'s predicate, collapsed from a bare Ecto.UUID.cast/1 onto Platform.UUID.cast/1 at the ADR-0046 merge. The site was already total — it passes the cast's OUTPUT to `Tasks.get_project/1` and additionally rescues — so this is the canonical-predicate fix, not a raise fix. Sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/design/preplan_step.ex", :get, "Task", 2, :flagged_sibling_owned,
     "`resolve_task/1`: :705 takes `%Task{}.id` off a loaded struct; :706 takes a raw binary. Every public entry point that can reach :706 with a caller-supplied string — `settle/2`, `expire/2`, `audit_ui_prediction/2`, `annotate/3` — wraps its body in `rescue`/`catch`, and the only lib caller passing a binary (`tool_surface.ex:5954`, `plan_create`) reaches it only AFTER `Tasks.create_plan/1` accepted the same id in the enclosing transaction. `start/1` does not rescue, but TaskRouter calls it with a `%Task{}` struct. Sibling-owned — RECORD, DO NOT EDIT"},
    # ── External agents ────────────────────────────────────────────────
    {"platform/external_agents.ex", :get_by, "Agent", 1, :safe_internal,
     "get_external_agent/1 checks Platform.UUID.valid?/1 before the id:-keyed get_by, which raises exactly like Repo.get/2 does. This is the spelling `git grep \"Repo.get(\"` cannot see"},
    {"platform/external_agents.ex", :get_by!, "Agent", 1, :safe_internal,
     "get_external_agent!/1 checks Platform.UUID.valid?/1 and raises Ecto.NoResultsError — its DOCUMENTED miss exception — rather than Ecto.Query.CastError. The bang twin the plan missed"},
    # ── Federation ─────────────────────────────────────────────────────
    {"platform/federation.ex", :get, "Agent", 4, :safe_internal,
     "all four read `runtime.agent_id` / a resolved `agent_id` off an `%AgentRuntime{}` or role assignment already loaded from the DB"},
    {"platform/federation.ex", :get, "AgentRuntime", 1, :safe_internal,
     "`Federation.get_runtime/1` is called with `socket.assigns.runtime_pk` (set at channel join from an authenticated row) or `agent.runtime_id` off a loaded struct"},
    {"platform/federation.ex", :get_by, "AgentRuntime", 1, :safe_internal,
     "keyed `runtime_id:`, a string column carrying the runtime's self-reported slug"},
    {"platform/federation/dead_letter_policy.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "both freshness predicates guard `dead_letter.subject_id` with Platform.UUID.valid?/1 before their subject lookup. The column is a :binary_id, but classify/1 takes a STRUCT rather than an id, so a hand-built row would otherwise raise Ecto.Query.CastError out of stage 3's drain loop — which aborts the drain for that runtime, making one malformed row withhold every good one"},
    {"platform/federation/dead_letter_policy.ex", :get, "Stage", 1, :safe_internal,
     "audit_diff_freshness/1's subject lookup, behind the Platform.UUID.valid?/1 guard recorded above; it keeps the predicate's fail-closed {:stale, :subject_superseded} return on a miss"},
    {"platform/federation/dead_letter_policy.ex", :get, "Plan", 2, :safe_internal,
     "one reads `stage.plan_id` off a %Stage{} Postgres just returned (NOT NULL uuid FK column); the other is review_plan_freshness/1's subject lookup, behind the Platform.UUID.valid?/1 guard recorded above"},
    {"platform/federation/dead_letter_policy.ex", :get, "Tasks.Task", 1, :safe_internal,
     "reads `plan.task_id` off a %Plan{} loaded two lines earlier — a NOT NULL uuid FK column, so no id reaches it that Postgres did not just hand back"},
    {"platform/federation/task_attrs.ex", :get, "Platform.Agents.Agent", 1, :safe_internal,
     "`default_agent_resolver/1` is the injection seam for tests; callers pass an `assignee_id` that `TaskAttrs` has already shape-validated"},
    {"platform/federation/tool_surface.ex", :platform_uuid_guard, "-", 6, :safe_internal,
     "file_delete_actor/1 now uses Platform.UUID.cast/1, so a 16-byte agent_id yields nil (delete refused) rather than a fabricated actor id written to the audit column; plus the get_by_uuid/2 helper's own guard. Count 2 -> 3 at the ADR-0046 merge: member 5 stage 4's `verdict_plan/1` was collapsed off a bare Ecto.UUID.cast/1 onto the same predicate. Count 3 -> 4 with ADR-0046 member 7 / task 019fa504 stage 2: `design_decline_task/1` casts `task_design_decline`'s agent-supplied task_id through the same predicate. Count 4 -> 5 with task 019fa609 stage 5: `stage_list_task_plan/2` guards `stage_list`'s newly-accepted agent-supplied task_id before it reaches `Tasks.current_plan/1` or `latest_plan/1`. These are context functions rather than a Repo.get/2 on a schema, so get_by_uuid/2 cannot be reused — but the exposure is identical (a raw tool argument cast into a query) and so is the remedy, which is why the classification still holds. Count 5 -> 6 with task 019fa61c stage 3: `stage_audit_stage/1` casts `stage_architecture_audit`'s agent-supplied stage_id through the same predicate — the classification is unchanged because the guard, not the caller, is what makes the lookup safe"},
    {"platform/federation/tool_surface.ex", :get, "Plan", 3, :safe_internal,
     "two read stage.plan_id off a %Stage{} already loaded in the same function; plan_approve's agent-supplied plan_id was moved onto the guarded get_by_uuid/2 helper. The third (count 2 -> 3 at the ADR-0046 merge) is member 5 stage 4's `verdict_plan/1`, whose agent-supplied plan_id is gated by Platform.UUID.cast/1 — collapsed from a bare Ecto.UUID.cast/1 at the merge — so Repo.get receives a canonical uuid or is never reached"},
    {"platform/federation/tool_surface.ex", :get, "Stage", 2, :safe_internal,
     "stage.plan_id is read off a %Stage{} the tool already loaded; the boundary-facing stage_complete lookup was moved onto the guarded get_by_uuid/2 helper. Count 1 -> 2 with task 019fa61c stage 3: `stage_audit_stage/1` behind `stage_architecture_audit`. The agent-supplied stage_id is gated by Platform.UUID.cast/1 in the same `with`, so Repo.get receives a canonical uuid or is never reached. The lookup lives HERE rather than being delegated to `StageAudit.record_note/3` (which resolves its own id) for the same reason `design_decline_task/1` does: `record_note/3` would report a mistyped stage_id as `stage_not_found` too, but resolving first is what lets the tool keep `stage_not_found` distinct from `audit_not_open` — an architect who fat-fingered an id must not be told the audit was never opened"},
    {"platform/federation/tool_surface.ex", :get, "Task", 1, :safe_internal,
     "ADR-0046 member 7 / task 019fa504 stage 2: `design_decline_task/1` behind `task_design_decline`. The agent-supplied task_id is gated by Platform.UUID.cast/1 in the same `with`, so Repo.get receives a canonical uuid or is never reached. The lookup exists HERE rather than being delegated to `PreplanStep.decline/3` (which resolves its own id) because `decline/3` collapses an unknown task and an already-closed step into the same `{:ok, :noop}` — resolving first is what lets the tool refuse `task_not_found` distinctly from `step_not_open`"},
    # ── Files ──────────────────────────────────────────────────────────
    {"platform/files.ex", :get, "Text", 1, :safe_internal,
     "fetch_extracted_text/1 checks Platform.UUID.valid?/1. Files.Text keys on a bare :binary_id, so before the guard a 16-byte binary returned nil silently while \"higgins\" raised — one lookup, two symptoms"},
    {"platform/files.ex", :get, "~q:File", 1, :safe_internal,
     "Files.get_file/2 checks Platform.UUID.valid?/1 before piping through the soft-delete filter, so the raw file_id MCP argument behind file_get_metadata / file_get_text / file_delete returns nil"},
    {"platform/files.ex", :get!, "~q:File", 1, :safe_internal,
     "Files.get_file!/2 checks Platform.UUID.valid?/1 and raises Ecto.NoResultsError — its documented miss exception — rather than Ecto.Query.CastError"},
    # ── Meetings ───────────────────────────────────────────────────────
    {"platform/meetings.ex", :platform_uuid_guard, "-", 13, :safe_internal,
     "cast_identity/2 now uses Platform.UUID.cast/1, so a 16-byte LiveKit webhook identity suffix yields :unknown instead of a fabricated user_id/agent_id FK; the remaining guards cover get_meeting/1, get_room/1, get_transcript/1, get_transcript_with_segments/1, the two recording lookups, resolve_agent/1, claim_router_dispatch/1 (019fa56b-c81f stage 2), whose transcript_id arrives inside a meeting:finished PubSub payload and must answer {:error, :no_such_transcript} rather than raise on the Router's dispatch path, and get_invite/1 (019fb954 stage 4), whose invite_id arrives inside a SIGNED GUEST TOKEN PAYLOAD — a signature proves who minted the payload, not that its ids are uuids, and a fabricated id must never be what decides whether a capability was revoked"},
    {"platform/meetings.ex", :get, "Agent", 1, :safe_internal,
     "the one remaining call is inside resolve_agent/1, which checks Platform.UUID.valid?/1 and falls back to Repo.get_by(Agent, slug:). generate_agent_token/3, dispatch_meeting_join/3 and dismiss_agent/2 all route through it"},
    {"platform/meetings.ex", :get, "Invite", 2, :safe_internal,
     "two, both behind Platform.UUID.valid?/1. (1) the miss branch of Meetings.revoke_invite/1: a malformed invite_id from the host's phx-value- revoke control returns {:error, :not_found} before either this Repo.get or the guarded UPDATE ... WHERE id = $1 ahead of it can raise (019fb954 stage 3). (2) get_invite/1, the revocation gate in resolve_guest_invite/2, whose invite_id is read out of a guest token payload on a public unauthenticated ingress; nil folds to {:error, :invalid} (019fb954 stage 4)"},
    {"platform/meetings.ex", :get, "Meeting", 1, :safe_internal,
     "Meetings.get_meeting/1 checks Platform.UUID.valid?/1 first; resolve_invited_meeting/2 was switched onto that guarded getter, so its rescue Ecto.Query.CastError is now belt-and-braces rather than the actual defence"},
    {"platform/meetings.ex", :get, "Platform.Tasks.Project", 1, :safe_internal,
     "`resolve_meeting_org_id/1` reads `project_id` off the `%Meeting{}` row it was handed"},
    {"platform/meetings.ex", :get, "Recording", 2, :safe_internal,
     "stop_recording/1 and recording_completed/2 each check Platform.UUID.valid?/1 in their with-chain, folding a malformed egress-webhook recording_id into the existing {:error, :not_found}"},
    {"platform/meetings.ex", :get, "Room", 1, :safe_internal,
     "Meetings.get_room/1 checks Platform.UUID.valid?/1 before Repo.get, so a phx-value- room id cannot raise"},
    {"platform/meetings.ex", :get, "Transcript", 2, :safe_internal,
     "get_transcript/1 and get_transcript_with_segments/1 both check Platform.UUID.valid?/1; the URL path segment at transcript_controller.ex:23 now 404s instead of raising"},
    {"platform/meetings.ex", :get!, "Room", 1, :safe_internal,
     "`start_recording/1` uses the `room_id` off the `%Room{}` `find_or_create_room/1` returned earlier in the same flow"},
    {"platform/meetings.ex", :get_by, "Invite", 2, :safe_internal,
     "keyed `meeting_id:` + `user_id:` inside Meetings.invite_user/3's idempotency path (the pre-check and the lost-race re-read). `meeting_id` is read off the `%Meeting{}` struct the caller passed; `user_id` is the boundary value and is checked with Platform.UUID.valid?/1 before either call, so an id from the invite UI's params map answers {:error, changeset} keyed :user_id rather than raising (019fb954 stage 3)"},
    {"platform/meetings.ex", :get_by, "Meeting", 1, :safe_internal,
     "keyed `project_id:` + `slug:`; the deliberate slug-scoped lookup documented at meetings.ex:34 as the authorization-safe path"},
    {"platform/meetings.ex", :get_by, "Room", 3, :safe_internal,
     "keyed `livekit_room_name:` (string) and `space_id:`; the `space_id` callers pass a `%Space{}` id already resolved by `Chat.get_space/1`"},
    {"platform/meetings/intent_classifier.ex", :get, "Platform.Agents.Agent", 1, :safe_internal,
     "`agent_slug/1` receives an `agent_id` the classifier read off a `%Participant{}` row in the same pipeline"},
    {"platform/meetings/intent_dispatcher.ex", :get, "Agent", 1, :safe_internal,
     "`safe_get_agent/1` is fed an `agent_id` resolved by `Roles.agent_id_for_role/1` before dispatch"},
    {"platform/meetings/intent_dispatcher.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`meeting_target_space_id/1` guards with Platform.UUID.valid?/1 before its lookup. The meeting_id is a per-meeting IntentQueue key, and the queue is Registry-keyed with no DB row required — nothing upstream guarantees it is a UUID, so an unguarded Repo.get would raise Ecto.Query.CastError on a best-effort dispatch path whose contract is always-:ok"},
    {"platform/meetings/intent_dispatcher.ex", :get, "Meeting", 1, :safe_internal,
     "reached only through `meeting_target_space_id/1`'s Platform.UUID.valid?/1 branch, so the value is a canonical 36-character uuid by construction; a meeting id with no row returns nil and the dispatch simply names no space"},
    {"platform/meetings/intent_runtime_adapter.ex", :get, "Agent", 1, :safe_internal,
     "`resolve_target/1` receives the `agent_id` the dispatcher already resolved from a role assignment"},
    # ── Memory ─────────────────────────────────────────────────────────
    {"platform/memory/proposals.ex", :get, "MemoryProposal", 1, :safe_internal,
     "Proposals.get/1 checks Platform.UUID.valid?/1 on the phx-value-id LiveView param before Repo.get"},
    {"platform/memory/telemetry_handler.ex", :get, "Platform.Org.WikiJournalEntry", 1,
     :safe_internal,
     "`metadata.memory_entry_id` comes off the telemetry event `Org.Wiki` emits with the PK it just inserted"},
    # ── Orchestration ──────────────────────────────────────────────────
    {"platform/orchestration/context_assembler.ex", :get, "TaskSchema", 1, :safe_internal,
     "`load_parent_plan_entry/1` uses `parent_id` read off the `%Task{}` it already loaded"},
    {"platform/orchestration/execution_space.ex", :get_by, "Participant", 1, :safe_internal,
     "`participant_id` is derived deterministically from space_id by `system_participant_id/1`; `participant_type` is the literal \"agent\""},
    {"platform/orchestration/phase_runtime.ex", :get, "Agent", 1, :must_cast,
     "task 019fb977 moved this lookup out of `task_router_watcher.ex`, where it was :safe_internal because the id came off the `tasks.assignee_id` COLUMN (a `Platform.Types.UUIDv7` cast at write time). `PhaseRuntime.resolve/1` now prefers `phase_assignees[current_phase(task)][\"assignee_id\"]`, which lives inside a JSONB map that `Task.validate_phase_assignees/1` (`tasks/task.ex:348`) checks only the PHASE KEYS of — never the id shape. An MCP `task_update` carrying `%{\"execution\" => %{\"assignee_id\" => \"higgins\"}}` therefore reaches this call as a raw agent-supplied string. Guarded with `Platform.UUID.valid?/1`, returning the site's existing `{:error, :agent_not_found}` rather than raising `Ecto.Query.CastError` inside the router's dispatch path; covered by `phase_runtime_test.exs` \":agent_not_found — not a raise — for a malformed phase-entry id\""},
    {"platform/orchestration/phase_runtime.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "the guard itself, paired with the `:get \"Agent\"` entry above: `Platform.UUID.valid?/1` is used as a BOOLEAN and the original string is passed on unchanged, which is the raise-exposed shape — safe here only because `valid?/1` is the strict 36-character check, not `Ecto.UUID.cast/1`, so a 16-byte binary cannot clear it and reach the strict `Platform.Types.UUIDv7` PK"},
    {"platform/orchestration/prompt_templates.ex", :get, "PromptTemplate", 1, :safe_internal,
     "get_template/1 checks Platform.UUID.valid?/1 first — conservative, since no in-repo caller pins this id's provenance and a redundant guard costs nothing"},
    {"platform/orchestration/prompt_templates.ex", :get_by, "PromptTemplate", 1, :safe_internal,
     "keyed `slug:`, a `prompt_templates.slug` string column — this is the lookup path actually used, and no UUID type participates in the comparison"},
    {"platform/orchestration/runtime_supervision.ex", :get_by, "RuntimeEvent", 1, :safe_internal,
     "keyed `idempotency_key:`, a string column"},
    # `task_router.ex — get(Platform.Agents.Agent)` was here, recorded as
    # sibling-owned against `resolve_stage_dispatch_assignee/1`. The ADR-0046
    # stack has now landed and member 9 (`66911d50`, "Strip the
    # stage-responsibility resolution path from TaskRouter") DELETED that
    # function along with the rest of the stage-responsibility concept, so the
    # lookup it classified no longer exists. Entry removed per this test's own
    # instruction for a stale site: the classification is not lost, the code it
    # described is gone. `stage_responsibility_retired_test.exs` guards the
    # removal.
    # MOVED, not deleted (task 019fb977): the lookup left
    # `task_router_watcher.ex` when `resolve_runtime_for_task/1`'s body became
    # a delegate to `Platform.Orchestration.PhaseRuntime.resolve/1`. Its
    # classification CHANGED with the move and that is the interesting part —
    # see the entry under `platform/orchestration/phase_runtime.ex` above.
    # ── Org ────────────────────────────────────────────────────────────
    {"platform/org/context.ex", :get, "WikiPage", 1, :safe_internal,
     "get_file_by_id/1 checks Platform.UUID.valid?/1 before Repo.get, so a caller-supplied page id from the memory MCP tools returns nil"},
    {"platform/org/preamble_builder.ex", :get, "Org", 3, :safe_internal,
     "one call reads `project.org_id` off a preloaded task, one walks `parent_org_id` off a loaded `%Org{}`, and the third takes `opts[:org_id]` which callers set from a resolved `%Org{}`"},
    {"platform/org/wiki/indexer.ex", :get, "WikiJournalEntry", 1, :safe_internal,
     "the indexer re-loads ids it selected from the same table in the enclosing sweep"},
    {"platform/org/wiki/indexer.ex", :get, "WikiPage", 1, :safe_internal,
     "same sweep provenance as the journal-entry lookup above"},
    {"platform/org/wiki/routing.ex", :platform_uuid_guard, "-", 5, :safe_internal,
     "all five namespace/owner casts are Platform.UUID.cast/1, so a 16-character project/space path segment no longer validates as a namespace uuid nor gets compared as an owner id. Fabricated-value family: nothing raised before, which is why an assert_raise test would not have caught it"},
    # ── Push ───────────────────────────────────────────────────────────
    {"platform/push.ex", :get, "Participant", 2, :safe_internal,
     "`participant_id` comes off the recipient list `Chat.list_participants/2` returned for the space being notified"},
    {"platform/push.ex", :get, "User", 2, :safe_internal,
     "`user_id` is `participant.participant_id` off the `%Participant{}` loaded on the line above, or a recipient id from the same list"},
    # ── Responsibilities (sibling-owned) ───────────────────────────────
    {"platform/responsibilities.ex", :get, "Responsibility", 1, :flagged_sibling_owned,
     "`Responsibilities.get/1` public getter; sibling-owned by the ADR-0046 stack — RECORD, DO NOT EDIT"},
    {"platform/responsibilities.ex", :get_by, "Responsibility", 1, :flagged_sibling_owned,
     "keyed `key:` (string column, so not exposed) but the file is sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/context_providers.ex", :get, "Plan", 1, :flagged_sibling_owned,
     "`load_plan/1`, reached from `resolve_anchor_task/1` with a `plan_id` off a responsibility trigger payload. Wrapped in this module's `safe/1`, which rescues and returns `{:error, {:exception, _}}`, so a malformed id degrades an OPTIONAL context slot to nil instead of raising. Sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/context_providers.ex", :get, "TaskSchema", 1,
     :flagged_sibling_owned,
     "`load_task/1`, same `resolve_anchor_task/1` ladder and the same `safe/1` wrapper as the Plan lookup above — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/handlers/architecture_audit_diff.ex", :get, "Plan", 1,
     :flagged_sibling_owned, "sibling-owned handler — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/handlers/architecture_audit_diff.ex", :get, "Stage", 1,
     :flagged_sibling_owned, "sibling-owned handler — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/handlers/architecture_audit_diff.ex", :get, "TaskSchema", 1,
     :flagged_sibling_owned, "sibling-owned handler — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/handlers/architecture_review_plan.ex", :get, "Plan", 1,
     :flagged_sibling_owned, "sibling-owned handler — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/router.ex", :get, "Message", 1, :flagged_sibling_owned,
     "`load_message_with_space_kind/1` takes `message_id` off a responsibility trigger payload; sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/router.ex", :get, "Platform.Chat.Space", 1,
     :flagged_sibling_owned, "sibling-owned router — RECORD, DO NOT EDIT"},
    # ── Roles ──────────────────────────────────────────────────────────
    {"platform/roles.ex", :get, "Agent", 1, :safe_internal,
     "`maybe_signal_runtime_mismatch/2` is called from `set_override/2` with the `agent_id` the caller is about to write as an FK; a miss falls through to `:ok` and the insert reports the real error"},
    {"platform/roles.ex", :get, "Role", 1, :safe_internal,
     "`Platform.Roles.Role` is `@primary_key {:key, :string}` — a string PK cannot raise a cast error. The only non-UUID PK in this inventory"},
    {"platform/roles.ex", :get!, "Role", 1, :safe_internal,
     "same string PK as `get_role/1`; `Repo.get!/2` on a `:string` PK raises `Ecto.NoResultsError`, never `Ecto.Query.CastError`"},
    # ── Skills ─────────────────────────────────────────────────────────
    {"platform/skills.ex", :get, "Skill", 1, :safe_internal,
     "get_skill/1 checks Platform.UUID.valid?/1 and returns nil for a slug, which is DESIGNED traffic here: skill_get accepts a slug or an id and tool_handlers.ex:49 routes any non-empty binary through both branches"},
    {"platform/skills.ex", :get, "Task", 1, :safe_internal,
     "resolve_skills/1 checks Platform.UUID.valid?/1 on the run-dispatch task_id before Repo.get, returning the existing empty list"},
    {"platform/skills.ex", :get_by, "Skill", 1, :safe_internal,
     "keyed `slug:`, a `skills.slug` string column — the slug half of `skill_get`, which cannot raise however malformed the argument is"},
    {"platform/skills.ex", :get_by, "SkillAttachment", 1, :safe_internal,
     "keyed `skill_id:` + `entity_type:` + `entity_id:`; `detach_skill/3` is called with ids the attach path already resolved to rows"},
    # ── Tasks (sibling-owned) ──────────────────────────────────────────
    {"platform/tasks.ex", :get, "Agent", 1, :flagged_sibling_owned,
     "`planner_display_name/1` — sibling-owned by the ADR-0046 stack — RECORD, DO NOT EDIT"},
    {"platform/tasks.ex", :get, "Epic", 1, :flagged_sibling_owned,
     "`get_epic/1` is MCP-reachable (`tool_surface.ex:3145`) but sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/tasks.ex", :get, "Plan", 4, :flagged_sibling_owned,
     "`get_plan/1` is MCP-reachable (`tool_surface.ex:5908`) but sibling-owned — RECORD, DO NOT EDIT. Count 1 -> 4 at the ADR-0046 merge, all three from the architecture gate: `:2445` re-reads `plan.id` after `update_all` (off a loaded struct) and `:2486` does the same, but `:2487` — `resolve_plan_for_gate(id) when is_binary(id)` — takes a RAW binary with no `Platform.UUID` guard and no rescue. That one is a genuine :must_cast, kept at :flagged_sibling_owned only because this file belongs to the stack being merged. The gate is reached from `tool_surface.ex` `plan_architecture_verdict`, whose own `verdict_plan/1` casts first and hands over a loaded `%Plan{}`, so the exposed arity is not reachable from THAT tool today — but nothing structural stops a future caller passing a string"},
    {"platform/tasks.ex", :get, "Project", 1, :flagged_sibling_owned,
     "`get_project/1` is MCP-reachable (`tool_surface.ex:3084,7053`) but sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/tasks.ex", :get, "Task", 10, :flagged_sibling_owned,
     "covers `get_task_record/1` (MCP-reachable at eight tool_surface call sites); sibling-owned — RECORD, DO NOT EDIT. Count 11 -> 10 at task 019fb977 stage 4: `maybe_apply_phase_assignee_and_reload/1` is GONE, not merely moved. It existed only to make a SECOND `Repo.update` (the flat phase pointer) visible on the struct the first one returned; folding that write into the status changeset leaves nothing to reload. Its `Repo.get(Task, task.id)` was the `:safe_internal` end of this key's range (id read off a struct `Repo.update/1` had just returned), so removing it cannot change the classification — the key stays pinned by `get_task_record/1`, its MOST exposed call. Count 8 -> 10 at the ADR-0046 merge: `resolve_task_for_planning_step/1` at :689 (`%Task{}.id`, safe) and :690 (raw binary, unguarded — the same :must_cast shape as `resolve_plan_for_gate/1` above, and recorded for the same reason). Count 10 -> 11 at task 019fa605 stage 4: `emit_architecture_gate_opened/1` reads `gated.task_id` off a `%Plan{}` that `open_architecture_gate/2` just returned from `Repo.update/1`, so it is a `tasks.id` FK column and a canonical UUID by construction — the SAME shape as `tasks/architecture_rejection.ex`'s entry below, and the classification is unchanged. It is additionally inside that function's own rescue/catch envelope, which exists precisely so a lookup fault cannot escape into the gate-open path"},
    {"platform/tasks.ex", :get, "Validation", 1, :flagged_sibling_owned,
     "`evaluate_validation/3` — sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/tasks.ex", :get!, "Task", 3, :flagged_sibling_owned,
     "`plan.task_id` / `updated_plan.task_id` off loaded structs, but sibling-owned — RECORD, DO NOT EDIT. Count 2 -> 3 at task 019fa605 stage 3: `retry_lost_deferred_tail/1` reads `plan.task_id` off a `%Plan{}` that `resolve_plan_for_gate/1` just re-read from the database, so it is a `tasks.id` FK column and a canonical UUID by construction — the SAME shape as the two already recorded, and the classification is unchanged. The caller is a reconcile-tick sweep, not an MCP surface"},
    {"platform/tasks.ex", :get_by, "Project", 1, :flagged_sibling_owned,
     "keyed `slug:` (string column, so not exposed) but sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/tasks.ex", :platform_uuid_guard, "-", 1, :flagged_sibling_owned,
     "classification is :flagged_sibling_owned only because `sibling_owned?/1` covers this whole PATH; the guard itself would be :safe_internal on the reasoning below. Task 019fb977 stage 4: `phase_pointer_attrs/2` folds the flat `assignee_id` pointer into the same changeset as `status`, so the id it reads out of the `phase_assignees` JSONB map is now cast on the STATUS write's path. `Task.validate_phase_assignees/1` (`tasks/task.ex:348`) checks only the phase KEYS, so an MCP `task_update` can persist `%{\"execution\" => %{\"assignee_id\" => \"higgins\"}}` — measured on the pre-fold code, that raised `Ecto.ChangeError` (`:binary_id` is a dump-time type error, so the old second write did NOT fall into `maybe_apply_phase_assignee/1`'s `_error -> :ok` arm) and, on the `in_progress` path, rolled the committed status back out of `transition_with_policy2_freeze/2`'s transaction. `Platform.UUID.valid?/1` is used as a BOOLEAN and the original string is discarded rather than passed on — the pointer is simply left unchanged and the transition still commits, pinned by `tasks_phase_pointer_test.exs` \"a malformed phase assignee id does not block the status transition\". Same strict 36-character check as the `phase_runtime.ex` guard above, which is the READER half of this pair"},
    {"platform/tasks/architecture_rejection.ex", :get, "Task", 1, :flagged_sibling_owned,
     "`Repo.get(Task, plan.task_id)` — `task_id` is a `tasks.id` FK column read off a loaded `%Plan{}`, so it is a canonical UUID by construction. Sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/tasks/plan_rejection.ex", :get, "Agent", 1, :flagged_sibling_owned,
     "`agent_name/1` inside `actor_display_name/1`. This lookup DOES raise on a malformed actor id and is deliberately allowed to — `actor_display_name/1`'s `rescue` is what folds it to \"the reviewer\". Note this became the raising tier only at the ADR-0046 merge: main's 9b0d74d8 made the `Accounts.get_user/1` tier above it total, so malformed ids now fall through to here. Pinned by plan_rejection_test.exs. Sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/tasks/task.ex", :ecto_uuid_cast, "-", 1, :flagged_sibling_owned,
     "`valid_dependency_entry?/1` bare-casts an agent-supplied `dependencies` payload, so a 16-char string validates and is persisted as a task_id. Sibling-owned — RECORD, DO NOT EDIT"},
    # ── Tasks: not sibling-owned ───────────────────────────────────────
    {"platform/tasks/canvas_attachments.ex", :get, "Canvas", 1, :safe_internal,
     "ensure_canvas_attachable/1 checks Platform.UUID.valid?/1 on the canvas_attach tool argument, folding a malformed id into {:error, :canvas_not_found}"},
    {"platform/tasks/canvas_attachments.ex", :get, "Task", 1, :safe_internal,
     "ensure_task_exists/1 checks Platform.UUID.valid?/1 on the same MCP payload, folding a malformed id into {:error, :task_not_found}"},
    {"platform/tasks/chat_pins.ex", :get_by, "ChatPin", 1, :safe_internal,
     "keyed `task_id:` + `participant_kind:` + `participant_id:`; `get_pin/3` is only reached from `pin/3`, whose ids the mention resolver already matched to rows"},
    {"platform/tasks/context_hydrator.ex", :get, "Task", 1, :safe_internal,
     "load_task/1 checks Platform.UUID.valid?/1 on the run-dispatch task_id, folding a malformed id into the existing {:error, :task_not_found}"},
    {"platform/tasks/deploy_merge_reconciler.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 019fba18 stage 4: `live_gate/1` guards `why_not_live/1`'s `where: v.id == ^id`, whose id is a COMMAND-LINE argument to `mix suite.deploy.scope_gate` — an operator pasting a task id, a truncated uuid or a stage id is the expected failure, not an edge case. The guard is used as a BOOLEAN and the id is downcased rather than replaced by the cast's return, because persisted ids are lowercase and `valid?/1` passes an uppercase uuid. A malformed value folds into `{:error, :malformed_id}` and the mix task renders it as a named refusal with a non-zero exit, pinned by suite_deploy_scope_gate_test.exs \"refuses an id that is not a well-formed uuid, including the 16-byte case\", which first shows the unguarded query raising `Ecto.Query.CastError`"},
    {"platform/tasks/plan_engine.ex", :get, "Plan", 1, :safe_internal,
     "`stage.plan_id` off the `%Stage{}` the engine just loaded"},
    {"platform/tasks/plan_engine.ex", :get, "Stage", 1, :safe_internal,
     "fetch_stage/1 checks Platform.UUID.valid?/1 on the agent-supplied stage_id from stage_start / stage_complete, folding a malformed id into {:error, :not_found}"},
    {"platform/tasks/plan_engine.ex", :get, "Task", 2, :safe_internal,
     "`plan.task_id` off a loaded `%Plan{}` in both cases"},
    {"platform/tasks/plan_engine.ex", :get!, "Plan", 9, :safe_internal,
     "every call reloads a `plan.id` / `stage.plan_id` the engine holds as a loaded struct; the bang form is deliberate because a missing row here is a broken invariant"},
    {"platform/tasks/plan_engine.ex", :get!, "Stage", 2, :safe_internal,
     "`validation.stage_id` / `updated.stage_id` off a loaded `%Validation{}`"},
    {"platform/tasks/plan_engine.ex", :get!, "Task", 1, :safe_internal,
     "`maybe_inject_deploy_or_complete/1` reads `plan.task_id` off the `%Plan{}` already loaded in the same function, so the id round-trips a value Ecto cast on the way out of the DB"},
    {"platform/tasks/plan_engine.ex", :get!, "Validation", 2, :safe_internal,
     "reopen_manual_approval/1 and evaluate_validation/3 both assert Platform.UUID.valid?/1 and raise Ecto.NoResultsError — the bang form's DOCUMENTED miss exception — so one lookup no longer raises two different ways depending on the typo"},
    {"platform/tasks/review_requests.ex", :get, "Agent", 1, :safe_internal,
     "requester_display_name/1's Agent arm now sits behind fetch_agent_for_display/1's Platform.UUID.valid?/1 branch, so only a canonical 36-character id reaches Repo.get; the slug traffic that dominates submitted_by takes the get_by(slug:) branch instead. Stage 5 of task 019fa129 also deleted the bare `rescue _` that had been masking the raise"},
    {"platform/tasks/review_requests.ex", :get_by, "Agent", 1, :safe_internal,
     "fetch_agent_for_display/1's non-UUID branch, keyed `slug:` — a plain string column, so it cannot raise whatever submitted_by holds; \"system:auto\" simply misses and falls through to the raw-id arm"},
    {"platform/tasks/review_requests.ex", :get, "ReviewItem", 1, :safe_internal,
     "fetch_item/1 checks Platform.UUID.valid?/1 on the phx-value- item_id from the review-approval event"},
    {"platform/tasks/review_requests.ex", :get, "ReviewRequest", 1, :safe_internal,
     "get_review_request/1 checks Platform.UUID.valid?/1 on the phx-value- id from the review UI, returning nil"},
    {"platform/tasks/review_requests.ex", :get, "Validation", 1, :safe_internal,
     "maybe_reopen_manual_approval/1 checks Platform.UUID.valid?/1 on validation_id before Repo.get, keeping its :ok fallthrough"},
    {"platform/tasks/stacks.ex", :get, "Stack", 17, :safe_internal,
     "Stacks.get_stack/1 checks Platform.UUID.valid?/1, so the seven tool_surface.ex sites that pass a raw stack_id tool argument return nil; the remaining calls reload ids off loaded structs"},
    {"platform/tasks/stacks.ex", :get, "Task", 5, :safe_internal,
     "all five read a member `task_id` off a `stack.members` / `%Task{}` row already loaded in the same function"},
    {"platform/tasks/stacks.ex", :get!, "Stack", 2, :safe_internal,
     "get_stack!/1 checks Platform.UUID.valid?/1 and raises Ecto.NoResultsError — its documented miss exception — rather than Ecto.Query.CastError"},
    {"platform/tasks/stacks/commencement_gate.ex", :get, "Stack", 1, :safe_internal,
     "`open?/1` is only called with a `stack_id` `Stacks` already resolved to a `%Stack{}`"},
    # ── Tenancy ────────────────────────────────────────────────────────
    {"platform/tenancy.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "uuid?/1 in member_of?/2 is now Platform.UUID.valid?/1, so a 16-character org slug takes the slug branch instead of being pinned as ^org_id against Org's strict UUIDv7 key; plus the get_org/1 and get_org!/1 guards"},
    {"platform/tenancy.ex", :get, "Org", 3, :safe_internal,
     "Tenancy.get_org/1 checks Platform.UUID.valid?/1, so the caller-supplied org ids from lifecycle_actions.ex, recovery_live.ex and chat_live.ex return nil; the other two walk parent_org_id off loaded structs"},
    {"platform/tenancy.ex", :get!, "Org", 1, :safe_internal,
     "get_org!/1 checks Platform.UUID.valid?/1 and raises Ecto.NoResultsError — its documented miss exception — rather than Ecto.Query.CastError"},
    {"platform/tenancy.ex", :get_by, "Org", 1, :safe_internal,
     "`get_org_by_slug/1` keys on `slug:`, an `orgs.slug` string column; it is deliberately the slug-first half of `member_of?/2`'s slug-or-uuid resolution"},
    {"platform/tenancy.ex", :get_by, "OrgMembership", 4, :safe_internal,
     "keyed `user_id:` + `org_id:`; all four callers (`mark_membership_external/2`, `upsert_membership/3`, `apply_derived_role/3`, `set_managed_role/3`) receive both ids off loaded `%User{}` / `%Org{}` structs"},
    {"platform/tenancy.ex", :get_by!, "ExternalDmAllowlistEntry", 1, :safe_internal,
     "keyed `user_id:` + `allowed_org_id:`, both taken off structs `allow_dm/2` resolved before inserting"},
    {"platform/tenancy.ex", :get_by!, "Org", 1, :safe_internal,
     "`get_org_by_slug!/1` keys on the same `orgs.slug` string column; the bang form can only raise `Ecto.NoResultsError`, never a cast error"},
    {"platform/tenancy/lifecycle.ex", :platform_uuid_guard, "-", 5, :safe_internal,
     "cascade_preview/1, cascade_hidden/1, purge_preview/1, project_writable?/1 and ensure_task_project_writable/1 all use Platform.UUID.cast/1. Each discards the cast output and pins the ORIGINAL value downstream, so the strict length check is what actually stops the raise"},
    # ── Types / UUID ───────────────────────────────────────────────────
    {"platform/types/uuid_v7.ex", :ecto_uuid_cast, "-", 1, :safe_internal,
     "reached only after the `<<_::288>>` binary pattern in `cast/1`'s own head, so the value is already length-constrained to 36 bytes"},
    {"platform/uuid.ex", :ecto_uuid_cast, "-", 2, :safe_internal,
     "the canonical predicate itself: :57 carries the `byte_size(value) == @canonical_length` prefix and :76 runs behind `valid?/1`"},
    # ── Vault ──────────────────────────────────────────────────────────
    {"platform/vault.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "check_explicit_grant/4 and normalize_uuid/1 use Platform.UUID.cast/1, so a 16-byte accessor id falls back to the system sentinel instead of being hex-encoded into an invented accessor_id written to the audit column"},
    # ── Web: channels / controllers / plugs ────────────────────────────
    {"platform_web/channels/runtime_channel.ex", :get, "Platform.Agents.Agent", 1, :safe_internal,
     "`runtime.agent_id` off the `%AgentRuntime{}` the channel authenticated at join"},
    {"platform_web/controllers/chat_attachment_upload_controller.ex", :get_by, "Attachment", 1,
     :safe_internal,
     "keyed `storage_key:`, a `chat_attachments.storage_key` string column minted by the presign step; no UUID type participates in the comparison"},
    {"platform_web/controllers/message_controller.ex", :get, "Message", 1, :safe_internal,
     "fetch_message/1 checks Platform.UUID.valid?/1 on the URL path segment, folding a malformed id into the controller's existing 404 envelope"},
    {"platform_web/controllers/message_controller.ex", :get, "Participant", 1, :safe_internal,
     "`message.frozen_by_participant_id` off the `%Message{}` loaded on the previous line"},
    {"platform_web/plugs/attachment_auth.ex", :get_by, "AgentRuntime", 1, :safe_internal,
     "keyed `auth_token_hash:`, a string column"},
    {"platform_web/plugs/external_user_scope.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "valid_uuid?/1 is now Platform.UUID.valid?/1. resolve_space/2 passes the ORIGINAL slug — a URL PATH SEGMENT — to Chat.get_space/1 when it returns true, so a 16-character channel slug cleared the bare cast and raised on a LIVE REQUEST PATH. That was the PR #613 failure, still present until stage 4"},
    {"platform_web/plugs/runtime_bearer_auth.ex", :get_by, "AgentRuntime", 1, :safe_internal,
     "keyed `auth_token_hash:`, a string column"},
    # ── Web: LiveViews ─────────────────────────────────────────────────
    {"platform_web/live/chat/active_agent_hooks.ex", :get, "Platform.Agents.Agent", 1,
     :safe_internal,
     "`resolve_by_agent_id/1` is fed `participant.participant_id` off the socket's loaded participant list"},
    {"platform_web/live/chat_live.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "valid_uuid?/1 is now Platform.UUID.valid?/1. It gates Chat.get_space/1 on the /chat/:slug URL PATH SEGMENT at :522 and :589, passing the ORIGINAL value, so a 16-character channel slug used to clear the bare cast and raise inside Repo on the mount path"},
    {"platform_web/live/control_center/agent_data.ex", :get_by, "Agent", 2, :safe_internal,
     "both key on `slug:`, an `agents.slug` string column; the control-center selector resolves by slug precisely so an operator-typed value cannot reach a UUID cast"},
    {"platform_web/live/control_center_live.ex", :get, "Agent", 1, :safe_internal,
     "`selected_agent.id` off the `%Agent{}` already in socket assigns"},
    {"platform_web/live/control_center_live.ex", :get!, "Agent", 1, :safe_internal,
     "`agent.id` off the `%Agent{}` already in socket assigns"},
    {"platform_web/live/org_memory_live/view.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "normalize_page_key/1 uses Platform.UUID.cast/1 and its CAST OUTPUT becomes a page key, so a 16-character LiveView param is now rejected rather than accepted as a namespace uuid. Fabricated-value family: nothing ever raised here"},
    {"platform_web/live/tasks_live.ex", :platform_uuid_guard, "-", 6, :safe_internal,
     "all six task_id/plan_id guards use Platform.UUID.cast/1 and pass the CAST OUTPUT to Repo.get(Plan, uuid), so these never raised — a 16-character param was hex-encoded into an invented plan id that silently missed. The strict predicate makes it take the :error branch"},
    {"platform_web/live/tasks_live.ex", :get, "Plan", 3, :safe_internal,
     "each receives the `{:ok, uuid}` output of the cast above, which is always a well-formed 36-character UUID by construction; the guard itself is now Platform.UUID.cast/1, recorded on the `:platform_uuid_guard` key for this file"},

    # ── Platform.UUID guards recorded by stage 4 (the ratchet) ─────────
    # Tracking the FIX, not just the defect: re-simplifying any guard below
    # back to a bare `Ecto.UUID.cast/1` both adds an unclassified
    # `:ecto_uuid_cast` key AND drops a count here — two independent test
    # failures, each naming the file, derived from source rather than from
    # anyone remembering to write a behavioural test.

    {"platform/accounts.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "Accounts.get_user/1's guard, added by stage 2 of task 019fa129. Tracked as its own key so re-simplifying it back to a bare cast trips BOTH the unclassified-site test and the count-drift test"},
    {"platform/changelog.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "Changelog.get_entry/1's guard on an entry id with no in-repo caller pinning its provenance"},
    {"platform/chat.ex", :platform_uuid_guard, "-", 12, :safe_internal,
     "guards on get_space/2 (the PR #613 site), get_message/2, get_thread/1, get_canvas/2, get_canvas_with_deleted/2, get_attachment/2, get_agent_participant/2 (both columns), add_agent_participant/3, do_unpin_message/2, resolve_agent/1 and space_for_path_segment/1 (the url-segment resolver, which must NOT treat a 16-character channel slug as a raw binary uuid)"},
    {"platform/chat/attachments/tool_handlers.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "finalize_pending/2's guard on the attachment_id supplied by the MCP attachment tool payload"},
    {"platform/chat/canvas_access.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "fetch_for_viewer/3's guard on the canvas id taken straight off the /canvases/:id URL path segment — the share-link route's only untrusted input"},
    {"platform/chat/freeze_policy.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "resolve_actor/2's guard on a task assignee_id that is routinely \"system\" or an agent slug"},
    {"platform/chat/sidebar.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "update_section/2's guard on the phx-value- section_id off the sidebar rename/recolor events"},
    {"platform/external_agents.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "get_external_agent/1 and get_external_agent!/1 — the id:-keyed get_by pair that `git grep \"Repo.get(\"` cannot see"},
    {"platform/files.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "get_file/2, get_file!/2 and fetch_extracted_text/1. The last matters most: Files.Text keys on a bare :binary_id, a different symptom from the UUIDv7 schemas"},
    {"platform/memory/proposals.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "Proposals.get/1's guard on the phx-value-id LiveView param from org_memory_live/view.ex:358,393"},
    {"platform/orchestration/prompt_templates.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "get_template/1's conservative guard — no in-repo caller pins this id's provenance"},
    {"platform/org/context.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "get_file_by_id/1's guard on a page id supplied by a caller of the memory MCP tools"},
    {"platform/skills.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "get_skill/1 and resolve_skills/1. get_skill/1's nil is what routes a slug to the get_by(Skill, slug:) branch, which is designed traffic for skill_get"},
    {"platform/tasks/canvas_attachments.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "ensure_task_exists/1 and ensure_canvas_attachable/1, both on canvas_attach MCP payload ids, plus list_canvas_tasks/1 (task 019e2c4b stage 1). The third is the same class: its canvas_id reaches the reverse lookup from the /canvases/:id URL segment via Platform.Chat.CanvasAccess, and `where: a.canvas_id == ^id` raises the SAME CastError a bare Repo.get would, so the guard folds a malformed id into an empty list"},
    {"platform/tasks/context_hydrator.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "load_task/1's guard on the task_id carried by the run-dispatch payload into hydrate_for_run/2"},
    {"platform/tasks/plan_engine.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "fetch_stage/1's guard plus the two get!(Validation) assertions that raise Ecto.NoResultsError instead of Ecto.Query.CastError"},
    {"platform/tasks/review_requests.ex", :platform_uuid_guard, "-", 4, :safe_internal,
     "get_review_request/1, fetch_item/1, maybe_reopen_manual_approval/1 (stage 4) plus fetch_agent_for_display/1 (stage 5). The fourth guard is what let stage 5 DELETE the bare `rescue _` that used to end requester_display_name/1: with both arms total the function cannot raise, so the rescue had nothing left to absorb"},
    {"platform/tasks/stacks.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "get_stack/1 and get_stack!/1, behind seven raw stack_id tool arguments"},
    {"platform_web/controllers/message_controller.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "fetch_message/1's guard on the message id taken straight off the URL path segment"},
    {"platform/federation/tool_surface.ex", :get, "~schema", 1, :safe_internal,
     "the single Repo.get inside get_by_uuid/2, the module's boundary-safe lookup helper: every id reaching it has already passed Platform.UUID.valid?/1. The load_agent/1, plan_approve, stage_complete, agent_home_org/1 and list_org_descendants/1 sites were all rewritten onto it"},
    {"platform/chat.ex", :get_by, "Agent", 1, :safe_internal,
     "keyed `slug:`, an `agents.slug` string column — the slug-fallback branch of resolve_agent/1, reached only when Platform.UUID.valid?/1 rejects the value"},
    {"platform/meetings.ex", :get_by, "Agent", 1, :safe_internal,
     "keyed `slug:`, an `agents.slug` string column — the slug-fallback branch of Meetings.resolve_agent/1"}
  ]

  # `Repo.one/1` per file. Counted, not classified: its ids live inside
  # `where:` clauses built by other functions, so attributing one
  # statically needs dataflow the scanner does not do. A count change
  # here is a prompt to triage the new call by hand.
  @repo_one_counts %{
    # 10 → 11 for task 019fa1cc stage 3's `pending_bytes_in_range/4`.
    # Triaged by hand: the new call is `Repo.one` over a subquery of
    # `per_day_bytes_query/4`, whose `where:` clause pins only two
    # `DateTime`s against a corpus timestamp column plus (for pages /
    # journal) a `workspace_id` already cast by `type(^workspace_id,
    # :binary_id)` — the same expression the ten pre-existing calls in this
    # file use, and the only caller passes the workspace_id straight through
    # from `HistorianDispatcher.slice_windows/2`. No `x.id == ^value` on the
    # path, so no `Ecto.Query.CastError` is reachable from a boundary and no
    # `Platform.UUID.valid?/1` guard applies.
    "platform/agents/historian.ex" => 11,
    # Task 019fa1cc stage 1 — `HistorianAudit.dispatched_message/3` and
    # `count_between/4`. Triaged by hand: neither `where:` clause pins an id.
    # `dispatched_message/3` compares JSONB text extractions against ISO-8601
    # strings rendered from an already-parsed `DateTime` plus a corpus name;
    # `count_between/4` compares a timestamp column against two `DateTime`s.
    # No `x.id == ^value` on either path, so no `Ecto.Query.CastError` is
    # reachable from a boundary and no `Platform.UUID.valid?/1` guard applies.
    "platform/agents/historian_audit.ex" => 2,
    "platform/analytics.ex" => 1,
    # Task 019fa61c: `task_id_for/1`'s `where: p.id == ^plan_id`, whose plan_id
    # is `stage.plan_id` off a loaded `%Stage{}` — a UUID column read from a
    # persisted row, never a boundary input. Triaged by hand as this map asks:
    # the select is nil-tolerant on purpose, because `after_stage_completed/1`
    # documents that a stage's plan row CAN be gone and a raise there would
    # record nothing at all.
    "platform/architecture/stage_audit.ex" => 1,
    "platform/chat.ex" => 14,
    "platform/chat/attachments/tool_handlers.ex" => 1,
    "platform/chat/canvas/versions.ex" => 1,
    # Task 019e2c4b stage 1 — `CanvasAccess.org_readable_space?/2`. Triaged by
    # hand: the `where:` clause pins `s.id == ^space_id`, but `space_id` is
    # destructured off the `%Canvas{}` row `fetch_for_viewer/3` has already
    # loaded, so it is a `chat_canvases.space_id` column value and cannot be
    # malformed. The boundary-supplied id on that path is the CANVAS id, which
    # is guarded by `Platform.UUID.valid?/1` one call earlier.
    "platform/chat/canvas_access.ex" => 1,
    "platform/chat/message_versions.ex" => 2,
    "platform/deploy/project_files.ex" => 3,
    "platform/federation.ex" => 1,
    "platform/federation/tool_surface.ex" => 2,
    "platform/files.ex" => 1,
    "platform/inbox.ex" => 1,
    "platform/meetings.ex" => 9,
    "platform/meetings/intent_corrections.ex" => 1,
    "platform/memory_feedback.ex" => 1,
    "platform/orchestration/context_assembler.ex" => 1,
    "platform/orchestration/execution_space.ex" => 3,
    "platform/orchestration/runtime_supervision.ex" => 4,
    "platform/org/context.ex" => 4,
    "platform/org/preamble_builder.ex" => 3,
    "platform/org/tenants_summary.ex" => 2,
    "platform/org/wiki.ex" => 5,
    # ADR-0046 merge: `latest_live_plan/1`, whose `where: p.task_id == ^task_id`
    # pins a UUID column and so raises Ecto.Query.CastError on a malformed id
    # exactly as Repo.get/2 would — the case this map exists to make someone
    # triage by hand. Triaged: the call sits inside this module's `safe/1`
    # rescue, like every lookup in the file, so a bad id degrades an OPTIONAL
    # context slot to nil rather than raising out of the provider.
    "platform/responsibilities/context_providers.ex" => 1,
    "platform/responsibilities/handlers/architecture_cron_sweep.ex" => 1,
    "platform/roles.ex" => 2,
    "platform/tasks.ex" => 6,
    "platform/tasks/chat_pins.ex" => 1,
    # 0 → 1 for task 019fba18 stage 4's `why_not_live/1`, which names WHY a
    # validation id is not a live reconciler candidate so
    # `mix suite.deploy.scope_gate` can refuse with a reason instead of a
    # stack trace. Triaged by hand as this map asks: its `where:` clause DOES
    # pin an id (`v.id == ^id`) and that id DOES arrive from a boundary — a
    # command-line argument, which is the sharpest case, since an operator
    # pasting a task id or a truncated uuid is the expected failure. So the
    # guard is required and is present: `live_gate/1` is the only caller and
    # it returns `{:error, :malformed_id}` unless `Platform.UUID.valid?/1`
    # passes first, pinned by a test that drives the mix task with a
    # non-uuid and asserts the named refusal rather than a cast error.
    # `Platform.Types.UUIDv7.cast/1` was not used; probed on this checkout it
    # is equally safe (it rejects the 16-byte binary `Ecto.UUID.cast/1`
    # accepts), so the reason is one derivation rather than two, which is
    # what this map asks the guard to be.
    "platform/tasks/deploy_merge_reconciler.ex" => 1,
    "platform/tasks/context_hydrator.ex" => 1,
    "platform/tasks/plan_engine.ex" => 2,
    "platform/tasks/review_requests.ex" => 1,
    "platform/tasks/rollup_webhook_processor.ex" => 1,
    "platform/tasks/stacks.ex" => 4,
    "platform/tenancy/external_grants.ex" => 1,
    "platform/tenancy/lifecycle.ex" => 2,
    "platform/vault.ex" => 4,
    "platform/webhooks/github_signature.ex" => 1,
    # Task 019fa63a: was 2 before stage 3, 1 after it, 0 now. Both of this
    # file's `Repo.one`s were the same defect in two spellings — `limit: 1`
    # deciding WHICH REPOSITORY an event belongs to by row order:
    #
    #   * stage 3 turned `find_pending_pr_merged_validation/1` into
    #     `find_pending_pr_merged_validations/1` (`Repo.all`), because the
    #     first pending merge gate wins regardless of which repo merged.
    #   * stage 4 turned `find_pending_ci_validation/1` into
    #     `find_pending_ci_validations/1` (`Repo.all`) for the identical
    #     reason on the CI side: the first pending `ci_passed` won regardless
    #     of which repo ran the checks, so a green in repo B was recorded as
    #     repo A's green — and then authorized repo A's merge.
    #
    # Hand-triage of the removed call, per this map's own instruction: both
    # queries pinned `t.id == ^task_id` and both are reached only after
    # `Changelog.extract_task_id_from_branch/1` has resolved a UUID-shaped
    # branch to a task that EXISTS, so no id from the wire ever reached the
    # `where:` uncast and no guard was owed. Removing them removes the risk
    # rather than relocating it — the `Repo.all` replacements carry exactly
    # the same `where:` clauses with the `limit: 1` dropped.
    #
    # The entry is kept at 0 rather than deleted so a future `Repo.one` added
    # to this file lands as a DRIFT (recorded 0, source has 1) and is triaged,
    # instead of as an unclassified site with no history attached.
    "platform_web/controllers/github_webhook_controller.ex" => 0,
    "platform_web/controllers/message_controller.ex" => 1,
    "platform_web/live/shell_live.ex" => 2
  }

  @classifications [:safe_internal, :must_cast, :flagged_sibling_owned]

  defp inventory_counts do
    Map.new(@inventory, fn {path, kind, schema, count, _class, _reason} ->
      {{path, kind, schema}, count}
    end)
  end

  describe "the Repo lookup boundary inventory" do
    test "every Repo.get-family call site in lib is classified" do
      scanned = RepoLookupScan.call_sites()
      recorded = inventory_counts()

      unclassified =
        scanned
        |> Map.drop(Map.keys(recorded))
        |> Enum.sort()

      assert unclassified == [], """
      #{length(unclassified)} unclassified Repo lookup site(s) found in apps/platform/lib.

      #{Enum.map_join(unclassified, "\n", fn {{path, kind, schema}, count} -> "  * #{path} — #{kind}(#{schema}) × #{count}" end)}

      Add each to @inventory in test/platform/repo_lookup_boundary_test.exs and
      classify it:

        :safe_internal        the id provably cannot be malformed. REQUIRES a
                              concrete reason naming the mechanism (which struct
                              field, which query selected it, which guard cast
                              it, or which primary-key type). "internal" is not
                              a reason.
        :must_cast            the id can arrive from an agent, an MCP tool
                              payload, a webhook body, a LiveView params map, a
                              channel message or a URL path segment. Guard with
                              Platform.UUID.valid?/1 and keep the site's
                              existing not-found return value.
        :flagged_sibling_owned  :must_cast, but the file belongs to an in-flight
                              sibling task. Record it; do not edit it.

      Why this test exists: Repo.get/2 RAISES Ecto.Query.CastError on a
      malformed id rather than returning nil. That defect has been fixed at one
      site three separate times (PR #613, task 019fa11d-1f6a, task 019fa129
      stages 1-2). Classifying the site is how the fourth time gets caught here
      instead of in production.
      """
    end

    test "no inventory entry names a site that no longer exists" do
      scanned = RepoLookupScan.call_sites()

      stale =
        recorded_keys()
        |> Enum.reject(&Map.has_key?(scanned, &1))
        |> Enum.sort()

      assert stale == [], """
      #{length(stale)} inventory entr(ies) point at a lookup that is no longer in lib:

      #{Enum.map_join(stale, "\n", fn {path, kind, schema} -> "  * #{path} — #{kind}(#{schema})" end)}

      If you removed or guarded the lookup, delete the entry. If you renamed the
      module or moved the file, update the entry's path — do NOT delete it
      wholesale, or the classification work is lost.
      """
    end

    test "recorded call counts match the source tree" do
      scanned = RepoLookupScan.call_sites()

      drifted =
        for {key, recorded} <- inventory_counts(),
            actual = Map.get(scanned, key),
            not is_nil(actual),
            actual != recorded,
            do: {key, recorded, actual}

      assert drifted == [], """
      #{length(drifted)} inventory entr(ies) have a stale call count:

      #{Enum.map_join(drifted, "\n", fn {{path, kind, schema}, was, now} -> "  * #{path} — #{kind}(#{schema}): inventory says #{was}, source has #{now}" end)}

      A count that GREW means a new lookup landed in a file that is already
      inventoried — re-read the classification and confirm it still holds for
      the new call before bumping the number. A key is classified by its MOST
      exposed call.
      """
    end
  end

  describe "inventory hygiene" do
    test "every classification is one of the three defined values" do
      bad =
        Enum.reject(@inventory, fn {_p, _k, _s, _c, class, _r} -> class in @classifications end)

      assert bad == [], "unknown classification(s): #{inspect(bad)}"
    end

    test "no :safe_internal reason is a placeholder" do
      # The :safe_internal entries are the whole point of the survey: they are
      # what stops the next reader redoing it. A reason that just says
      # "internal" documents nothing.
      placeholders = ~w(internal safe n/a na todo tbd - ?)

      bad =
        for {path, kind, schema, _c, :safe_internal, reason} <- @inventory,
            normalized = reason |> String.downcase() |> String.trim(),
            normalized in placeholders or String.length(reason) < 40,
            do: {path, kind, schema, reason}

      assert bad == [], """
      #{length(bad)} :safe_internal entr(ies) carry a placeholder reason:

      #{Enum.map_join(bad, "\n", fn {path, kind, schema, reason} -> "  * #{path} — #{kind}(#{schema}): #{inspect(reason)}" end)}

      Name the mechanism: which struct field the id was read from, which query
      selected it, which guard already cast it, or which primary-key type makes
      a cast impossible.
      """
    end

    test "no key is recorded twice" do
      dupes =
        recorded_keys()
        |> Enum.frequencies()
        |> Enum.filter(fn {_key, count} -> count > 1 end)

      assert dupes == [], "duplicate inventory keys: #{inspect(dupes)}"
    end

    test "every sibling-owned file is flagged, and nothing else is" do
      misfiled =
        for {path, kind, schema, _c, class, _r} <- @inventory,
            sibling_owned?(path) != (class == :flagged_sibling_owned),
            do: {path, kind, schema, class}

      assert misfiled == [], """
      Sibling-boundary mismatch:

      #{Enum.map_join(misfiled, "\n", fn {path, kind, schema, class} -> "  * #{path} — #{kind}(#{schema}) is #{inspect(class)}" end)}

      Files owned by in-flight sibling tasks (019f9d80, 019fa003, 019fa06a and
      the unmerged ADR-0046 stack) must be :flagged_sibling_owned and left
      unedited. Files outside that set must NOT borrow the flag to dodge a
      classification.
      """
    end
  end

  describe "Repo.one (counted, not classified)" do
    test "per-file Repo.one counts are unchanged" do
      scanned = RepoLookupScan.query_lookup_counts()

      drift =
        (Map.keys(scanned) ++ Map.keys(@repo_one_counts))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.reject(&(Map.get(scanned, &1, 0) == Map.get(@repo_one_counts, &1, 0)))
        |> Enum.map(&{&1, Map.get(@repo_one_counts, &1, 0), Map.get(scanned, &1, 0)})

      assert drift == [], """
      Repo.one/1 counts drifted in #{length(drift)} file(s):

      #{Enum.map_join(drift, "\n", fn {path, was, now} -> "  * #{path}: recorded #{was}, source has #{now}" end)}

      Repo.one is counted rather than classified because its ids live inside
      `where:` clauses built by other functions. Triage the new call by hand:
      does its where clause pin an id that can arrive from a boundary? If so it
      needs a Platform.UUID.valid?/1 guard, because `where: x.id == ^value`
      raises the SAME Ecto.Query.CastError as Repo.get/2. Then update the count.
      """
    end
  end

  describe "the scan itself" do
    test "reconciles exactly against a plain-text grep of the same tree" do
      # 249 text matches on this tree = 241 real calls + 8 lines of @doc and
      # comment prose that name a lookup they do not perform. If this drifts,
      # either the scanner started missing a spelling or somebody wrote new
      # documentation — check which before touching the numbers.
      lookup_calls =
        RepoLookupScan.call_sites()
        |> Enum.reject(fn {{_p, kind, _s}, _c} ->
          kind in [:ecto_uuid_cast, :platform_uuid_guard]
        end)
        |> Enum.map(fn {_key, count} -> count end)
        |> Enum.sum()

      assert lookup_calls + RepoLookupScan.doc_mention_count() == grep_line_count()
    end

    test "sees the fully-qualified Platform.Repo.get( spelling" do
      # The blind spot that made the previous surveys wrong. `git grep
      # "Repo.get("` finds these too, but a scanner keyed on a bare `Repo`
      # alias would not — and neither would one that only matched the
      # unqualified call.
      fully_qualified = [
        {"platform/federation/task_attrs.ex", :get, "Platform.Agents.Agent"},
        {"platform/meetings/intent_classifier.ex", :get, "Platform.Agents.Agent"},
        {"platform/memory/telemetry_handler.ex", :get, "Platform.Org.WikiJournalEntry"},
        {"platform_web/channels/runtime_channel.ex", :get, "Platform.Agents.Agent"}
      ]

      # chat_live.ex used to be the fifth entry here. Stage 4 rewrote both of
      # its `Platform.Repo.get(Platform.Chat.Message, msg_id)` calls onto the
      # guarded `Chat.get_message/1`, so the specimen is gone from the tree.
      # The scanner's ABILITY to see the spelling is proved below against a
      # synthetic snippet instead — a capability test must not depend on a
      # live defect continuing to exist.

      sites = RepoLookupScan.call_sites()

      for key <- fully_qualified do
        assert Map.has_key?(sites, key),
               "scanner lost the fully-qualified Platform.Repo.get( site #{inspect(key)}"

        assert {_p, _k, _s} = key
      end
    end

    test "sees Repo.get_by/2 sites whose exposed id is a keyword value" do
      # `Repo.get_by(Agent, id: id, kind: @external_kind)` is invisible to a
      # `Repo.get(` grep and was the concrete blind spot the plan named. The
      # bang variant ten lines below it was missed even by the plan.
      keys = RepoLookupScan.get_by_id_keys()

      assert [[:id, :kind]] = Map.fetch!(keys, {"platform/external_agents.ex", :get_by, "Agent"})
      assert [[:id, :kind]] = Map.fetch!(keys, {"platform/external_agents.ex", :get_by!, "Agent"})
    end

    test "still detects a bare Ecto.UUID.cast/1 guard, and the fully-qualified spelling" do
      # Capability, proved against a SYNTHETIC snippet rather than a live
      # defect. Stage 3 asserted "the scanner still sees the bare cast in
      # external_user_scope.ex" — true when written, and then falsified by
      # stage 4 *fixing* the bug. A scanner test that fails because someone
      # fixed a bug is testing the wrong thing.
      sites =
        RepoLookupScan.scan_source(
          """
          defmodule Fixture do
            def a(id), do: match?({:ok, _}, Ecto.UUID.cast(id)) && Repo.get(Space, id)
            def b(id), do: Platform.Repo.get(Platform.Chat.Message, id)
            def c(id), do: Platform.UUID.valid?(id)
          end
          """,
          "fixture.ex"
        )

      assert Map.fetch!(sites, {"fixture.ex", :ecto_uuid_cast, "-"}) == 1
      assert Map.fetch!(sites, {"fixture.ex", :get, "Space"}) == 1
      assert Map.fetch!(sites, {"fixture.ex", :get, "Platform.Chat.Message"}) == 1
      assert Map.fetch!(sites, {"fixture.ex", :platform_uuid_guard, "-"}) == 1
    end

    test "no bare Ecto.UUID.cast/1 survives outside the three places it is correct" do
      # The ratchet, and the reason the :platform_uuid_guard kind exists.
      #
      # Before stage 4 there were bare casts on live request paths, each
      # gating a lookup on a URL path segment with a predicate that does not
      # work: Ecto.UUID.cast/1 hex-encodes a raw 16-byte binary and returns
      # {:ok, _}, so a 16-character slug clears the guard and Repo raises
      # anyway. A survey scoped to Repo.get call sites never sees them, which
      # is exactly how they survived two previous passes.
      #
      # Only three bare casts may remain, and each is correct for a stated
      # structural reason. Re-simplify any Platform.UUID guard back to a bare
      # cast and this test names the file.
      bare =
        RepoLookupScan.call_sites()
        |> Enum.filter(fn {{_p, kind, _s}, _c} -> kind == :ecto_uuid_cast end)
        |> Enum.map(fn {{path, _k, _s}, _c} -> path end)
        |> Enum.sort()

      assert bare == [
               # carries the `String.length(value) == 36` prefix itself
               "platform/agents/agent_server.ex",
               # The ADR-0046 merge added three bare casts here — `brand.ex`
               # `fetch_project/1`, `tool_surface.ex` `verdict_plan/1` and
               # `tasks.ex` `human_approver/1` — and all three were collapsed
               # onto `Platform.UUID.cast/1` at the merge rather than
               # allow-listed, so this list is unchanged. `human_approver/1`
               # is the collapse this module's moduledoc explicitly left to
               # whoever merged the stack; the other two got the same
               # treatment because they are the same shape. All three were
               # behaviour-identical swaps: each already passed the cast's
               # OUTPUT to Repo, so the 16-byte gap produced a miss, not a
               # raise. The ratchet stays at four files.
               # sibling-owned (ADR-0046 stack) — recorded, not edited
               "platform/tasks/task.ex",
               # reached only behind a `<<_::288>>` binary pattern
               "platform/types/uuid_v7.ex",
               # the canonical predicate's own implementation
               "platform/uuid.ex"
             ],
             """
             A bare `Ecto.UUID.cast/1` appeared outside the places it is correct.

             Found: #{inspect(bare)}

             Use `Platform.UUID.valid?/1` (boolean) or `Platform.UUID.cast/1`
             (error tuple). The length check is load-bearing — a bare cast
             accepts ANY 16-byte binary, so a 16-character slug clears it and
             `Repo` raises anyway. See Platform.UUID's moduledoc.
             """
    end

    test "16-byte binaries are why the length check is load-bearing" do
      # Do not prune this as a duplicate of the Platform.UUID tests. It is the
      # justification for the :ecto_uuid_cast call kind existing at all: a
      # suite built from "higgins" plus a valid UUID is FULLY GREEN against the
      # bug, because Ecto.UUID.cast/1 rejects "higgins" on its own. Only a
      # 16-byte input discriminates.
      slug = "higginshigginsxx"
      assert byte_size(slug) == 16
      assert {:ok, _hex} = Ecto.UUID.cast(slug)
      assert :error = Ecto.UUID.dump(slug)
      refute Platform.UUID.valid?(slug)

      assert :error = Platform.Types.UUIDv7.cast(slug)
      assert {:ok, _} = Ecto.UUID.cast(:crypto.strong_rand_bytes(16))
      refute Platform.UUID.valid?(:crypto.strong_rand_bytes(16))
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────

  defp recorded_keys do
    Enum.map(@inventory, fn {path, kind, schema, _c, _class, _r} -> {path, kind, schema} end)
  end

  defp sibling_owned?(path) do
    Enum.any?(@sibling_owned_prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix)
    end)
  end

  defp grep_line_count do
    pattern = ~r/(^|[^.\w])(Platform\.)?Repo\.(get|get!|get_by|get_by!)\(/

    RepoLookupScan.source_files()
    |> Enum.map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.count(&Regex.match?(pattern, &1))
    end)
    |> Enum.sum()
  end
end
