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
    # Stage 3 of task 019e41a9 — emitted by
    # `Platform.Tenancy.promote_to_admin/2` and `revoke_admin/2`.
    [:platform, :tenancy, :role_change],
    # Task 019f25f2 — auto-approve plan bridging (stage 2 emitters,
    # this bridge added in a corrective patch on top of stage 4).
    # `Platform.Tasks.maybe_auto_approve/1` emits these; metadata carries
    # `resource_type: "plan"` + `resource_id: plan_id` for audit correlation.
    [:platform, :plan, :auto_approved],
    [:platform, :plan, :auto_approve_skipped],
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
    # Task 019f5d47-8090 — stage-level responsibility routing fallback.
    # Emitted by Platform.Orchestration.TaskRouter.resolve_stage_dispatch_assignee/3
    # when a stage's responsibility can't be resolved to a live runtime.
    # Metadata carries stage_id, task_id, responsibility, fallback_runtime_id, reason.
    [:platform, :plans, :stage_dispatch, :assignee_unresolvable],
    # Task 019f5e0b — meeting-scribe dispatch fallback. Emitted by
    # Platform.Federation.dispatch_scribe_attention/2 (via
    # emit_scribe_dispatch_fallback/3) when the scribe agent can't be
    # resolved to a live runtime or the broadcast fails. Metadata carries
    # agent_id, reason (:agent_not_found | :runtime_unresolvable |
    # :broadcast_failed | :endpoint_not_ready), and optional broadcast_error.
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
    [:platform, :orchestration, :alarm_silence]
  ]

  @doc "Attach the handler to all registered platform telemetry events."
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
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

    # Task.Supervisor.start_child callers under Platform.TaskSupervisor must
    # rescue DBConnection.OwnershipError — the spawned Task is not in the
    # DataCase sandbox owner chain in test env. See
    # apps/platform/notes/2026-07-06-datacase-cascade-rootcause.md and the
    # regression audit at
    # apps/platform/test/platform/regression/supervised_task_repo_audit_test.exs.
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
