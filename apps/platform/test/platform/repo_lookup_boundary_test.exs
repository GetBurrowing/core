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
     exposed** call. `platform/tasks/stacks.ex :get "Stack"` covers 18
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
    {"mix/tasks/platform/voice_runtime.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`get_agent_by_id/1`'s predicate on `--agent` is `Platform.UUID.cast/1`, so a slug that is not a canonical 36-character uuid takes the `:error` branch and returns nil instead of clearing a bare cast and raising against Agent's strict UUIDv7 PK"},
    {"mix/tasks/platform/voice_runtime.ex", :get, "Agent", 1, :safe_internal,
     "reached only through `get_agent_by_id/1`'s `Platform.UUID.cast/1` branch, so the value is a canonical uuid by construction; the slug form goes to `Platform.Agents.SlugLookup.resolve/2` first, which refuses a slug shared across workspaces with an explicit `Mix.raise` (task 01a0e77c)"},
    {"mix/tasks/platform/voice_runtime.ex", :get_by, "User", 1, :safe_internal,
     "keyed `email:`, a plain string column — no UUID type on either side; the value is `--owner` out of the task's own OptionParser opts and a miss is an explicit `Mix.raise` in the operator's terminal"},
    {"mix/tasks/platform/seed_meeting_voice_agent.ex", :get_by, "User", 1, :safe_internal,
     "keyed `email:`, a plain string column — no UUID type on either side; the value is `--owner` out of the task's own OptionParser opts and a miss is an explicit `Mix.raise` in the operator's terminal"},
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
    {"platform/agents/config.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "fetch_agent/1's predicate is now Platform.UUID.valid?/1, so a 16-character agent slug takes the slug branch instead of clearing a bare cast and raising against Agent's strict UUIDv7 PK. Reverting it to Ecto.UUID.cast/1 reintroduces an unclassified :ecto_uuid_cast key here AND drops this count — two failures naming this file"},
    {"platform/agents/config.ex", :get, "Agent", 1, :safe_internal,
     "reached only via fetch_agent/1's Platform.UUID.valid?/1 branch, so the value is a canonical 36-character uuid by construction; a slug goes to Platform.Agents.SlugLookup.resolve/2 (Repo.all, limit 2), which fails closed on a slug shared across workspaces (task 01a0e77c)"},
    {"platform/agents/historian_dispatcher.ex", :get, "Agent", 1, :safe_internal,
     "agent_id comes from `Roles.agent_id_for_role(\"historian\")`, i.e. a `role_assignments.agent_id` column selected out of the DB"},
    {"platform/agents/historian_dispatcher.ex", :get_by, "Chat.Participant", 1, :safe_internal,
     "`participant_id` is derived deterministically from space_id by `ensure_system_participant/1`; `participant_type` is a literal"},
    {"platform/agents/memory_context.ex", :get_by, "WorkspaceFile", 2, :safe_internal,
     "`agent_id` is `agent.id` off a loaded `%Agent{}` at all four callers (Agents.Config, Agents.Orchestration, WorkspaceBootstrap, ControlCenter.WorkspaceEvents); `file_key` is a string column"},
    {"platform/agents/orchestration.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "fetch_agent/1's predicate is now Platform.UUID.valid?/1. This is the function stage 4's brief named as the shape to MIRROR: the branch structure was always right, only the predicate was broken"},
    {"platform/agents/orchestration.ex", :get, "Agent", 1, :safe_internal,
     "reached only via fetch_agent/1's Platform.UUID.valid?/1 branch; slugs go to Platform.Agents.SlugLookup.resolve/2 instead, which returns {:error, :ambiguous_slug} rather than raising Ecto.MultipleResultsError when two workspaces share one (task 01a0e77c)"},
    {"platform/agents/workspace_bootstrap.ex", :get!, "Agent", 1, :safe_internal,
     "`agent.id` read off the `%Agent{}` `upsert_agent!/1` just returned in the same function"},
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
     "both remaining calls go through resolve_agent/1, which checks Platform.UUID.valid?/1 and falls back to Platform.Agents.SlugLookup.resolve/2 — so an MCP-supplied agent slug resolves instead of raising, and a slug shared across workspaces resolves to nil (task 01a0e77c). The four dm/group/roster call sites were rewritten onto that helper"},
    {"platform/chat.ex", :get, "Attachment", 1, :safe_internal,
     "Chat.get_attachment/2 checks Platform.UUID.valid?/1 before Repo.get, so an MCP-supplied attachment id that is not a uuid returns nil"},
    {"platform/chat.ex", :get, "Canvas", 2, :safe_internal,
     "get_canvas/2 and get_canvas_with_deleted/2 both check Platform.UUID.valid?/1 first, so the canvas_get / canvas_describe tool arguments cannot raise"},
    {"platform/chat.ex", :get, "Message", 3, :safe_internal,
     "Chat.get_message/2 checks Platform.UUID.valid?/1 first; the other two read r.message_id / message_id off rows already loaded in the same function"},
    {"platform/chat.ex", :get, "Participant", 4, :safe_internal,
     "every call takes a participant id read off a loaded struct — `message.participant_id`, `r.message_id`'s reaction row, `p.participant_id`; `get_participant/1`'s only in-repo callers (agent_responder.ex, active_agent_hooks.ex) pass `message.participant_id`"},
    {"platform/chat.ex", :get, "Platform.Accounts.User", 2, :safe_internal,
     "`sponsor_email_for/2` reads a loaded task's sponsor_user_id; mention inbox filtering reads participant_id off a persisted `%Participant{}` with a :binary_id field"},
    {"platform/chat.ex", :get, "Platform.Tasks.Task", 3, :safe_internal,
     "task_id is read from the execution space's own `metadata[\"task_id\"]`, written by `Orchestration.ExecutionSpace` from a persisted task PK. Residual risk is a hand-corrupted metadata blob, not a request-path input. Was 2 until task 01a0ac64 stage 1 added `sponsor_of_space_task?/2`, the mention-summon authorization check — a third call reading the SAME metadata key by the same route, so the classification is unchanged"},
    {"platform/chat.ex", :get, "Space", 6, :safe_internal,
     "guarded at the source: Chat.get_space/2 checks Platform.UUID.valid?/1 before Repo.get, so the PR #613 site now returns nil for a channel slug. ensure_dm_send_allowed/2 was switched from Repo.get/2 to that guarded getter; space_for_path_segment/1 (task 019fabe8) takes the same Platform.UUID.valid?/1 branch before Repo.get and falls back to get_space_by_slug/2 otherwise; the remaining calls read space_id off a loaded %Message{} or off the space's own metadata"},
    {"platform/chat.ex", :get, "Thread", 2, :safe_internal,
     "Chat.get_thread/1 checks Platform.UUID.valid?/1 first; reply_to_thread/3's lookup is reached with a thread_id that getter already resolved"},
    {"platform/chat.ex", :get_by, "Participant", 4, :safe_internal,
     "get_agent_participant/2 checks Platform.UUID.valid?/1 on BOTH space_id and participant_id (both :binary_id columns), and add_agent_participant/3 checks space_id before delegating to do_add_agent_participant/3. Count 2 -> 3 with task 01a0cbe0 stage 1: get_space_participant/2 checks Platform.UUID.valid?/1 on BOTH space_id and the participant's own id before `Repo.get_by(Participant, id:, space_id:)`. Its participant id arrives from a tool-call context (`context.agent_participant_id`) that ToolSurface verifies against the target space, so it is guarded rather than trusted. Count 3 -> 4 with task 01a0fd62 stage 1: seat_creator_admin/2's fallback `Repo.get_by(Participant, space_id:, participant_type: \"user\", participant_id:)` takes `space.id` off the `%Space{}` `create_space/1` just inserted and `created_by` off that same row, which `Space.changeset/2` cast as :binary_id and the `chat_spaces_created_by_fkey` FK ties to an existing user, so neither can be malformed"},
    {"platform/chat.ex", :get_by, "Pin", 1, :safe_internal,
     "do_unpin_message/2 checks Platform.UUID.valid?/1 on the phx-value- message_id before reaching the :binary_id-keyed lookup, returning the existing {:error, :not_found}"},
    {"platform/chat.ex", :get_by, "Platform.Accounts.User", 1, :safe_internal,
     "keyed `email:`, a string column — the `@mention` pin-target resolver"},
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
    {"platform/chat/attention_router.ex", :get, "Participant", 1, :safe_internal,
     "push_recipient_may_read?/2 checks Platform.UUID.valid?/1 before resolving a bare recipient id; malformed routing ids keep the existing no-row push behavior"},
    {"platform/chat/attention_router.ex", :get, "Platform.Accounts.User", 2, :safe_internal,
     "sender_user/1 guards the author's loaded participant_id with Platform.UUID.valid?/1; push_recipient_may_read?/2 reads its other user id from a persisted %Participant{} :binary_id field"},
    {"platform/chat/attention_router.ex", :get, "Space", 1, :safe_internal,
     "space_id comes off the `%Message{}` the router just loaded"},
    {"platform/chat/attention_router.ex", :get, "TaskRecord", 1, :safe_internal,
     "execution_assignee_agent_id/1 checks Platform.UUID.valid?/1 before reading the task id from the execution space's `metadata[\"task_id\"]`"},
    {"platform/chat/attention_router.ex", :platform_uuid_guard, "-", 4, :safe_internal,
     "mention_names/1 guards the agent-name fallback lookup; sender_user/1 guards the push sender's user lookup; execution_assignee_agent_id/1 guards the task id from execution-space metadata; push_recipient_may_read?/2 guards a bare participant id before Repo.get(Participant). Malformed values retain those paths' existing no-match outcomes"},
    {"platform/chat/canvas/server.ex", :get, "Canvas", 1, :safe_internal,
     "`do_persist/1` uses the canvas_id the `CanvasServer` was started with, which `Chat.get_canvas/1` already resolved to a row"},
    {"platform/chat/canvas_search_index.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "unindexed_count/1 filters the space_ids list through Platform.UUID.valid?/1 before `where: c.space_id in ^ids`, which raises the same Ecto.Query.CastError as Repo.get/2 on a non-uuid. The ids arrive from whatever spaces the caller is rendering (task 01a07402 stage 5's partial-index line), so a malformed one folds into a 0 count instead of taking the render down"},
    {"platform/chat/canvas_access.ex", :get, "Canvas", 1, :safe_internal,
     "fetch_for_viewer/3 checks Platform.UUID.valid?/1 on the /canvases/:id URL path segment before the lookup, folding a malformed id into the existing {:error, :not_found}"},
    {"platform/chat/reply_context.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "normalize/3 guards the runtime-supplied in_reply_to_message_id (a raw channel-frame field) with Platform.UUID.valid?/1 and folds a malformed value into a dropped `invalid_uuid` entry, and participant/1 guards the agent participant id before Chat.get_participant/1; neither can raise, and the reply still posts (task 01a0d8de stage 2)"},
    {"platform/chat/dispatch_membership.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "resolve_space/1 and resolve_agent/1 each guard with Platform.UUID.valid?/1 before their lookups. Both ids arrive verbatim off dispatch payloads (meeting transcript rows, TaskRouter context maps, the intent queue) and agent_id is routinely a slug, so a bare Ecto.UUID.cast/1 would hex-encode a 16-character slug, clear the guard, and raise against the strict UUIDv7 PK — on a best-effort path whose contract is always-:ok"},
    {"platform/chat/dispatch_membership.ex", :get, "Agent", 1, :safe_internal,
     "reached only through resolve_agent/1's Platform.UUID.valid?/1 branch, so the value is a canonical 36-character uuid by construction; a slug goes to Platform.Agents.SlugLookup.resolve/2, and a slug shared across workspaces is refused as {:skip, :ambiguous_agent_slug} (task 01a0e77c)"},
    {"platform/chat/dispatch_membership.ex", :get, "Space", 1, :safe_internal,
     "reached only through resolve_space/1's Platform.UUID.valid?/1 branch; a non-UUID space_id returns {:skip, :invalid_space_id} without touching Repo"},
    {"platform/chat/freeze_policy.ex", :get_by, "Participant", 1, :safe_internal,
     "resolve_actor/2 checks Platform.UUID.valid?/1 on assignee_id — routinely \"system\" or an agent slug — before the :binary_id-keyed lookup, keeping nil as the not-found value"},
    {"platform/chat/messages/edit.ex", :get, "Participant", 1, :safe_internal,
     "`message.frozen_by_participant_id` destructured off a loaded `%Message{}`"},
    {"platform/chat/sidebar.ex", :get, "Agent", 2, :safe_internal,
     "task 01a0b491 stage 4's `agents_leader/1`. Site one takes `Roles.agent_id_for_role/1`'s return, which is `select: ra.agent_id` off `role_assignments` — a :binary_id column, and the function is guarded `is_binary(id)` before the get. Site two takes `leader_agent_id` destructured off a `%Chat.Space{}` the function head pattern-matches, which is a :binary_id column on `chat_spaces` with an FK to `agents`. Neither id ever comes from params, an MCP payload or a URL segment: there is no caller that passes an agent id INTO this function"},
    {"platform/chat/sidebar.ex", :get, "Section", 1, :safe_internal,
     "update_section/2 checks Platform.UUID.valid?/1 on the phx-value- section_id, folding a malformed id into the existing {:error, :not_found}"},
    {"platform/chat/sidebar.ex", :get_by, "Section", 1, :safe_internal,
     "ensure_default_section/1 re-reads by `org.id` destructured off a `%Tenancy.Org{}` the function head pattern-matches — the struct is either freshly inserted by `Lifecycle.create_org/2` inside the same Ecto.Multi or loaded from `orgs`, so the id is always a well-formed :binary_id and never a boundary string"},
    {"platform/chat/space_access.ex", :get_by, "Participant", 1, :safe_internal,
     "authorize_writer/2's single participant lookup guards BOTH ids with Platform.UUID.valid?/1 before the get_by. Both are :binary_id columns and both arrive from a boundary: the space_id is a client-supplied phx-value- param off pin_toggle / dismiss_agent (it is the forged input this module exists to refuse), and the participant_id is a socket assign that is nil on anonymous shells. Guarding folds either malformed value into the module's existing {:error, :forbidden} instead of raising Ecto.Query.CastError out of an authorization check — which is precisely why Chat.participant?/2, an unguarded Repo.exists?, was not reused"},
    # ── Design (sibling-owned, ADR-0046) ───────────────────────────────
    {"platform/design/brand.ex", :platform_uuid_guard, "-", 1, :flagged_sibling_owned,
     "`fetch_project/1`'s predicate, collapsed from a bare Ecto.UUID.cast/1 onto Platform.UUID.cast/1 at the ADR-0046 merge. The site was already total — it passes the cast's OUTPUT to `Tasks.get_project/1` and additionally rescues — so this is the canonical-predicate fix, not a raise fix. Sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/design/preplan_step.ex", :get, "Task", 2, :flagged_sibling_owned,
     "`resolve_task/1`: :705 takes `%Task{}.id` off a loaded struct; :706 takes a raw binary. Every public entry point that can reach :706 with a caller-supplied string — `settle/2`, `expire/2`, `audit_ui_prediction/2`, `annotate/3` — wraps its body in `rescue`/`catch`, and the only lib caller passing a binary (`tool_surface.ex:5954`, `plan_create`) reaches it only AFTER `Tasks.create_plan/1` accepted the same id in the enclosing transaction. `start/1` does not rescue, but TaskRouter calls it with a `%Task{}` struct. Sibling-owned — RECORD, DO NOT EDIT"},
    # ── Experiments (ADR-0048, task 019fe6b9) ──────────────────────────
    {"platform/experiments.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "get_experiment/1's predicate: the id reaches this context from an agent or an MCP payload, so the guard is what keeps a malformed id returning nil instead of raising Ecto.Query.CastError against Experiment's strict UUIDv7 primary key. Task 01a0d415 stage 6 adds agent_names/1, which filters its id list through the same predicate before `a.id in ^ids`, so a malformed `proposed_by_agent_id` is dropped rather than raising in the where clause"},
    {"platform/experiments.ex", :get, "Experiment", 1, :safe_internal,
     "the sole Repo.get sits inside get_experiment/1, behind the Platform.UUID.valid?/1 guard counted above; the two entries fail together if either is removed"},
    {"platform/experiments.ex", :get!, "Experiment", 3, :safe_internal,
     "3 calls, all keyed by `experiment.id` destructured off a loaded `%Experiment{}`. activate/2's Multi re-reads the experiment by `experiment.id` destructured off a loaded `%Experiment{}` whose PK was minted by Platform.Types.UUIDv7 autogenerate. It is re-read rather than reused precisely so a caller's stale preloaded :variants cannot decide the control guard — the id never leaves the struct. Task 01a0d415 stage 2 adds start/2 and approve_launch/2, which re-read the same `experiment.id` under the start lock so the guardrail check judges the current row"},
    {"platform/experiments.ex", :get_by, "Experiment", 1, :safe_internal,
     "keyed `slug:`, a plain string column on experiments with no UUID type on either side of the comparison; get_experiment_by_slug/1 cannot raise a cast error"},
    {"platform/experiments.ex", :get_by, "PromptTemplate", 1, :safe_internal,
     "keyed `slug:`, the same plain string column `Orchestration.PromptTemplates.get_template_by_slug/1` already reads unguarded; activate/2 folds a miss into {:error, changeset} rather than raising"},
    {"platform/experiments/promotion.ex", :get_by, "PromptTemplate", 1, :safe_internal,
     "keyed `slug:`, a plain string column — the value is `experiment.target_template_slug` off a loaded `%Experiment{}`, itself written only by Experiments.activate/2 from a template row it had just read. No UUID type on either side, and promote/2 folds a miss into {:error, :template_not_found} rather than raising"},
    {"platform/experiments/assignments.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "get_assignment/2's predicate. Its Repo.one pins `a.subject_id == ^subject_id` in the where clause, and the subject is caller-supplied — a task id today, a dispatch id once the later ADR-0048 members land — so a malformed binary would raise Ecto.Query.CastError from the where clause exactly as Repo.get/2 does. The guard folds it into the nil this function already returns for an unassigned subject"},
    # ── Experimentation layer (task 01a0d415 stage 1) ──────────────────
    {"platform/experiments/experiment.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "derive_org_from_project/1's predicate. `project_id` is a changeset field a caller can set from an agent or MCP payload; the guard keeps a malformed id from raising Ecto.Query.CastError in the Repo.get below, and the FK constraint reports it on write instead"},
    {"platform/experiments/experiment.ex", :get, "Platform.Tasks.Project", 1, :safe_internal,
     "the sole Repo.get sits inside derive_org_from_project/1, behind the Platform.UUID.valid?/1 guard counted above; the two entries fail together if either is removed"},
    {"platform/experiments/surfaces.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "latest_default_row/3's predicate. `org_id` arrives through resolve/4's `:org_id` option and current_default/3's argument, both caller-supplied; the guard folds a malformed id into the nil a missing history already returns"},
    {"platform/experiments/surfaces/dispatch_prompt.ex", :get_by, "PromptTemplate", 1,
     :safe_internal,
     "keyed `slug:`, a plain string column with no UUID type on either side; control_payload/2 folds a miss into {:error, :template_not_found} rather than raising"},
    {"platform/experiments/surfaces/dispatch_prompt.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "subject_attributes/1's predicate. Its Repo.one pins `t.id == ^task_id`, and the task id is the dispatch assign `task_id`, which several sites pass as an arbitrary string; the guard folds a malformed id into the empty attribute map"},
    {"platform/experiments/surfaces/open_question_classifier.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "subject_attributes/1's predicate (task 01a0e8b5 stage 5). Its Repo.one pins `m.id == ^meeting_id`, and the meeting id is the transcript chunk payload's `meeting_id`, which arrives over PubSub; the guard folds a malformed id into the empty attribute map, so a scoped experiment answers :no_opinion instead of raising into the classifier's read point"},
    # ── Experiments over MCP (task 01a0d415 stage 2) ───────────────────
    {"platform/experiments/guardrails.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "org_row/1's predicate. `org_id` is `experiment.org_id` today, but for_org/1 is public and the stage-6 guardrails panel passes a selected org from LiveView params; the guard folds a malformed id into the nil a missing org row already returns, and the Repo.one's `g.org_id == ^org_id` never sees it"},
    {"platform/experiments/tools.ex", :platform_uuid_guard, "-", 6, :safe_internal,
     "the MCP boundary's own guards: required_uuid/3 and optional_uuid/3 (every `experiment_id`, `subject_id`, `org_id`, `project_id` argument), maybe_where_org/2's filter, update_goal/4's `goal_id`, load_agent/1's `context.agent_id` and home_org/1's `metadata[\"org_id\"]`. Each folds a malformed value into the tool's not-found or invalid-arguments envelope before any Repo call"},
    {"platform/experiments/tools.ex", :get, "Experiment", 1, :safe_internal,
     "fetch/2's lookup; `experiment_id` is an MCP argument and reaches Repo.get only through required_uuid/3 (guard counted above)"},
    {"platform/experiments/tools.ex", :get!, "Experiment", 1, :safe_internal,
     "experiment_start's re-read after a pending result, keyed by `experiment.id` off the `%Experiment{}` fetch/2 just returned — a primary key the DB produced"},
    {"platform/experiments/tools.ex", :get, "Goal", 1, :safe_internal,
     "update_goal/4 guards `goal_id` (an MCP argument) with Platform.UUID.valid?/1 on the same line, counted above; a malformed id is the not-found envelope"},
    {"platform/experiments/tools.ex", :get, "Agent", 1, :safe_internal,
     "load_agent/1 reads `context.agent_id` only after Platform.UUID.valid?/1 on the same line (counted above), mirroring ToolSurface.load_agent/1's get_by_uuid"},
    # ── Dispatch tool-call ledger and metrics (task 01a114a8 stage 1) ──
    {"platform/federation/tool_call_ledger.ex", :platform_uuid_guard, "-", 4, :safe_internal,
     "attribution_hints/1 keeps a call's `task_id` / `stage_id` / `plan_id` / `space_id` argument only when Platform.UUID.valid?/1 holds, so every id the ladder's three Repo.one (stage -> task, plan -> task, execution space -> task) and Repo.all pin has passed the guard; execution_space/1 checks the `metadata.task_id` it reads back, sole_acked_stage/2 filters the ack payloads' `stage_id` strings before `s.id in ^ids`, and valid_uuid_or_nil/1 folds a malformed `parent_run_id` into nil"},
    {"platform/orchestration/dispatch_metrics.ex", :platform_uuid_guard, "-", 4, :safe_internal,
     "run_tool/2's uuid_arg/2 (the MCP `agent_id` / `task_id` arguments: a malformed value is the invalid-arguments envelope), caller_org/1's `context.agent_id`, ack_units/2's filter on the ack payloads' `stage_id` before any `in ^ids` query, and for_tasks/2's filter on the task ids (experiment assignment subject_ids, task 01a114a8 stage 4) before the `in ^task_ids` queries"},
    {"platform/orchestration/dispatch_metrics.ex", :get, "Platform.Agents.Agent", 1,
     :safe_internal,
     "caller_org/1 reads `context.agent_id` only after Platform.UUID.valid?/1 on the line above (counted above)"},
    {"platform/experiments/tools.ex", :get, "Org", 1, :safe_internal,
     "home_org/1 reads the agent's `metadata[\"org_id\"]` pin only behind `Platform.UUID.valid?(org_id) &&` in the same expression (counted above); a malformed pin is root-equivalent, as in ToolSurface.agent_home_org/1"},
    {"platform/experiments/tools.ex", :get, "Platform.Tasks.Project", 1, :safe_internal,
     "tenancy/2's lookup; `project_id` is an MCP argument that reaches Repo.get only through optional_uuid/3 (guard counted above), and a missing project is the not-found envelope"},
    # ── Blind labeler mail source (task 01a0d415 stage 3) ──────────────
    {"platform/experiments/signals/mail_source.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "on_inbound/1's predicate. The id is the `id` of a {:mail_inbound_ingested, _} PubSub payload, which any process on the node may broadcast; the guard folds a malformed id into the [] an unknown id already returns, and the Repo.one's `m.id == ^inbound_id` never sees it"},
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
    # ── Install-to-install federation (task 01a0d90f stage 2, ADR 0054) ──
    {"platform/federation/peers.ex", :get, "Peer", 1, :safe_internal,
     "`get_peer/1` guards the id with Platform.UUID.valid?/1 in the same `if` — later stages reach it from an admin action or an envelope — and a malformed id returns nil, the function's existing miss"},
    {"platform/federation/peers.ex", :get_by, "Peer", 1, :safe_internal,
     "`get_peer_by_install_id/1` keys `peer_install_id:` (an `Ecto.UUID` column) and guards it with Platform.UUID.valid?/1 in the same `if`; the install id will arrive in a remote envelope's `from` field, so a malformed one must be a nil miss, not a cast error"},
    {"platform/federation/peers.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "the two guards recorded above, in `get_peer/1` and `get_peer_by_install_id/1`. Count 2 -> 3 with task 01a0d90f stage 5: `replica_space_id/1` checks the `data.space_id` a PEER's inbox answered to `space.share` before it is stored as `remote_space_id` (an `Ecto.UUID` column); a malformed id is `{:error, :invalid_answer}` and no row is written, so the guard, not the peer, bounds the insert"},
    # ── Install-to-install federation, shared spaces (task 01a0d90f stage 5) ──
    {"platform/federation/peers/ingest.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "`parse/1` checks the relay payload's `space_id` and `message_id` — both from a REMOTE install's signed envelope, so attacker-shaped — before either reaches a query (`SharedSpaces.get_active/2`'s `local_space_id ==` comparison and the `federation_message_links` claim insert). A malformed id is `{:error, :invalid_payload}`, the handler's existing refusal"},
    {"platform/federation/peers/peer_connection.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`acknowledged/3` checks the `data.message_id` a peer's inbox answered with before `SharedSpaces.record_outbound/3` inserts it into `federation_message_links.remote_message_id` (an `Ecto.UUID` column); a malformed id records no link and the cursor still advances"},
    {"platform/federation/peers/shared_spaces.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`accept_share/2` checks a remote `space.share` payload's `space_id` before `existing_replica/2` compares it against `remote_space_id` (an `Ecto.UUID` column); a malformed id is `{:error, :invalid_payload}`"},
    {"platform/federation/task_attrs.ex", :get, "Platform.Agents.Agent", 1, :safe_internal,
     "`default_agent_resolver/1` is the injection seam for tests; callers pass an `assignee_id` that `TaskAttrs` has already shape-validated"},
    {"platform/federation/tool_surface.ex", :platform_uuid_guard, "-", 11, :safe_internal,
     "file_delete_actor/1 now uses Platform.UUID.cast/1, so a 16-byte agent_id yields nil (delete refused) rather than a fabricated actor id written to the audit column; plus the get_by_uuid/2 helper's own guard. Count 2 -> 3 at the ADR-0046 merge: member 5 stage 4's `verdict_plan/1` was collapsed off a bare Ecto.UUID.cast/1 onto the same predicate. Count 3 -> 4 with ADR-0046 member 7 / task 019fa504 stage 2: `design_decline_task/1` casts `task_design_decline`'s agent-supplied task_id through the same predicate. Count 4 -> 5 with task 019fa609 stage 5: `stage_list_task_plan/2` guards `stage_list`'s newly-accepted agent-supplied task_id before it reaches `Tasks.current_plan/1` or `latest_plan/1`. These are context functions rather than a Repo.get/2 on a schema, so get_by_uuid/2 cannot be reused — but the exposure is identical (a raw tool argument cast into a query) and so is the remedy, which is why the classification still holds. Count 5 -> 6 with task 019fa61c stage 3: `stage_audit_stage/1` casts `stage_architecture_audit`'s agent-supplied stage_id through the same predicate — the classification is unchanged because the guard, not the caller, is what makes the lookup safe. Count 6 -> 7 with task 01a0a633 stage 1: `resolve_ack_stage_id/2` casts `task_ack`/`alarm_silence`'s agent-supplied stage_id through the same predicate before looking the stage up. Classification unchanged for the same reason as every entry above it — the cast, not the caller, is what bounds the query. Count 7 -> 8 with task 01a0acc3 stage 3: `task_list_assignee_opts/1` casts `task_list`'s agent-supplied assignee_id through the same predicate before it reaches `Tasks.list_tasks_page/2` / `count_tasks/1`, whose `t.assignee_id == ^id` comparison raises Ecto.Query.CastError on a non-UUID; the cast OUTPUT (lowercased) is what the query receives, because the phase_assignees slots are compared as text. Count 8 -> 10 with task 01a114a8 stage 3: `task_get` guards its agent-supplied task_id with `Platform.UUID.valid?/1` before `Tasks.get_task_record/1` (a malformed id now gets the not-found envelope instead of Ecto.Query.CastError), and `validation_list` guards its stage_id before `Tasks.list_validations/1` (refused as invalid_stage_id). Classification unchanged: the guard is what bounds the query. Count 10 -> 11 with task 01a1472d stage 2: `task_write_fence_target/4` passes a Tasks write tool's target id to `Platform.Access.task_target/3` only when Platform.UUID.valid?/1 accepts it (a malformed id is never swapped and reaches the handler's own malformed-id path); `Access.TaskTarget.resolve/1` casts it again before any query. Classification unchanged"},
    {"platform/federation/tool_surface.ex", :get, "Plan", 3, :safe_internal,
     "two read stage.plan_id off a %Stage{} already loaded in the same function; plan_approve's agent-supplied plan_id was moved onto the guarded get_by_uuid/2 helper. The third (count 2 -> 3 at the ADR-0046 merge) is member 5 stage 4's `verdict_plan/1`, whose agent-supplied plan_id is gated by Platform.UUID.cast/1 — collapsed from a bare Ecto.UUID.cast/1 at the merge — so Repo.get receives a canonical uuid or is never reached"},
    {"platform/federation/tool_surface.ex", :get, "Stage", 3, :safe_internal,
     "stage.plan_id is read off a %Stage{} the tool already loaded; the boundary-facing stage_complete lookup was moved onto the guarded get_by_uuid/2 helper. Count 1 -> 2 with task 019fa61c stage 3: `stage_audit_stage/1` behind `stage_architecture_audit`. The agent-supplied stage_id is gated by Platform.UUID.cast/1 in the same `with`, so Repo.get receives a canonical uuid or is never reached. The lookup lives HERE rather than being delegated to `StageAudit.record_note/3` (which resolves its own id) for the same reason `design_decline_task/1` does: `record_note/3` would report a mistyped stage_id as `stage_not_found` too, but resolving first is what lets the tool keep `stage_not_found` distinct from `audit_not_open` — an architect who fat-fingered an id must not be told the audit was never opened. Count 2 -> 3 with task 01a0a633 stage 1: `resolve_ack_stage_id/2` behind `task_ack` and `alarm_silence`. Same shape as `stage_audit_stage/1` directly above — the agent-supplied stage_id is gated by `Platform.UUID.cast/1` in the same `with`, so Repo.get receives a canonical uuid or is never reached — and for the same reason the lookup lives here rather than in the caller: keeping `stage_not_found` distinct from `stage_wrong_task` and `stage_not_running` is the whole point of the guard"},
    {"platform/federation/tool_surface.ex", :get, "Task", 1, :safe_internal,
     "ADR-0046 member 7 / task 019fa504 stage 2: `design_decline_task/1` behind `task_design_decline`. The agent-supplied task_id is gated by Platform.UUID.cast/1 in the same `with`, so Repo.get receives a canonical uuid or is never reached. The lookup exists HERE rather than being delegated to `PreplanStep.decline/3` (which resolves its own id) because `decline/3` collapses an unknown task and an already-closed step into the same `{:ok, :noop}` — resolving first is what lets the tool refuse `task_not_found` distinctly from `step_not_open`"},
    # ── Files ──────────────────────────────────────────────────────────
    {"platform/files.ex", :get, "Text", 1, :safe_internal,
     "fetch_extracted_text/1 checks Platform.UUID.valid?/1. Files.Text keys on a bare :binary_id, so before the guard a 16-byte binary returned nil silently while \"higgins\" raised — one lookup, two symptoms"},
    {"platform/files.ex", :get, "~q:File", 1, :safe_internal,
     "Files.get_file/2 checks Platform.UUID.valid?/1 before piping through the soft-delete filter, so the raw file_id MCP argument behind file_get_metadata / file_get_text / file_delete returns nil"},
    {"platform/files.ex", :get!, "~q:File", 1, :safe_internal,
     "Files.get_file!/2 checks Platform.UUID.valid?/1 and raises Ecto.NoResultsError — its documented miss exception — rather than Ecto.Query.CastError"},
    # ── Inbox ──────────────────────────────────────────────────────────
    {"platform/inbox.ex", :get, "Platform.Accounts.User", 1, :safe_internal,
     "emit/1 reads user_id from a valid Inbox.Item changeset, whose Ecto.UUID cast rejects malformed ids before Repo.get"},
    {"platform/inbox.ex", :get, "~schema", 1, :safe_internal,
     "resource_for/2 is called by emit/1 with source_id from a valid Inbox.Item Ecto.UUID changeset; its schema is one of Message, ReviewRequest or Meeting"},
    {"platform/inbox.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "fetch_owned/2, the one owned-row lookup behind mark_read/2, mark_dismissed/2 and open_item/2 (task 01a11703), checks Platform.UUID.valid?/1 on both item_id and user_id before `where: i.id == ^item_id and i.user_id == ^user_id`. item_id arrives from InboxLive's client \"open\"/\"dismiss\" events, so a malformed id folds into the existing {:error, :not_found} instead of raising Ecto.Query.CastError"},
    # ── Lifecycle ──────────────────────────────────────────────────────
    {"platform/lifecycle/executor.ex", :get, "TaskSchema", 1, :safe_internal,
     "task 019fe1b6 stage 4 — `maybe_notify/3` loads the task to read `sponsor_user_id` before emitting a `lifecycle_step_failed` inbox row. The id is `run.task_id`, read off a `%StepRun{}` this function just loaded from `lifecycle_step_runs`, so it is a persisted column value constrained by a NOT NULL FK to `tasks`; it cannot be malformed without the FK having admitted a malformed row. Note the module deliberately calls `Repo.get/2` and NOT `Platform.Tasks.get_task/1` — that name belongs to the artifacts-summary reader and returns `{:ok, %Detail{}} | {:error, :not_found}`, a different concept that compiles fine here and fails at the field access"},
    {"platform/lifecycle/runs.ex", :get, "StepRun", 1, :safe_internal,
     "task 019fe1b6 stage 4 — `Runs.settle/2` resolves a run row to update it in place when a non-awaited step settles after its edge reported. The id is the `lifecycle_step_runs` PK exposed as `:run_id` on `Executor.run_edge/3`'s summary; every caller holds it because `record/1` returned it in the same process. It is deliberately UNGUARDED by `Platform.UUID.valid?/1`: the function's contract already answers `{:error, :not_found}` for an unknown id, and a guard would fold a malformed id into that same answer, hiding a caller bug as an ordinary miss. `Repo.get/2` on the strict `Platform.Types.UUIDv7` PK raises for a non-uuid, which is the louder and correct signal for a handle that can only come from this system"},
    # ── Meetings ───────────────────────────────────────────────────────
    {"platform/meetings/invite_delivery.ex", :get, "Platform.Accounts.User", 1, :safe_internal,
     "deliver_internal/2 reads invite.user_id off a persisted %Invite{} row whose user_id is a UUID foreign key to users"},
    {"platform/meetings/meeting_notifier.ex", :get, "Platform.Accounts.User", 1, :safe_internal,
     "readable_recipients/2 receives ids selected from persisted Invite.user_id or Participant.participant_id :binary_id fields by Meetings.recipients_for_meeting/1"},
    # ── Email module (task 01a0cf21-29ba-7001-8690-3c59d6cb17c6) ──────
    # Stages 1-3 landed these without classifying them; stage 4 records them
    # together with its own `mailbox.ex` / `email_live.ex` sites.
    {"platform/mail.ex", :get, "Account", 4, :safe_internal,
     "two sit behind Platform.UUID.valid?/1 on the same value in the same `with` (`get_account/2` checks org_id AND id; `fetch_account_by_id/1`, the first step of `resolve_sender/3`, checks account_id, which arrives from a draft row or an MCP/deploy payload); the third, `authorize_manage/2`, reads `id` off an `%Account{}` struct the caller already loaded through one of those guarded getters — a `mail_accounts` UUIDv7 PK; the fourth (task 01a13ba5 stage 1, `start_backfill/4`) re-reads the same struct's `id` AFTER `authorize_manage/2` passed, for a fresh eligibility check"},
    {"platform/mail.ex", :get_by, "Sender", 2, :safe_internal,
     "both keyed `account_id:` read off an already-loaded `%Account{}` struct (a `mail_accounts` PK) plus `key:`, a `:string` column that cannot raise a cast error; `fetch_sender/2` additionally requires `is_binary(key)` in its head"},
    {"platform/mail.ex", :platform_uuid_guard, "-", 4, :safe_internal,
     "`list_accounts/1` (org_id), `get_account/2` (org_id and id — two calls) and `fetch_account_by_id/1` (account_id): each guards a value that arrives from a LiveView param, a draft row or an MCP/deploy payload before it reaches `where:` or `Repo.get/2`, and folds a malformed one into the function's existing miss (`[]`, `nil`, `{:error, :account_not_found}`)"},
    {"platform/mail/deliverer.ex", :get, "Delivery", 1, :safe_internal,
     "`deliver/1`'s id is the `mail_deliveries` PK that `Dispatch.record/6` generated in-process with `Platform.Types.UUIDv7.generate/0` and committed before calling it — the send path's only caller, pinned by `single_sender_guard_test.exs`"},
    {"platform/mail/deliverer.ex", :get!, "Account", 1, :safe_internal,
     "`delivery.account_id` is a NOT NULL FK column read off the `%Delivery{}` row `deliver/1` just loaded, so it is a canonical uuid by construction; `get!` is deliberate — a delivery whose account row is gone is a broken invariant, and it raises inside the rescue envelope that records `failed`"},
    {"platform/mail/deliverer.ex", :get_by, "Sender", 1, :safe_internal,
     "keyed `account_id:` (the delivery row's NOT NULL FK column) and `key:` (the row's `sender_key`, a `:string` column) — both columns off a loaded `%Delivery{}`"},
    {"platform/mail/dispatch.ex", :get, "Account", 1, :safe_internal,
     "`rate_usage/1` reads `id` off an `%Account{}` struct its caller already loaded (the account card and the confirm pane both read it from `Platform.Mail.list_accounts/1` / `get_account/2`) — a `mail_accounts` UUIDv7 PK"},
    {"platform/mail/dispatch.ex", :get, "Draft", 1, :safe_internal,
     "`fetch_draft/1` guards the draft id with Platform.UUID.valid?/1 in the same `with` — the id arrives from a LiveView event or an agent tool call — and a malformed one returns `{:error, :draft_not_found}`"},
    {"platform/mail/dispatch.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`fetch_draft/1`'s guard, recorded above: `dispatch/3`'s draft_id is caller-supplied"},
    {"platform/mail/drafts.ex", :platform_uuid_guard, "-", 12, :safe_internal,
     "stage 5's draft writes and reads. Every id reaches this module from a boundary — the `mail_draft_create` / `mail_draft_update` MCP payload (org_id, draft_id, account_id, to_user_ids, on_behalf_of_user_id, task_id) or a LiveView `/email/drafts/:id` path segment — and each is guarded before it reaches `where:`: `get/2` (org_id and id — two calls), `org_people/1` (org_id), `agent_exists?/1` (the agent id off the caller's context), `fetch_org/1` (org_id), `fetch_draft/1` (draft_id), `check_on_behalf_of/2`, `check_task/2`, and the three batch readers `users_by_id/1`, `names_by_id/2`, `titles_by_id/1`, which drop a malformed id from the `in ^ids` list instead of raising. A malformed value becomes the function's existing miss (`nil`, `[]`, `{:error, :draft_not_found}`, a named refusal). Count 11 -> 12 with task 01a0cf21 stage 6: `system_stage_id/1` guards the `stage_id` `create_system/2` accepts from `Platform.Deploy.Email` (a `stages.id` PK off the injected deploy stage) before it is written to the draft, refusing a malformed one as `{:invalid, _}` rather than persisting it"},
    {"platform/mail/inbound.ex", :get, "Space", 1, :safe_internal,
     "`usable_space/1` is called only with `account.inbound_space_id`, a `belongs_to` FK column on the loaded `%Account{}`; the nil case has its own clause first"},
    {"platform/mail/inbound.ex", :get!, "InboundMessage", 1, :safe_internal,
     "`row.id` is the PK `ingest/5` generated with `Platform.Types.UUIDv7.generate/0` a few lines earlier and just inserted"},
    {"platform/mail/inbound.ex", :get_by, "FolderCursor", 1, :safe_internal,
     "keyed `account_id:` off the loaded `%Account{}` being polled and `folder:`, a `:string` column holding the IMAP folder name"},
    {"platform/mail/inbound.ex", :get_by, "Participant", 1, :safe_internal,
     "`space_id` is off a `%Space{}` `usable_space/1` just loaded; `participant_id` is built by `email_participant_id/1` from a sha256 hex digest formatted 8-4-4-4-12, so it is uuid-shaped by construction; `participant_type` is the literal \"system\""},
    {"platform/mail/inbound_access.ex", :platform_uuid_guard, "-", 5, :safe_internal,
     "task 01a13ba5 stage 2's agent mail reads. Every id arrives from the `mail_inbound_list` / `mail_inbound_get` MCP payload (org_id, account_id, id) or off the caller's context (agent_id), and each is guarded before it reaches `where:`: `list/3` (agent_id, org_id, and account_id when given — three calls) and `get/2` (agent_id and id — two calls). A malformed value becomes the existing miss: `{[], 0}` for the list, `:not_found` for the get, which the tool returns as the one not-found envelope"},
    {"platform/mail/inbound/poller.ex", :get, "Account", 2, :safe_internal,
     "both calls (the timer tick and the `:poll_now` call) reload the poller's `account_id`, its start arg, and both starters pass an `%Account{}` PK: `Inbound.sync_poller/1` (`account.id`) and `start_all_pollers/0` (ids off `Repo.all` of `mail_accounts`)"},
    {"platform/mail/mailbox.ex", :platform_uuid_guard, "-", 10, :safe_internal,
     "stage 4's Email module reads. The org id, account filter and message/project ids arrive from LiveView `params` (`?org=`, `?account=`, `/email/messages/:id`, the Add to files select) and each is guarded before it reaches `where:`: `inbound_query/2`, `deliveries_query/3`, `drafts_query/2`, `org_projects/1`, `org_channels/1` (org_id), `get_inbound/2` (org_id and id — two calls), `inbound_org_id/1` (id), `narrow_account/2` (account_id) and `fetch_org_project/2` (project_id). A malformed value narrows to nothing / nil rather than dropping the filter"},
    {"platform_web/live/experiments_live.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "parse_project/1's predicate (task 01a0d415 stage 6). `project_id` comes from the create form's LiveView params; the guard turns a malformed id into the page's 'No such project.' flash before it reaches Experiment.changeset/2, whose own guard and FK constraint are the second line"},
    {"platform_web/live/email_live.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`account_param/1` guards the `?account=` query param before it becomes the account filter; a malformed value is dropped to nil (all accounts), and `Mailbox.narrow_account/2` guards it again at the query"},
    {"platform/meetings.ex", :platform_uuid_guard, "-", 21, :safe_internal,
     "cast_identity/2 now uses Platform.UUID.cast/1, so a 16-byte LiveKit webhook identity suffix yields :unknown instead of a fabricated user_id/agent_id FK; the remaining guards cover get_meeting/1, get_room/1, get_transcript/1, get_transcript_with_segments/1, the two recording lookups, resolve_agent/1, claim_router_dispatch/1 (019fa56b-c81f stage 2), whose transcript_id arrives inside a meeting:finished PubSub payload and must answer {:error, :no_such_transcript} rather than raise on the Router's dispatch path, and get_invite/1 (019fb954 stage 4), whose invite_id arrives inside a SIGNED GUEST TOKEN PAYLOAD — a signature proves who minted the payload, not that its ids are uuids, and a fabricated id must never be what decides whether a capability was revoked. Count 13 -> 14 with 019fb955 stage 4: `ensure_delivery_invitee/2` guards `invite.user_id` before the `Repo.get_by(Platform.Chat.Participant, ...)` recorded below. The classification is unchanged because the guard, not the caller, is what makes the lookup safe — `InviteDelivery.deliver/2` takes an %Invite{} STRUCT, so nothing upstream of the guard proves the field came out of the column. Count 14 -> 15 with 019fb955 stage 2: `invited_to_space?/2` guards its `space_id` before the `Repo.exists?` join, because that argument arrives off a session assign / a join-seam caller and the column is uuid — an unguarded bad value raises Ecto.Query.CastError out of an access predicate whose contract is a boolean, which fails the gate OPEN by crashing the caller instead of denying. Count 15 -> 16 at this stack's rollup merge, for `intent_muted?/1` (019fbaac stage 1, landed on main independently), whose meeting_id arrives inside a meeting:transcript_chunk PubSub payload and is legitimately nil whenever the chunk's space has no meeting — it is read per transcript chunk from the singleton IntentClassifier GenServer, so a raise there stops classification for every room on the node at once. Count 16 -> 17 with task 019fcfcf stage 1: `get_whiteboard/1`, whose meeting_id arrives unresolved from the whiteboard tab's mount/params path, and whose contract is `%Whiteboard{} | nil` — an empty board is the ordinary starting state, so a malformed id must answer nil rather than raise Ecto.Query.CastError out of a read whose miss is already meaningful. Count 17 -> 18 with task 01a00066 stage 1: `meeting_live?/1`, whose meeting id arrives from an inbox row's `source_id` column and whose contract is a boolean — an unresolvable id answers `true` (still live, so the caller never dismisses a row on ambiguity) instead of raising. Count 18 -> 19 with task 01a0740d-e5ce-7001-812e-aa79a5392aed stage 1: `live_recording_for_room/1`, whose room_id reaches it from a LiveView assign and from a `{:recording_updated, _}` broadcast payload, and whose contract is `%Recording{} | nil`. Note this is NOT the same shape as the two unguarded transcript reads recorded in the Repo.one map below: `meeting_transcripts.room_id` is a `:string` column holding the LiveKit room NAME, whereas `meeting_recordings.room_id` is a `belongs_to(:room)` on a `:binary_id` FK, so `where: r.room_id == ^room_id` here raises the same Ecto.Query.CastError `Repo.get/2` would. It backs a consent indicator in the call header, so a malformed id must read as `nil` (nothing is recording) rather than take the header render down. Count 19 -> 20 with task 01a0e906 stage 2: `resolve_removable_agent_row/2`, whose `row_id` arrives from the host's phx-value- \"Remove from meeting\" control; a malformed id folds into {:error, :not_found} before the `Repo.get(Participant, _)` recorded below. Count 20 -> 21 with task 01a10db7 stage 1: `get_meeting_for_user/2`, whose meeting id arrives as the `:id` URL path segment of `POST /api/app/meetings/:id/join` and `/leave`; a malformed id folds into {:error, :not_found} (404) before the `where: m.id == ^meeting_id` / `Repo.one` recorded in the Repo.one map below"},
    {"platform/meetings/ringing.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a10db7 stage 2: `get_ring_for_user/2` guards the ring id, which arrives as the `:id` URL path segment of `GET /api/app/rings/:id` and its answer/decline/missed routes, with Platform.UUID.valid?/1 before the `where: r.id == ^ring_id` / `Repo.one` recorded in the Repo.one map; a malformed id folds into {:error, :not_found} (404)"},
    {"platform/meetings.ex", :get_by, "Whiteboard", 1, :safe_internal,
     "task 019fcfcf stage 1 — `get_whiteboard/1`, keyed `meeting_id:`. Classified safe because the call sits inside `if Platform.UUID.valid?(meeting_id)`; without that guard a `meeting_id` from a params map raises rather than returning the nil that means \"this meeting has no board yet\", which is a state the editor is required to render"},
    {"platform/meetings.ex", :get, "Agent", 1, :safe_internal,
     "the one remaining call is inside resolve_agent/1, which checks Platform.UUID.valid?/1 and falls back to Platform.Agents.SlugLookup.resolve/2 (nil on a slug shared across workspaces, task 01a0e77c). generate_agent_token/3, dispatch_meeting_join/3 and dismiss_agent/2 all route through it"},
    {"platform/meetings.ex", :get, "Invite", 2, :safe_internal,
     "two, both behind Platform.UUID.valid?/1. (1) the miss branch of Meetings.revoke_invite/1: a malformed invite_id from the host's phx-value- revoke control returns {:error, :not_found} before either this Repo.get or the guarded UPDATE ... WHERE id = $1 ahead of it can raise (019fb954 stage 3). (2) get_invite/1, the revocation gate in resolve_guest_invite/2, whose invite_id is read out of a guest token payload on a public unauthenticated ingress; nil folds to {:error, :invalid} (019fb954 stage 4)"},
    {"platform/meetings.ex", :get, "Meeting", 2, :safe_internal,
     "Meetings.get_meeting/1 checks Platform.UUID.valid?/1 first; resolve_invited_meeting/2 was switched onto that guarded getter, so its rescue Ecto.Query.CastError is now belt-and-braces rather than the actual defence. Count 1 -> 2 with task 01a0e906 stage 2: `reload_meeting/1` in remove_agent_from_call/3 reads `id` off the `%Meeting{}` struct it pattern-matches, i.e. the meetings.id primary key of a row already loaded"},
    {"platform/meetings.ex", :get, "Participant", 1, :safe_internal,
     "task 01a0e906 stage 2 — `resolve_removable_agent_row/2`. The `row_id` is a boundary value (the host's phx-value- remove control) and the call sits behind `Platform.UUID.valid?(row_id)` at the head of the same with-chain, so a malformed id answers {:error, :not_found} instead of raising Ecto.Query.CastError"},
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
    {"platform/meetings.ex", :get_by, "Platform.Chat.Participant", 1, :safe_internal,
     "019fb955 stage 4 — `ensure_delivery_invitee/2`'s get-or-insert guard ahead of `Chat.add_participant/2`, which has no such branch of its own and would hit `chat_participants_unique` on a re-delivery. `space_id` is `%Chat.Space{}.id` off the row `Chat.get_space/1` or `Chat.create_space/1` just returned in the same function. `participant_id` is `invite.user_id`, a `meeting_invites.user_id` FK column, and is checked with Platform.UUID.valid?/1 anyway before the lookup — because `deliver/2` accepts a STRUCT rather than an id, so a hand-built %Invite{} can carry anything, and because `Repo.get_by(_, participant_id: nil)` raises ArgumentError rather than returning nil (the nil case has its own head returning {:error, :no_invitee_user})"},
    {"platform/meetings.ex", :get_by, "Room", 3, :safe_internal,
     "keyed `livekit_room_name:` (string) and `space_id:`; the `space_id` callers pass a `%Space{}` id already resolved by `Chat.get_space/1`"},
    {"platform/meetings.ex", :get_by, "User", 1, :safe_internal,
     "019fb955-1d7b stage 2 — `invite_external_user/3` resolving the address a host TYPED into an account, which is the whole three-way branch. The value IS a boundary value, and it is safe for a reason this inventory should state precisely: the lookup is keyed `email:` only, a `:string` column, and casting a binary to `:string` cannot fail — `Ecto.Query.CastError`, the defect this test exists to catch, is only reachable when a boundary value is cast to `:binary_id`. No `Platform.UUID.valid?/1` guard applies because no UUID is pinned. `users.email` also carries a unique index, so `get_by/3` cannot raise `Ecto.MultipleResultsError` here either"},
    {"platform/meetings/agent_activity.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a04a98 stage 1 — `agent_id_for_chat_participant/1`. The id is the `participant_id` field of an `{:agent_typing, %{…}}` PubSub payload, i.e. it arrives as a message rather than out of a query, and the lookup runs inside `PlatformWeb.MeetingLive.handle_info/2` — an `Ecto.Query.CastError` there kills the LiveView for every viewer of the meeting, not just the malformed event. The function's contract is already `binary() | nil` (`nil` = \"that participant does not seat an agent\"), so a malformed id folds into the existing miss"},
    {"platform/meetings/agent_activity.ex", :get, "Participant", 1, :safe_internal,
     "task 01a04a98 stage 1 — the `Chat.Participant` -> `Agents.Agent` bridge behind `agent_id_for_chat_participant/1`. Classified safe because the call sits in `lookup_agent_id/1`, reachable only through the `Platform.UUID.valid?/1` guard recorded immediately above; the guard, not the caller, is what makes it safe — the two live producers of the payload (`Chat.AgentResponder`, `PlatformWeb.RuntimeChannel`) both read the id out of a column, but nothing structural stops a third publisher on the same chat-space topic"},
    {"platform/meetings/archive.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "019fb954-c848 stage 2 — `maybe_filter_project/2` and `maybe_filter_person/2` each guard with Platform.UUID.valid?/1 before their id reaches a `where:`. Both come straight off the archive LiveView's `params` map (`?project=` / `?person=`), and `where: m.project_id == ^value` raises the same Ecto.Query.CastError as Repo.get/2 would. A malformed id narrows the query to nothing rather than dropping the filter — failing open on a scoping filter would turn a no-results page into a listing of every project the viewer can see. Stage 3 adds the third: `meeting_ids/1` filters the page's ids with the same guard before they reach `where: m.id in ^ids`, for the same reason and with the same failure mode — the ids reach `artifacts_for/2` by way of the page that rendered them, so one stale or hand-edited value would otherwise raise on a read that is supposed to degrade to 'that row has no artifacts'. Classification is unchanged: every one of the three narrows a query that is already org-scoped by `scoped_query/2`"},
    {"platform/meetings/intent_classifier.ex", :get, "Platform.Agents.Agent", 1, :safe_internal,
     "`agent_slug/1` receives an `agent_id` the classifier read off a `%Participant{}` row in the same pipeline"},
    {"platform/meetings/intent_classifier.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a0e58f stage 2 — `read_participants/1` guards the transcript payload's `room_id` with Platform.UUID.valid?/1 before `Meetings.active_participants/1` puts it in `where: p.room_id == ^room_id`. The room_id is free-form on the transcript chunk topic (tests and the eval harness use slugs like \"room-decide\"), so an unguarded query would raise Ecto.Query.CastError; a malformed id reads as nil, which the addressee gate treats as inert rather than as an empty room"},
    {"platform/meetings/intent_context.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a0e58f stage 4 — `room_participants/1` guards the dispatch payload's `room_id` with Platform.UUID.valid?/1 before `Meetings.active_participants/1` puts it in `where: p.room_id == ^room_id`. The room_id rides the IntentQueue row from a transcript payload and is free-form there (tests use slugs like \"seam-room-1\"), so an unguarded query would raise Ecto.Query.CastError inside `gather_context/2`; a malformed id reads as nil, which the addressee gate treats as inert rather than as an empty room"},
    {"platform/meetings/intent_dispatcher.ex", :get, "Agent", 1, :safe_internal,
     "`safe_get_agent/1` is fed an `agent_id` resolved by `Roles.agent_id_for_role/1` before dispatch"},
    {"platform/meetings/intent_dispatcher.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`meeting_target_space_id/1` guards with Platform.UUID.valid?/1 before its lookup. The meeting_id is a per-meeting IntentQueue key, and the queue is Registry-keyed with no DB row required — nothing upstream guarantees it is a UUID, so an unguarded Repo.get would raise Ecto.Query.CastError on a best-effort dispatch path whose contract is always-:ok"},
    {"platform/meetings/intent_dispatcher.ex", :get, "Meeting", 1, :safe_internal,
     "reached only through `meeting_target_space_id/1`'s Platform.UUID.valid?/1 branch, so the value is a canonical 36-character uuid by construction; a meeting id with no row returns nil and the dispatch simply names no space"},
    {"platform/meetings/intent_runtime_adapter.ex", :get, "Agent", 1, :safe_internal,
     "`resolve_target/1` receives the `agent_id` the dispatcher already resolved from a role assignment"},
    {"platform/meetings/intent_queue/server.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a03fb8 stage 3 — `uuid_or_nil/1` in the durable candidate mirror. Not a lookup guard at all: it sanitises `room_id` / `transcript_chunk_id` / `target_agent_id` before they are cast into the candidate's binary_id columns. Those values reach the queue from a transcript payload and are free-form there, so a non-uuid degrades to nil rather than costing the whole candidate row"},
    {"platform/meetings/candidate_events.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "task 01a03fba — `list_for_candidate/1` and `list_for_meeting/1` each guard with Platform.UUID.valid?/1 before their `Repo.all`. Same boundary as `candidates.ex`'s own reads and for the same reason: a candidate id arrives from the card rail's `phx-value-` payload, and a meeting id reaches the rail from a LiveKit room whose name is not always a uuid. Both contracts are already `[]`-returning, and an activity log with no lines is an ordinary state for a card nothing has happened to yet, so a malformed id must answer `[]` rather than raise Ecto.Query.CastError out of a read the board performs on every mount. Not a `Repo.get`-family lookup: the guard protects a `where` on a `:binary_id` column, which is the cast that would otherwise raise"},
    {"platform/meetings/candidates.ex", :platform_uuid_guard, "-", 7, :safe_internal,
     "task 01a03fb8 stage 2 — `get/1` and `get_by_intent_id/1` each guard with Platform.UUID.valid?/1 before their lookup. Both ids are boundary values: a candidate id arrives from the board's `phx-value-` payload, and an intent id is an IntentQueue ETS key derived from whatever a transcript chunk carried, with no DB row required to mint it. Both functions' contracts are already `| nil`, so a malformed id must answer nil rather than raise Ecto.Query.CastError out of a read whose miss is an ordinary state. Task 01a04a7f adds five more of the same shape on the pre-classification write path, and every one of them guards a value that arrives straight off a LiveKit transcript payload rather than out of the database: `record_heard/1` rejects a non-uuid meeting id and a non-uuid transcript chunk id up front (a chunk with no usable key cannot be reconciled later, so it must not open a card at all), `recorded_chunk/2` re-guards both because it is also reached from `create_or_attach/1` where nothing has validated them, and `uuid_or_nil/1` guards the room id for the same reason `IntentQueue.Server` does — a LiveKit room name is not always a uuid, and a failed :binary_id cast would take the whole changeset down and silently disable early cards for that room"},
    {"platform/meetings/candidates.ex", :get, "MeetingCandidate", 1, :safe_internal,
     "reached only through `get/1`'s Platform.UUID.valid?/1 branch recorded above, so the value is a canonical uuid by construction; an id with no row returns nil, which `fetch/1` folds into {:error, :not_found}"},
    {"platform/meetings/candidates.ex", :get, "Platform.Meetings.Meeting", 1, :safe_internal,
     "task 01a03fb8 stage 4 — `meeting_for/1` in `graduate/2`. The id is the loaded candidate row's `meeting_id`, a `:binary_id` column Ecto already cast on write, and the clause is guarded `when is_binary(meeting_id)` so a nil never reaches the lookup. A meeting id with no row returns nil and `meeting_field/2` answers nil, which surfaces as a changeset error from the deliverable create rather than a raise"},
    {"platform/meetings/candidates.ex", :get_by, "MeetingCandidate", 1, :safe_internal,
     "`get_by_intent_id/1`, keyed `intent_id:` and reached only through that function's Platform.UUID.valid?/1 branch. The column carries a unique index (the stage-3 mirror's idempotence key), so Ecto.MultipleResultsError is unreachable here too"},
    {"platform/meetings/press_card.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "per-agent hold-to-talk — `resolve_pressed_agent/1` guards with Platform.UUID.valid?/1 before its `Repo.get(Agent, ...)`. The pressed `agent_id` arrives on the `push_to_talk_press` payload (a user-controlled phx-value / channel message), so a malformed id would otherwise raise Ecto.Query.CastError out of `PressCard.open/3` on key-down. Used as a BOOLEAN with the string discarded — a malformed id folds to `:error`, exactly like a well-formed-but-absent one, and the press takes the configured default target rather than crashing. Pinned by `push_to_talk_target_test.exs` \"a malformed pressed id falls back to the default and does not raise\""},
    {"platform/meetings/press_card.ex", :get, "Agent", 1, :safe_internal,
     "reached only through `resolve_pressed_agent/1`'s Platform.UUID.valid?/1 branch recorded above, so the value is a canonical 36-character uuid by construction; an id with no active-agent row returns `:error` and `pressed_agent/1` falls back to the default target, never bylining a card to a stranger"},
    {"platform/meetings/triage.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a03fda — `build_reconciliation/1` guards the meeting-candidate reconciliation query. `:meeting_id` has always been an OPTIONAL passthrough on `file_tasks_from_canvas/2`, enriched by the triage-officer runtime and forwarded straight into telemetry, so it has never had to be a real id — `triage_test.exs` passes the literal \"mtg-stage4\". Without the guard that string reaches a `:binary_id` WHERE and raises Ecto.Query.CastError mid-batch. An unusable id reconciles nothing, which is the pre-01a03fda behaviour"},
    # ── Memory ─────────────────────────────────────────────────────────
    {"platform/memory/insights/briefings.ex", :get_by, "Briefing", 3, :safe_internal,
     "task 01a13867 stage 4: `get_by_canvas/1` looks up `canvas_id:` with the id of a canvas row the caller already loaded (canvas_hooks.ex `insight_card_action/5` passes the clicked `%Canvas{}.id` from `find/2`), behind this file's Platform.UUID.valid?/1 guard; the briefing's insight id is then read out of that row's `items`, never from the click Count 1 -> 3 at task 01a15ee1 stages 4-5: `for_user_on/2` (`user_id:` + `digest_date:`) and `get_for_user/2` (`id:` + `user_id:`) each check every id with Platform.UUID.valid?/1 before the lookup. The briefing id reaches `get_for_user/2` from an InboxLive event and the date from the `/inbox/briefing/:date` path, so these are the :must_cast end, and the guard keeps a malformed id a nil (the same as another person's row) rather than a CastError"},
    {"platform/memory/insights/briefings.ex", :get, "Briefing", 3, :safe_internal,
     "task 01a15ee1 stages 5-6: `inbox_row_stale?/2` checks the id with Platform.UUID.valid?/1 in the same `with` before Repo.get, so a malformed Inbox `source_id` is not stale rather than a CastError. `handle/5` and `undo/3` re-read `%Briefing{id: ...}` off a struct their caller already loaded (InboxLive gets it through the guarded, owner-scoped `get_for_user/2`), a `briefings.id` primary key and a canonical uuid by construction"},
    {"platform/memory/insights/disseminator.ex", :get_by, "Briefing", 1, :safe_internal,
     "task 01a13867 stage 3: `deliver/6` looks up `(user_id, digest_date)` with a user id that is a key of `Digest.select/2`'s map, i.e. a `memory_insights.addressee_user_id` or an `org_memberships.user_id` uuid column value, and a `Date` computed by `local_date/1`"},
    {"platform/memory/insights.ex", :get, "Insight", 1, :safe_internal,
     "Insights.get/1 (task 01a13867 stage 1) checks Platform.UUID.valid?/1 on the LiveView / canvas param before Repo.get, mirroring Proposals.get/1"},
    {"platform/memory/telemetry_handler.ex", :get, "Platform.Org.WikiJournalEntry", 1,
     :safe_internal,
     "`metadata.memory_entry_id` comes off the telemetry event `Org.Wiki` emits with the PK it just inserted"},
    # ── Orchestration ──────────────────────────────────────────────────
    {"platform/orchestration/context_assembler.ex", :get, "TaskSchema", 1, :safe_internal,
     "`load_parent_plan_entry/1` uses `parent_id` read off the `%Task{}` it already loaded"},
    {"platform/orchestration/execution_space.ex", :get_by, "Participant", 1, :safe_internal,
     "`participant_id` is derived deterministically from space_id by `system_participant_id/1`; `participant_type` is the literal \"agent\""},
    {"platform/orchestration/execution_space.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`task_id/1` (task 01a1559a stage 3) reads `metadata[\"task_id\"]` off an execution space. `metadata` is a JSONB map with no shape check on that key, so the value is guarded before `task_titles/1` binds it in `where: t.id in ^task_ids`; a malformed value reads as a space with no task (the picker falls back to the space name) rather than raising Ecto.Query.CastError"},
    {"platform/orchestration/phase_runtime.ex", :get, "Agent", 1, :must_cast,
     "task 019fb977 moved this lookup out of `task_router_watcher.ex`, where it was :safe_internal because the id came off the `tasks.assignee_id` COLUMN (a `Platform.Types.UUIDv7` cast at write time). `PhaseRuntime.resolve/1` now prefers `phase_assignees[current_phase(task)][\"assignee_id\"]`, which lives inside a JSONB map that `Task.validate_phase_assignees/1` (`tasks/task.ex:348`) checks only the PHASE KEYS of — never the id shape. An MCP `task_update` carrying `%{\"execution\" => %{\"assignee_id\" => \"higgins\"}}` therefore reaches this call as a raw agent-supplied string. Guarded with `Platform.UUID.valid?/1`, returning the site's existing `{:error, :agent_not_found}` rather than raising `Ecto.Query.CastError` inside the router's dispatch path; covered by `phase_runtime_test.exs` \":agent_not_found — not a raise — for a malformed phase-entry id\""},
    {"platform/orchestration/heartbeat_scheduler.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "experiment_subject/1's predicate (task 01a0d415 stage 4). The dispatch task's id is often a plain map field in callers and tests, and the resolver's assignment lookups pin `subject_id == ^id`; the guard folds a malformed id into `nil` (no subject, prompt unchanged) before any Repo call"},
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
    {"platform/org/wiki/nodes.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a1386d-e528 stage 1: `org_of/2` checks the `project/<id>/` or `space/<id>/` path segment with Platform.UUID.valid?/1 before `where: r.id == ^id` (this file's `@repo_one_counts` entry), so a non-UUID segment answers nil and `ensure/2` falls back to the root org instead of raising Ecto.Query.CastError on a path an agent supplied"},
    {"platform/access/grants.ex", :get, "Grant", 4, :must_cast,
     "task 01a1386d-e528 stage 2: `revoke/1` takes a raw grant id from its caller. Guarded with Platform.UUID.valid?/1 (this file's :platform_uuid_guard), returning the site's `{:error, :not_found}`; covered by precedence_test.exs \"malformed ids are not found and decide nothing\". 1 → 2 for task 01a1386e-30bd stage 1: `revoke/2` re-reads the same id inside its ledgered mutation (`Platform.Access.Changes.commit/4`), reached only after that guard has passed. 2 → 4 for member9: prepare_op/revoke guards its supplied id before the preview lookup; apply_ops re-reads that same guarded id inside the ledger mutation"},
    {"platform/access/changes.ex", :get, "Change", 1, :must_cast,
     "task 01a1386e-30bd stage 1: `undo/3` takes a raw change id from its caller (stage 2's delegation and a later MCP tool will pass it through). Guarded with Platform.UUID.valid?/1 (this file's :platform_uuid_guard), returning `{:error, :not_found}`; covered by changes_test.exs \"a second undo is refused; undoing the undo redoes the change\" (`undo(\"nope\", _)`)"},
    {"platform/access/changes.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "task 01a1386e-30bd stage 1: `undo/3`'s change id, checked before the `get(Change)` above. Used as a BOOLEAN and the string discarded"},
    {"platform/access/grants.ex", :get, "Node", 1, :must_cast,
     "task 01a1386d-e528 stage 2: `fetch_resource(:memory_node, id)` is reached only through `resource_fields/1`'s Platform.UUID.valid?/1 check on a caller-supplied `{:memory_node, id}`; a malformed id is `{:error, :resource_not_found}`. Same test as above"},
    {"platform/access/grants.ex", :platform_uuid_guard, "-", 3, :must_cast,
     "member9 adds prepare_op/revoke Platform.UUID.valid?/1 before its extra get; existing guards remain. task 01a1386d-e528 stage 2: (1) `revoke/1`'s grant id; (2) `resource_fields/1`'s `{:project | :space | :canvas | :memory_node, id}` before the three `Repo.one` lookups (this file's `@repo_one_counts` entry) and the `get(Node)` above. Used as a BOOLEAN and the string discarded; covered by precedence_test.exs \"malformed ids are not found and decide nothing\""},
    # Member9 access tools/cards: each lookup classified by its actual UUID provenance.
    {"platform/access/agent_tools.ex", :get, "~schema", 1, :must_cast,
     "resource/1 guards the raw MCP resource.id with Platform.UUID.valid?/1 before Repo.get on the fixed project/space/canvas/memory-node schema map; malformed ids return not_found"},
    {"platform/access/agent_tools.ex", :platform_uuid_guard, "-", 7, :must_cast,
     "MCP space_id, revoke grant id, operation principal/resource ids, user target id, both role org_id forms and resource.id are checked as booleans before typed queries/context lookups"},
    {"platform/access/effective.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "scope_for/1 checks the agent target id from panel URL or access_explain before Federation.get_runtime; non-UUID values can resolve only through the slug-safe runtime_id query"},
    {"platform/access/impact.ex", :get, "Change", 1, :must_cast,
     "diff/2 receives an undo change id from access_undo and checks Platform.UUID.valid?/1 before Repo.get(Change); malformed ids return not_found"},
    {"platform/access/impact.ex", :get, "Grant", 1, :must_cast,
     "op_target/1 checks the revoke operation id with Platform.UUID.valid?/1 before Repo.get(Grant); malformed ids return not_found"},
    {"platform/access/impact.ex", :platform_uuid_guard, "-", 2, :must_cast,
     "diff/2 guards the undo change id and op_target/1 guards the revoke grant id before their get lookups; both are MCP-reachable values"},
    {"platform/access/proposals.ex", :get, "Canvas", 2, :safe_internal,
     "Both propose clauses receive attrs.canvas_id only from AgentTools.create_card after Chat.create_canvas_with_message returned a persisted Canvas UUID; direct tests likewise use persisted Canvas.id fields"},
    {"platform/access/proposals.ex", :get, "Change", 1, :must_cast,
     "The MCP undo change_id passes Impact.diff/2 and its Platform.UUID.valid?/1 guard before propose reaches Repo.get(Change); a refused or malformed id short-circuits the with"},
    {"platform/access/proposals.ex", :get, "Platform.Agents.Agent", 1, :safe_internal,
     "principal_label/1 reads Grant.principal_id from a successful Grant.changeset cast in prepare_ops, or a persisted ledger Grant snapshot reconstructed by Grant.from_snapshot; both UUID fields are normalized before the lookup"},
    {"platform/access/proposals.ex", :get, "Proposal", 1, :must_cast,
     "valid_get/1 is the MCP proposal-id boundary and checks Platform.UUID.valid?/1 before Repo.get; malformed input returns nil/not_found"},
    {"platform/access/proposals.ex", :get!, "Canvas", 1, :safe_internal,
     "publish_card/2 reads row.canvas_id from the persisted Proposal schema UUID FK, never from action or MCP payloads"},
    {"platform/access/proposals.ex", :get!, "Change", 1, :safe_internal,
     "apply/3 reads change_id only from the successful ledger commit result stored in Proposal.change_id UUID FK"},
    {"platform/access/proposals.ex", :get!, "Proposal", 3, :must_cast,
     "The stale/expired apply arm uses id only after locked!/1 checked Platform.UUID.valid?/1; the other two publish_card calls read row.id from a persisted Proposal UUID PK"},
    {"platform/access/proposals.ex", :get!, "~schema", 1, :safe_internal,
     "factual_label/2 reads resource_id from the validated Grant returned by Grants.prepare_ops or persisted Grant snapshot, and selects its schema from the fixed resource_type map"},
    {"platform/access/proposals.ex", :platform_uuid_guard, "-", 2, :must_cast,
     "valid_get/1 and locked!/1 guard raw proposal ids from MCP or click entry points before Repo.get and the FOR UPDATE Repo.one id predicate"},
    {"platform_web/live/access_live.ex", :get, "Platform.Agents.Agent", 1, :safe_internal,
     "row_label/2 reads principal_id from Changes.list_changes persisted Grant.snapshot ledger rows, whose original Grant.principal_id field is UUID-typed"},
    {"platform_web/live/access_live.ex", :get, "~module", 1, :safe_internal,
     "row_label/2 reads resource_id from persisted Grant.snapshot ledger rows and selects the schema from its fixed resource_type module map; Grant.resource_id is UUID-typed"},
    {"platform_web/live/chat/canvas_hooks.ex", :get_by, "Proposal", 1, :safe_internal,
     "access_card_action/4 uses canvas.id from the Canvas returned by the authorized find lookup; its UUID PK, rather than an id supplied in the action value, binds the proposal query"},
    {"platform/access/agent_wake.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "task 01a1386e-45a5 stage 2: `valid_id?/1` filters the agent ids `denied/3` and `check_agent/4` receive (participant_id values and `%Agent{}` ids today, but both are public API) before they are pinned with `type(^ids, {:array, :binary_id})`, so a non-UUID id is never queried and decides nothing. Used as a BOOLEAN and the string discarded"},
    {"platform/access.ex", :platform_uuid_guard, "-", 2, :must_cast,
     "task 01a1386e-59d1: `holds_role?/3`'s `org_chain/1` checks the caller-supplied `org_id` before `walk_orgs/3`'s `Repo.one`, and `restriction_denied?/3` checks an untyped caller-supplied resource id before querying a canvas or restriction. Both use Platform.UUID.valid?/1 as a BOOLEAN and discard malformed ids; covered by custom_roles_test.exs and space_restrictions_test.exs"},
    {"platform/access/idp_group_roles.ex", :get, "IdpGroupRole", 1, :must_cast,
     "task 01a1386e-59d1 stage 3: `delete/1` takes a raw mapping id through the context API; Platform.UUID.valid?/1 returns {:error, :not_found} before Repo.get for malformed ids"},
    {"platform/access/idp_group_roles.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "guards the raw mapping id accepted by `delete/1` before Repo.get(IdpGroupRole); a malformed id returns {:error, :not_found}"},
    {"platform/access/restrictions.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "task 01a1386e-59d1 stage 2: `restrict_space/3` checks its raw space id before the locked Repo.one query; a malformed id returns {:error, :not_found}"},
    {"platform/access/roles.ex", :get, "Org", 1, :must_cast,
     "task 01a1386e-59d1 stage 1: `create_custom_role/2` takes a raw org id from its caller; guarded by Platform.UUID.valid?/1 (this file's :platform_uuid_guard) and answering the site's `{:error, :org_not_found}`"},
    {"platform/access/roles.ex", :get, "RoleAssignment", 1, :must_cast,
     "task 01a1386e-59d1 stage 1: `unassign/1` takes a raw assignment id; guarded by Platform.UUID.valid?/1 (this file's :platform_uuid_guard) and answering the site's `{:error, :not_found}`; covered by custom_roles_test.exs \"two assignments\" (unassign of a deleted id)"},
    {"platform/access/roles.ex", :get_by, "Role", 1, :safe_internal,
     "task 01a1386e-59d1 stage 1: `get_role/1` looks up by `access_roles.key`, a TEXT column (custom keys are `custom:<uuidv7>`, built-ins `admin`/`member`/`guest`), so no value can raise Ecto.Query.CastError; an unknown key answers nil"},
    {"platform/access/roles.ex", :platform_uuid_guard, "-", 4, :must_cast,
     "task 01a1386e-59d1 stage 1: (1) `create_custom_role/2`'s org id before `get(Org)`; (2) `list_roles/1`'s org id before the custom-role `where: r.org_id == ^org_id`; (3) `unassign/1`'s id before `get(RoleAssignment)`; (4) `principal/1`'s `{:user | :agent, id}` before the membership and agent `exists?` queries. Every failure answers the site's not-found or `{:error, :invalid_principal}`; covered by custom_roles_test.exs \"refuses a non-member, an external member, a built-in role and a missing agent\""},
    {"platform/access/lineage.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "task 01a1386d-e528 stage 2: `typed/1` makes a `{type, id}` resource tuple `:untyped` unless its id is a canonical UUID, so every `Repo.one` in `ancestors/1` and `base_candidates/1` (this file's `@repo_one_counts` entry) sees only valid ids. A tuple can carry a LiveView param or an MCP argument from stage 3 on; covered by precedence_test.exs \"malformed ids are not found and decide nothing\""},
    {"platform/access/task_target.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "task 01a1472d stage 1: `resolve/1` casts every client-supplied target id (a LiveView `phx-value-*` or form param naming a task, project, stack, plan, stage, validation, review item/request, epic, space or org) through Platform.UUID.cast/1 before any query, so the three `Repo.one` walks (this file's `@repo_one_counts` entry) and the `Repo.exists?` checks see only canonical ids; a malformed id is `:not_found`, the same answer as a missing row. Covered by task_target_test.exs \"an invalid UUID, a 16-byte slug, a missing row and an unknown form are :not_found\""},
    {"platform/access/view_as.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "task 01a1386e-30bd stage 4: the agent runtime id comes from `/access/view-as/agent/:id`. The human-readable runtime_id lookup uses a string column; the fallback primary-key lookup runs only when Platform.UUID.valid?/1 accepts the URL segment. A malformed id retains the view-as not-found response rather than raising Ecto.Query.CastError"},
    {"platform/org/wiki/indexer.ex", :get, "WikiJournalEntry", 1, :safe_internal,
     "the indexer re-loads ids it selected from the same table in the enclosing sweep"},
    {"platform/org/wiki/indexer.ex", :get, "WikiPage", 1, :safe_internal,
     "same sweep provenance as the journal-entry lookup above"},
    {"platform/org/wiki/routing.ex", :platform_uuid_guard, "-", 5, :safe_internal,
     "all five namespace/owner casts are Platform.UUID.cast/1, so a 16-character project/space path segment no longer validates as a namespace uuid nor gets compared as an owner id. Fabricated-value family: nothing raised before, which is why an assert_raise test would not have caught it"},
    {"platform/org/wiki/search.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "task 01a08a6e stage 1: `classify_untagged_ids/2` filters semantic-provider `entry_id`s through Platform.UUID.valid?/1 before `where([r], r.id in ^ids)` on three UUID-typed PKs. The ids come from memory-service's /search response, not from a loaded row, and a non-UUID value previously raised Ecto.Query.CastError in bulk_load_pages/2. Covered by `untagged hits with an unknown UUID or a non-UUID id are dropped without crashing` in search_test.exs. Count 1 -> 2 at task 01a1386d-e528 stage 4: `drop_unreadable_pages/2` filters the same provider `entry_id`s through Platform.UUID.valid?/1 before its `where([p], p.id in ^page_ids)` access-scope query, so a non-UUID id is left for hydration to drop exactly as before. Count 2 -> 3 at task 01a1386e-45a5 stage 4: `corpus_hit_ids/2` similarly filters semantic-provider task and message ids before UUID-typed access queries; malformed ids continue to hydration without entering those queries"},
    # ── Push ───────────────────────────────────────────────────────────
    {"platform/push.ex", :get, "Participant", 4, :safe_internal,
     "`participant_id` comes off the recipient list `Chat.list_participants/2` returned for the space being notified. The third call (task 019ffd19) is `subscriptions_for_recipient/1` reading `participant_type` to decide between user-scoped and per-membership device resolution; same provenance as the other two, and the router passes the already-loaded `%Participant{}` so its own path never reaches this clause. Count 3 -> 4 at task 01a10882 stage 2: `apns_user_id/1` reads the same recipient id to decide whether the row is USER-typed (APNs) or not; same provenance, and it is additionally behind its own Platform.UUID.valid?/1 guard (this file's :platform_uuid_guard 1 -> 2)"},
    {"platform/push.ex", :get, "User", 2, :safe_internal,
     "`user_id` is `participant.participant_id` off the `%Participant{}` loaded on the line above, or a recipient id from the same list"},
    {"platform/push.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "task 01a10882 stage 2 (1 -> 2): `apns_user_id/1` guards the participant id before `Repo.get(Participant, _)` so `send_notification/2`, which is public, cannot raise on a malformed recipient id on the APNs leg. task 019ffe52: `anchor_participant_id/1` pins `p.participant_id == ^user_id` on a `:binary_id` column, which raises Ecto.Query.CastError on a malformed binary exactly as Repo.get/2 does. `subscribe_for_user/2` is public API and the id is not derived from a loaded row, so the guard belongs at the query. Today's only caller is ShellLive's `push_subscribed` clause reading `:current_user_id`, which is unvalidated (assigned from `session[\"current_user_id\"]` behind an is_binary/1 check) but unreachable with a malformed value in practice: the shell mount raises earlier on the same id in `Tenancy.visibility/1`. Covered by `subscribe_for_user/2 a malformed user id is refused, not raised on` in push_test.exs"},
    {"platform/push/apns.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "task 01a10882 stage 2: `devices_for_user/1` guards `user_id` with Platform.UUID.valid?/1 before `where: d.user_id == ^user_id` on the `apns_devices.user_id` binary_id column. `deliver_to_user/2` is public; today's callers in `Platform.Push` pass a user id read off a loaded `%User{}`/`%Participant{}` row, so the guard is for the next caller. Count 1 -> 2 with task 01a10db7 stage 1: `voip_devices_for_user/1`, the same guard on the same shape for `apns_voip_devices.user_id`, ahead of `deliver_voip_to_user/2`, which is public"},
    {"platform/push/fcm.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a10d8e stage 1: the FCM twin of apns.ex. `devices_for_user/1` guards `user_id` with Platform.UUID.valid?/1 before `where: d.user_id == ^user_id` on the `fcm_devices.user_id` binary_id column. `deliver_to_user/2` is public; today's callers in `Platform.Push` pass a user id read off a loaded `%User{}`/`%Participant{}` row, so the guard is for the next caller"},
    {"platform/push/relay_server.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a1261e stage 2: `revoke_install/1` guards the install id with Platform.UUID.valid?/1 before `where: i.id == ^id` on `push_relay_installs.id`. The id arrives from an operator's `mix platform.push_relay_install --revoke <id>` argument, a boundary value, so a malformed one answers `{:error, :not_found}` instead of raising"},
    {"platform/push/notification.ex", :get, "Platform.Tasks.Task", 1, :safe_internal,
     "task 01a10882 stage 2: `task_title/2` reads `item.source_id` off an `%Inbox.Item{}` that `Inbox.emit/1` just inserted. `source_id` is an `Ecto.UUID` field cast by `Item.changeset/2`, so it is a canonical UUID by construction. The call also sits inside a rescue that falls back to the inbox title, so an unpersisted item with a bad id degrades to copy, never a raise"},
    # ── Mobile app (task 01a10882) ─────────────────────────────────────
    {"platform/mobile.ex", :get_by, "AppSession", 1, :safe_internal,
     "task 01a10882 stage 1: `verify_bearer/1` looks the session up by `token_hash`, a :binary column holding the SHA-256 of the presented bearer token. No UUID column is pinned, so no client-supplied value can raise Ecto.Query.CastError here"},
    {"platform/mobile/app_entities.ex", :platform_uuid_guard, "-", 5, :safe_internal,
     "task 01a10db6: the iOS App Intents API's entity layer. `fetch_own_approval/2` guards the approve/reject `item_id`, `actor_name/1` guards a generic actor string (user id, agent id, or a label such as \"system:auto\"), `authorize_space/2` guards the space id from a URL path / JSON body, `open_agent_dm/2` guards the `agent_id` from the request body, and `cursor/1` guards the `after` message cursor. Each is used as a BOOLEAN; a malformed id folds into the site's existing {:error, :not_found} / {:error, :forbidden} / {:error, :invalid_cursor} / nil instead of raising Ecto.Query.CastError"},
    {"platform/mobile/app_entities.ex", :get, "Agent", 2, :safe_internal,
     "task 01a10db6: (1) `actor_name/1` calls Repo.get(Agent, actor) inside `if Platform.UUID.valid?(actor)`; (2) `open_agent_dm/2` calls Repo.get(Agent, agent_id) after `is_binary(agent_id) and Platform.UUID.valid?(agent_id)` at the head of the same with-chain, so a malformed request-body id answers {:error, :not_found}"},
    {"platform/mobile/app_people.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a111bb stage 1: `open_dm/2` guards the `:user_id` URL path segment of `POST /api/app/people/:user_id/dm` with `is_binary/1 and Platform.UUID.valid?/1` at the head of its with-chain, before `Accounts.get_user/1` and `Chat.find_or_create_dm/4` see it. Used as a BOOLEAN; a malformed id answers {:error, :not_found} (404) instead of raising Ecto.Query.CastError"},
    {"platform/meetings/call_invites.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "task 01a111bb stage 1: (1) `authorize_ids/2` checks every `invitee_user_ids` element (a JSON body value) with Platform.UUID.valid?/1 before `a.id in ^ids` (Agent) and `Chat.dm_candidates/3`'s `u.id in ^ids`; (2) `authorize_space/2` guards the `invite_space_id` body value before `Chat.get_space/1`. Both are BOOLEAN guards; a malformed id folds into {:error, :forbidden} (403) and nothing is created"},
    {"platform_web/controllers/app_intents_controller.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "task 01a111bb stage 1: `task_assignee/2` guards the `assignee_id` JSON body value of `POST /api/app/tasks` with Platform.UUID.valid?/1 before it reaches `Tasks.create_from_request/2`; a malformed id answers 422 `invalid_assignee` and writes no task"},
    {"platform_web/controllers/app_api_controller.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "task 01a10882 stage 1: `agent_mention/2` guards the share request's `agent_id` (a JSON body value, so boundary-reachable) with Platform.UUID.valid?/1 before pinning `p.participant_id == ^agent_id`; a malformed id answers 422 `unknown_agent` instead of raising"},
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
    {"platform/responsibilities/handlers/agents_goal_heartbeat.ex", :platform_uuid_guard, "-", 2,
     :flagged_sibling_owned,
     "task 01a0ca9f: `resolve_scope/1` guards the space's `metadata[\"goal_project_id\"]` (free-form JSON, so :must_cast) with `Platform.UUID.cast/1` before `Tasks.get_project/1`; a malformed value resolves to `:unknown` and renders the fault clause. 1 -> 2 for task 01a0cef1's `put_goal_scope/2`, whose `raw` is the goal editor's submitted project id (a LiveView `params` value, so :must_cast): it is cast with `Platform.UUID.cast/1` before it is compared against `goal_scope_projects/1`, and a malformed value is refused as `{:error, :unknown_project}`. Under the responsibilities/ sibling prefix, so flagged per that rule"},
    {"platform/responsibilities/janitor.ex", :platform_uuid_guard, "-", 2, :flagged_sibling_owned,
     "task 019fa1ac-6685 stage 3, under the responsibilities/ sibling prefix. (1) `valid_uuid/1` guards `hand_back/3`'s `task_id`, which is the `janitor_hand_back` MCP tool argument (so :must_cast), BEFORE the locked `Repo.one` in `lock_task/1` (this file's `@repo_one_counts` entry); a malformed id returns `{:error, :invalid_task_id}` and opens no transaction. (2) `audit/4` uses `Platform.UUID.valid?/1` as a BOOLEAN on the caller agent id before it becomes `audit_events.actor_id`; the string is discarded when it fails, so the row records no actor rather than raising. Pinned by `janitor_cron_drain_test.exs` (hand-back refusals write nothing)."},
    {"platform/responsibilities/router.ex", :get, "Message", 1, :flagged_sibling_owned,
     "`load_message_with_space_kind/1` takes `message_id` off a responsibility trigger payload; sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/responsibilities/router.ex", :get, "Platform.Chat.Space", 1,
     :flagged_sibling_owned, "sibling-owned router — RECORD, DO NOT EDIT"},
    # ── Roles ──────────────────────────────────────────────────────────
    {"platform/access/agents.ex", :get, "AgentRuntime", 1, :safe_internal,
     "`manage?/2` reads `runtime_id` from an already loaded Agent struct; the primary key was decoded by Ecto before this lookup"},
    {"platform/access/runtime_profiles.ex", :get, "RuntimeProfile", 1, :safe_internal,
     "`get/1` reads the primary key from an already loaded AgentRuntime struct; Ecto decoded it before this lookup"},
    {"platform/roles.ex", :get, "Agent", 1, :safe_internal,
     "All actor-aware assignment and override lookups pass through `get_agent_if_valid/1`, whose Platform.UUID.valid?/1 guard folds malformed caller ids into nil before this UUID primary-key lookup"},
    {"platform/roles.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "`get_agent_if_valid/1` guards the caller-supplied agent id before the sole Repo.get(Agent, id) in this module"},
    {"platform/roles.ex", :get_by, "ResponsibilityOverride", 2, :safe_internal,
     "Both override lookups use `responsibility_key`, a string natural key, rather than a UUID input"},
    {"platform/roles.ex", :get_by, "RoleAssignment", 1, :safe_internal,
     "The assignment lookup uses `role_key`, a string natural key, rather than a UUID input"},
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
    {"platform/tasks.ex", :get, "Plan", 5, :flagged_sibling_owned,
     "`get_plan/1` is MCP-reachable (`tool_surface.ex:5908`) but sibling-owned — RECORD, DO NOT EDIT. Count 1 -> 4 at the ADR-0046 merge, all three from the architecture gate: `:2445` re-reads `plan.id` after `update_all` (off a loaded struct) and `:2486` does the same, but `:2487` — `resolve_plan_for_gate(id) when is_binary(id)` — takes a RAW binary with no `Platform.UUID` guard and no rescue. That one is a genuine :must_cast, kept at :flagged_sibling_owned only because this file belongs to the stack being merged. The gate is reached from `tool_surface.ex` `plan_architecture_verdict`, whose own `verdict_plan/1` casts first and hands over a loaded `%Plan{}`, so the exposed arity is not reachable from THAT tool today — but nothing structural stops a future caller passing a string. Count 4 -> 5 at task 01a05b32 stage 2 (caught by stage 3's first full-suite run — stage 2 exercised focused files only): `replace_plan_stages/3` re-reads `plan.id` INSIDE its `Repo.transaction` so the draft-status precondition is checked against the persisted row rather than the caller's possibly-stale struct. The id comes off a `%Plan{}` the `plan_update` tool layer already resolved through `get_plan/1` — a `plans.id` PK, canonical UUID by construction, the :safe_internal end of this key's range. Classification unchanged; the key stays pinned by the raw-binary `resolve_plan_for_gate/1` clause, its MOST exposed call"},
    {"platform/tasks.ex", :get, "Project", 2, :flagged_sibling_owned,
     "`get_project/1` is MCP-reachable (`tool_surface.ex:3084,7053`) but sibling-owned — RECORD, DO NOT EDIT. Count 1 -> 2 at task 01a08c1e stage 2: `project_policy_fits?/2` reads the project's `config[\"plan_auto_approve\"]` policy inside `auto_approve_via/2`. Its argument is `task.project_id` off a `%Task{}` that `maybe_auto_approve/1` / `retry_lost_deferred_tail/1` just loaded with `Repo.get!/2` — a `projects.id` FK column, canonical UUID by construction, the SAME shape as the `plan.task_id` entries on this file's Task key — and the nil case is matched out by a separate clause before the lookup. Classification unchanged; the key stays pinned by `get_project/1`, its MOST exposed call"},
    {"platform/tasks.ex", :get, "Task", 13, :flagged_sibling_owned,
     "covers `get_task_record/1` (MCP-reachable at eight tool_surface call sites); sibling-owned — RECORD, DO NOT EDIT. Count 11 -> 10 at task 019fb977 stage 4: `maybe_apply_phase_assignee_and_reload/1` is GONE, not merely moved. It existed only to make a SECOND `Repo.update` (the flat phase pointer) visible on the struct the first one returned; folding that write into the status changeset leaves nothing to reload. Its `Repo.get(Task, task.id)` was the `:safe_internal` end of this key's range (id read off a struct `Repo.update/1` had just returned), so removing it cannot change the classification — the key stays pinned by `get_task_record/1`, its MOST exposed call. Count 8 -> 10 at the ADR-0046 merge: `resolve_task_for_planning_step/1` at :689 (`%Task{}.id`, safe) and :690 (raw binary, unguarded — the same :must_cast shape as `resolve_plan_for_gate/1` above, and recorded for the same reason). Count 10 -> 11 at task 019fa605 stage 4: `emit_architecture_gate_opened/1` reads `gated.task_id` off a `%Plan{}` that `open_architecture_gate/2` just returned from `Repo.update/1`, so it is a `tasks.id` FK column and a canonical UUID by construction — the SAME shape as `tasks/architecture_rejection.ex`'s entry below, and the classification is unchanged. It is additionally inside that function's own rescue/catch envelope, which exists precisely so a lookup fault cannot escape into the gate-open path. Count 10 -> 11 at task 019fe1b7 stage 3: `run_architect_edge/1` reads `plan.task_id` off the `%Plan{}` that `Repo.update/1` returned at the top of `submit_plan_for_review/1` — a `tasks.id` FK column, canonical UUID by construction, IDENTICAL in shape to `emit_architecture_gate_opened/1` above and classified the same. It is likewise inside its own rescue envelope, because a lifecycle RECORD must never be able to fail a committed plan submission. Count 11 -> 12 at task 01a00066 stage 5: `dismiss_plan_review_inbox/1` reads the task behind an eager `task_plan_review` inbox clear. Its argument is `plan.task_id` off a `%Plan{}` the approve/reject write just returned — a `tasks.id` FK column, canonical UUID by construction, the SAME shape as the two entries above — and the clause is additionally guarded `when is_binary(task_id)` with a total catch-all beside it, and wrapped in its own rescue/catch envelope because an inbox failure must never fail a plan transition. Classification unchanged; the key stays pinned by `get_task_record/1`, its MOST exposed call. Count 12 -> 13 at task 01a049be: `do_apply_operator_correction/6` — the shared writer behind `reinstate_cancelled_task/3` and `close_as_delivered/3` — reads the task inside its transaction so the status precondition cannot be checked against a stale row. Its `task_id` is a RAW BINARY off the public arity-3 API (`when is_binary(task_id)`), i.e. the :must_cast end of this key's range and the SAME shape as `resolve_task_for_planning_step/1` at :690 — but it is the only entry here reached through a `Platform.UUID.valid?/1` pre-check (see this file's `:platform_uuid_guard` entry for tasks.ex, bumped 1 -> 2 by the same change), which converts a malformed id into `{:error, :not_found}` rather than an `Ecto.Query.CastError`. That matters because these two functions are operator-console entry points where the id is typed or pasted, not read off a struct. Classification unchanged; the key stays pinned by `get_task_record/1`, its MOST exposed call"},
    {"platform/tasks.ex", :get, "Validation", 1, :flagged_sibling_owned,
     "`evaluate_validation/3` — sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/tasks.ex", :get, "~q:Validation", 1, :flagged_sibling_owned,
     "task 01a0acb4 stage 1: `amend_validation_payload/4` reads the row as `Validation |> lock(\"FOR UPDATE\") |> Repo.get(validation_id)` inside its transaction so the kind/plan/status refusals are checked against the locked row. The id is a RAW BINARY that becomes an MCP tool argument in stage 2, so this site is genuinely :must_cast; it is recorded :flagged_sibling_owned only because `sibling_owned?/1` covers this whole PATH. The cast is present: `Platform.UUID.valid?/1` runs first (this file's tasks.ex `:platform_uuid_guard` entry, 2 -> 3) and a malformed id returns `{:error, :not_found}`"},
    {"platform/tasks.ex", :get!, "Task", 3, :flagged_sibling_owned,
     "`plan.task_id` / `updated_plan.task_id` off loaded structs, but sibling-owned — RECORD, DO NOT EDIT. Count 2 -> 3 at task 019fa605 stage 3: `retry_lost_deferred_tail/1` reads `plan.task_id` off a `%Plan{}` that `resolve_plan_for_gate/1` just re-read from the database, so it is a `tasks.id` FK column and a canonical UUID by construction — the SAME shape as the two already recorded, and the classification is unchanged. The caller is a reconcile-tick sweep, not an MCP surface"},
    {"platform/tasks.ex", :get_by, "Project", 1, :flagged_sibling_owned,
     "keyed `slug:` (string column, so not exposed) but sibling-owned — RECORD, DO NOT EDIT"},
    {"platform/tasks.ex", :platform_uuid_guard, "-", 9, :flagged_sibling_owned,
     "classification is :flagged_sibling_owned only because `sibling_owned?/1` covers this whole PATH; the guard itself would be :safe_internal on the reasoning below. Task 019fb977 stage 4: `phase_pointer_attrs/2` folds the flat `assignee_id` pointer into the same changeset as `status`, so the id it reads out of the `phase_assignees` JSONB map is now cast on the STATUS write's path. `Task.validate_phase_assignees/1` (`tasks/task.ex:348`) checks only the phase KEYS, so an MCP `task_update` can persist `%{\"execution\" => %{\"assignee_id\" => \"higgins\"}}` — measured on the pre-fold code, that raised `Ecto.ChangeError` (`:binary_id` is a dump-time type error, so the old second write did NOT fall into `maybe_apply_phase_assignee/1`'s `_error -> :ok` arm) and, on the `in_progress` path, rolled the committed status back out of `transition_with_policy2_freeze/2`'s transaction. `Platform.UUID.valid?/1` is used as a BOOLEAN and the original string is discarded rather than passed on — the pointer is simply left unchanged and the transition still commits, pinned by `tasks_phase_pointer_test.exs` \"a malformed phase assignee id does not block the status transition\". Same strict 36-character check as the `phase_runtime.ex` guard above, which is the READER half of this pair. Count 1 -> 2 at task 01a049be: `apply_operator_correction/6` guards the raw-binary `task_id` its two public callers (`reinstate_cancelled_task/3`, `close_as_delivered/3`) accept, before the `Repo.get(Task, ...)` recorded in this file's `get(Task)` entry. Used as a BOOLEAN and the string is discarded — a malformed id returns `{:error, :not_found}` rather than raising `Ecto.Query.CastError` out of an operator console. Pinned by `operator_correction_test.exs` \"a malformed task id is reported as :not_found, not a cast error\". Count 2 -> 3 at task 01a0acb4 stage 1: `amend_validation_payload/4` guards its raw-binary `validation_id` (an MCP tool argument from stage 2 on, so the :must_cast end) before the locked `Repo.get` recorded in this file's `get(~q:Validation)` entry. Used as a BOOLEAN and the string is discarded — a malformed id returns `{:error, :not_found}` rather than raising `Ecto.Query.CastError`. Pinned by `validation_payload_amend_test.exs` \"a malformed validation id is :not_found and nothing is written\". Count 3 -> 4 at task 019f9b61 stage 2: `plan_task_id/1` guards its `plan_id` before the one-column `Repo.one` (this file's `@repo_one_counts` tasks.ex entry, 6 -> 7). Used as a BOOLEAN and the string is discarded — a malformed id answers nil, which the TaskRouter reads as a foreign task and ignores silently. Pinned by `task_router_non_current_plan_transition_test.exs` \"plan_task_id/1 answers nil for a malformed id\" Count 4 -> 9 at task 01a15ee1 stage 3: the live-project reads behind `Platform.Memory.Insights.ProjectInference`. `project_id_for_task/1` guards its task id, `live_project_ids/2` and `live_project_id_by_slug/2` their org id, and `live_project_in_org?/2` both ids, before the Repo.one / Repo.all / Repo.exists? (this file's `@repo_one_counts` tasks.ex entry, 8 -> 10). The ids are read out of a dreaming agent's insight attributes, so they are agent-reachable; each guard is used as a BOOLEAN, and a malformed id answers nil, [] or false"},
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
     "load_live_task/1 (task 01a1559a stage 1, the task load that used to live in the deleted task-binding module) checks Platform.UUID.valid?/1 on the task_id before the lookup — a raw task_attach_canvas / task_detach_canvas / task_list_canvases MCP tool argument — folding a malformed id into the same {:error, :task_not_found} an absent or soft-deleted row returns"},
    {"platform/tasks/chat_pins.ex", :get_by, "ChatPin", 1, :safe_internal,
     "keyed `task_id:` + `participant_kind:` + `participant_id:`; `get_pin/3` is only reached from `pin/3`, whose ids the mention resolver already matched to rows"},
    {"platform/tasks/context_hydrator.ex", :get, "Task", 1, :safe_internal,
     "load_task/1 checks Platform.UUID.valid?/1 on the run-dispatch task_id, folding a malformed id into the existing {:error, :task_not_found}"},
    {"platform/tasks/deploy_merge_reconciler.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 019fba18 stage 4: `live_gate/1` guards `why_not_live/1`'s `where: v.id == ^id`, whose id is a COMMAND-LINE argument to `mix suite.deploy.scope_gate` — an operator pasting a task id, a truncated uuid or a stage id is the expected failure, not an edge case. The guard is used as a BOOLEAN and the id is downcased rather than replaced by the cast's return, because persisted ids are lowercase and `valid?/1` passes an uppercase uuid. A malformed value folds into `{:error, :malformed_id}` and the mix task renders it as a named refusal with a non-zero exit, pinned by suite_deploy_scope_gate_test.exs \"refuses an id that is not a well-formed uuid, including the 16-byte case\", which first shows the unguarded query raising `Ecto.Query.CastError`"},
    {"platform/tasks/payload_amendment_notice.ex", :get, "Agent", 1, :safe_internal,
     "task 01a0e266 stage 2: `agent_name/1` resolves the amender's display name for the execution-space notice. The id is the `agent_id` element of `Tasks.amend_validation_payload/4`'s actor, which the tool path takes from a loaded `%Agent{}` but which a remote-console caller of the public arity-4 API could hand in raw; so it is reached only through this file's `Platform.UUID.valid?/1` guard (recorded as this file's `:platform_uuid_guard` entry), and a malformed id folds to the `amended_by` label instead of raising. The notice also runs post-commit inside its own rescue, so no lookup fault can change the amend's return value"},
    {"platform/tasks/plan_engine.ex", :get, "Plan", 1, :safe_internal,
     "`stage.plan_id` off the `%Stage{}` the engine just loaded"},
    {"platform/tasks/plan_engine.ex", :get, "Stage", 2, :safe_internal,
     "fetch_stage/1 checks Platform.UUID.valid?/1 on the agent-supplied stage_id from stage_start / stage_complete, folding a malformed id into {:error, :not_found}. 1 -> 2 for task 01a006e7 stage 3's open_remediation_stage/2, which is the SAME class: the gate stage_id reaches it from the router, is guarded by the same Platform.UUID.valid?/1 check, and a miss rolls the transaction back as {:error, :stage_not_found}"},
    {"platform/tasks/plan_engine.ex", :get, "Task", 2, :safe_internal,
     "`plan.task_id` off a loaded `%Plan{}` in both cases"},
    {"platform/tasks/plan_engine.ex", :get!, "Plan", 11, :safe_internal,
     "every call reloads a `plan.id` / `stage.plan_id` the engine holds as a loaded struct; the bang form is deliberate because a missing row here is a broken invariant"},
    {"platform/tasks/plan_engine.ex", :get!, "Stage", 2, :safe_internal,
     "`validation.stage_id` / `updated.stage_id` off a loaded `%Validation{}`"},
    {"platform/tasks/plan_engine.ex", :get!, "Task", 3, :safe_internal,
     "`maybe_inject_deploy_or_complete/1` reads `plan.task_id` off the `%Plan{}` already loaded in the same function, so the id round-trips a value Ecto cast on the way out of the DB. 1 -> 3 for task 01a0665e stage 3: `skip_unevaluated_validations/2` reads `plan.task_id` off a `%Plan{}` it just loaded, and `maybe_lift_to_in_review_for_deploy/2` reloads `task.id` off the `%Task{}` it was handed — same class"},
    {"platform/tasks/plan_engine.ex", :get!, "Validation", 2, :safe_internal,
     "reopen_manual_approval/1 and evaluate_validation/3 both assert Platform.UUID.valid?/1 and raise Ecto.NoResultsError — the bang form's DOCUMENTED miss exception — so one lookup no longer raises two different ways depending on the typo"},
    {"platform/tasks/review_requests.ex", :get, "Agent", 1, :safe_internal,
     "requester_display_name/1's Agent arm now sits behind fetch_agent_for_display/1's Platform.UUID.valid?/1 branch, so only a canonical 36-character id reaches Repo.get; the slug traffic that dominates submitted_by goes to Platform.Agents.SlugLookup.resolve/2 instead (task 01a0e77c: an ambiguous slug is nil, not a raise). Stage 5 of task 019fa129 also deleted the bare `rescue _` that had been masking the raise"},
    {"platform/tasks/review_requests.ex", :get, "ReviewItem", 1, :safe_internal,
     "fetch_item/1 checks Platform.UUID.valid?/1 on the phx-value- item_id from the review-approval event"},
    {"platform/tasks/review_requests.ex", :get, "ReviewRequest", 2, :safe_internal,
     "get_review_request/1 checks Platform.UUID.valid?/1 on the phx-value- id from the review UI, returning nil. Count 1 -> 2 at task 019fed8d stage 3: `ensure_request_actionable/1` reads `review_request_id` off a `%ReviewItem{}` that `fetch_item/1` just loaded, so it is a `review_requests.id` FK column and a canonical UUID by construction — Ecto cast it on the way out of the database, and the untrusted `phx-value-` item_id upstream is already guarded by `fetch_item/1`'s own Platform.UUID.valid?/1 check. The key's classification is set by its MOST exposed call and that is still the guarded `get_review_request/1` arm, so :safe_internal is unchanged"},
    {"platform/tasks/review_requests.ex", :get, "Validation", 1, :safe_internal,
     "the single remaining site is maybe_reopen_manual_approval/1's guarded arm, which checks Platform.UUID.valid?/1 on validation_id before Repo.get and keeps its :ok fallthrough, so an unparseable id never reaches the database. Count 2 -> 1 at task 01a006f6 stage 3: the second site was `carry_prior_rulings/2`, retired when the prior_rulings archive merge moved into PlanEngine.evaluate_validation/2 — the engine now reads the archive off the validation struct it has already loaded, so ReviewRequests no longer re-fetches the row to re-attach it and the guarantee no longer depends on this caller"},
    {"platform/tasks/stacks.ex", :get, "Stack", 19, :safe_internal,
     "Stacks.get_stack/1 checks Platform.UUID.valid?/1, so the seven tool_surface.ex sites that pass a raw stack_id tool argument return nil; the remaining calls reload ids off loaded structs. Count 17 -> 19 across two concurrent tasks, one site each. Task 01a05392 stage 1: `do_start_stack_cascade/1` re-reads the stack after the synchronous rollup-branch ensure so the cascade sees the `rollup_branch_ready` stamp the ensure just wrote; classification unchanged — the id comes off the `%Stack{}` struct the caller already loaded, never off a tool argument. Task 01a05393 stage 4: `clear_conflict/2`'s struct arm re-reads the row by `stack.id` off the `%Stack{}` it was handed (a loaded row, so a canonical UUID by construction); its id arm goes through the guarded `get_stack/1` rather than adding a bare lookup, so the raw `stack_id` a tool could hand it never reaches the Repo unguarded"},
    {"platform/tasks/stacks.ex", :get, "Task", 5, :safe_internal,
     "all five read a member `task_id` off a `stack.members` / `%Task{}` row already loaded in the same function"},
    {"platform/tasks/stacks.ex", :get!, "Stack", 2, :safe_internal,
     "get_stack!/1 checks Platform.UUID.valid?/1 and raises Ecto.NoResultsError — its documented miss exception — rather than Ecto.Query.CastError"},
    {"platform/tasks/stacks/commencement_gate.ex", :get, "Stack", 1, :safe_internal,
     "`open?/1` is only called with a `stack_id` `Stacks` already resolved to a `%Stack{}`"},
    # ── Tenancy ────────────────────────────────────────────────────────
    {"platform/tenancy.ex", :platform_uuid_guard, "-", 4, :safe_internal,
     "uuid?/1 in member_of?/2 is now Platform.UUID.valid?/1, so a 16-character org slug takes the slug branch instead of being pinned as ^org_id against Org's strict UUIDv7 key; plus the get_org/1 and get_org!/1 guards, plus live_orgs_by_id/1 (task 019ff7ff stage 3), which filters ids read out of audit metadata through Platform.UUID.valid?/1 before pinning them with `o.id in ^valid` — a junk id folds into an absent map key, not a cast error"},
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
    {"platform/vault/shared.ex", :platform_uuid_guard, "-", 2, :must_cast,
     "task 01a131c5 stage 1. `cast_agent_ids/1` and `cast_uuid/1` cast the agent ids and the credential id that `/admin/vault` LiveView params will carry (stage 2) with Platform.UUID.cast/1 BEFORE they reach `where: a.id in ^ids` or `shared_credential/1`'s `Repo.one`; a malformed agent id returns `{:error, :unknown_agent}` and a malformed credential id `{:error, :not_found}`, writing nothing. Pinned by `shared_test.exs` (unknown agent id writes nothing)."},
    {"platform/vault/tool_handlers.ex", :platform_uuid_guard, "-", 1, :must_cast,
     "task 01a131c5 stage 1. `list/2` casts `context.agent_id` (the MCP caller) with Platform.UUID.cast/1 before it reaches `where: g.grantee_id == ^agent_id`; a nil or malformed id answers an empty list rather than raising. Pinned by `tool_handlers_test.exs` (nil agent id lists nothing)."},
    # ── Web: channels / controllers / plugs ────────────────────────────
    {"platform_web/channels/runtime_channel.ex", :get, "Platform.Agents.Agent", 1, :safe_internal,
     "`runtime.agent_id` off the `%AgentRuntime{}` the channel authenticated at join"},
    {"platform_web/controllers/agent_avatar_controller.ex", :get, "Agent", 1, :must_cast,
     "task 01a00122 stage 1. `id` is the `:id` path segment of `GET /agents/:id/avatar` — the most directly attacker-controlled shape there is, since anyone with a session can type it. Unguarded it raises `Ecto.Query.CastError` against Agent's strict `Platform.Types.UUIDv7` PK, turning `/agents/x/avatar` into a 500. Guarded with `Platform.UUID.valid?/1` in `fetch_avatar_key/1`, returning the site's existing 404; covered by `agent_avatar_controller_test.exs` \"404, not 500, for a non-UUID id\""},
    {"platform_web/controllers/agent_avatar_controller.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "the guard itself, paired with the `:get \"Agent\"` entry above: `Platform.UUID.valid?/1` is used as a BOOLEAN and the original string is passed to `Repo.get/2` unchanged, which is the raise-exposed shape — safe only because `valid?/1` is the strict 36-character check, so a 16-byte binary cannot clear it and reach the strict UUIDv7 PK the way a bare `Ecto.UUID.cast/1` would let it"},
    {"platform_web/controllers/user_avatar_controller.ex", :get, "User", 1, :must_cast,
     "`id` is the `:id` path segment of `GET /api/app/users/:id/avatar`, typed by any app bearer holder. Unguarded it raises `Ecto.Query.CastError` and the route 500s. Guarded with `Platform.UUID.valid?/1` in `app_show/2`, returning the route's existing 404; covered by `app_user_avatar_test.exs` \"an unknown user, and a non-UUID id\""},
    {"platform_web/controllers/user_avatar_controller.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "the guard itself, paired with the `:get \"User\"` entry above: `Platform.UUID.valid?/1` is used as a BOOLEAN and the original string is passed to `Repo.get/2` unchanged, safe only because `valid?/1` is the strict 36-character check, so a 16-byte binary cannot clear it and reach the PK cast the way a bare `Ecto.UUID.cast/1` would let it"},
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
    {"platform_web/live/chat/large_upload_hooks.ex", :get, "Attachment", 1, :must_cast,
     "task 01a120be. `delete_reservation/2` takes the `\"id\"` of the `\"large_upload_cancel\"` LiveView event, a client params value. Guarded by the `Platform.UUID.valid?/1` entry below in the same `with`, so a malformed id falls out of the `with` (nothing deleted) instead of raising `Ecto.Query.CastError`"},
    {"platform_web/live/chat/large_upload_hooks.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "the guard itself, paired with the `:get \"Attachment\"` entry above: used as a BOOLEAN in `delete_reservation/2`'s `with`, the original string then reaches `Repo.get/2` unchanged, safe because `valid?/1` is the strict 36-character check"},
    {"platform_web/live/chat_live.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "valid_uuid?/1 is now Platform.UUID.valid?/1. It gates Chat.get_space/1 on the /chat/:slug URL PATH SEGMENT at :522 and :589, passing the ORIGINAL value, so a 16-character channel slug used to clear the bare cast and raise inside Repo on the mount path"},
    {"platform_web/live/control_center/native_agent_events.ex", :get, "Agent", 2, :must_cast,
     "task 01a10322 stage 4. `agent_id` is the `phx-value-agent_id` of the native Start / Stop / Restart controls, a LiveView params map anyone with a socket can forge. Guarded with `Platform.UUID.valid?/1` in the same `with`, falling into the handler's existing \"not run by this server\" flash instead of raising Ecto.Query.CastError. Stage 6 adds the second call, `with_manageable/3`, behind the same guard: its `agent_id` is the login form's hidden field and the Remove / Recent output controls' `phx-value-agent_id`, just as forgeable"},
    {"platform_web/live/control_center/native_agent_events.ex", :platform_uuid_guard, "-", 2,
     :safe_internal,
     "the guard itself, paired with the `:get \"Agent\"` entry above: `valid?/1` is the strict 36-character check, so the original string passed to `Repo.get/2` cannot be a 16-byte binary that clears a bare cast"},
    {"platform/chat/reply_failure.ex", :get, "Agent", 1, :must_cast,
     "task 01a10322 stage 7. `unanswered/2`'s `agent_id` is, via `notify_pending/1`, the `agent_id` of the agent host's `agent.state` channel payload (and, via `no_response/1`, a watchdog entry built off a loaded `%Agent{}`). Guarded with `Platform.UUID.valid?/1` at the head of the same `with`, falling into its `:none` return instead of raising"},
    {"platform/chat/reply_failure.ex", :get, "Message", 1, :safe_internal,
     "task 01a10322 stage 7. `message_id` is read back from `Dedupe.take_pending/1` or a `Watchdog` entry, whose only writer, `remember_delivery/1`, stores `message.id` off a loaded `%Message{}`"},
    {"platform/chat/reply_failure.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "the guard itself, paired with the `:get \"Agent\"` entry above: `valid?/1` used as a boolean on the original string, safe because it is the strict 36-character check"},
    {"platform_web/components/reply_failure_row.ex", :get, "Agent", 1, :must_cast,
     "task 01a10322 stage 4. `agent_id` is read from a chat message's `metadata`, which `ReplyFailure.notify/2` writes but which any message posted through the chat or MCP surface can also carry. Guarded with `Platform.UUID.valid?/1` in `load_agent/1`, returning nil (the row renders \"This agent\" and no action) instead of raising mid-render"},
    {"platform_web/components/reply_failure_row.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "the guard itself, paired with the `:get \"Agent\"` entry above: `valid?/1` used as a boolean on the original string, safe because it is the strict 36-character check"},
    {"platform_web/live/control_center_live.ex", :get, "Agent", 1, :safe_internal,
     "`selected_agent.id` off the `%Agent{}` already in socket assigns"},
    {"platform_web/live/control_center_live.ex", :get!, "Agent", 1, :safe_internal,
     "`agent.id` off the `%Agent{}` already in socket assigns"},
    {"platform_web/live/org_memory_live/view.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "normalize_page_key/1 uses Platform.UUID.cast/1 and its CAST OUTPUT becomes a page key, so a 16-character LiveView param is now rejected rather than accepted as a namespace uuid. Fabricated-value family: nothing ever raised here"},
    {"platform_web/live/tasks_live.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "the surviving task_id guard uses Platform.UUID.cast/1 and passes the CAST OUTPUT downstream, so it never raised — a 16-character param was hex-encoded into an invented id that silently missed. The strict predicate makes it take the :error branch. The five plan_id guards moved to task_detail_component.ex with the plan events (task 01a008f6 stage 4) and are inventoried below"},
    {"platform_web/live/tasks/task_detail_component.ex", :platform_uuid_guard, "-", 4,
     :safe_internal,
     "the plan_id guards moved here from tasks_live.ex with the plan-approval events (task 01a008f6 stage 4). Each uses Platform.UUID.cast/1 and passes the CAST OUTPUT to Repo.get(Plan, uuid); the classification is unchanged by the move — the ids still arrive as phx-value-plan-id LiveView params and are still cast before the lookup. Three sites rather than six because approve/reject/reject-with-feedback now share one fetch_plan/1. The fourth (task 01a11ec3 stage 4) is promotable_task/1: the detail_promote_from_quarantine phx-value-id is checked with Platform.UUID.valid?/1 before Tasks.get_task_record/1, so a malformed id is \"not found\" rather than a cast raise"},
    {"platform_web/live/tasks/task_detail_component.ex", :get, "Plan", 1, :safe_internal,
     "fetch_plan/1 receives the `{:ok, uuid}` output of the cast above, which is always a well-formed 36-character UUID by construction; the guard itself is Platform.UUID.cast/1, recorded on the `:platform_uuid_guard` key for this file"},

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
    {"platform/chat.ex", :platform_uuid_guard, "-", 19, :safe_internal,
     "guards on get_space/2 (the PR #613 site), get_message/2, get_thread/1, get_canvas/2, get_canvas_with_deleted/2, get_attachment/2, get_agent_participant/2 (both columns), add_agent_participant/3, do_unpin_message/2, resolve_agent/1 and space_for_path_segment/1 (the url-segment resolver, which must NOT treat a 16-character channel slug as a raw binary uuid). Count 12 -> 14 with task 01a00066 stage 1: `message_read_by_user?/2` guards BOTH its message_id and its user_id before the two `Repo.one` reads recorded below. Both arrive from an inbox row's `source_id` / `user_id` columns via the staleness reconciler, so neither is proven to be a uuid at the call site, and the predicate's contract is a boolean — an unguarded bad value would raise Ecto.Query.CastError out of a read whose whole job is to answer false. 14 -> 15 with task 01a07401 stage 2: `cursor_ordered_at/1` guards the keyset cursor id before resolving that row's ordering key, because `before_id` / `after_id` reach `list_messages/2` from the MCP `space_get_messages` tool and from `phx-value-` params. The classification is unchanged — the guard is what keeps it :safe_internal. 15 -> 16 with task 01a0740d stage 1: `canvas_parent_titles/1` filters its batch of `cloned_from` ids through the guard before one `c.id in ^valid_ids` read. This is the first site here where the guard protects an IN list rather than a single `Repo.get`, and the exposure is the same: a malformed member raises Ecto.Query.CastError out of the whole batch, taking the valid ids down with it. The function is public and documents malformed ids as resolving to the `:deleted` marker, so the guard is also the contract, not just a shield. 16 -> 17 with task 01a0ac64 stage 2: `bound_by_history_grant/2`'s binary clause guards the `:as_participant` id before `get_participant/1` resolves the row whose `history_visible_from` bounds an agent's history read. The id arrives as a caller-supplied option on `list_messages/2` — the agent read paths pass a participant id they resolved, but the option is public, so an unguarded bad value would raise Ecto.Query.CastError out of a plain message list. The guard's else branch returns the query UNBOUNDED, matching the clause above it: an unknown id means 'no grant recorded', not 'no history'. 17 -> 19 with task 01a0cbe0 stage 1: `get_space_participant/2` guards BOTH its space_id and its participant id (two calls, one per :binary_id column, mirroring get_agent_participant/2) before its `Repo.get_by`. The participant id is `context.agent_participant_id` on the send_media / react / design_critique_request write paths, verified here against the target space; a malformed value returns nil, which those paths refuse with `space_write_denied/1`"},
    {"platform/chat/attachments/tool_handlers.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "finalize_pending/2's guard on the attachment_id supplied by the MCP attachment tool payload"},
    {"platform/deploy/skip_notice.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a0feff stage 2: `space_exists?/1` guards the configured DEPLOY_SKIP_NOTICE_SPACE_ID before `Repo.exists?` on chat_spaces. The value is operator env, not a request field, but nothing validates it at boot, so a typo must fold into the module's logged {:error, :space_not_found} instead of raising Ecto.Query.CastError inside the GitHub webhook handler. It also gates `already_posted?/3`, whose `m.space_id == ^space_id` runs only after this check passes"},
    {"platform/chat/canvas_access.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "fetch_for_viewer/3's guard on the canvas id taken straight off the /canvases/:id URL path segment — the share-link route's only untrusted input"},
    {"platform/chat/freeze_policy.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "resolve_actor/2's guard on a task assignee_id that is routinely \"system\" or an agent slug"},
    {"platform/chat/sidebar.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "update_section/2's guard on the phx-value- section_id off the sidebar rename/recolor events"},
    {"platform/chat/space_access.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "task 01a01ce0 stage 1 — lookup_participant/3 guards the space_id AND the participant_id before the get_by recorded above. Two calls, one per :binary_id column, because either one being malformed raises. The space_id is the forged phx-value- param this whole module exists to refuse, so a guard that raises instead of denying would convert an authorization refusal into a 500 on a request path"},
    {"platform/external_agents.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "get_external_agent/1 and get_external_agent!/1 — the id:-keyed get_by pair that `git grep \"Repo.get(\"` cannot see"},
    {"platform/feedback/intake.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "configured_project_id/0's predicate (task 01a11ec3 stage 3): the FEEDBACK_INTAKE_PROJECT_ID config value is checked with Platform.UUID.valid?/1 before the Repo.exists? that pins `p.id == ^id`, so a malformed operator value resolves to no configured project instead of raising Ecto.Query.CastError inside webhook intake"},
    {"platform/files.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "get_file/2, get_file!/2 and fetch_extracted_text/1. The last matters most: Files.Text keys on a bare :binary_id, a different symptom from the UUIDv7 schemas"},
    {"platform/files/cataloger.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a0008c stage 2 — `card_path?/2`'s guard on the project_id it is about to INTERPOLATE INTO A REGEX, not into a query. This is the same predicate protecting a different failure mode, which is why it is recorded rather than waved through: `card_path_regex/1` interpolates it into `~r/^project\\/<project_id>\\/page\\/files\\/…/` to decide whether a wiki file_key belongs to this project's card prefix, and the cataloger is a background emitter with NO authorization above it (`Wiki.upsert_page/3` never consults `Wiki.Routing`; the `:historian_required` gate lives at the MCP surface a server-side emitter never crosses). A non-UUID project_id reaching that interpolation makes the gate answer for a pattern nobody wrote — `Regex.escape/1` stops metacharacters, but the guard is what stops a caller-shaped fragment from being treated as a legitimate project scope at all. The module performs no `Repo.get/2` of its own: it reads through `Files.list_catalogable_files/2`, `Files.get_file/1` and `Tasks.get_project/1`, each of which carries its own classified guard"},
    {"platform/files/supersession.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a0008c stage 5 — `rule_claim/3`'s guard on the claimant id it reads out of a card's FRONTMATTER before handing it to `Files.get_file/1`. Frontmatter is a parsed YAML map on a wiki page: the cataloger writes a real `platform_files.id` there, but the same page is writable through `Wiki.upsert_page/3`, which performs no authorization at all, so the value is agent-reachable and cannot be treated as internal. `Files.get_file/1` carries its own classified guard, so this one is belt-and-braces at the boundary rather than the only rail — it is what makes a malformed claimant id return the `{:error, :no_card}` the caller already handles instead of relying on the callee's guard to fold it into a nil this function would then have to re-interpret"},
    {"platform/memory/insights.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "Insights.get/1's guard on the insight id a LiveView or canvas action supplies (task 01a13867 stage 1). 1 -> 2 at task 01a13867 stage 2: `ingest_org_id/1` guards the `project/<id>/` segment of the journal path before `where: p.id == ^project_id` (this file's `@repo_one_counts` entry); a non-UUID segment falls back to the root org"},
    {"platform/memory/insights/briefing_card.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a15587 stage 4: `filed_task_id/1` checks the uuid in a task insight's `artefact_ref` (`\"task:<uuid>\"`) with Platform.UUID.valid?/1 before it is rendered into the briefing's `/tasks/<uuid>` link or handed to `Tasks.get_task_record/1` by `Actions.delete_filed_task/3`. The ref is written by the platform when it files the task, but the column is free text, so a malformed value renders no link and is `{:error, :not_retractable}`, never a CastError"},
    {"platform/memory/insights/briefings.ex", :platform_uuid_guard, "-", 9, :safe_internal,
     "task 01a13867 stage 4: `get_by_canvas/1` checks the canvas id with Platform.UUID.valid?/1 before `Repo.get_by(Briefing, canvas_id: ...)`; the only caller passes a loaded canvas row's id, and the guard keeps any other caller's malformed id a nil rather than a CastError Count 1 -> 9 at task 01a15ee1 stages 4-6: `for_user_on/2` (user id), `get_for_user/2` (briefing id and user id), `list_for_user/2` (each briefing id and the user id), `inbox_row_stale?/2` (an Inbox row's `source_id`), `open_item?/1` and `load_insights/1` (insight ids read out of the briefing's jsonb `items`). Each is used as a filter or boolean, so a malformed id names nothing: nil, an empty map, not stale, or not open, never a CastError"},
    {"platform/memory/insights/actions.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "task 01a15ee1 stages 2 and 5: `execute/4` for a task insight checks the `project_id` / `target` a dreaming agent wrote into the insight's `action` (a missing or malformed one is `{:error, :no_project}`, the pick-a-project prompt), `delete_verdict/3` checks the verdict id a briefing receipt stored before `where: v.id == ^verdict_id` (malformed is :not_found), and `move_filed_task/4` checks the clicked target project id from the InboxLive move picker (malformed is :invalid). All three are used as BOOLEANS ahead of the lookup, so the original string never reaches a `:binary_id` WHERE unchecked"},
    {"platform/memory/insights/parser.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a15ee1 stage 2: `task_project_id/2` lifts a task insight's `target` attribute into `project_id` only when Platform.UUID.valid?/1 holds, and nil otherwise. The attribute is dreaming-agent text, so a slug or prose target never becomes a `project_id` that a later lookup would cast"},
    {"platform/memory/insights/unattended.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a15587 stage 4: `agent/1` checks the agent id with Platform.UUID.valid?/1 before `where: a.id == ^id` (this file's `@repo_one_counts` entry). It takes either `Roles.agent_id_for_role/1`'s uuid column value or the `acting_agent_id` an unattended act stored in the insight's jsonb `pre_image`, which `undo_page_edit_actor/2` / `undo_task_actor/1` read back; a malformed value is no agent, so the undo is `{:error, :unauthorized}`"},
    {"platform/memory/insights/grounding.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "task 01a13867 stage 2: the `task:<uuid>` and `message:<uuid>` source refs and `author_user/1`'s author id are each checked with Platform.UUID.valid?/1 before their `where: x.id == ^id`. The refs are parsed out of a dreaming agent's `source` attribute and the author id is a page's `updated_by` or a journal entry's `authored_by`, so all three are agent-reachable; a malformed id is ungrounded / unresolved, never a CastError"},
    {"platform/memory/insights/routing.ex", :platform_uuid_guard, "-", 3, :safe_internal,
     "task 01a13867 stage 2: `addressee/1` (an agent-written `addressee` attribute or a Reroute input) and `task_sponsor/1` (a `task:<uuid>` source ref) check Platform.UUID.valid?/1 before `where: u.id == ^value` / the task `Repo.one` (this file's `@repo_one_counts` entry); a malformed value falls through to the next rung. Stage 5: `names/1` filters its ids with the same guard before `where: u.id in ^ids`, so a malformed id is left out of the name map"},
    {"platform/memory/insights/tier.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a13867 stage 2: `internal_member?/2` checks the insight's `addressee_user_id` with Platform.UUID.valid?/1 before the membership query; the column is a uuid, but `classify/1` also takes plain maps, so the guard keeps a malformed id a `:needs_call` rather than a CastError"},
    {"platform/orchestration/prompt_templates.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "get_template/1's conservative guard — no in-repo caller pins this id's provenance"},
    {"platform/org/context.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "get_file_by_id/1's guard on a page id supplied by a caller of the memory MCP tools"},
    {"platform/org/preamble_builder.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "experiment_subject/1 (task 01a10a44 stage 2) reads `task.id` off the `%Task{}` ContextAssembler loaded by primary key; the guard only keeps a hand-built map out of the experiments resolver, and a failing id falls back to the surface's control keys"},
    {"platform/skills.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "get_skill/1 and resolve_skills/1. get_skill/1's nil is what routes a slug to the get_by(Skill, slug:) branch, which is designed traffic for skill_get"},
    {"platform/tasks/canvas_attachments.ex", :platform_uuid_guard, "-", 7, :safe_internal,
     "ensure_canvas_attachable/1 on the canvas_attach MCP payload's canvas_id, plus list_canvas_tasks/1 (task 019e2c4b stage 1). The second is the same class: its canvas_id reaches the reverse lookup from the /canvases/:id URL segment via Platform.Chat.CanvasAccess, and `where: a.canvas_id == ^id` raises the SAME CastError a bare Repo.get would, so the guard folds a malformed id into an empty list. Back to 3 at task 01a1559a stage 1: `load_live_task/1` guards the task_id before the gate (the guard had moved to a task-binding module in task 019fb581 stage 3; that module was deleted and the guard came home). 3 -> 7 at task 01a1559a stage 2: `detach_canvas_from_stack/3` guards the raw `stack_detach_canvas` canvas_id before `where: a.canvas_id == ^canvas_id` (a malformed id detaches nothing), `list_stack_canvases/1` and `stack_coverage/2` guard the stack_id a LiveView param will supply (stage 4) before `where: t.stack_id == ^stack_id`, and `stack_coverage/2` guards the canvas_id before its count; each folds a malformed id into the empty answer"},
    {"platform/tasks/context_hydrator.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "load_task/1's guard on the task_id carried by the run-dispatch payload into hydrate_for_run/2"},
    {"platform/tasks/payload_amendment_notice.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "task 01a0e266 stage 2: `agent_name/1`'s guard on the amender's agent_id before the `Repo.get(Agent, _)` recorded above; the actor tuple of the public `Tasks.amend_validation_payload/4` is caller-shaped, so the guard is what makes a malformed id resolve no name rather than raise"},
    {"platform/tasks/pipeline_health.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "agent_activity/1 (task 01a08c1e stage 4): attribution_key/1 folds a non-id `payload->>'reported_by'` (the tool surface writes the literal \"agent\" when its context has no agent_id) into the 'unattributed' row, and agent_names/1 filters the union of those keys and the `phase_assignees->execution->>assignee_id` strings before `where: a.id in ^valid` — the values are JSON strings read off runtime_events and tasks rows, never a boundary-supplied id, and the guard is what keeps a stray non-uuid payload value from raising Ecto.Query.CastError inside the admin page render"},
    {"platform/tasks/plan_engine.ex", :platform_uuid_guard, "-", 4, :safe_internal,
     "fetch_stage/1's guard plus the two get!(Validation) assertions that raise Ecto.NoResultsError instead of Ecto.Query.CastError, plus open_remediation_stage/2's guard on the gate stage_id (task 01a006e7 stage 3), which folds a malformed id into {:error, :stage_not_found} rather than a CastError"},
    {"platform/tasks/review_requests.ex", :platform_uuid_guard, "-", 5, :safe_internal,
     "list_items_for_task/1 (task 01a00570 stage 1) guards the task_id an agent hands the read tool: it lands in a `where: rr.task_id == ^task_id` that would raise the same CastError a bare Repo.get would, so the guard folds a malformed id into an empty list. Plus get_review_request/1, fetch_item/1, maybe_reopen_manual_approval/1 (stage 4) plus fetch_agent_for_display/1 (stage 5). The fourth guard is what let stage 5 DELETE the bare `rescue _` that used to end requester_display_name/1: with both arms total the function cannot raise, so the rescue had nothing left to absorb"},
    {"platform/tasks/stacks.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "get_stack/1 and get_stack!/1, behind seven raw stack_id tool arguments"},
    {"platform_web/controllers/message_controller.ex", :platform_uuid_guard, "-", 1,
     :safe_internal,
     "fetch_message/1's guard on the message id taken straight off the URL path segment"},
    {"platform/federation/tool_surface.ex", :get, "~schema", 1, :safe_internal,
     "the single Repo.get inside get_by_uuid/2, the module's boundary-safe lookup helper: every id reaching it has already passed Platform.UUID.valid?/1. The load_agent/1, plan_approve, stage_complete, agent_home_org/1 and list_org_descendants/1 sites were all rewritten onto it"},
    # ── Prototypes (task 01a1316b-4e46 stage 1, ADR 0057) ─────────────
    {"platform/prototypes.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "get_prototype/1's predicate: the id arrives as a `/proto/:id/...` URL path segment and as the `prototype_id` MCP tool argument, so Platform.UUID.valid?/1 folds a malformed id into the nil (404 / not_found) an unknown id already returns. The second call (task 01a1316b-4e46 stage 2, counted here by 01a1316b-677a) is publisher_names/1's filter on the ids read out of `published_by` jsonb before `where: u.id in ^ids` / `a.id in ^ids`, so a malformed stored id is dropped rather than raising"},
    {"platform/chat/canvas/kinds/prototype.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "validate_prototype_id/1 (task 01a1316b-4e46 stage 2, classified by 01a1316b-677a): the `prototype_id` node prop is agent-written, and the guard refuses a malformed one at validation, so no non-UUID ever reaches Prototypes.frame_view/3. No Repo call in this file"},
    {"platform/chat/canvas/kinds/embed.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "scripted_src/1 (task 01a1316b-677a): `prototype_ref.prototype_id` is stamped by the server, but render does not trust it, so a malformed id renders the unavailable panel instead of a /proto URL. No Repo call in this file; render stays pure"},
    {"platform/prototypes.ex", :get, "Prototype", 1, :safe_internal,
     "the sole Repo.get sits inside get_prototype/1, behind the Platform.UUID.valid?/1 guard counted above; the two entries fail together if either is removed"},
    {"platform/prototypes/tools.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "fetch_space/2's guard on the `space_id` MCP tool argument before Chat.get_space/1; a malformed id answers space_not_found instead of raising"},
    # ── Canvas rooms (task 01a1316b-84fa stage 1) ─────────────────────
    {"platform/chat/canvas_room.ex", :platform_uuid_guard, "-", 2, :safe_internal,
     "(1) validate_key/2 guards the `canvas_id` every public CanvasRoom function takes (stage 2 passes it from a LiveView event's params) before the room's Registry key, its Repo.one on chat_canvas_rooms.canvas_id and Chat.get_canvas/1; a malformed id is {:error, :invalid_canvas_id}. (2) event_row/2 uses it as a BOOLEAN on the actor id before it becomes chat_canvas_room_events.actor_id (a uuid column); a non-UUID actor id is recorded as NULL rather than raising inside the flush transaction"},
    {"platform_web/live/chat/canvas_hooks.ex", :platform_uuid_guard, "-", 1, :safe_internal,
     "room_canvas/2 (task 01a1316b-84fa stage 2) guards the `canvas_id` a `canvas_room_*` LiveView event carries in its params before CanvasAccess.fetch_for_viewer/3; a malformed id folds into {:error, :not_found}, the reply an unknown canvas already gets"}
  ]

  # `Repo.one/1` per file. Counted, not classified: its ids live inside
  # `where:` clauses built by other functions, so attributing one
  # statically needs dataflow the scanner does not do. A count change
  # here is a prompt to triage the new call by hand.
  @repo_one_counts %{
    # 0 → 3 for task 01a114a8 stage 1's attribution ladder in
    # `ToolCallLedger`: stage -> task, plan -> task and execution space ->
    # task. Triaged by hand: each `where:` pins an id that arrives as a tool
    # argument, so each is boundary-reachable, and each reaches the query only
    # through `attribution_hints/1`'s Platform.UUID.valid?/1 filter.
    "platform/federation/tool_call_ledger.ex" => 3,
    # 0 → 1 for `AttentionRouter.mention_names/1`, the agent-name fallback that
    # makes `@[Name]` mention routing key on the PRINCIPAL rather than on the
    # nullable `chat_participants.display_name` cache. Triaged by hand: the
    # `where:` clause DOES pin an id (`a.id == ^agent_id`) and that id arrives
    # from a participant row, so it is boundary-reachable — the call is
    # therefore wrapped in a `Platform.UUID.valid?/1` guard, exactly as this
    # file's guidance requires. A malformed id degrades to "no mention"
    # instead of raising `Ecto.Query.CastError` inside the routing pipeline.
    "platform/chat/attention_router.ex" => 1,
    # 0 → 1 for task 01a07402 stage 3's `CanvasSearchIndex.unindexed_count/1`,
    # the single source of truth for "is this space's canvas body index still
    # partial". Triaged by hand: the `where:` clause DOES pin ids
    # (`c.space_id in ^ids`) and they arrive from the caller's current view
    # rather than from code, so it is boundary-reachable — the list is
    # therefore filtered through `Platform.UUID.valid?/1` first, exactly as
    # this file's guidance requires. A malformed id degrades to "nothing
    # unindexed there" instead of raising `Ecto.Query.CastError` inside a
    # page render.
    "platform/chat/canvas_search_index.ex" => 1,
    # Task 01a0d90f stage 2: 0 -> 2. `get_record/0` and `current_key/0` in
    # InstallIdentity. Triaged by hand: neither `where:` pins an id — one
    # reads the singleton identity row with `limit: 1`, the other filters on
    # `status == "current"`, a string literal — so nothing boundary-reachable
    # can raise Ecto.Query.CastError there.
    "platform/federation/peers/install_identity.ex" => 2,
    # Task 01a0cf21 (Email module). dispatch.ex: 0 → 2 — `recent_count/1`
    # (`account_id` off a locked `%Account{}`) and `lock_draft!/1` (the draft
    # id `fetch_draft/1` already guarded). mailbox.ex: 0 → 6 — three
    # `count(...)` reads and `get_inbound/2` / `inbound_org_id/1` /
    # `fetch_org_project/2`, every pinned id behind Platform.UUID.valid?/1
    # (recorded in @inventory).
    "platform/mail/dispatch.ex" => 2,
    # Task 01a13ba5 stage 1 (mail backfill). mail.ex: 0 -> 1 —
    # `latest_backfill/2`, `where: r.account_id == ^account.id` with the id
    # read off an `%Account{}` struct that `authorize_manage/2` has just
    # re-loaded by PK. inbound/backfill.ex: 0 -> 1 — the folder-cursor read in
    # `import_folder/5`, pinning `account.id` off the same kind of loaded
    # struct and `folder`, a `:string` column that cannot raise a cast error.
    # Neither pins a boundary-supplied id.
    "platform/mail.ex" => 1,
    "platform/mail/inbound/backfill.ex" => 1,
    # Task 01a13ba5 stage 2: 0 -> 1, `InboundAccess.get/2`. Triaged by hand:
    # the `where:` pins `m.id == ^id` (an MCP argument) and
    # `p.participant_id == ^agent_id` (off the caller's context); both are
    # behind Platform.UUID.valid?/1 in the same `with` (recorded in
    # @inventory), so a malformed one is `:not_found`, never a raise.
    "platform/mail/inbound_access.ex" => 1,
    # Task 01a11ec3 stage 2: 0 -> 1, `Feedback.Submission.existing/1`.
    # Triaged by hand: the `where:` pins `r.fingerprint == ^fingerprint`, a
    # `:string` column holding a sha256 hex digest the module computes itself
    # (`fingerprint/1`) from the normalized submission; no caller-supplied id
    # reaches it, and a string column cannot raise Ecto.Query.CastError.
    "platform/feedback/submission.ex" => 1,
    # Task 01a11ec3 stage 3: 0 -> 1, `Feedback.Intake.existing_task/2`.
    # Triaged by hand: the `where:` pins `lower(external_repository_identity)`
    # (a string normalized by Tasks.RepoRef) and `external_issue_number` (an
    # integer guarded positive by `extract_issue/1`); no id is pinned, so
    # nothing boundary-reachable can raise Ecto.Query.CastError there.
    "platform/feedback/intake.ex" => 1,
    # Task 01a0cf21 stage 5. drafts.ex: 0 → 2 — `get/2` and `fetch_draft/1`,
    # each pinning an id behind Platform.UUID.valid?/1 in the same
    # expression (recorded in @inventory).
    "platform/mail/drafts.ex" => 2,
    "platform/mail/mailbox.ex" => 6,
    # Task 01a0cf21 stage 6. outbox.ex: 0 → 1 — `pending_test_pass/1`, whose
    # `stage_id` is read off a `%Delivery{}` row the Outbox just claimed and
    # delivered (a snapshot column `Dispatch.enqueue/3` wrote from the
    # injected deploy stage's PK, validated by `Drafts.create_system/2`).
    "platform/mail/outbox.ex" => 1,
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
    #
    # 11 → 13 for task 01a0008c stage 4's two `sum_corpus_bytes("files", …)`
    # clauses. Triaged by hand: they are the exact complement of the two
    # `sum_corpus_bytes("pages", …)` clauses already counted here — same
    # `org_wiki_pages` source, same `type(^workspace_id, :binary_id)` cast,
    # same `updated_at` cursor filter — differing only by
    # `Wiki.only_card_pages/1` vs `exclude_card_pages/1`, whose subquery
    # pins no id at all (`card_file_key IS NOT NULL` and
    # `deleted_at IS NULL`). No `x.id == ^value` on the path, so no
    # `Ecto.Query.CastError` is reachable from a boundary and no
    # `Platform.UUID.valid?/1` guard applies.
    "platform/agents/historian.ex" => 13,
    # Task 019fa1cc stage 1 — `HistorianAudit.dispatched_message/3` and
    # `count_between/4`. Triaged by hand: neither `where:` clause pins an id.
    # `dispatched_message/3` compares JSONB text extractions against ISO-8601
    # strings rendered from an already-parsed `DateTime` plus a corpus name;
    # `count_between/4` compares a timestamp column against two `DateTime`s.
    # No `x.id == ^value` on either path, so no `Ecto.Query.CastError` is
    # reachable from a boundary and no `Platform.UUID.valid?/1` guard applies.
    #
    # 2 → 4 for task 01a0008c stage 4's `raw_row_count("pages", …)` and
    # `raw_row_count("files", …)`, which stopped sharing `count_between/4`
    # so each could compose its half of the card partition. Triaged by
    # hand: both are `count_between_query/4` — two `DateTime`s against
    # `org_wiki_pages.updated_at` — narrowed by a subquery on
    # `platform_files.card_file_key`, which pins no id either. Same
    # verdict as the two above.
    "platform/agents/historian_audit.ex" => 4,
    "platform/analytics.ex" => 1,
    # 0 → 1 for task 01a0e882 stage 2: `set_cron_cadence/4` locks its row
    # with `Repo.one(... where: r.key == ^key, lock: "FOR UPDATE")`. Triaged
    # by hand: the where clause pins `key`, a `:string` column, not an id,
    # so no value can raise Ecto.Query.CastError; no UUID guard needed.
    "platform/responsibilities.ex" => 1,
    # Task 019fa61c: `task_id_for/1`'s `where: p.id == ^plan_id`, whose plan_id
    # is `stage.plan_id` off a loaded `%Stage{}` — a UUID column read from a
    # persisted row, never a boundary input. Triaged by hand as this map asks:
    # the select is nil-tolerant on purpose, because `after_stage_completed/1`
    # documents that a stage's plan row CAN be gone and a raise there would
    # record nothing at all.
    "platform/architecture/stage_audit.ex" => 1,
    # 17 as of task 01a00910 stage 5: `get_orgless_space_by_slug/1`. Triaged by
    # hand as this map asks. Its `where:` clause pins a SLUG (a URL path
    # segment, i.e. a boundary input) — but it is narrowed by
    # `is_nil(s.org_id)`, which is what makes it safe: it can only ever return
    # a space belonging to NO org, so a slug typed by a member of one org can
    # never surface another org's channel. That narrowing is the whole point of
    # the function existing instead of reusing the unscoped oldest-row branch
    # of `get_space_by_slug/2`; do not relax it.
    # 18 as of task 01a04ad4: `existing_agent_dm/2`, the DM lookup behind
    # `find_or_create_agent_dm/2`. Triaged by hand as this map asks. Its
    # `where:` clause pins TWO ids that originate at a boundary — an MCP
    # `dm_create` call names both the agent and the user — but neither reaches
    # the query as caller input. `find_or_create_agent_dm/2` resolves the agent
    # through `resolve_agent/1` and the user through
    # `Platform.Accounts.get_user/1`, BOTH of which guard with
    # `Platform.UUID.valid?/1` and return nil rather than raising, and the
    # query is then handed `agent.id` and `user.id` read off the loaded rows.
    # A malformed id therefore never reaches Ecto: it is refused one frame
    # earlier as `:agent_not_found` / `:user_not_found`. Keep the resolve-then-
    # query order; passing the raw arguments straight through would make this
    # `:must_cast`.
    #
    # 18 -> 19 for task 01a07401 stage 2's `cursor_ordered_at/1`, which resolves
    # a keyset cursor's own ordering key so `list_messages/2` can page a room
    # that no longer sorts by `id`. Triaged by hand as this map asks: its
    # `where:` clause pins `m.id == ^id`, and that id IS boundary-reachable —
    # `before_id` / `after_id` arrive from the MCP `space_get_messages` tool and
    # from `phx-value-` params — so the call is wrapped in a
    # `Platform.UUID.valid?/1` guard. A malformed cursor returns nil and drops
    # through to the plain `m.id < ^before_id` comparison that path already
    # had, so this lookup adds no failure mode the caller did not already have.
    #
    # 19 -> 20 for task 01a0ca24 stage 3's `latest_agent_message_since/3`,
    # the goal heartbeat's read-back of the leader's last reply. Triaged by
    # hand as this map asks: its `where:` pins `m.space_id == ^space_id` and
    # `m.author_agent_id in ^agent_ids`, and none of those ids arrives from a
    # boundary. Its one caller, `AgentsGoalHeartbeat.prior_claim/3`, passes
    # `space.id` off the `%Space{}` `agents_space/0` loaded and agent ids read
    # off `space.leader_agent_id` and the `%Agent{}` `Roles.assignee_for/1`
    # returned, i.e. column values. A malformed id cannot reach it today; a
    # future boundary caller would need a `Platform.UUID.valid?/1` guard.
    "platform/chat.ex" => 20,
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
    # 0 → 1 for task 01a00910 stage 2's `ensure_default_section/1`. Triaged by
    # hand: the call is `Repo.one(from s in Section, select: max(s.position))`
    # — an aggregate over the whole table with NO `where:` clause at all, so
    # no id of any provenance reaches the query and no `Ecto.Query.CastError`
    # is reachable. No `Platform.UUID.valid?/1` guard applies.
    "platform/chat/sidebar.ex" => 1,
    "platform/deploy/project_files.ex" => 3,
    # Task 01a0cf21 stage 6. deploy/email.ex: 0 → 1 — `test_pass_validation/1`,
    # the same shape as project_files.ex's: `stage_id` is `deploy_stage.id` off
    # the `%Stage{}` `PlanEngine.inject_deploy_stage/4` just created.
    "platform/deploy/email.ex" => 1,
    # 0 → 1 for task 019fe6b9 stage 2's `get_assignment/2` (ADR-0048).
    # Triaged by hand as this map asks: the `where:` clause pins
    # `a.experiment_id == ^experiment_id`, destructured off a loaded
    # `%Experiment{}`, AND `a.subject_id == ^subject_id`, which IS
    # caller-supplied. The second one can arrive malformed, so the call sits
    # behind a `Platform.UUID.valid?/1` guard — recorded as the
    # :platform_uuid_guard entry for this file in @inventory above. Removing
    # the guard fails there and reintroduces the raise here.
    "platform/experiments/assignments.ex" => 1,
    # 0 → 1 for task 019fe6ba stage 2's `last_promoted_at/1`, the cooldown
    # guard's lookup of the most recent `prompt_template_history` row.
    # Triaged by hand as this map asks: the `where:` clause pins
    # `h.template_id == ^template_id`, and that id is read off the
    # `%PromptTemplate{}` struct `fetch_template/1` returned from its own
    # `Repo.get_by(PromptTemplate, slug:)` earlier in the same `with` — so
    # it is a `prompt_templates.id` column value the DB itself produced,
    # not a boundary input. `promote/2` takes an `%Experiment{}` struct and
    # resolves the template by slug from it; no caller-supplied id reaches
    # this predicate, so no `Platform.UUID.valid?/1` guard applies.
    # 1 → 2 for task 01a0d415 stage 2's `check_surface_cooldown/1`: pins
    # surface_key/target (plain strings) and `d.org_id` from a loaded
    # `%Experiment{}` — a value the DB produced, not a boundary input.
    "platform/experiments/promotion.ex" => 2,
    # 0 → 2 for task 01a0d415 stage 2's `Guardrails.for_org/1`: `org_row/1`
    # pins `g.org_id == ^org_id` behind a `Platform.UUID.valid?/1` guard
    # (inventory entry above); `install_row/0` pins nothing (`IS NULL`).
    "platform/experiments/guardrails.ex" => 2,
    # 0 → 1 for task 019fe6b9's `get_variant/2`, the variant-blob read behind
    # `render_template/2`. Triaged by hand as this map asks: neither side of
    # the `where:` clause can raise a cast error. `v.experiment_id ==
    # ^experiment_id` is destructured off a loaded `%Experiment{}` — the row
    # was fetched before the call, so the id is a value the DB itself
    # produced, not one a boundary supplied. `v.slug == ^variant_slug` is a
    # plain string column with no UUID type on either side, and the value
    # comes from an assignment row's `variant_slug`, which is likewise
    # already in the database. No caller-supplied id reaches this predicate,
    # so no `Platform.UUID.valid?/1` guard applies.
    "platform/experiments.ex" => 1,
    # 0 → 2 for task 01a0d415 stage 1's `Surfaces`. Triaged by hand:
    # `latest_default_row/3` pins surface_key/target (plain strings) and
    # `d.org_id == ^org_id`, which is caller-supplied and sits behind a
    # `Platform.UUID.valid?/1` guard (inventory entry above).
    # `variant_resolution/6` pins `v.experiment_id` off a loaded
    # `%Experiment{}` and `v.slug` (a string read from an assignment row) —
    # no boundary id reaches it.
    "platform/experiments/surfaces.ex" => 2,
    # 0 → 1 for task 01a0d415 stage 1's `DispatchPrompt.subject_attributes/1`:
    # pins `t.id == ^task_id` behind a `Platform.UUID.valid?/1` guard
    # (inventory entry above).
    "platform/experiments/surfaces/dispatch_prompt.ex" => 1,
    # 0 → 1 for task 01a0e8b5 stage 5's `OpenQuestionClassifier.subject_attributes/1`:
    # pins `m.id == ^meeting_id` behind a `Platform.UUID.valid?/1` guard
    # (inventory entry above).
    "platform/experiments/surfaces/open_question_classifier.ex" => 1,
    # 0 → 1 for task 01a0d415 stage 3's `MailSource.on_inbound/1`: pins
    # `m.id == ^inbound_id` behind a `Platform.UUID.valid?/1` guard (inventory
    # entry above).
    "platform/experiments/signals/mail_source.ex" => 1,
    "platform/federation.ex" => 1,
    "platform/federation/tool_surface.ex" => 2,
    # 1 → 3 for task 01a091b7 stage 1: `Files.get_by_storage_key/1` and
    # `Files.get_pending_by_storage_key/1`. Triaged by hand: both `where:`
    # clauses pin `f.storage_key == ^key`, a plain string column with no
    # UUID type on either side, so a malformed value cannot raise
    # `Ecto.Query.CastError`; the key itself comes out of an HMAC-verified
    # upload token, not a caller-supplied id. No `Platform.UUID.valid?/1`
    # guard applies.
    "platform/files.ex" => 3,
    # 1 → 2 for task 01a11703. Stage 1: `open_item/2` shares
    # `fetch_owned/2` with `set_timestamp/3` rather than adding a second
    # Repo.one, and that lookup is UUID-guarded (see the inventory entry).
    # Stage 3: `last_dismissed_on_open/2` adds one. Triaged by hand: its
    # `where:` pins only `i.user_id == ^user_id`, and the one caller
    # (`InboxLive.open_undo_toast/2`) passes the mount-time
    # `current_user_id` from the signed session, never a client event, so
    # no `Platform.UUID.valid?/1` guard applies.
    # 2 -> 3 for task 01a15ee1 stage 1: `briefing_row/1` pins
    # `i.user_id` and `i.source_id` to a loaded `%Briefing{}` row's `user_id`
    # and `id` (uuid column values), so no boundary value reaches it.
    "platform/inbox.ex" => 3,
    # Task 019fe1b6 stage 1 — `Runs.next_run_seq/2` and `Runs.run_count/2`.
    # Triaged by hand as this map asks: both `where:` clauses pin
    # `r.task_id == ^task_id` against a `:binary_id` column, so a malformed
    # value WOULD raise `Ecto.Query.CastError`. They are unguarded
    # deliberately. Every caller is the lifecycle pipeline runner, which is
    # invoked from a status transition on a `%Platform.Tasks.Task{}` it has
    # already loaded — the id is a persisted `tasks.id` column value, never a
    # boundary input. Nothing on this member's surface accepts a task id from
    # a user, a webhook or a PubSub payload. A `Platform.UUID.valid?/1` guard
    # here would convert a genuine programmer error into a silent `1` from
    # `next_run_seq/2`, which is worse than a crash: it would reissue a
    # `run_seq` that already exists and make one firing look like two.
    "platform/lifecycle/runs.ex" => 2,
    # 9 → 11 across two independent additions, both triaged by hand as this
    # map asks. The count is the SUM of both sides of this stack's rollup
    # merge, not either side's number.
    #
    # (a) task 019fb955-1d7b stage 2's `upsert_external_invite/3`.
    # Triaged by hand as this map asks: the `where:` clause is
    # `i.meeting_id == ^meeting.id and i.email == ^address and
    # is_nil(i.user_id)`. `meeting.id` is destructured off the `%Meeting{}`
    # the caller passed, so it is a persisted `meetings.id` column value,
    # not a boundary input. `address` is a boundary value (the host typed
    # it) but is pinned against `meeting_invites.email`, a `:string`
    # column — casting a binary to `:string` cannot fail. No `x.id ==
    # ^value` against a `:binary_id` on the path, so no
    # `Ecto.Query.CastError` is reachable and no `Platform.UUID.valid?/1`
    # guard applies. The call exists because no unique index covers
    # `[meeting_id, email]` for `user_id`-NULL rows (the one on the table
    # is partial on `user_id IS NOT NULL`), so dedupe must be a lookup.
    #
    # (b) task 019fbaac stage 1 — `intent_muted?/1`. Its `where:` clause DOES
    # pin `m.id == ^meeting_id`, and the id DOES arrive from a boundary — the
    # `meeting:transcript_chunk` PubSub payload, where it is nil whenever the
    # chunk's space has no meeting. So this one needs the guard and has it:
    # the call sits inside `if Platform.UUID.valid?(meeting_id)`, which is why
    # the `:platform_uuid_guard` count for this file moved by one in the same
    # change. Without it the nil case raises ArgumentError out of the query
    # builder and a 16-byte binary raises Ecto.Query.CastError, both from the
    # singleton IntentClassifier GenServer that classifies for every room on
    # the node.
    # 11 -> 12 with task 019fcfcf stage 1: `lock_whiteboard/1`, the
    # `SELECT ... FOR UPDATE` inside `upsert_whiteboard_scene/4`'s
    # transaction. Its `where: w.meeting_id == ^meeting_id` pins a uuid
    # column, and `meeting_id` reaches the public function from a
    # column. It is unguarded deliberately: the id is `%Meeting{}.id`
    # off the row the caller already loaded to be drawing on it — a save
    # cannot be addressed to a meeting the saver has not opened — and
    # the head guards `is_binary(meeting_id)`. The READ path
    # (`get_whiteboard/1`) takes the opposite call because it IS handed
    # unresolved ids, and guards with `Platform.UUID.valid?/1`.
    # 12 -> 14 with task 019ff6f3 stage 1: `room_has_segments?/1` and
    # `get_summarizable_transcript_for_room/1`. Neither pins an id column —
    # both filter on `where: t.room_id == ^room_id`, and `room_id` is a
    # `:string` field (the LiveKit room name), not a uuid. A malformed value
    # therefore returns no rows rather than raising Ecto.Query.CastError, so
    # no `Platform.UUID.valid?/1` guard applies. Both heads guard
    # `is_binary(room_id)`.
    #
    # 14 -> 15 with task 01a0740d-e5ce-7001-812e-aa79a5392aed stage 1:
    # `live_recording_for_room/1`. Triaged by hand, and it lands on the
    # OPPOSITE side of the line from the two transcript reads above: its
    # `where:` DOES pin an id column, because `meeting_recordings.room_id` is
    # a `belongs_to(:room)` `:binary_id` FK rather than the `:string` LiveKit
    # room name `meeting_transcripts.room_id` holds. So a malformed binary
    # raises the same Ecto.Query.CastError `Repo.get/2` does, and the call is
    # guarded with `Platform.UUID.valid?/1` (counted in this file's
    # `:platform_uuid_guard` entry for meetings.ex, 18 -> 19 by the same
    # change). A malformed id degrades to "nothing is recording" instead of
    # raising out of the call header's render.
    #
    # 15 -> 17 with task 01a1117f stage 1: `find_active_participant_by_identity/2`
    # and `agent_name_from_participant_row/2`. Triaged by hand: both pin
    # `p.room_id` (a uuid FK) to the `id` of a `%Room{}` already loaded from
    # the database (the caller's room struct, or `get_room_by_name/1`'s
    # result), never to a boundary value. The boundary value they DO take,
    # a LiveKit `identity` string, is compared against
    # `metadata->>'identity'`, a TEXT expression, so a malformed identity
    # matches no row instead of raising Ecto.Query.CastError. No
    # `Platform.UUID.valid?/1` guard applies.
    #
    # 17 -> 18 with task 01a10db7 stage 1: `get_meeting_for_user/2`. Triaged
    # by hand: its `where:` pins `m.id == ^meeting_id`, an id that arrives as
    # the `:id` path segment of `POST /api/app/meetings/:id/join` (boundary-
    # reachable), so the `Repo.one` sits inside `if Platform.UUID.valid?(...)`
    # (the meetings.ex `:platform_uuid_guard` entry, 20 -> 21 by the same
    # change). A malformed id answers {:error, :not_found}.
    "platform/meetings.ex" => 18,
    # Task 019fb954-c848 stage 2 — `Archive.counts/3`, the single aggregate
    # pass behind `search/2`. Triaged by hand as this map asks: its `where:`
    # clauses come from `scoped_query/2`, and TWO of them pin ids that arrive
    # from a boundary — `:project_id` and `:person_id` are read off a LiveView
    # `params` map. Both are therefore guarded by `Platform.UUID.valid?/1`
    # before they reach a `where:`, and a malformed one narrows the query to
    # nothing rather than dropping the filter. The remaining clauses pin no id
    # (`m.status in`) or a value read from a persisted row.
    "platform/meetings/archive.ex" => 1,
    # 0 → 1 for task 01a0740e stage 5's `restorable_stop/1`, the read behind
    # `Candidates.reopen/2` that answers "was this close a stop, and what state
    # did it come from". Triaged by hand as this map asks: the `where:` clause
    # DOES pin an id (`e.candidate_id == ^candidate_id`), and it is nonetheless
    # unreachable from a boundary. `reopen/2` calls `fetch/1` twice before it
    # gets here — once on whatever it was handed, then a SECOND time on the
    # `id` off the struct that came back — and the second `fetch/1` goes
    # through `Candidates.get/1`, which is already `Platform.UUID.valid?/1`
    # guarded (one of this file's seven `:platform_uuid_guard` entries for
    # candidates.ex). So the value pinned here is a uuid Postgres itself
    # returned on a row it selected, never a `phx-value-` payload, and no
    # `Ecto.Query.CastError` is reachable. No further guard applies.
    #
    # 1 → 2 for task 01a0740e stage 1's `fetch_agent_slug/1`, the slug read
    # behind `correct/3`'s `:reassign`. Triaged by hand: the `where:` clause
    # DOES pin an id (`a.id == ^agent_id`) and that id is boundary-reachable —
    # it arrives as `opts[:agent_id]` from the correction panel's
    # `phx-value-` payload, which is the same provenance as the candidate id
    # in the entry above. It is therefore passed through `uuid_or_nil/1`
    # (`Platform.UUID.valid?/1`, one of the seven guard sites already recorded
    # for this file) BEFORE the query, and a value that fails it is refused as
    # `{:error, :no_agent}` rather than reaching a `:binary_id` WHERE. The
    # lookup is deliberately `Repo.one` over a `where` rather than a
    # `Repo.get`: an agent id naming no row must answer `{:error,
    # :unknown_agent}` so the correction corpus cannot record an exemplar
    # routing to an agent that does not exist.
    "platform/meetings/candidates.ex" => 2,
    "platform/meetings/intent_corrections.ex" => 1,
    # Task 019fb955 stage 2 — `SenderSeed.get/0`. Triaged by hand as this map
    # asks: the `where:` clause is `a.slug == ^@slug and is_nil(a.workspace_id)`,
    # where `@slug` is the compile-time constant `"meetings"`. No id is pinned
    # and no value on the clause originates at a boundary, so no
    # `Ecto.Query.CastError` is reachable and no `Platform.UUID.valid?/1` guard
    # applies. Nil-tolerant on purpose: "not seeded yet" is the expected state
    # whenever `MEETINGS_ENABLED` is unset.
    "platform/meetings/sender_seed.ex" => 1,
    # Task 01a10db7 stage 2 — `Ringing.get_ring_for_user/2`. Triaged by hand:
    # the `where:` pins `r.id == ^ring_id` (a URL path segment) and
    # `r.user_id == ^user_id` (the bearer's own loaded `%User{}`), and the
    # call sits inside `with true <- Platform.UUID.valid?(ring_id)`, recorded
    # as this file's `:platform_uuid_guard` entry. A malformed id is a 404.
    "platform/meetings/ringing.ex" => 1,
    "platform/memory_feedback.ex" => 1,
    # Task 01a13867 stage 2. Triaged by hand. insights.ex: `ingest_org_id/1`
    # pins `p.id == ^project_id` behind Platform.UUID.valid?/1 (this file's
    # `:platform_uuid_guard` entry). grounding.ex: `agent_owner/1` pins
    # `r.agent_id`, reached with an id `author_user/1` has already guarded or
    # one read off an `agents.id` row. routing.ex: the email lookup pins a
    # lower-cased email and the slug lookup an agent slug (no id, no cast);
    # `task_sponsor/1` pins `t.id` behind Platform.UUID.valid?/1.
    "platform/memory/insights.ex" => 1,
    "platform/memory/insights/grounding.ex" => 1,
    "platform/memory/insights/routing.ex" => 3,
    # Task 01a13867 stage 3. disseminator.ex: `participant/3` pins the DM's
    # `space_id` (a `chat_spaces.id` from `find_or_create_dm/3`), an agent id
    # off `Roles.assignee_for/1`'s `%Agent{}` and a user id from
    # `Digest.select/2` (uuid column values); no boundary input reaches it.
    "platform/memory/insights/disseminator.ex" => 1,
    # Task 01a15587 stage 2. unattended.ex: `historian/0` pins `a.id` to the
    # `role_assignments.agent_id` `Roles.agent_id_for_role/1` returns, a uuid
    # column value, so no boundary input reaches it. (Stage 3 replaced the
    # runtime query with `Federation.get_runtime_for_agent/1`: 2 -> 1.)
    # Stage 4 moved that one query into `agent/1`, shared with the undo
    # actors, behind Platform.UUID.valid?/1 (this file's
    # `:platform_uuid_guard` entry): still 1.
    "platform/memory/insights/unattended.ex" => 1,
    # Task 01a15ee1. actions.ex: `latest_rejection_id/2` pins `v.block_hash`
    # (a string) and `v.actor_id` to the clicking scope's actor id from
    # `Actions.scope_actor_id/1` (a session user or agent id, never a client
    # value). briefings.ex: `put_receipt/3` locks `b.id` read off a
    # `%Briefing{}` that `handle/5` / `undo/3` just loaded. outside.ex:
    # `draft_locked/3` locks `i.id` read off a loaded `%Insight{}`. All are
    # uuid column values, so no Platform.UUID.valid?/1 guard applies.
    "platform/memory/insights/actions.ex" => 1,
    "platform/memory/insights/briefings.ex" => 1,
    "platform/memory/insights/outside.ex" => 1,
    # Task 01a10db6: 0 -> 5 in the iOS App Intents entity layer. Triaged by
    # hand: `fetch_own_approval/2` pins `i.id == ^item_id` behind
    # `Platform.UUID.valid?/1`; `user_participant/2` pins `space.id` off a
    # loaded %Space{} row after `authorize_space/2`'s guard; `pending_plan/1`,
    # `settled_plan_by/1` and `settled_review_by/1` pin a `task_id` read from
    # an `%Inbox.Item{}` whose `source_id` is an `Ecto.UUID` field, or from
    # `review_requests.task_id` via `ReviewRequests.task_id_for_request/1`, so
    # no boundary value reaches those `where:` clauses uncast.
    "platform/mobile/app_entities.ex" => 5,
    "platform/orchestration/context_assembler.ex" => 1,
    # 3 → 4 for task 01a03ed3's `latest_engagement/1`, the durable read of the
    # last engagement the TaskRouter posted into an execution space. Triaged by
    # hand: the `where:` clause DOES pin an id (`m.space_id == ^space_id`), so
    # a malformed value would raise `Ecto.Query.CastError` the same way a bare
    # `Repo.get/2` would. It is NOT boundary-reachable and carries no
    # `Platform.UUID.valid?/1` guard, for the same reason its sibling
    # `list_messages_with_participants/2` in this module does not: the only
    # caller shape is a `space_id` already read off a `chat_spaces` row, via
    # `find_by_task_id/1` or the router's own `state.execution_space_id`.
    # Nothing hands this function a raw path segment or tool argument. If a
    # caller ever does, it needs the guard — and this count is the tripwire
    # that will make somebody look.
    # 0 → 1 for tasks 01a04135 / 01a00915's `last_stage_event_at/3`, which the
    # TaskRouter's live-acked-executor guard uses to ask when a stage was last
    # acked. HAND TRIAGE: the `where:` does pin `e.task_id` as a uuid, and it
    # carries no `Platform.UUID.valid?/1` guard for the same reason its sibling
    # `stage_acked?/2` directly above it does not — the only caller shape is a
    # `task_id` off the router's own `state.task_id` and a `stage_id` read from
    # a `%Stage{}` already loaded from the plan. Nothing hands either one a raw
    # path segment or tool argument. The `stage_id` half is compared as text
    # through `payload->>'stage_id'` and cannot cast-raise at all. If a boundary
    # caller ever appears, it needs the guard — and this count is the tripwire.
    # 1 → 2 for ticket 01a08e86 stage 2's `last_stage_ack/2`, which returns the
    # ack's instant AND its `subagent_id` so the withheld-dispatch notice can
    # name who acked and how long ago. HAND TRIAGE: same query shape and the
    # same two bound values as `last_stage_event_at/3` directly above it — the
    # `where:` pins `e.task_id` as a uuid and compares `stage_id` as text
    # through `payload->>'stage_id'`, which cannot cast-raise. Its only caller
    # is `TaskRouter.live_ack_identity/2`, reached from
    # `suppress_live_acked_executor/3` with `state.task_id` and a `stage.id`
    # read off a `%Stage{}` already loaded from the plan. No boundary caller
    # exists; one would need `Platform.UUID.valid?/1`, and this count is the
    # tripwire that makes somebody look.
    "platform/orchestration.ex" => 2,
    "platform/orchestration/execution_space.ex" => 4,
    # 4 → 5 for task 01a04a8c's `needs_human_hold/3`. Its `where:` pins a
    # `task_id`, a `runtime_id` and a `stage_id`, and all three reach it from
    # `TaskRouter` state — `state.task_id`, `state.assignee.id` resolved by
    # `PhaseRuntime`, and a `stage_id` read off a `%Stage{}` already loaded
    # from the plan. No boundary caller exists, and the router's call site
    # rescues anyway. A boundary caller would need `Platform.UUID.valid?/1`.
    # 5 → 6 for task 01a0665e stage 4's `last_human_release_at/2`, which the
    # same live-acked-executor guard reads through `human_released_since?/3`.
    # HAND TRIAGE: its `where:` pins `task_id` and `stage_id` as uuids, and
    # both arrive the same way `needs_human_hold/3`'s do — `state.task_id`
    # and a `stage.id` off a `%Stage{}` loaded from the plan — inside a guard
    # that rescues and fails open. No boundary caller exists; one would need
    # `Platform.UUID.valid?/1`.
    "platform/orchestration/runtime_supervision.ex" => 6,
    # 0 -> 1 for task 01a136c1 stage 1: `open_stack_deployer_blocked_event?/1`
    # (the unstamped-member sweep's open-blocker check) takes the latest
    # stack_deployer `execution.blocked` time with `select: max(...)`. Triaged
    # by hand: the `where:` clause pins `e.task_id == ^task_id`, and that id is
    # the `id` field of a `%Task{}` the sweep's own query just loaded (a
    # `Platform.Types.UUIDv7` primary key), never a boundary value.
    "platform/orchestration/task_router_watcher.ex" => 1,
    "platform/org/context.ex" => 4,
    "platform/org/preamble_builder.ex" => 3,
    "platform/org/tenants_summary.ex" => 2,
    "platform/org/wiki.ex" => 5,
    # 0 → 2 for task 01a1386d-e528 stage 1's `Platform.Org.Wiki.Nodes`:
    # `current/2` pins `p.path == ^path` (a string column, no UUID type) and
    # `org_of/2` pins `r.id == ^id` only behind Platform.UUID.valid?/1 (this
    # file's :platform_uuid_guard entry).
    "platform/org/wiki/nodes.ex" => 2,
    # 3 → 4 for member9: apply_ops tuple_query receives fields from a
    # successfully cast Grant changeset (or a loaded Grant for revoke).
    # 0 → 3 for task 01a1386d-e528 stage 2's `Platform.Access.Grants`: the
    # project, space and canvas lookups of `fetch_resource/2`, each reached
    # only through `resource_fields/1`'s Platform.UUID.valid?/1 check.
    # 4 → 5 for task 01a14721 stage 2: `fetch_resource(:module, id)` pins
    # `o.id == ^id` for a module lock's `{:module, org_id}`, reached only
    # through the same `resource_fields/1` Platform.UUID.valid?/1 check.
    "platform/access/grants.ex" => 5,
    # Member9: participant lookup checks MCP space_id first; runtime.agent_id
    # comes from the loaded AgentRuntime UUID field.
    "platform/access/agent_tools.ex" => 1,
    # Provenance uses org/id UUID fields from a loaded Grant, never params.
    "platform/access/effective.ex" => 1,
    # Memory NodePath lookup receives a Lineage.typed validated resource id
    # or a UUID resource_id from the persisted ledger snapshot.
    "platform/access/impact.ex" => 1,
    # locked!/1 guards the raw proposal id before its FOR UPDATE query.
    "platform/access/proposals.ex" => 1,
    # 0 → 1 for task 01a1386e-59d1 stage 2's channel replacement: the
    # caller's space id is checked by Platform.UUID.valid?/1 before the
    # locked query pins it against chat_spaces.id.
    "platform/access/restrictions.ex" => 1,
    # 0 → 1 for task 01a1386e-59d1 stage 1's `Platform.Access.holds_role?/3`:
    # `walk_orgs/3` pins an org id that is either the caller's id behind
    # `org_chain/1`'s Platform.UUID.valid?/1 guard, or a `parent_org_id` /
    # root-org id read from the Repo. No unguarded caller id reaches it.
    "platform/access.ex" => 1,
    # RBAC member 6 stage 2: project, space, canvas and memory-node org lookups
    # in Delegation.resource_org_id/1. `Changes.commit/4` supplies only
    # Grant.snapshot/1 rows or normalized Grant.tuple_key/1 resources; the
    # human demotion path supplies an org id from a loaded membership.
    # Consequently each typed id is a stored UUID, not a raw boundary string.
    "platform/access/delegation.ex" => 4,
    # 0 → 10 for task 01a1386d-e528 stage 2's `Platform.Access.Lineage`:
    # `ancestors/1` and `base_candidates/1` pin ids that come either from a
    # resource tuple (behind `typed/1`'s Platform.UUID.valid?/1 guard), from a
    # struct loaded from the Repo, or from a UUID column of a row just read
    # (`space_id`, `project_id`). No unguarded caller id reaches them.
    "platform/access/lineage.ex" => 10,
    # Task 01a1472d stage 1: `one/2`, the review-item and the review-request
    # walks. Each `where:` pins an id that `resolve/1` has already passed
    # through Platform.UUID.cast/1, or a UUID column of a row just read.
    "platform/access/task_target.ex" => 3,
    # 0 → 1 for task 019ffe52's `anchor_participant_id/1`, which resolves the
    # `chat_participants` row a user-level push subscription is filed against.
    # Triaged by hand as this map asks: the `where:` clause pins
    # `p.participant_id == ^user_id` on a `:binary_id` column, so it DOES raise
    # the same Ecto.Query.CastError as Repo.get/2 on a malformed binary, and
    # `subscribe_for_user/2` is public API taking that id as an argument rather
    # than reading it off a loaded row. Guarded with `Platform.UUID.valid?/1`
    # accordingly, nil-tolerant for the reason the guard exists: an id that
    # cannot be a UUID resolves no row.
    #
    # Today's caller cannot actually deliver a malformed one. `ShellLive`
    # assigns `:current_user_id` from `session["current_user_id"]` behind
    # nothing but an `is_binary/1` check, but the shell mount raises earlier on
    # the same value inside `Tenancy.visibility/1`, so the crash is reached
    # before push ever runs. The guard is for the next caller.
    "platform/push.ex" => 1,
    # Task 01a1261e stage 2: 0 -> 2, triaged by hand. `revoke_install/1` pins
    # `i.id == ^id` (an operator's mix-task argument) behind
    # Platform.UUID.valid?/1, recorded as this file's :platform_uuid_guard.
    # `verify_credential/1` pins `i.credential_hash == ^digest`, a SHA-256
    # binary computed here on a `:binary` column: no cast, so no CastError is
    # reachable whatever the bearer holds.
    "platform/push/relay_server.ex" => 2,
    # Task 01a1316b-4e46 stage 1 (ADR 0057). Triaged by hand: both pin a
    # prototype id taken off a loaded `%Prototype{}` (the controller, the
    # tools and the purger only call `get_live_version/2` after
    # `get_prototype/1` returned a row; `next_version/1` runs on the row
    # `lock_or_create/3` just locked or inserted) and an integer version the
    # controller has already parsed. No caller-supplied string reaches either
    # where clause.
    # Task 01a1316b-677a stage 1: 2 -> 3, triaged by hand. canvas_prototype/2
    # pins `canvas_id` to the id of a loaded `%Canvas{}` (the canvas server's
    # state, or the row the create Multi just inserted) and `canvas_node_id`,
    # a `:string` column, so no cast and no CastError is reachable.
    "platform/prototypes.ex" => 3,
    # Task 01a1316b-84fa stage 1: 0 -> 1, triaged by hand. `load/2` pins
    # `r.canvas_id` and `r.node_id`; the canvas id passed `validate_key/2`'s
    # Platform.UUID.valid?/1 guard before the room process was started (the
    # only path into `init/1`), and node_id is a text column, so no cast.
    "platform/chat/canvas_room.ex" => 1,
    # Task 01a10882 stage 1: 0 -> 2, triaged by hand. `user_participant/2`
    # pins `p.space_id` and `p.participant_id` to ids read off the `%Space{}`
    # `Chat.get_space/1` returned and the bearer's loaded `%User{}`, so
    # neither is a raw client value. `agent_mention/2` pins the request's
    # `agent_id`, a JSON body value, behind Platform.UUID.valid?/1 (recorded
    # in @inventory).
    "platform_web/controllers/app_api_controller.ex" => 2,
    # Task 01a120be: 0 -> 2, triaged by hand. `settle_chunk/3` and
    # `release_claim/1` re-read the reservation `FOR UPDATE`, pinning
    # `a.id` to the `id` field of the `%Attachment{}` the controller already
    # loaded by `storage_key` (recorded in @inventory), so neither `where:`
    # sees a raw client value.
    "platform_web/controllers/chat_attachment_upload_controller.ex" => 2,
    # ADR-0046 merge: `latest_live_plan/1`, whose `where: p.task_id == ^task_id`
    # pins a UUID column and so raises Ecto.Query.CastError on a malformed id
    # exactly as Repo.get/2 would — the case this map exists to make someone
    # triage by hand. Triaged: the call sits inside this module's `safe/1`
    # rescue, like every lookup in the file, so a bad id degrades an OPTIONAL
    # context slot to nil rather than raising out of the provider.
    "platform/responsibilities/context_providers.ex" => 1,
    # Both are id-free aggregates: `agents_space/0` filters on
    # `goal IS NOT NULL` and `open_task_count/0` on `status NOT IN (...)`.
    # Neither where clause pins an id, boundary-supplied or otherwise, so
    # neither needs a `Platform.UUID.valid?/1` guard.
    "platform/responsibilities/handlers/agents_goal_heartbeat.ex" => 2,
    "platform/responsibilities/handlers/architecture_cron_sweep.ex" => 1,
    # Task 019fa1ac-6685 stage 3: `lock_task/1`'s `where: t.id == ^task_id`
    # pins the `janitor_hand_back` tool's task_id, which `valid_uuid/1`
    # (this file's platform_uuid_guard entry) has already refused if
    # malformed.
    "platform/responsibilities/janitor.ex" => 1,
    "platform/roles.ex" => 2,
    # 6 -> 7 with task 019f9b61 stage 2: `plan_task_id/1`, whose
    # `where: p.id == ^plan_id` pins a UUID column. Its caller is the
    # TaskRouter's `{:stage_transitioned, stage}` clause (`stage.plan_id`, an
    # FK off a board PubSub payload), but the function is public, so it guards
    # with `Platform.UUID.valid?/1` (this file's tasks.ex
    # `:platform_uuid_guard` entry, 3 -> 4) and answers nil for a malformed id.
    #
    # 7 -> 8 for task 01a11ec3 stage 1's `promote_from_quarantine/3`, which
    # re-reads the task `FOR UPDATE` so the trust decision is made against
    # the persisted row. Its `t.id == ^task_id` pins the `id` of a `%Task{}`
    # struct (the function head matches `%Task{id: task_id}` with
    # `is_binary(task_id)`), i.e. a primary key read back from the column,
    # canonical by construction; no boundary string reaches it.
    #
    # 8 -> 10 for task 01a15ee1 stage 3: `project_id_for_task/1` and
    # `live_project_id_by_slug/2` pin a task id and an org id behind
    # Platform.UUID.valid?/1 (this file's tasks.ex `:platform_uuid_guard`
    # entry, 4 -> 9); the slug is a string column, so it is not cast.
    "platform/tasks.ex" => 10,
    # task 01a1559a stage 2: `stack_coverage/2`'s count and
    # `stack_member_count/1`. Both pin `t.stack_id == ^stack_id` (and the
    # first `a.canvas_id == ^canvas_id`); every caller has passed
    # Platform.UUID.valid?/1 on both ids first (the guards counted above).
    "platform/tasks/canvas_attachments.ex" => 2,
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
    # 0 → 1 for `PipelineHealth.instrumented_from/0`, which reads the earliest
    # recorded phase transition so the page can state the date before which
    # nothing can be decomposed. Triaged by hand as this map asks: the query
    # has NO `where:` clause at all — it is `select: min(t.occurred_at)` over
    # the whole table — so no id is pinned, no value crosses a boundary into
    # it, and `Ecto.Query.CastError` is unreachable. No guard applies.
    "platform/tasks/pipeline_health.ex" => 1,
    # 2 → 3 for task 01a006e7's `open_remediation_stage_for/1`, which selects
    # the plan's single remediation stage by name and status. Stage 5 added the
    # call and left this count at 2, so the branch carried a RED boundary test;
    # counted here as part of the same task's remediation. Triaged by hand as
    # this map asks: the `where:` clause pins `s.plan_id == ^plan_id` where
    # `plan_id` is read off a `%Stage{}` the same transaction just fetched by
    # its own guarded id — it is a column value, never a boundary-supplied
    # string — plus a module-attribute name and a literal status list. No
    # boundary value is pinned against an id column, so `Ecto.Query.CastError`
    # is unreachable and no `Platform.UUID.valid?/1` guard applies. The
    # boundary-supplied `gate_stage_id` that reaches the same function IS
    # guarded, one frame up in `open_remediation_stage/2` (see the
    # `:platform_uuid_guard` row for this file).
    "platform/tasks/plan_engine.ex" => 3,
    "platform/tasks/review_requests.ex" => 1,
    "platform/tasks/rollup_webhook_processor.ex" => 1,
    "platform/tasks/stacks.ex" => 4,
    # 1 → 2 for task 019fb955-1d7b stage 2's `get_grant_by_email/1`.
    # Triaged by hand as this map asks: the `where:` clause is
    # `g.email == ^addr` — a boundary-supplied address pinned against a
    # `:string` column, where casting a binary to `:string` cannot fail.
    # No id is pinned, so no `Ecto.Query.CastError` is reachable and no
    # `Platform.UUID.valid?/1` guard applies. It is deliberately NOT the
    # existing `lookup_by_email_or_sub/1`: that one filters
    # `applied_at IS NULL` and is therefore blind to applied rows, which
    # still occupy the `email` unique index (it is not partial on
    # `applied_at`). Branching on the blind one is fail-open.
    "platform/tenancy/external_grants.ex" => 2,
    # 2 → 3 for task 019ffe9d stage 1's `root_org_id/0`, which resolves the
    # single `parent_org_id IS NULL` org so `create_org/2` can parent a new
    # tenant. Triaged by hand as this map asks: the `where:` clause is
    # `is_nil(o.parent_org_id)` — a NULL test over a column, pinning NO id at
    # all, so nothing crosses a boundary into it and `Ecto.Query.CastError` is
    # unreachable. No `Platform.UUID.valid?/1` guard applies. It deliberately
    # does NOT use `get_org_by_slug!("acme")`: resolving the root by slug would
    # both raise on a bare DB and let a rename silently reparent new orgs.
    "platform/tenancy/lifecycle.ex" => 3,
    # 4 → 3 for task 019f9cb8 stage 2: `delete/2` now resolves through
    # `resolve_one_by_slug/2` (a `Repo.all` with `limit(2)`) instead of the
    # private `lookup_by_slug/2`, which wrapped a `limit(1) |> Repo.one()` and
    # picked whichever row the planner reached first on an ambiguous slug.
    # That function is now unused and deleted along with its `Repo.one` call
    # — no `where:` clause survives to triage.
    "platform/vault.ex" => 3,
    # 0 → 1 for task 01a131c5 stage 1: `serve/2`'s `where: c.id ==
    # ^ticket.credential_id` pins an id read off the claimed `%FetchTicket{}`
    # row (a FK column), never a boundary value — no guard needed.
    "platform/vault/fetch.ex" => 1,
    # 0 → 1 for task 01a131c5 stage 1: `shared_credential/1` runs only after
    # `cast_uuid/1` (Platform.UUID.cast/1) in `set_grants/3`.
    "platform/vault/shared.ex" => 1,
    # 1 → 0 for task 019f9cb8 stage 3 Part A: `project_secret/1`'s
    # `limit(1) |> Repo.one()` on `where: p.repo_url == ^repo_url` picked
    # whichever project row Postgres reached first when two projects shared a
    # `repo_url` (no uniqueness constraint on that column), silently offering
    # an arbitrarily-chosen project's `webhook_secret` as a signature
    # candidate. Now `Repo.all/1` on the identical `where:` clause, matched
    # against `[single_row]` — two-or-more collapses to `nil` instead of
    # picking one. No `Platform.UUID.valid?/1` guard is owed: `repo_url` is a
    # `:string` column (`Platform.Tasks.Project.repo_url`), not a UUID-cast
    # id, so the `Ecto.Query.CastError` this map exists to catch cannot occur
    # here regardless of what arrives from the webhook payload.
    "platform/webhooks/github_signature.ex" => 0,
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
    "platform_web/live/shell_live.ex" => 1
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
