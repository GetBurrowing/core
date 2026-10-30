defmodule Platform.Audit.TelemetryHandler do
  @moduledoc """
  Bridges `:telemetry` events to the audit event store.

  Attach once in `Application.start/2`:

      Platform.Audit.TelemetryHandler.attach()

  Any module can emit auditable events via standard telemetry:

      :telemetry.execute(
        [:platform, :auth, :login],
        %{system_time: System.system_time()},
        %{
          actor_id: user.id,
          actor_type: "user",
          action: "success",
          ip_address: "203.0.113.1"
        }
      )

  The handler converts the telemetry event into a persisted `Audit.Event`
  and broadcasts it to PubSub subscribers.
  """

  require Logger

  @handler_id "platform-audit-telemetry"

  @events [
    [:platform, :auth, :login],
    [:platform, :auth, :callback],
    [:platform, :auth, :logout],
    [:platform, :auth, :access_blocked],
    # rbac-external-users M3 stage 3 (task 019f8837) — external admission
    # decisions emitted by `Platform.Accounts.ExternalAdmission` on every
    # login. Persisted here (sync auth path) so each `action: "holding"`
    # row becomes the DURABLE "external login awaiting setup" record the
    # M3 stage-4 recovery queue queries (`ExternalAdmission.awaiting_setup/0`)
    # — no bespoke table. Metadata carries reason/email/external?; actor_id
    # is the user id. `action` is "full" | "holding" | "recovered".
    [:platform, :auth, :external_admission],
    # Stage 3 of task 019e41a9 — emitted by
    # `Platform.Tenancy.promote_to_admin/2` and `revoke_admin/2`.
    [:platform, :tenancy, :role_change],
    # Task 019f4eaa stage 3 — org lifecycle. Emitted by
    # `Platform.Tenancy.Lifecycle` (archive/schedule/restore). Metadata
    # carries actor_id, actor_type: "user", resource_type: "org",
    # resource_id + org slug/name; the scheduled event adds
    # retention_deadline. Archive/schedule also cascade-hide child
    # projects + chat_spaces in the same transaction (see that module).
    [:platform, :tenancy, :org_archived],
    [:platform, :tenancy, :org_unarchived],
    [:platform, :tenancy, :org_deletion_scheduled],
    [:platform, :tenancy, :org_deletion_cancelled],
    # Task 019ffe9d stage 1 — org creation. Emitted by
    # `Platform.Tenancy.Lifecycle.create_org/2` after the insert commits.
    # Same org metadata shape as the lifecycle events above. Registration
    # here is load-bearing: an emit with no matching @events entry fails
    # SILENTLY (nothing raises, the audit row simply never appears), which
    # is why `lifecycle_test.exs` pins this row explicitly.
    [:platform, :tenancy, :org_created],
    # Task 019f4eaa stage 3 — project lifecycle (single-row). Emitted by
    # `Platform.Tenancy.Lifecycle` (archive/schedule/restore). Metadata
    # carries actor_id, resource_type: "project", resource_id + project
    # slug/name + org_id; the scheduled event adds retention_deadline.
    [:platform, :tasks, :project_archived],
    [:platform, :tasks, :project_unarchived],
    [:platform, :tasks, :project_deletion_scheduled],
    [:platform, :tasks, :project_deletion_cancelled],
    # Task 019f4eaa stage 4 — retention purge. Emitted by
    # `Platform.Tenancy.ContainerPurger` (actor_type: "system") when a
    # directly-scheduled project OR a project cascade-hidden by a scheduled
    # org is hard-deleted past the retention window. Cascade-hidden chat_spaces
    # reuse `[:platform, :chat, :space_purged]` below. Metadata carries
    # resource_type "project", resource_id, project slug/name, org_id, and
    # archived_cascade_org_id (present only for cascade-hidden children).
    [:platform, :tasks, :project_purged],
    # Task 019f25f2 — auto-approve plan bridging (stage 2 emitters,
    # this bridge added in a corrective patch on top of stage 4).
    # `Platform.Tasks.maybe_auto_approve/1` emits these; metadata carries
    # `resource_type: "plan"` + `resource_id: plan_id` for audit correlation.
    [:platform, :plan, :auto_approved],
    [:platform, :plan, :auto_approve_skipped],
    # Task 01a05b32 stage 1 — the planner's self-service draft rejection.
    # Emitted by `Platform.Federation.ToolSurface.execute("plan_reject", ...)`
    # after `Tasks.reject_plan/3` commits a DRAFT → rejected transition (the
    # tool gates on draft; the human-review and reopen flows keep their
    # existing paths). Metadata carries plan_id, task_id, rejected_by,
    # rejection_reason, plus resource_type "plan" / resource_id / action /
    # actor_type for the Audit.Event columns. Sync (default handle_event
    # clause) so tests can assert the row immediately after the tool call.
    # Registration here is load-bearing: an emit with no matching @events
    # entry fails SILENTLY (nothing raises, the audit row simply never
    # appears).
    [:platform, :tasks, :plan_rejected],
    # Task 01a05b32 stage 2 — the planner's IN-PLACE draft correction.
    # Emitted by `Platform.Federation.ToolSurface.execute("plan_update", ...)`
    # after `Tasks.replace_plan_stages/3` commits the replacement stage tree
    # on a DRAFT (the tool gates on draft via :invalid_transition; a
    # pending_review / approved / completed plan is refused upstream and
    # emits nothing). Metadata carries plan_id, task_id, updated_by, plus a
    # before/after summary (stage count, stage names+positions, validation
    # kinds per stage) so the audit row answers "who changed what", plus
    # resource_type "plan" / resource_id / action / actor_type for the
    # Audit.Event columns. plan_id and version are STABLE across the
    # rewrite — the audit row, not a new plan row, is the record that a
    # correction happened. Sync (default handle_event clause) so tests can
    # assert the row immediately after the tool call. Registration here is
    # load-bearing: an emit with no matching @events entry fails SILENTLY.
    [:platform, :tasks, :plan_updated],
    # Task 01a0acb4 stage 1 — the in-place correction of ONE e2e_behavior
    # validation's evaluation_payload on an approved/executing plan. Emitted
    # by `Platform.Tasks.amend_validation_payload/4` after its transaction
    # commits. Metadata carries validation_id, stage_id, plan_id, task_id,
    # amended_by, reason and prior_payload, plus resource_type "validation" /
    # resource_id / action / actor_type / actor_id for the Audit.Event
    # columns. `actor_id` is the calling agent's UUID (task 01a0e266 stage 1)
    # and nil on the operator path; `amended_by` (the slug or operator label)
    # stays in metadata beside it, because actor_id is a UUID column. Sync (default
    # handle_event clause) so the row exists when the call returns. An
    # unregistered emit fails SILENTLY.
    [:platform, :tasks, :validation_payload_amended],
    # Task 01a11ec3 stage 1 — the explicit, attributed promotion of a
    # quarantined external-feedback task to trusted. Emitted by
    # `Platform.Tasks.promote_from_quarantine/3` after the write commits.
    # Metadata carries task_id, origin, trust, external_repository_identity,
    # external_issue_number, actor_type / actor_id and via, plus
    # resource_type "task" / resource_id / action for the Audit.Event
    # columns. Registration here is load-bearing: an emit with no matching
    # @events entry fails SILENTLY and the audit row never appears.
    [:platform, :tasks, :external_feedback_promoted],
    # Task 019e95ea — channel lifecycle. Emitted by `Platform.Chat.archive_space/1,2`
    # and `unarchive_space/2`; metadata carries actor_id (nil for system
    # callers), resource_type: "chat_space", space kind + name.
    [:platform, :chat, :space_archived],
    [:platform, :chat, :space_unarchived],
    # Task 019e95ea stage 3 — scheduled channel deletion. Scheduled/cancelled
    # are emitted by `Platform.Chat.schedule_space_deletion/2` and
    # `cancel_space_deletion/2`; purged by `Platform.Chat.SpacePurger` with
    # actor_type "system" once the retention window elapses.
    [:platform, :chat, :space_deletion_scheduled],
    [:platform, :chat, :space_deletion_cancelled],
    [:platform, :chat, :space_purged],
    # Task 019e2c4b stage 1 — canvas read by a NON-member. Emitted by
    # `Platform.Chat.CanvasAccess.fetch_for_viewer/3` only when the grant is
    # `:task_agent`, `:task_reader` or `:org_reader`; `:member` reads are
    # in-space and are deliberately not audited (they would bury the signal).
    # Metadata carries actor_id (viewer), actor_type "user" OR "agent" —
    # `:task_agent` (task 019fb01b stage 2) is the agent-shaped level, and
    # `Platform.Audit.Event` allows that value (event.ex:39) — resource_type
    # "canvas", resource_id (canvas id), action "read", plus grant + space_id.
    # Sync (default handle_event clause) so tests can assert the row
    # immediately after the call returns.
    [:platform, :chat, :canvas_read],
    # Task 019fb01b stage 5 — the DENIAL half of the line above. Emitted by
    # `Platform.Chat.Canvas.ToolAccess.fetch_for_read/2` on the `:forbidden`
    # branch only, i.e. the MCP canvas tool surface. Metadata carries actor_id +
    # actor_type ("agent"; "user" for the user-shaped context that surface
    # accepts; "anonymous" for a runtime with a nil agent_id), resource_type
    # "canvas", resource_id (canvas id), action "read_denied", surface
    # "mcp_tool", and runtime_id when the context carries one — the last is what
    # makes a run of denials attributable to one caller rather than unrelated
    # mistakes. It is omitted rather than set to nil, because `ensure_json_safe/1`
    # below stringifies atoms and would persist nil as the string "nil".
    #
    # This is the detection control for the existence oracle stage 3 kept on
    # purpose: `:not_found` and `:forbidden` stay distinct, so a forbidden
    # answer confirms an id is real. `:not_found` answers deliberately do NOT
    # emit — a stale task attachment produces one on an honest call — and nor do
    # write denials. Sync (default handle_event clause) so tests can assert the
    # row immediately after the call returns.
    #
    # `[:platform, :federation, :tool_call_denied]` (runtime_channel.ex) does
    # not cover this: it fires when a runtime asks for a tool outside its
    # capability bundle, one level earlier and on a different question.
    [:platform, :chat, :canvas_read_denied],
    # Task 019fb581 stage 1 — task access DENIED. Emitted by
    # `Platform.Tasks.CanvasAttachments.ensure_task_touchable/3` (since task
    # 01a1559a stage 1) on the `{:error, :task_forbidden}` arm only; grants are deliberately not audited (they are the common path
    # and would bury the signal), and a `{:error, :not_found}` emits nothing so
    # the audit stream is not an existence oracle. Metadata carries actor_id,
    # actor_type ("user" | "agent" | "anonymous"), resource_type "task",
    # resource_id (task id), action "denied", plus project_id and the attempted
    # tool name. Since task 01a1559a stage 2 the stack canvas tools emit it
    # too, with resource_type "stack" when the stack itself is refused and
    # "task" naming the refused member otherwise; same metadata. Sync (default
    # handle_event clause) so tests can assert the row
    # immediately after the call returns.
    [:platform, :tasks, :access_denied],
    # Task 019f5bc4 — historian dispatch pipeline audit trail. Emitters at
    # HistorianDispatcher.do_dispatch_windowed/5 + dispatch_one_window/12
    # (landed stage 1). These are the ONLY events routed async (via
    # Platform.TaskSupervisor); all other events above stay inline for
    # backward compat with existing sync test assertions.
    [:platform, :historian, :pass_started],
    [:platform, :historian, :pass_completed],
    [:platform, :historian, :window_dispatched],
    [:platform, :historian, :cursor_advanced],
    [:platform, :historian, :error],
    # Task 019fa1cc stage 4 — the cursor invariant's audit trail.
    # `window_truncated` fires when the digest withheld rows and the cursor
    # was held short of `window_end`; `item_skipped` fires when one row
    # exceeds the whole window budget alone and the sweep steps past it.
    # A skip that is not a queryable row is a silent advance, which is the
    # defect the stage exists to remove.
    [:platform, :historian, :window_truncated],
    [:platform, :historian, :item_skipped],
    # Task 019f5e7d — Historian dispatch-loop diagnostics.
    # `no_op_pass` fires from Higgins's runtime when a dispatch completes
    # with zero curation writes (proxy for the pre-fix "backlog drained"
    # spam). `dispatch_debounced` fires from
    # `Platform.Agents.MeetingHistorianHandler` when a duplicate
    # `{:meeting_ended, _}` broadcast is rejected inside the per-meeting
    # debounce window (see stage 4). Both events sit under the
    # `:agents` namespace because their emit sites live in Agents
    # runtime/handler code rather than the HistorianDispatcher pipeline
    # — the `[:platform, :agents, :historian | _]` handler clause below
    # routes them through the same async persist path.
    # Scope contract: metadata MUST include `workspace_id` or `org_id`
    # (audit rows without a scope are dropped — see scope_check/2).
    [:platform, :agents, :historian, :no_op_pass],
    [:platform, :agents, :historian, :dispatch_debounced],
    # Task 01a0a12e stage 3 — emitted by MeetingHistorianHandler when the
    # meeting-ended curation dispatch is withheld by default (config
    # `:meeting_historian_curation` is not `:dispatch`). Same handler clause
    # and scope contract as `dispatch_debounced`; the emitter carries
    # `org_id` from the meeting's project so the row persists.
    [:platform, :agents, :historian, :meeting_curation_withheld],
    # Task 019f5e0b — meeting-scribe dispatch fallback. Emitted by
    # Platform.Federation.dispatch_scribe_attention/2 (via
    # emit_scribe_dispatch_fallback/3) when the scribe agent can't be
    # resolved to a live runtime or the broadcast fails. Metadata carries
    # agent_id and reason (:empty_prompt | :agent_not_found |
    # :runtime_unresolvable | :broadcast_failed | :endpoint_not_ready).
    #
    # Task 019fb90f stage 2 dropped the optional `broadcast_error` key: the
    # broadcast now happens inside `Platform.Federation.AttentionDispatch`,
    # whose return is a closed set of atoms, and the underlying error term is
    # logged there instead. It was unreachable in practice anyway — the PubSub
    # adapter in use never returns `{:error, _}` from a broadcast.
    [:platform, :meetings, :scribe_dispatch, :assignee_unresolvable],
    # Task 019f5e66 stage 5 — project_files deploy strategy audit trail.
    # Emitted by Platform.Deploy.ProjectFiles.execute/2. The :deployed
    # event carries source_task_id, target_project_id, folder, filename,
    # version_id; :cross_tenant_rejected additionally carries
    # source_workspace_id + target_workspace_id so a reviewer can see
    # which pairing was refused. Both use actor_type: "system".
    [:platform, :deploy, :project_files, :deployed],
    [:platform, :deploy, :project_files, :cross_tenant_rejected],
    # Task 019f6791-c01b stage 3 — alarm_silence MCP tool. Emitted by
    # Platform.Federation.ToolSurface.execute("alarm_silence", ...) after a
    # successful LeaseManager.silence + runtime_event persist. Metadata
    # carries actor_id (runtime_id), actor_type "runtime", resource_type
    # "task", resource_id (task_id), plus stage_id/silenced_until/reason
    # payload. Emitted synchronously (default handle_event/4 clause) so
    # the audit row exists by the time the tool response returns.
    [:platform, :orchestration, :alarm_silence],
    # Task 019f5e2a — meeting triage dispatch fallback. Emitted by
    # Platform.Federation.dispatch_triage_attention/2 when the resolved
    # triage_officer agent has no runtime linked, the broadcast fails, or
    # the endpoint isn't ready. Metadata carries agent_id, reason atom,
    # actor_type: "system", resource_type: "agent", resource_id.
    [:platform, :meetings, :triage_dispatch, :assignee_unresolvable],
    # Task 01a07400 stage 1 — the `meeting_say` trace. Emitted by
    # `Platform.Meetings.SayTelemetry` from three points in
    # `Platform.Meetings`: `say/4` (immediately after the ack subscribe and
    # before the broadcast), `record_agent_say_ack/2` (whatever status the
    # runtime sent, verbatim), and `post_spoken_utterance/2`'s success
    # branch (the chat row committed). All three carry utterance_id,
    # agent_id and room_name; the ack adds `status` metadata plus
    # `latency_ms` / `duration_s` measurements. actor_type "agent",
    # actor_id the agent, resource_type "meeting_utterance", resource_id
    # the utterance_id. Sync (default handle_event clause) — a say is
    # capped at six a minute per agent, so the volume does not warrant the
    # historian's async path, and a test can assert the row immediately.
    # Registration here is load-bearing: an emit with no matching @events
    # entry fails SILENTLY (nothing raises, the audit row simply never
    # appears).
    [:platform, :meetings, :say, :dispatch],
    [:platform, :meetings, :say, :ack],
    [:platform, :meetings, :say, :posted],
    # Task 01a07400 stage 2 — how long after a transcript frame the agent
    # first spoke. Emitted by `Platform.Meetings.TranscriptTelemetry` from
    # `say/4`, at the same instant as `:say, :dispatch` above, and ONLY when
    # that agent had an outstanding frame in the room. Measurement
    # `response_ms`; metadata carries the `segment_id` it was measured from
    # so the number has a referent. actor_type "agent", resource_type
    # "meeting_utterance", resource_id the utterance_id — same shape as the
    # say trace, and the same volume envelope (a say is capped at six a
    # minute per agent), which is why it can share the sync path.
    #
    # `response_ms` is frame-delivery to first say DISPATCH. It is not a
    # first-token time and must not be reported as one: the agent is
    # federated and core observes its actions, never its tokens. See that
    # module's moduledoc.
    #
    # Its sibling `[:platform, :meetings, :transcript, :delivered]` is
    # deliberately absent from this list: it fires per recipient agent per
    # final segment, uncapped, and does not belong in an audit log.
    [:platform, :meetings, :agent, :responded],
    # Task 019f7cb0 stage 2 — file soft-delete lifecycle. Emitted by
    # `Platform.Files.delete_file/2` and `restore_file/2` after the DB
    # write commits. Metadata carries actor_id, actor_type: "user",
    # resource_type: "file", resource_id, project_id, org_id, file_name.
    # Sync (default handle_event clause) so tests can assert the audit
    # row immediately after the call returns.
    [:platform, :files, :file_deleted],
    [:platform, :files, :file_restored],
    # Task 01a06a20 stage 1 — the interactive-code gate. Emitted by
    # `Platform.Files.mark_interactive/2` and `unmark_interactive/2` after
    # the DB write commits. Metadata carries actor_id, actor_type: "user",
    # resource_type: "file", resource_id, project_id, org_id, file_name —
    # same shape as the file_deleted/file_restored pair above. Sync
    # (default handle_event clause) so tests can assert the audit row
    # immediately after the call returns. Registration here is
    # load-bearing: an emit with no matching @events entry fails
    # SILENTLY (nothing raises, the audit row simply never appears).
    [:platform, :files, :file_interactive_marked],
    [:platform, :files, :file_interactive_unmarked],
    # Task 019f7cb0 stage 3 — permanent purge after the retention window.
    # Emitted by `Platform.Files.Purger` (actor_type: "system", actor_id
    # nil — timer purges have no acting user) once a soft-deleted file's
    # bytes + row are permanently erased. Metadata carries resource_type
    # "file", resource_id, project_id, org_id, file_name, storage_key,
    # byte_size, and the stringified deleted_at. Sync (default
    # handle_event clause) so tests can assert the audit row immediately
    # after `sweep/1` returns.
    [:platform, :files, :file_purged],
    # Task 019f921d Gap 3 — commencement-gate anomaly alerting. Emitted by
    # `Platform.Tasks.Stacks.CommencementGate.open?/1` on EVERY gate check
    # (high volume). The handler clause below persists an audit row + warns
    # ONLY on the exact bug signature `open=false AND blocked_by_count=0`
    # ("stack not in_progress but no plan gap" — the state that stranded the
    # Inbox stack in `forming`); benign checks are dropped without a write.
    [:platform, :stacks, :commencement, :gate_check],
    # Task 01a089b3-7f84 stage 1 — transcript failure history. Emitted by
    # `Platform.Meetings.fail_transcript/3` (it always did); it was simply
    # never registered here, so every emit was dropped SILENTLY and
    # `audit_events` held ZERO transcript-failure rows. This registration is
    # LOAD-BEARING for the clear-on-success change in the later stages of
    # this task: once `failure_reason` is cleared on a successful retry, the
    # audit row is the ONLY durable record that the transcript ever failed.
    # Metadata carries resource_type "meeting_transcript", resource_id,
    # action "failed", failure_reason, transcript_id and room_id. Sync
    # (default handle_event clause) so tests can assert the row immediately
    # after `fail_transcript/3` returns; `scope_check/2` falls through to
    # `:ok` for this namespace.
    [:platform, :meetings, :transcription_failed],
    # Task 01a1316b-aab0 stage 2 — one canvas handler invocation (a call or
    # a timer fire), emitted by `Platform.Chat.CanvasRoom` when the run ends
    # or is refused before it starts. Metadata carries canvas_id, node_id,
    # handler, script_sha256 (of the source), caller_type / caller_id,
    # engine, trigger ("call" | "timer"), duration_ms, result (ok | an engine
    # kind | busy | rate_limited | unknown_handler | an op error code) and
    # code (the refusal code, e.g. binding_not_registered), plus
    # resource_type "canvas" / resource_id / action "script_run" / actor_type
    # / actor_id. Never the source, args, state or result. Sync (default
    # handle_event clause). Registration here is load-bearing: an emit with
    # no matching @events entry fails SILENTLY.
    [:platform, :canvas, :script_run],
    # Task 01a1386e-30bd stage 1 — one committed change to the grants table.
    # Emitted by `Platform.Access.Changes` AFTER its transaction commits
    # (grant, deny, revoke, undo, system_repoint). Metadata carries
    # actor_id / actor_type ("user" | "agent" | "system"), resource_type
    # "access_grant_change", resource_id (the change id), action,
    # via_agent_id, bypass, org_id, undoes_change_id and tuple_keys. The
    # ledger row is the undo source; this is its mirror on the platform
    # stream. Sync (default handle_event clause). Registration here is
    # load-bearing: an emit with no matching @events entry fails SILENTLY.
    [:platform, :access, :grant_changed]

    # NOTE: `[:platform, :memory, :proposal_promoted]` is NOT registered
    # here. The since-retired `Platform.Memory.Proposals.queue_promotion/1`
    # (task 019f70e9 stage-8 fix; deleted by task 01a13867 stage 5) recorded that event via `Platform.Audit.record/1`
    # directly so it lands regardless of whether this handler is
    # attached in the caller's runtime — mirrors how
    # `Platform.Memory.MaintenanceSubagent` writes its per-op audit
    # rows (see maintenance_subagent.ex:record_audit/4).
  ]

  @doc """
  Attach the handler to all registered platform telemetry events.

  Idempotent — a duplicate attach is a no-op. `:telemetry` keys handlers
  by `@handler_id`, so the second attach cannot install a second copy; it
  only reports `{:error, :already_exists}`. Normalising that to `:ok`
  removes the reason a test would `detach/0` first, which is what leaked
  a globally-detached handler into the rest of the run (task 019f9d80).
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the handler (useful in tests)."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc "Returns the list of telemetry events this handler is attached to."
  def events, do: @events

  @doc false
  def handle_event([:platform, :historian | _] = event_name, measurements, metadata, config) do
    # Historian dispatch fires at chat-message cadence — a synchronous
    # Repo.insert per event would regress emit latency by ~1-5ms per
    # window. Spawn under Platform.TaskSupervisor (already started in
    # application.ex:50) so :telemetry.execute returns in <100µs.
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      persist_or_skip(event_name, measurements, metadata, config)
    end)

    :ok
  end

  # Task 019f5e7d stage 5 — `[:platform, :agents, :historian, _]` events
  # (no_op_pass, dispatch_debounced) route through the same async persist
  # path as their 3-element cousins. Same emit-latency budget; same
  # scope_check contract.
  def handle_event(
        [:platform, :agents, :historian | _] = event_name,
        measurements,
        metadata,
        config
      ) do
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      persist_or_skip(event_name, measurements, metadata, config)
    end)

    :ok
  end

  # Task 019f921d Gap 3 — the commencement gate_check fires on every
  # `open?/1` call (very high volume), so we must NOT persist a row per
  # check. Persist + warn ONLY on the anomaly signature: the gate is closed
  # (`open == false`) yet there is no plan gap (`blocked_by_count == 0`) —
  # i.e. the stack is not `in_progress` despite every member plan being
  # approved, the precise deadlock that stranded the Inbox stack. All other
  # gate_checks (open, or blocked by a real plan gap) are dropped silently.
  def handle_event(
        [:platform, :stacks, :commencement, :gate_check] = event_name,
        measurements,
        metadata,
        config
      ) do
    open = Map.get(metadata, :open, false)
    blocked_by_count = Map.get(measurements, :blocked_by_count, 0)

    if open == false and blocked_by_count == 0 do
      Logger.warning(
        "[TelemetryHandler] commencement gate_check anomaly: stack=#{inspect(Map.get(metadata, :stack_id))} " <>
          "task=#{inspect(Map.get(metadata, :task_id))} open=false blocked_by_count=0 " <>
          "— stack not in_progress but no plan gap (forming-lockout signature)"
      )

      enriched =
        metadata
        |> Map.put(:resource_type, "stack")
        |> Map.put(:resource_id, Map.get(metadata, :stack_id))
        |> Map.put(:action, "gate_check_anomaly")
        |> Map.put(:actor_type, "system")

      persist_or_skip(event_name, measurements, enriched, config)
    else
      :ok
    end
  end

  # Task 01a089b3-7f84 stage 1 — `[:platform, :meetings, :transcription_failed]`
  # needs the SYNC persist path (tests read the row straight after
  # `fail_transcript/3` returns), but its emitter is uniquely exposed: it is
  # reached from `Summarizer.summarize_async/1`'s `Task.Supervisor` child,
  # which in an `async: true` `PlatformWeb.ConnCase` test borrows the TEST
  # process's sandbox connection and outlives it. When the test process
  # exits, DBConnection tears the connection down and the in-flight
  # `INSERT INTO audit_events` arrives as a process EXIT — and `:telemetry`
  # responds to an exiting handler by DETACHING it for the whole VM. Measured
  # on this branch: one such orphan reddened 7 unrelated audit tests later in
  # the run (the task-access test, CanvasAttachmentsTest, ExternalAdmissionTest,
  # CanvasLiveTest) with zero rows, which reads identically to a missing
  # registration.
  #
  # This clause is deliberately NARROW — one event name, not the general
  # path. `persist_or_skip/4`'s closing comment refuses a blanket
  # `catch :exit` because it would silence a destroyed write on the
  # high-volume historian path; that refusal stands. Here the exit is caught
  # for ONE event and logged at `:error` naming the lost row, so nothing goes
  # quiet — what is prevented is one doomed orphan disarming audit for every
  # test that follows it.
  #
  # The race is TIMING-DEPENDENT: this clause did NOT fire in the run that
  # shipped it. A clean suite is therefore not evidence that this clause is
  # unnecessary — the evidence it is needed is the earlier run in which one
  # orphan detached audit for 7 unrelated tests. Do not delete this as dead
  # code on the strength of a green suite.
  def handle_event(
        [:platform, :meetings, :transcription_failed] = event_name,
        measurements,
        metadata,
        config
      ) do
    persist_or_skip(event_name, measurements, metadata, config)
  catch
    :exit, reason ->
      Logger.error(
        "Audit persist EXITED for platform.meetings.transcription_failed " <>
          "(transcript=#{inspect(Map.get(metadata, :transcript_id))}) — the row is LOST. " <>
          "Reason: #{inspect(reason)}"
      )

      :ok
  end

  def handle_event(event_name, measurements, metadata, config) do
    # Existing sync path — auth, tenancy, plan, chat. Kept synchronous
    # because existing tests call `Audit.list/1` immediately after
    # `:telemetry.execute/3` and expect the row to already exist.
    persist_or_skip(event_name, measurements, metadata, config)
  end

  defp persist_or_skip(event_name, measurements, metadata, _config) do
    case scope_check(event_name, metadata) do
      :ok ->
        attrs = build_attrs(event_name, measurements, metadata)

        case Platform.Audit.record(attrs) do
          {:ok, _event} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "Audit persist failed: #{inspect(changeset.errors)}",
              event: inspect(event_name)
            )
        end

      {:skip, reason} ->
        Logger.warning(
          "[TelemetryHandler] dropped #{Enum.map_join(event_name, ".", &to_string/1)}: #{reason}"
        )
    end

    # Task.Supervisor.start_child callers under Platform.TaskSupervisor rescue
    # DBConnection.OwnershipError because in an `async: true` test the spawned
    # Task is not in the DataCase sandbox owner chain, and Repo raises. See
    # apps/platform/notes/2026-07-06-datacase-cascade-rootcause.md and the
    # regression audit at
    # apps/platform/test/platform/regression/supervised_task_repo_audit_test.exs,
    # which requires this clause of every Platform.TaskSupervisor caller.
    #
    # WHAT THIS CLAUSE DOES **NOT** COVER (task 019f9d80 stage 3, measured —
    # the earlier version of this comment claimed the opposite and that claim
    # is what kept the real route invisible):
    #
    #   In a shared-mode (`async: false`) test the child DOES inherit the
    #   owner's connection, so no OwnershipError is raised — the insert simply
    #   succeeds. The failure there is the owner EXITING first: DBConnection
    #   disconnects the connection and delivers `shutdown:
    #   %DBConnection.ConnectionError{message: "owner #PID<...> exited"}` to
    #   the child as a process **exit**. No `rescue` can catch an exit, so this
    #   clause has never fired for it (0 hits across an instrumented
    #   ordered-pair run; 21 ConnectionErrors in the same run).
    #
    #   That is deliberate and must stay deliberate. Adding `catch :exit` here
    #   would silence a destroyed audit write and a force-reconnected pool
    #   connection. The condition is fixed where it is created instead — the
    #   sandbox owner now waits for these children before releasing its
    #   connection (`Platform.SandboxHelpers`, called from
    #   `Platform.DataCase`), so the orphan does not arise.
  rescue
    DBConnection.OwnershipError ->
      Logger.debug(
        "Audit persist skipped: sandbox owner not shared with spawned Task",
        event: inspect(event_name)
      )

    error ->
      # Telemetry detaches handlers that raise — never let that happen.
      Logger.error(
        "Audit handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}",
        event: inspect(event_name)
      )
  end

  # Historian events with neither workspace_id nor org_id are dropped —
  # they cannot be attributed to a scope for HistorianAudit.recent_for_scope/2
  # lookup (stage 3). Everything else is unconditionally persisted.
  defp scope_check([:platform, :historian | _], metadata),
    do: historian_scope_check(metadata)

  # Same scope contract for the `[:platform, :agents, :historian | _]`
  # namespace introduced in task 019f5e7d stage 5. The emitters
  # (Higgins runtime, MeetingHistorianHandler) MUST populate
  # workspace_id or org_id — for meeting-scope events derive from
  # `project.org_id` before emitting.
  defp scope_check([:platform, :agents, :historian | _], metadata),
    do: historian_scope_check(metadata)

  defp scope_check(_event_name, _metadata), do: :ok

  defp historian_scope_check(metadata) do
    cond do
      is_binary(Map.get(metadata, :workspace_id)) -> :ok
      is_binary(Map.get(metadata, :org_id)) -> :ok
      true -> {:skip, "historian event missing workspace_id and org_id"}
    end
  end

  # -- Internals --

  defp build_attrs(event_name, measurements, metadata) do
    event_type = event_name |> Enum.map_join(".", &Atom.to_string/1)

    %{
      event_type: event_type,
      actor_id: Map.get(metadata, :actor_id),
      actor_type: Map.get(metadata, :actor_type, "system"),
      # ADR 0040: actor_org_id propagates the org owning the actor. NULL for
      # legacy emitters and intra-org events; populated for federated events
      # (where actor_id is an opaque OwnerHandle and actor_org_id identifies
      # the originating peer org).
      actor_org_id: Map.get(metadata, :actor_org_id),
      resource_type: Map.get(metadata, :resource_type),
      resource_id: Map.get(metadata, :resource_id),
      action: Map.get(metadata, :action, "execute") |> to_string(),
      metadata: build_metadata(measurements, metadata),
      session_id: Map.get(metadata, :session_id),
      ip_address: Map.get(metadata, :ip_address)
    }
  end

  @top_level_keys ~w(actor_id actor_type actor_org_id resource_type resource_id action session_id ip_address)a

  defp build_metadata(measurements, metadata) do
    metadata
    |> Map.drop(@top_level_keys)
    |> Map.merge(measurements)
    |> ensure_json_safe()
  end

  defp ensure_json_safe(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), ensure_json_safe(v)}
      {k, v} -> {to_string(k), ensure_json_safe(v)}
    end)
  end

  defp ensure_json_safe(v) when is_atom(v), do: Atom.to_string(v)
  defp ensure_json_safe(v) when is_tuple(v), do: Tuple.to_list(v) |> Enum.map(&ensure_json_safe/1)
  defp ensure_json_safe(v) when is_list(v), do: Enum.map(v, &ensure_json_safe/1)
  defp ensure_json_safe(v) when is_pid(v), do: inspect(v)
  defp ensure_json_safe(v) when is_reference(v), do: inspect(v)
  defp ensure_json_safe(v) when is_function(v), do: inspect(v)
  defp ensure_json_safe(v), do: v
end
