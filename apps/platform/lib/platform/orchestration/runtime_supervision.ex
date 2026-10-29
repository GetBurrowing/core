defmodule Platform.Orchestration.RuntimeSupervision do
  @moduledoc """
  Persistence and normalization for federated runtime execution events.

  This is the first slice of the execution-lease contract from ADR 0028:
  runtimes can publish normalized events and Burrow records durable lease state
  instead of inferring liveness from chat silence alone.
  """

  import Ecto.Query
  require Logger

  alias Ecto.Multi
  alias Platform.Orchestration.{ExecutionLease, ExecutionSpace, LeaseManager, RuntimeEvent}
  alias Platform.Repo
  alias Platform.Tasks

  @active_statuses ~w(active blocked)

  # The `runtime_id` the TaskRouter stamps on events it files on its own
  # behalf (`record_unresolved_stage_blocker/4`,
  # `record_review_unrunnable_blocker/4`). Named here rather than repeated as
  # a literal so `needs_human_hold/3` and the router cannot drift apart.
  @self_filed_runtime_id "task_router"

  @doc "The `runtime_id` the TaskRouter uses for events it files itself."
  @spec self_filed_runtime_id() :: String.t()
  def self_filed_runtime_id, do: @self_filed_runtime_id

  @event_statuses %{
    "assignment.accepted" => nil,
    "assignment.rejected" => "abandoned",
    # Payload shape: %{"stage_id" => binary, "acked_at" => iso8601,
    # "runtime_id" => binary, "subagent_id" => binary} — subagent_id
    # (task 019f6c73) is the well-formed spawn-handle enforced by
    # ToolSurface.execute("task_ack", ...). Keep it in payload verbatim;
    # downstream audit + presence consumers read RuntimeEvent.payload
    # directly — no separate telemetry emit, so don't reintroduce a
    # redundant [:platform, :orchestration, :task_ack] telemetry bridge.
    "execution.acked" => nil,
    # `nil` — silence is an operator override, orthogonal to lifecycle
    # state (same rationale as `execution.acked`). See LeaseManager.silence/3
    # and the `alarm_silence` MCP tool (task 019f6791-c01b stage 3).
    "execution.alarm_silenced" => nil,
    # `nil` is LOAD-BEARING, same rationale as `execution.acked` and
    # `execution.alarm_silenced`: a nil status makes `upsert_lease/2`
    # short-circuit, so this event inserts NO execution_lease row. That is the
    # whole point — a dispatch that resolved no stage must leave a durable,
    # MCP-readable trace WITHOUT minting a lease keyed to a stage that does not
    # exist (task 01a0a5fa stage 1). Emitted by the TaskRouter itself, never by
    # a recipient runtime. Payload shape: %{"stage_id" => nil, "task_status" =>
    # binary, "dispatch_runtime_id" => binary, "delivered_online" => boolean,
    # "reported_by" => "task_router", "description" => binary}.
    "execution.dispatch_stageless" => nil,
    # `nil` for exactly the same lease-free reason as
    # `execution.dispatch_stageless` above: the watchdog that emits this
    # (task 01a0a5fa stage 2) observes a TASK-level fact — a dispatch was sent
    # with no stage open and nothing came back within the stageless watchdog
    # window — and a lease row keyed to a stage that never existed would be a
    # record of something that did not happen. Observability floor only: this
    # event sets no `needs_human`, does not stall the router, and does not
    # block the task. Emitted at most ONCE per dispatch token. Payload shape:
    # %{"stage_id" => nil, "dispatched_at" => iso8601, "elapsed_ms" =>
    # integer, "dispatch_runtime_id" => binary, "delivered_online" => boolean,
    # "reported_by" => "task_router", "description" => binary}.
    "execution.dispatch_unanswered" => nil,
    "execution.dispatch_attempt" => nil,
    "execution.dispatch_result" => nil,
    "execution.dispatch_suppressed" => nil,
    "execution.started" => "active",
    "execution.heartbeat" => "active",
    "execution.progress" => "active",
    "execution.blocked" => "blocked",
    "execution.unblocked" => "active",
    "execution.finished" => "finished",
    "execution.failed" => "failed",
    "execution.abandoned" => "abandoned"
  }

  @doc "Record a normalized runtime execution event and update the active lease."
  def record_event(attrs, opts \\ []) when is_map(attrs) do
    attrs = attrs |> normalize_attrs() |> associate_dispatch()
    enclosing_transaction? = Repo.in_transaction?()
    maybe_log_owner_unknown_breadcrumb(attrs)

    with :ok <- validate_phase(attrs.phase),
         :ok <- validate_event_type(attrs.event_type),
         {:ok, task} <- fetch_task(attrs.task_id),
         {:ok, attrs} <- normalize_dependency_block(attrs) do
      case existing_event(attrs) do
        %RuntimeEvent{} = event ->
          if replay_matches?(event, attrs) do
            event = Repo.preload(event, :lease)

            unless Keyword.get(opts, :defer_broadcast, false),
              do: broadcast_and_mirror(event, event.lease, attrs, duplicate: true)

            {:ok, event}
          else
            {:error, :idempotency_conflict}
          end

        nil ->
          Multi.new()
          |> Multi.run(:lease, fn repo, _changes ->
            # Dependency verification already holds the lease row inside its
            # enclosing transaction. Do not invert its lease -> task lock order.
            unless enclosing_transaction?, do: lock_task!(attrs.task_id)
            upsert_lease(repo, attrs)
          end)
          |> Multi.insert(:event, fn %{lease: lease} ->
            # RuntimeEvent has no stage_id column; the stage_id is
            # preserved on the linked ExecutionLease (via upsert_lease)
            # and echoed inside `payload["stage_id"]` for downstream consumers.
            RuntimeEvent.changeset(%RuntimeEvent{}, %{
              task_id: task.id,
              lease_id: lease && lease.id,
              phase: attrs.phase,
              runtime_id: attrs.runtime_id,
              event_type: attrs.event_type,
              occurred_at: attrs.occurred_at,
              idempotency_key: attrs.idempotency_key,
              payload: lifecycle_payload(attrs, lease),
              invoked_by_user_id: attrs.invoked_by_user_id,
              owner_org_id: attrs.owner_org_id,
              owner_attribution_status: attrs.owner_attribution_status
            })
          end)
          |> Repo.transaction()
          |> case do
            {:ok, %{event: %RuntimeEvent{} = event, lease: lease}} ->
              event = Repo.preload(event, :lease)

              unless Keyword.get(opts, :defer_broadcast, false),
                do: broadcast_and_mirror(event, lease, attrs)

              maybe_reconcile_late_ack(task, attrs)
              {:ok, event}

            {:error, :event, changeset, _changes} ->
              case existing_event(attrs) do
                %RuntimeEvent{} = existing ->
                  if replay_matches?(existing, attrs),
                    do: {:ok, Repo.preload(existing, :lease)},
                    else: {:error, :idempotency_conflict}

                _ ->
                  {:error, changeset}
              end

            {:error, :lease, reason, _changes} ->
              {:error, reason}
          end
      end
    end
  end

  defp existing_event(attrs),
    do: Repo.get_by(RuntimeEvent, idempotency_key: attrs.idempotency_key)

  defp replay_matches?(event, attrs) do
    event.task_id == attrs.task_id and event.runtime_id == attrs.runtime_id and
      event.event_type == attrs.event_type and event.phase == attrs.phase and
      event.payload["stage_id"] == attrs.stage_id and
      (attrs.event_type != "execution.started" or
         (event.payload["runtime_worker_ref"] == attrs.runtime_worker_ref and
            event.payload["correlation_id"] == attrs.payload["correlation_id"]))
  end

  @doc "Broadcast a newly recorded event after its enclosing transaction commits."
  def broadcast_recorded_event(event) do
    broadcast_and_mirror(event, event.lease, %{execution_space_id: nil, task_id: event.task_id})
  end

  defp associate_dispatch(%{stage_id: stage_id} = attrs) when is_binary(stage_id) do
    if attrs.event_type in ~w(execution.acked execution.started execution.heartbeat execution.progress execution.blocked execution.unblocked execution.finished execution.failed execution.abandoned) do
      case latest_dispatch(attrs.task_id, stage_id, attrs.runtime_id) do
        %{occurred_at: sent_at, payload: payload} ->
          if DateTime.compare(attrs.occurred_at, sent_at) != :lt do
            source =
              if is_binary(attrs.payload["correlation_id"]),
                do: "runtime_echo",
                else: "inferred_current_stage"

            %{
              attrs
              | payload:
                  attrs.payload
                  |> Map.put_new("correlation_id", payload["correlation_id"])
                  |> Map.put("correlation_source", source)
            }
          else
            attrs
          end

        _ ->
          attrs
      end
    else
      attrs
    end
  end

  defp associate_dispatch(attrs), do: attrs

  defp normalize_dependency_block(%{event_type: "execution.blocked"} = attrs),
    do: Platform.Orchestration.BlockerReassessment.normalize_block(attrs)

  defp normalize_dependency_block(attrs), do: {:ok, attrs}

  # Task 01a0e7ac stage 2. A NEW `execution.acked` row may be the late ack of
  # a dispatch the no-ack alarm already blocked; `LateAckReconcile` decides.
  # Runs after the transaction committed and only on the new-row branch, so a
  # replayed duplicate never reconciles twice. Best-effort: an ack must never
  # fail because the reconcile did, so nothing here reaches the return value.
  defp maybe_reconcile_late_ack(task, %{event_type: "execution.acked"} = attrs) do
    Platform.Orchestration.LateAckReconcile.maybe_reconcile(
      task.id,
      attrs.stage_id,
      attrs.runtime_id
    )

    :ok
  rescue
    error ->
      Logger.warning(
        "[RuntimeSupervision] task #{task.id} — late-ack reconcile raised: #{Exception.message(error)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "[RuntimeSupervision] task #{task.id} — late-ack reconcile #{kind}: #{inspect(reason)}"
      )

      :ok
  end

  defp maybe_reconcile_late_ack(_task, _attrs), do: :ok

  @doc """
  Return the newest active lease for the task across every stage. Kept for
  backward-compatibility and one-shot boot hydration; prefer
  `current_lease_for_stage/2` when the caller knows which stage it's asking
  about (see ADR pending — task 019f6791).
  """
  def current_lease_for_task(task_id) do
    expire_stale_leases(Repo, task_id: task_id)

    ExecutionLease
    |> where([l], l.task_id == ^task_id and l.status in ^@active_statuses)
    |> live_lease(DateTime.utc_now())
    |> order_by([l], desc: l.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Return the newest active/blocked lease for the given (task_id, stage_id).
  Returns nil if no such lease exists.

  Stage-scoped alternative to `current_lease_for_task/1` — the router uses
  this to answer "does the currently-running stage have a live blocker?"
  without being confused by leftover leases from earlier stages.
  """
  def current_lease_for_stage(task_id, stage_id) do
    expire_stale_leases(Repo, task_id: task_id, stage_id: stage_id)

    ExecutionLease
    |> where([l], l.task_id == ^task_id and l.status in ^@active_statuses)
    |> live_lease(DateTime.utc_now())
    |> filter_by_stage(stage_id)
    |> order_by([l], desc: l.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Mark every active/blocked lease for (task_id, stage_id) as `"abandoned"`
  with `expires_at: now` and `block_reason: nil`. Returns the number of
  rows affected.

  Called by `Platform.Orchestration.TaskRouter` on stage transition to
  guarantee a clean slate for the incoming stage — leftover blockers from
  the outgoing stage no longer poison the router's rehydration path.
  """
  def drop_leases_for_stage(task_id, stage_id) do
    now = DateTime.utc_now()

    query =
      ExecutionLease
      |> where([l], l.task_id == ^task_id and l.status in ^@active_statuses)
      |> filter_by_stage(stage_id)

    {count, _} =
      Repo.update_all(query,
        set: [
          status: "abandoned",
          expires_at: now,
          block_reason: nil,
          updated_at: now
        ]
      )

    count
  end

  @doc """
  Return every active/blocked lease for a task across all stages. Used at
  router boot for hydration and diagnostics — callers that need per-stage
  behaviour should prefer `current_lease_for_stage/2`.
  """
  def list_active_leases_for_task(task_id) do
    expire_stale_leases(Repo, task_id: task_id)

    ExecutionLease
    |> where([l], l.task_id == ^task_id and l.status in ^@active_statuses)
    |> live_lease(DateTime.utc_now())
    |> order_by([l], desc: l.inserted_at)
    |> Repo.all()
  end

  @doc "Return the most recent lease for a task, including failed/expired ones."
  def latest_lease_for_task(task_id, phase \\ nil) do
    expire_stale_leases(Repo, task_id: task_id, phase: phase)

    ExecutionLease
    |> where([l], l.task_id == ^task_id)
    |> maybe_filter(:phase, phase)
    |> order_by([l], desc: l.updated_at, desc: l.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def current_lease_for_task_runtime(task_id, runtime_id) do
    expire_stale_leases(Repo, task_id: task_id, runtime_id: runtime_id)

    ExecutionLease
    |> where(
      [l],
      l.task_id == ^task_id and l.runtime_id == ^runtime_id and l.status in ^@active_statuses
    )
    |> live_lease(DateTime.utc_now())
    |> order_by([l], desc: l.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Abandon any currently-active lease for the given task/phase so a fresh runtime
  dispatch can acquire a new one immediately.
  """
  def abandon_current_lease_for_task(task_id, phase \\ "execution") do
    expire_stale_leases(Repo, task_id: task_id, phase: phase)

    now = DateTime.utc_now()

    {count, _} =
      from(l in ExecutionLease,
        where: l.task_id == ^task_id and l.phase == ^phase and l.status in ^@active_statuses
      )
      |> live_lease(now)
      |> Repo.update_all(
        set: [
          status: "abandoned",
          expires_at: now,
          block_reason: nil,
          updated_at: now
        ]
      )

    count
  end

  defp fetch_task(task_id) do
    case Tasks.get_task_record(task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, task}
    end
  end

  defp validate_phase(phase) do
    if phase in ExecutionLease.phases(), do: :ok, else: {:error, :invalid_phase}
  end

  defp validate_event_type(event_type) when is_map_key(@event_statuses, event_type), do: :ok
  defp validate_event_type(_event_type), do: {:error, :invalid_event_type}

  # ADR 0040 — observability for the owner-attribution gap. Logs a single
  # info-level breadcrumb when a runtime event arrives without owner identity,
  # making the gap discoverable in production without flooding logs. Stage 2's
  # NOT-NULL transition uses the count of these breadcrumbs to gate when
  # enforcement is safe to enable (ADR §D3 soak-exit criterion).
  defp maybe_log_owner_unknown_breadcrumb(
         %{owner_attribution_status: "attribution_failed"} = attrs
       ) do
    Logger.info(
      "runtime_event_owner_unknown runtime=#{attrs.runtime_id} phase=#{attrs.phase} event_type=#{attrs.event_type}",
      runtime_id: attrs.runtime_id,
      phase: attrs.phase,
      event_type: attrs.event_type,
      task_id: attrs.task_id
    )
  end

  defp maybe_log_owner_unknown_breadcrumb(_attrs), do: :ok

  defp normalize_attrs(attrs) do
    phase = Map.get(attrs, :phase) || Map.get(attrs, "phase") || "execution"
    runtime_id = Map.get(attrs, :runtime_id) || Map.get(attrs, "runtime_id")
    event_type = Map.get(attrs, :event_type) || Map.get(attrs, "event_type")
    task_id = Map.get(attrs, :task_id) || Map.get(attrs, "task_id")
    payload = Map.get(attrs, :payload) || Map.get(attrs, "payload") || %{}

    worker_ref =
      Map.get(attrs, :runtime_worker_ref) || Map.get(attrs, "runtime_worker_ref") ||
        Map.get(payload, "runtime_worker_ref") || Map.get(payload, "subagent_id")

    # Stage-scoped lease keying (task 019f6791). The `report_blocker` MCP tool
    # (and every other runtime-event surface today) puts `stage_id` inside the
    # payload, so the payload is the source of truth; a top-level `stage_id`
    # attr is a convenience for direct Elixir callers.
    stage_id =
      Map.get(attrs, :stage_id) || Map.get(attrs, "stage_id") ||
        Map.get(payload, "stage_id") || Map.get(payload, :stage_id)

    # Normalize both supported ingress forms into the persisted envelope.
    # Replay and restart reconciliation must not lose a top-level stage id.
    payload = if is_binary(stage_id), do: Map.put(payload, "stage_id", stage_id), else: payload

    occurred_at =
      parse_datetime(Map.get(attrs, :occurred_at) || Map.get(attrs, "occurred_at")) ||
        DateTime.utc_now()

    # ADR 0040 — owner identity (Stage 1: NULL-permissive, Stage 2: enforced).
    # When fully populated, status="attributed". When partial or missing,
    # status="attribution_failed" — populated rows still get NULL ids so that
    # Stage 2's NOT-NULL transition can identify gaps to backfill or reject.
    invoked_by_user_id =
      Map.get(attrs, :invoked_by_user_id) || Map.get(attrs, "invoked_by_user_id")

    owner_org_id =
      Map.get(attrs, :owner_org_id) || Map.get(attrs, "owner_org_id")

    owner_attribution_status =
      cond do
        not is_nil(invoked_by_user_id) and not is_nil(owner_org_id) -> "attributed"
        true -> "attribution_failed"
      end

    # ADR 0040 §architect-finding-1: include invoked_by_user_id in the
    # idempotency_key so multi-user-per-runtime invocations at the same
    # microsecond produce distinct event rows. NULL-safe sentinel "-" keeps
    # legacy callers (no owner) producing the same keys as before this change.
    user_key_part = invoked_by_user_id || "-"

    # Stage-scoped keying (task 019f6791): sit stage_id between phase and
    # event_type so blockers filed on distinct stages of the same task
    # produce distinct idempotency keys and can coexist as separate rows.
    # NULL-safe sentinel "-" keeps legacy callers (no stage) generating the
    # same keys they did before this change.
    stage_key_part = stage_id || "-"

    idempotency_key =
      Map.get(attrs, :idempotency_key) ||
        Map.get(attrs, "idempotency_key") ||
        "#{runtime_id}:#{task_id}:#{phase}:#{stage_key_part}:#{event_type}:#{user_key_part}:#{DateTime.to_unix(occurred_at, :microsecond)}"

    %{
      task_id: task_id,
      stage_id: stage_id,
      phase: phase,
      runtime_id: runtime_id,
      event_type: event_type,
      occurred_at: occurred_at,
      idempotency_key: idempotency_key,
      payload:
        if(event_type == "execution.started" and is_binary(worker_ref),
          do: Map.put(payload, "runtime_worker_ref", worker_ref),
          else: payload
        ),
      runtime_worker_ref: worker_ref,
      invoked_by_user_id: invoked_by_user_id,
      owner_org_id: owner_org_id,
      owner_attribution_status: owner_attribution_status,
      execution_space_id:
        Map.get(attrs, :execution_space_id) || Map.get(attrs, "execution_space_id")
    }
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp upsert_lease(repo, attrs) do
    status = Map.fetch!(@event_statuses, attrs.event_type)

    cond do
      is_nil(status) ->
        {:ok,
         current_active_lease(repo, attrs.task_id, attrs.phase, attrs.runtime_id, attrs.stage_id)}

      true ->
        lease =
          current_active_lease(repo, attrs.task_id, attrs.phase, attrs.runtime_id, attrs.stage_id)

        cond do
          needs_human_hold?(lease) and attrs.event_type == "execution.blocked" and
              (attrs.payload["needs_human"] in [false, "false"] or
                 (lease.metadata["wait_kind"] == "human" and
                    attrs.payload["wait_kind"] == "dependency")) ->
            # A new blocker report may update a reason; it cannot answer a
            # human ruling or bypass the explicitly attributed unblock path.
            {:error, :human_action_required}

          dispatch_event_stale?(attrs) and attrs.event_type == "execution.started" ->
            {:error, :stale_worker}

          dispatch_event_stale?(attrs) ->
            {:ok, lease}

          attrs.event_type == "execution.started" and is_binary(attrs.payload["correlation_id"]) and
              not is_binary(attrs.runtime_worker_ref) ->
            {:error, :worker_reference_required}

          duplicate_worker_start?(attrs) ->
            {:error, :worker_already_started}

          needs_human_hold?(lease) and attrs.event_type != "execution.unblocked" and
            (is_nil(ExecutionLease.dependency_wait(lease)) or
               status in ~w(finished failed abandoned)) and status != "blocked" ->
            # Runtime activity/turn completion is evidence, never a human ruling.
            {:ok, lease}

          stale_worker_event?(lease, attrs) ->
            {:ok, lease}

          (status == "active" and ExecutionLease.dependency_wait(lease)) &&
              not (attrs.event_type == "execution.unblocked" and
                       verified_dependency_release?(lease, attrs)) ->
            {:error, :dependency_verification_required}

          true ->
            persist_lease(repo, lease, status, attrs)
        end
    end
  end

  defp worker_started?(attempt) do
    correlation = attempt.payload["correlation_id"]

    Repo.exists?(
      from(e in RuntimeEvent,
        where:
          e.task_id == ^attempt.task_id and
            e.runtime_id == ^attempt.payload["addressed_runtime"] and
            e.event_type == "execution.started" and
            e.payload["correlation_id"] == ^correlation and
            fragment("COALESCE(?->>'worker_event_applied', 'true') <> 'false'", e.payload)
      )
    )
  end

  defp duplicate_worker_start?(
         %{event_type: "execution.started", payload: %{"correlation_id" => correlation}} = attrs
       ) do
    Repo.exists?(
      from(e in RuntimeEvent,
        where:
          e.task_id == ^attrs.task_id and
            e.runtime_id == ^attrs.runtime_id and e.event_type == "execution.started" and
            e.payload["correlation_id"] == ^correlation and
            fragment("COALESCE(?->>'worker_event_applied', 'true') <> 'false'", e.payload) and
            fragment("COALESCE(?->>'runtime_worker_ref', '')", e.payload) !=
              ^(attrs.runtime_worker_ref || "")
      )
    )
  end

  defp duplicate_worker_start?(_attrs), do: false

  defp dispatch_event_stale?(%{event_type: type})
       when type in ~w(execution.dispatch_attempt execution.dispatch_result execution.dispatch_suppressed execution.alarm_silenced),
       do: false

  defp dispatch_event_stale?(attrs) do
    case latest_stage_dispatch(attrs.task_id, attrs.stage_id) do
      nil ->
        false

      attempt ->
        correlation = attrs.payload["correlation_id"]
        # A backdated block is still a durable hold, not a worker liveness
        # claim. Legacy blockers are never silently dropped for missing tokens.
        if attrs.event_type in ~w(execution.blocked execution.unblocked) and is_nil(correlation) do
          false
        else
          attempt.payload["addressed_runtime"] != attrs.runtime_id or
            (is_binary(correlation) and correlation != attempt.payload["correlation_id"]) or
            DateTime.compare(attrs.occurred_at, attempt.occurred_at) == :lt
        end
    end
  end

  defp lifecycle_payload(attrs, lease) do
    payload =
      if dispatch_event_stale?(attrs) do
        Map.put(attrs.payload, "worker_event_applied", false)
      else
        if attrs.event_type in ~w(execution.finished execution.failed execution.abandoned assignment.rejected) do
          applied = not needs_human_hold?(lease) and not stale_worker_event?(lease, attrs)
          Map.put(attrs.payload, "worker_event_applied", applied)
        else
          if attrs.event_type in ~w(execution.started execution.progress execution.heartbeat execution.acked),
            do: Map.put(attrs.payload, "worker_event_applied", true),
            else: attrs.payload
        end
      end

    case {attrs.event_type, lease} do
      {"execution.blocked", %ExecutionLease{} = hold} ->
        Map.put(payload, "hold_revision", hold_revision(hold))

      _ ->
        payload
    end
  end

  # A delayed terminal from a former turn must not close the replacement worker.
  defp stale_worker_event?(nil, _attrs), do: false

  defp stale_worker_event?(%ExecutionLease{} = lease, attrs) do
    terminal? =
      attrs.event_type in ~w(execution.finished execution.failed execution.abandoned assignment.rejected)

    terminal? and
      ((is_binary(lease.runtime_worker_ref) and
          attrs.runtime_worker_ref != lease.runtime_worker_ref) or
         DateTime.compare(attrs.occurred_at, lease.last_progress_at || lease.started_at) == :lt)
  end

  defp stale_worker_event?(_lease, _attrs), do: false

  @doc "Stage/runtime/worker fence shared by live router event handling. Missing legacy identity is unknown."
  def event_matches_worker?(event, stage_id, runtime_id) do
    payload = event.payload || %{}
    event_stage = payload["stage_id"] || (event.lease && Map.get(event.lease, :stage_id))
    worker = payload["runtime_worker_ref"] || payload["subagent_id"]
    lease = event.lease

    owner_matches =
      event.runtime_id == runtime_id or
        (event.event_type == "execution.blocked" and event.runtime_id == self_filed_runtime_id())

    owner_matches and (is_nil(event_stage) or event_stage == stage_id) and
      payload["worker_event_applied"] != false and not ack_after_terminal?(event) and
      not dispatch_event_stale?(%{
        task_id: event.task_id,
        stage_id: event_stage,
        runtime_id: event.runtime_id,
        occurred_at: event.occurred_at,
        event_type: event.event_type,
        payload: payload
      }) and
      not (not is_nil(lease) and
             stale_worker_event?(lease, %{
               event_type: event.event_type,
               runtime_worker_ref: worker,
               occurred_at: event.occurred_at
             }))
  end

  defp ack_after_terminal?(
         %{event_type: "execution.acked", payload: %{"correlation_id" => correlation}} = event
       ) do
    Repo.exists?(
      from(e in RuntimeEvent,
        where:
          e.task_id == ^event.task_id and
            e.runtime_id == ^event.runtime_id and e.payload["correlation_id"] == ^correlation and
            e.event_type in ["execution.finished", "execution.failed", "execution.abandoned"] and
            e.payload["worker_event_applied"] == true
      )
    )
  end

  defp ack_after_terminal?(_event), do: false

  @doc "True only for a measured end of the latest correlated dispatch, never from silence."
  def dispatch_turn_ended?(task_id, stage_id, runtime_id) do
    case latest_dispatch(task_id, stage_id, runtime_id) do
      nil -> false
      attempt -> not dispatch_open?(attempt)
    end
  end

  # The task row serializes durable dispatch reservations with lifecycle writes.
  # It is not a new worker queue: a reservation names one worker token even
  # across bounded transport retries. Missing receipt/turn-end stays unknown;
  # the existing watchdog resolves it. Runtimes must await accepted started
  # admission for their worker reference before doing work for that token.
  defp lock_task!(task_id) do
    Repo.one!(from(t in Platform.Tasks.Task, where: t.id == ^task_id, lock: "FOR UPDATE"))
  end

  @doc "Reserve a correlated dispatch before sending, surviving router/node restarts."
  def reserve_dispatch(task_id, stage_id, runtime_id, now \\ DateTime.utc_now(), opts \\ []) do
    Repo.transaction(fn ->
      task = lock_task!(task_id)
      plan = Tasks.current_plan(task_id)

      unless plan && Enum.any?(plan.stages, &(&1.id == stage_id and &1.status == "running")) do
        Repo.rollback(:stale_stage)
      end

      if needs_human_hold(task_id, stage_id, runtime_id), do: Repo.rollback(:human_hold)
      prior_attempt = latest_stage_dispatch(task_id, stage_id)

      reassigned? =
        not is_nil(prior_attempt) and prior_attempt.payload["addressed_runtime"] != runtime_id and
          match?({:ok, %{id: ^runtime_id}}, Platform.Orchestration.PhaseRuntime.resolve(task))

      previous = if reassigned?, do: nil, else: prior_attempt

      if previous && dispatch_open?(previous) do
        # A bounded transport retry reuses the same worker token. A release
        # from a hold, or any measured worker start, keeps the strict fence.
        if Keyword.get(opts, :transport_retry, false) and
             previous.payload["addressed_runtime"] == runtime_id and
             is_nil(previous.payload["hold_id"]) and not worker_started?(previous) do
          {:reserved, previous}
        else
          {:in_flight, previous.payload["correlation_id"]}
        end
      else
        correlation = Ecto.UUID.generate()
        lease = current_lease_for_stage(task_id, stage_id)

        revision =
          if lease &&
               (lease.metadata["hold_revision"] || lease.metadata["wait_kind"] == "dependency"),
             do: hold_revision(lease),
             else: nil

        payload = %{
          "stage_id" => stage_id,
          "correlation_id" => correlation,
          "addressed_runtime" => runtime_id,
          "core_build" => Platform.BuildInfo.commit(),
          "hold_revision" => revision,
          "hold_id" => lease && lease.id,
          "supersedes_correlation_id" =>
            if(reassigned?, do: prior_attempt.payload["correlation_id"], else: nil),
          "superseded_worker_state" =>
            if(reassigned?, do: "ownership_revoked_lifecycle_unknown", else: nil),
          "transport_send" => "reserved",
          "runtime_receipt" => "unknown",
          "worker_start" => "unknown",
          "terminal" => "unknown"
        }

        {:ok, event} =
          record_event(
            %{
              task_id: task_id,
              stage_id: stage_id,
              runtime_id: self_filed_runtime_id(),
              phase: Tasks.current_phase(task),
              event_type: "execution.dispatch_attempt",
              occurred_at: now,
              idempotency_key: "dispatch:" <> correlation,
              payload: payload
            },
            defer_broadcast: true
          )

        {:reserved, event}
      end
    end)
  end

  defp latest_stage_dispatch(_task_id, nil), do: nil

  defp latest_stage_dispatch(task_id, stage_id) do
    query =
      from(e in RuntimeEvent,
        where:
          e.task_id == ^task_id and e.runtime_id == ^@self_filed_runtime_id and
            e.event_type == "execution.dispatch_attempt" and e.payload["stage_id"] == ^stage_id,
        order_by: [desc: e.inserted_at],
        limit: 1
      )

    Repo.one(query)
  end

  defp latest_dispatch(task_id, stage_id, runtime_id) do
    Repo.one(
      from(e in RuntimeEvent,
        where:
          e.task_id == ^task_id and e.runtime_id == ^@self_filed_runtime_id and
            e.payload["addressed_runtime"] == ^runtime_id and
            e.event_type == "execution.dispatch_attempt" and e.payload["stage_id"] == ^stage_id,
        order_by: [desc: e.inserted_at],
        limit: 1
      )
    )
  end

  defp dispatch_open?(attempt) do
    correlation = attempt.payload["correlation_id"]
    # A confirmed transport failure sent no frame; retry may reserve a new attempt.
    closed =
      Repo.exists?(
        from(e in RuntimeEvent,
          where:
            e.task_id == ^attempt.task_id and
              e.inserted_at >= ^attempt.inserted_at and
              ((e.runtime_id == ^@self_filed_runtime_id and
                  e.event_type == "execution.dispatch_result" and
                  e.payload["correlation_id"] == ^correlation and
                  e.payload["transport_send"] == "failed" and
                  not exists(
                    from(sent in RuntimeEvent,
                      where:
                        sent.task_id == ^attempt.task_id and
                          sent.runtime_id == ^@self_filed_runtime_id and
                          sent.payload["correlation_id"] == ^correlation and
                          sent.event_type == "execution.dispatch_result" and
                          sent.payload["transport_send"] == "accepted"
                    )
                  )) or
                 (e.runtime_id == ^attempt.payload["addressed_runtime"] and
                    e.event_type in [
                      "execution.finished",
                      "execution.failed",
                      "execution.abandoned",
                      "execution.blocked",
                      "execution.unblocked"
                    ] and
                    e.payload["stage_id"] == ^attempt.payload["stage_id"] and
                    (e.event_type == "execution.blocked" or e.occurred_at >= ^attempt.occurred_at) and
                    (e.event_type in ["execution.unblocked", "execution.blocked"] or
                       (e.payload["correlation_id"] == ^correlation and
                          e.payload["worker_event_applied"] == true))))
        )
      )

    released_at = last_human_release_at(attempt.task_id, attempt.payload["stage_id"])

    human_released =
      not is_nil(released_at) and DateTime.compare(released_at, attempt.occurred_at) != :lt

    stage =
      Repo.one(
        from(s in Platform.Tasks.Stage,
          where: s.id == ^attempt.payload["stage_id"],
          select: s.started_at
        )
      )

    restarted = not is_nil(stage) and DateTime.compare(stage, attempt.occurred_at) == :gt
    not (closed or human_released or restarted)
  end

  @doc "Original reservation time for bounded watchdog reconstruction; nil means historical coverage unknown."
  def dispatch_started_at(task_id, stage_id, runtime_id) do
    case latest_dispatch(task_id, stage_id, runtime_id) do
      nil -> nil
      attempt -> if dispatch_open?(attempt), do: attempt.occurred_at, else: nil
    end
  end

  @doc "Durable activity for the current worker token, used only to restore a lost watchdog row."
  def dispatch_activity(task_id, stage_id, runtime_id) do
    case latest_dispatch(task_id, stage_id, runtime_id) do
      nil ->
        {nil, nil}

      attempt ->
        correlation = attempt.payload["correlation_id"]

        Repo.one(
          from(e in RuntimeEvent,
            where:
              e.task_id == ^task_id and e.runtime_id == ^runtime_id and
                e.payload["correlation_id"] == ^correlation and
                e.occurred_at >= ^attempt.occurred_at and
                e.event_type in [
                  "execution.acked",
                  "execution.started",
                  "execution.heartbeat",
                  "execution.progress"
                ] and
                fragment("COALESCE(?->>'worker_event_applied', 'true') <> 'false'", e.payload),
            select:
              {filter(max(e.occurred_at), e.event_type == "execution.acked"),
               filter(max(e.occurred_at), e.event_type != "execution.acked")}
          )
        )
    end
  end

  @doc "Record transport acceptance separately from runtime receipt; never claim delivery from presence."
  def dispatch_result(attempt, result, online) do
    payload =
      Map.merge(attempt.payload, %{
        "transport_send" => if(result == :ok, do: "accepted", else: "failed"),
        "transport_result" => if(result == :ok, do: "pubsub_accepted", else: "send_failed"),
        "socket_online_at_send" => online
      })

    record_event(%{
      task_id: attempt.task_id,
      runtime_id: attempt.runtime_id,
      phase: attempt.phase,
      event_type: "execution.dispatch_result",
      idempotency_key: attempt.id <> ":send:" <> Ecto.UUID.generate(),
      payload: payload
    })
  end

  @doc "Persist the reminder send and its result under a lease lock; failures retry without a success stamp."
  def deliver_hold_notice(lease_id, interval_ms, deliver, now \\ DateTime.utc_now()) do
    Repo.transaction(fn ->
      lease = Repo.one!(from(l in ExecutionLease, where: l.id == ^lease_id, lock: "FOR UPDATE"))
      metadata = lease.metadata || %{}
      revision = hold_revision(lease)
      same_generation? = metadata["human_notice_revision"] == revision
      last = if same_generation?, do: parse_datetime(metadata["human_notice_sent_at"]), else: nil

      retry =
        if same_generation?, do: parse_datetime(metadata["human_notice_retry_at"]), else: nil

      cond do
        not needs_human_hold?(lease) ->
          :released

        retry && DateTime.compare(now, retry) == :lt ->
          :not_due

        last && DateTime.diff(now, last, :millisecond) < interval_ms ->
          :not_due

        true ->
          result =
            try do
              deliver.(lease)
            rescue
              _ -> {:error, :delivery_exception}
            catch
              :exit, _ -> {:error, :delivery_exit}
            end

          success? = match?({:ok, _}, result)

          update =
            if success?,
              do: %{
                "human_notice_sent_at" => DateTime.to_iso8601(now),
                "human_notice_retry_at" => nil,
                "human_notice_result" => "sent",
                "human_notice_revision" => revision
              },
              else: %{
                "human_notice_retry_at" => DateTime.to_iso8601(DateTime.add(now, 60, :second)),
                "human_notice_result" => "failed",
                "human_notice_revision" => revision,
                "human_notice_sent_at" =>
                  if(same_generation?, do: metadata["human_notice_sent_at"], else: nil)
              }

          lease
          |> ExecutionLease.changeset(%{metadata: Map.merge(metadata, update)})
          |> Repo.update!()

          if success?, do: :sent, else: {:delivery_failed, result}
      end
    end)
  end

  defp verified_dependency_release?(lease, attrs) do
    wait = ExecutionLease.dependency_wait(lease)

    wait["state"] == "verified" and wait["revision"] == attrs.payload["hold_revision"] and
      wait["verified_runtime"] == attrs.runtime_id
  end

  defp current_active_lease(repo, task_id, phase, runtime_id, stage_id) do
    expire_stale_leases(repo,
      task_id: task_id,
      runtime_id: runtime_id,
      phase: phase,
      stage_id: stage_id
    )

    ExecutionLease
    |> where([l], l.task_id == ^task_id and l.phase == ^phase and l.runtime_id == ^runtime_id)
    |> where([l], l.status in ^@active_statuses)
    |> live_lease(DateTime.utc_now())
    |> filter_by_stage(stage_id)
    |> order_by([l], desc: l.inserted_at)
    |> limit(1)
    |> repo.one()
  end

  defp persist_lease(repo, nil, status, attrs) do
    %ExecutionLease{}
    |> ExecutionLease.changeset(%{
      task_id: attrs.task_id,
      stage_id: attrs.stage_id,
      phase: attrs.phase,
      runtime_id: attrs.runtime_id,
      runtime_worker_ref: attrs.runtime_worker_ref,
      status: status,
      started_at: attrs.occurred_at,
      last_heartbeat_at: heartbeat_at(status, attrs),
      last_progress_at: progress_at(attrs.event_type, attrs.occurred_at),
      expires_at: expires_at(attrs, status),
      block_reason: block_reason(status, attrs),
      metadata: lease_metadata(nil, status, attrs),
      # ADR 0040 — owner identity captured at lease creation. Subsequent
      # event-driven updates (the other persist_lease/4 clause) deliberately
      # do NOT overwrite these fields: the lease was created with an owner
      # and that attribution stays stable for the lifetime of the lease.
      invoked_by_user_id: attrs.invoked_by_user_id,
      owner_org_id: attrs.owner_org_id,
      owner_attribution_status: attrs.owner_attribution_status
    })
    |> repo.insert()
  end

  defp persist_lease(repo, lease, status, attrs) do
    lease
    |> ExecutionLease.changeset(%{
      runtime_worker_ref: attrs.runtime_worker_ref || lease.runtime_worker_ref,
      status: status,
      last_heartbeat_at: heartbeat_at(status, attrs) || lease.last_heartbeat_at,
      last_progress_at:
        progress_at(attrs.event_type, attrs.occurred_at) || lease.last_progress_at,
      expires_at: expires_at(attrs, status),
      block_reason: block_reason(status, attrs),
      metadata: lease_metadata(lease, status, attrs)
    })
    |> repo.update()
  end

  defp lease_metadata(lease, status, attrs) do
    prior = if lease, do: lease.metadata || %{}, else: %{}
    metadata = Map.merge(prior, attrs.payload || %{})

    if status == "blocked" do
      dependency_revision =
        case {metadata["wait_kind"], metadata["dependency_wait"]} do
          {"dependency", %{"revision" => revision}} when is_binary(revision) -> revision
          _ -> nil
        end

      prior_revision =
        if lease && lease.status == "blocked", do: prior["hold_revision"], else: nil

      revision = dependency_revision || prior_revision || Ecto.UUID.generate()

      blocked_at =
        if prior_revision == revision && prior["blocked_at"],
          do: prior["blocked_at"],
          else: DateTime.to_iso8601(attrs.occurred_at)

      metadata |> Map.put("hold_revision", revision) |> Map.put("blocked_at", blocked_at)
    else
      metadata
    end
  end

  @doc "Stable current hold generation, including legacy leases without a revision."
  def hold_revision(lease) do
    metadata = lease.metadata || %{}

    case {metadata["wait_kind"], metadata["dependency_wait"]} do
      {"dependency", %{"revision" => revision}} when is_binary(revision) -> revision
      _ -> metadata["hold_revision"] || lease.id
    end
  end

  @doc "Recorded block time; legacy rows fall back to the lease's original start time."
  def blocked_at(lease),
    do: parse_datetime((lease.metadata || %{})["blocked_at"]) || lease.started_at

  defp heartbeat_at("active", attrs), do: attrs.occurred_at
  defp heartbeat_at("blocked", attrs), do: attrs.occurred_at
  defp heartbeat_at(_, _attrs), do: nil

  defp progress_at(event_type, occurred_at)
       when event_type in ["execution.started", "execution.progress"], do: occurred_at

  defp progress_at(_event_type, _occurred_at), do: nil

  # The lease's block_reason is the ONLY text the awaiting-human notice in
  # TaskRouter renders, so the cost the executor paid (attempts, unblock
  # action) is folded in here; the human reads it without opening anything.
  defp block_reason("blocked", attrs) do
    payload = attrs.payload || %{}

    base =
      payload["description"] || payload[:description] || payload["block_reason"] ||
        payload[:block_reason]

    attempts = payload["attempts"] || payload[:attempts]
    unblock = payload["unblock_action"] || payload[:unblock_action]

    [
      base,
      if(is_list(attempts) and attempts != [], do: "tried: " <> Enum.join(attempts, "; ")),
      if(is_binary(unblock) and unblock != "", do: "unblock: " <> unblock)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, " | ")
    end
  end

  defp block_reason(_status, _attrs), do: nil

  # Task 01a04a8c. THE ONE PLACE where "waiting for a person" stops being
  # measured on the same clock as "the executor might be dead".
  #
  # A lease TTL is a LIVENESS statement: it says how long we are willing to
  # believe a silent runtime is still working before something re-dispatches
  # the stage to a fresh executor. For `active` — and for a plain
  # `report_blocker(needs_human: false)`, which means "I am stuck but I may
  # recover" — that reading is correct and the phase TTLs below are unchanged.
  #
  # For `report_blocker(needs_human: true)` it is the wrong quantity
  # altogether. That blocker says the next move belongs to a PERSON, and a
  # person is not going to answer inside fifteen minutes; they may be asleep.
  # Before this clause existed the blocked lease lapsed on the liveness clock
  # and `TaskRouterWatcher.active_lease_present?/2` then stopped filtering the
  # stage out of `redispatch_for_runtime/1`, so the next runtime reconnect
  # re-sent the whole dispatch payload as though the refusal had never been
  # filed. Observed live on 2026-08-28: three blockers, ~6 hours, one loop.
  #
  # REVERSED (task 01a0665e stage 2). Task 01a04a8c made the hold BOUNDED —
  # a 12-hour `expires_at` after which the sweep flipped the lease to
  # `expired` and dispatch resumed — on the reasoning that an unbounded hold
  # would recreate task 01a04333's silent park. Measured on 01a04fbc-1e71
  # and 01a03f4e-78b1, the horizon's only effect was: a re-dispatch of a stage
  # the executor had already refused, which it refused again within 70 s
  # (no ack), then `fire_no_ack_alert/2` transitioning the task to `blocked`
  # with the sentence "Executor never acked" — i.e. the silent park 01a04333
  # wanted to prevent, plus an untruth on top. The clock never was the
  # anti-silence mechanism; `TaskRouter`'s hourly reminder is.
  #
  # So a `needs_human` lease that names a stage is NEVER expired by the sweep
  # (`expire_stale_leases/2`) and reads as live in every lease query here
  # (`live_lease/2`), whatever its `expires_at` says. It ends only when a
  # person or the runtime says so: `execution.unblocked` (status -> `active`),
  # the stage moving on (`drop_leases_for_stage/2`), or a human transition
  # (`release_needs_human_holds/2`, called from `Platform.Tasks`).
  #
  # `@needs_human_ttl_ms` survives ONLY as the value written into the row's
  # `expires_at` column, which the schema requires. It is informational —
  # nothing reads it as a deadline for a `needs_human` hold — and it is
  # deliberately not configurable: the former `:needs_human_lease_ttl_ms`
  # knob changed nothing once the sweep stopped honouring it, and a knob
  # that changes nothing is a lie.
  @needs_human_ttl_ms 12 * 60 * 60_000

  defp expires_at(attrs, "blocked") do
    if needs_human_payload?(attrs.payload) and not is_nil(attrs.stage_id) do
      DateTime.add(attrs.occurred_at, @needs_human_ttl_ms, :millisecond)
    else
      DateTime.add(attrs.occurred_at, liveness_ttl_ms(attrs.phase), :millisecond)
    end
  end

  defp expires_at(attrs, "active") do
    DateTime.add(attrs.occurred_at, liveness_ttl_ms(attrs.phase), :millisecond)
  end

  defp expires_at(attrs, _status), do: attrs.occurred_at

  defp liveness_ttl_ms("planning"), do: 20 * 60_000
  defp liveness_ttl_ms("review"), do: 30 * 60_000
  defp liveness_ttl_ms(_phase), do: 15 * 60_000

  @doc """
  Is this lease an OPEN "a person owes the next move" hold?

  True only for a `blocked` lease that names a stage and whose recorded
  blocker payload set `needs_human: true`. `needs_human` has been written
  into `metadata` by `report_blocker` since the tool existed; until task
  01a04a8c nothing ever read it back, so the flag was recorded and ignored.

  Reads `metadata` rather than re-querying the runtime_event stream: the
  lease is the row every liveness decision already consults, and `metadata`
  is the merged payload of the events that produced it.
  """
  @spec needs_human_hold?(ExecutionLease.t() | nil) :: boolean()
  def needs_human_hold?(%ExecutionLease{status: "blocked", stage_id: stage_id} = lease)
      when not is_nil(stage_id) do
    needs_human_payload?(lease.metadata)
  end

  def needs_human_hold?(_lease), do: false

  @doc """
  The open `needs_human` hold on `(task_id, stage_id, runtime_id)`, or `nil`.

  Scoped to a runtime on purpose. The question a dispatcher is asking is
  "did the executor I am about to prompt already tell me it cannot proceed
  without a person?" — a blocker filed by some OTHER runtime (including the
  router's own `#{inspect(@self_filed_runtime_id)}` self-blockers) answers a
  different question and must not gate this dispatch.
  """
  @spec needs_human_hold(String.t(), String.t() | nil, String.t()) :: ExecutionLease.t() | nil
  def needs_human_hold(task_id, stage_id, runtime_id)
      when is_binary(task_id) and is_binary(runtime_id) do
    if is_nil(stage_id) do
      nil
    else
      expire_stale_leases(Repo,
        task_id: task_id,
        runtime_id: runtime_id,
        stage_id: stage_id
      )

      # No `expires_at` clause, on purpose (task 01a0665e stage 2): the hold
      # is `status == "blocked"` on a stage-scoped `needs_human` row, and the
      # sweep above never expires such a row. A clock here would be the
      # bounded horizon this stage removed, re-entering through a side door.
      ExecutionLease
      |> where([l], l.task_id == ^task_id and l.runtime_id == ^runtime_id)
      |> where([l], l.status == "blocked")
      |> filter_by_stage(stage_id)
      |> order_by([l], desc: l.inserted_at)
      |> limit(1)
      |> Repo.one()
      |> case do
        %ExecutionLease{} = lease -> if needs_human_hold?(lease), do: lease, else: nil
        nil -> nil
      end
    end
  end

  def needs_human_hold(_task_id, _stage_id, _runtime_id), do: nil

  # `needs_human` crosses the MCP boundary as JSON and is stored in a JSONB
  # column, so it can arrive as a boolean or as the string a loosely-typed
  # client sent. Anything else — absent, nil, false, "false", 0 — is NOT a
  # human hold: this predicate must fail CLOSED, because a false positive
  # here withholds dispatch from a stage that nobody is waiting on.
  defp needs_human_payload?(payload) when is_map(payload) do
    case Map.get(payload, "needs_human", Map.get(payload, :needs_human)) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  defp needs_human_payload?(_payload), do: false

  # A `needs_human` HOLD row, as a query condition: `blocked`, names a stage,
  # and the merged blocker payload says `needs_human`. Mirrors
  # `needs_human_hold?/1` exactly — the JSONB value is `true` or the string
  # `"true"` (see `needs_human_payload?/1`), and `->>` renders both as the
  # text `'true'`; a NULL `metadata` coalesces to `'false'`, so this fails
  # CLOSED the same way the Elixir predicate does.
  defp needs_human_hold_row do
    dynamic(
      [l],
      l.status == "blocked" and not is_nil(l.stage_id) and
        fragment("coalesce(? ->> 'needs_human', 'false') = 'true'", l.metadata)
    )
  end

  # "Live" for every reader in this module: unexpired, OR a `needs_human`
  # hold, whose `expires_at` is informational (task 01a0665e stage 2). One
  # predicate rather than one per query, because the readers that drifted —
  # `current_active_lease/5` (what `execution.unblocked` must FIND to flip),
  # `current_lease_for_task_runtime/2` (the watcher's reconnect filter),
  # `current_lease_for_stage/2` (the router's `stage_has_live_blocker?`) —
  # each carried their own copy of the clock, and each was a re-dispatch.
  defp live_lease(query, %DateTime{} = now) do
    where(query, ^dynamic([l], l.expires_at > ^now or ^needs_human_hold_row()))
  end

  @doc """
  End every open `needs_human` hold on `task_id` because a PERSON moved the
  task (task 01a0665e stage 2). Sets the leases to `expired` — the closed
  lease vocabulary has no "released" — and stamps
  `metadata["released_by_user_id"]` / `"released_at"` so the row says who
  ended it and when. Returns the number of leases released.

  This is one of exactly three ways such a hold ends; the others are the
  runtime's own `execution.unblocked` and the stage moving on. `:system` and
  agent actors never call this — `Platform.Tasks.transition_task/3` and
  `drop_task_to_column/3` gate it on the actor being a user.
  """
  @spec release_needs_human_holds(String.t(), released_by_user_id: String.t()) ::
          non_neg_integer()
  def release_needs_human_holds(task_id, opts) when is_binary(task_id) and is_list(opts) do
    user_id = Keyword.fetch!(opts, :released_by_user_id)
    now = DateTime.utc_now()

    stamp = %{"released_by_user_id" => user_id, "released_at" => DateTime.to_iso8601(now)}

    {count, _} =
      ExecutionLease
      |> where([l], l.task_id == ^task_id)
      |> where(^needs_human_hold_row())
      |> update([l],
        set: [
          status: "expired",
          updated_at: ^now,
          metadata: fragment("coalesce(?, '{}'::jsonb) || ?", l.metadata, type(^stamp, :map))
        ]
      )
      |> Repo.update_all([])

    count
  end

  @doc """
  When a PERSON last released a `needs_human` hold on `(task_id, stage_id)`,
  or `nil` if nobody ever has (task 01a0665e stage 4).

  Reads the row `release_needs_human_holds/2` leaves behind: `expired`,
  `needs_human`, stamped `released_by_user_id`. Its `updated_at` is the
  release instant — the same write sets both, so the two cannot drift.

  Exists for `TaskRouter`'s live-acked-executor guard. An executor acks the
  stage, then files `report_blocker(needs_human: true)`, and its ack is
  still inside the stage's safety net when the person rules. Without this
  the guard read that ack as "someone is on it" and withheld the very
  dispatch the release was for (measured on 01a06b2b-8185, 2026-09-04: the
  drag released the lease, `force_dispatch/1` two minutes later was
  withheld with "already has an acked executor inside its safety net").
  A release newer than the ack says the ack belongs to an executor that
  parked itself on a human; it is a record of the past, like an
  `execution.finished`.
  """
  @spec last_human_release_at(String.t(), String.t() | nil) :: DateTime.t() | nil
  def last_human_release_at(task_id, stage_id) when is_binary(task_id) and is_binary(stage_id) do
    ExecutionLease
    |> where([l], l.task_id == ^task_id and l.status == "expired")
    |> filter_by_stage(stage_id)
    |> where([l], fragment("coalesce(? ->> 'needs_human', 'false') = 'true'", l.metadata))
    |> where([l], fragment("? ->> 'released_by_user_id' IS NOT NULL", l.metadata))
    |> order_by([l], desc: l.updated_at)
    |> limit(1)
    |> select([l], l.updated_at)
    |> Repo.one()
  end

  def last_human_release_at(_task_id, _stage_id), do: nil

  defp expire_stale_leases(repo, filters) do
    now = DateTime.utc_now()
    task_id = Keyword.get(filters, :task_id)
    runtime_id = Keyword.get(filters, :runtime_id)
    phase = Keyword.get(filters, :phase)
    # Sentinel `:any` = caller did not scope by stage; `nil` (explicitly passed)
    # = filter WHERE stage_id IS NULL (legacy leases). See task 019f6791.
    stage_id = Keyword.get(filters, :stage_id, :any)

    # A `needs_human` hold is never swept (task 01a0665e stage 2) — see the
    # note on `@needs_human_ttl_ms`. Everything else expires on its clock.
    query =
      ExecutionLease
      |> where([l], l.status in ^@active_statuses)
      |> where([l], l.expires_at <= ^now)
      |> where(^dynamic([l], not (^needs_human_hold_row())))
      |> maybe_filter(:task_id, task_id)
      |> maybe_filter(:runtime_id, runtime_id)
      |> maybe_filter(:phase, phase)
      |> maybe_filter(:stage_id, stage_id)

    repo.update_all(query, set: [status: "expired", updated_at: now])
    :ok
  end

  # stage_id clauses come first so that `maybe_filter(:stage_id, nil)` is
  # treated as "filter WHERE stage_id IS NULL", not as the generic
  # `_field, nil` no-op.
  defp maybe_filter(query, :stage_id, :any), do: query
  defp maybe_filter(query, :stage_id, value), do: filter_by_stage(query, value)
  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :task_id, value), do: where(query, [l], l.task_id == ^value)
  defp maybe_filter(query, :runtime_id, value), do: where(query, [l], l.runtime_id == ^value)
  defp maybe_filter(query, :phase, value), do: where(query, [l], l.phase == ^value)

  # NULL-safe stage_id filter: Postgres `= NULL` is unknown, so callers that
  # want the legacy no-stage lease set must translate to `IS NULL` explicitly.
  defp filter_by_stage(query, nil), do: where(query, [l], is_nil(l.stage_id))
  defp filter_by_stage(query, stage_id), do: where(query, [l], l.stage_id == ^stage_id)

  defp broadcast_and_mirror(event, lease, attrs, opts \\ []) do
    unless Keyword.get(opts, :duplicate, false) do
      Tasks.broadcast_board({:runtime_event, event})
      maybe_post_execution_log(event, lease, attrs)
    end
  end

  defp maybe_post_execution_log(event, lease, attrs) do
    space_id =
      attrs.execution_space_id ||
        case ExecutionSpace.find_by_task_id(attrs.task_id) do
          %{id: id} -> id
          _ -> nil
        end

    if is_binary(space_id) do
      ExecutionSpace.post_log(space_id, format_log_message(event, lease))
    end
  end

  # Task 01a0db63-e4b1 stage 1. Word the `execution.acked` space line by the
  # LeaseManager ETS owner, not by the fact that a row was written. A non-owner
  # row still reaches this path (RuntimeChannel `execution_event` forces only
  # `runtime_id`), and the router refuses it as liveness; the space post must
  # say so rather than read as a real ack.
  #
  # RACE, documented and not fixed: this reads ETS before the router's own
  # `LeaseManager.record_ack/3` runs for the same event. A dispatch that
  # re-owns the lease between the two reads can make this line disagree with
  # the router's verdict. Out of scope.
  #
  # No lease (nil) keeps the old wording: there is no owner to compare
  # against, and the router accepts the ack in that case. That also means a
  # stranger's ack reads as an ack in the window after a LeaseManager
  # restart or clear.
  defp format_ack_log_message(event) do
    runtime = event.runtime_id

    lease = if is_binary(event.task_id), do: LeaseManager.get(event.task_id)

    case lease do
      nil ->
        "Runtime #{runtime} acked dispatch for #{event.phase}"

      %{} ->
        owner = Map.get(lease, :owner_runtime_id)

        if ack_from_owner?(runtime, owner) do
          "Runtime #{runtime} acked dispatch for #{event.phase}"
        else
          "Runtime #{runtime} reported an ack for #{event.phase}, but this stage is " <>
            "dispatched to runtime #{owner}; the ack was refused and is not counted as liveness"
        end
    end
  end

  # Mirrors the binary-and-equal semantics of the private
  # `LeaseManager.owner?/2`, failing closed: a non-binary caller or owner is
  # never the owner.
  defp ack_from_owner?(caller, owner) when is_binary(caller) and is_binary(owner),
    do: caller == owner

  defp ack_from_owner?(_caller, _owner), do: false

  defp format_log_message(event, lease) do
    runtime = event.runtime_id

    case event.event_type do
      "assignment.accepted" ->
        "Runtime #{runtime} accepted assignment for #{event.phase}"

      "assignment.rejected" ->
        "Runtime #{runtime} rejected assignment for #{event.phase}"

      "execution.acked" ->
        format_ack_log_message(event)

      "execution.alarm_silenced" ->
        silenced_until =
          event.payload["silenced_until"] || event.payload[:silenced_until] || "unknown"

        reason = event.payload["reason"] || event.payload[:reason] || "no reason provided"
        "Runtime #{runtime} silenced no-ack alarm until #{silenced_until}: #{reason}"

      "execution.started" ->
        "Runtime #{runtime} started execution (worker=#{(lease && lease.runtime_worker_ref) || "unknown"})"

      "execution.heartbeat" ->
        "Runtime heartbeat received from #{runtime}"

      "execution.progress" ->
        details = event.payload["summary"] || event.payload[:summary]

        details =
          if is_binary(details) and byte_size(details) > 300,
            do: String.slice(details, 0, 300) <> "…",
            else: details

        if details,
          do: "Runtime progress from #{runtime}: #{details}",
          else: "Runtime progress received from #{runtime}"

      "execution.blocked" ->
        reason =
          event.payload["description"] || event.payload[:description] || "no reason provided"

        "Runtime reported blocker: #{reason}"

      "execution.unblocked" ->
        "Runtime #{runtime} cleared blocker and resumed work"

      "execution.finished" ->
        "Runtime #{runtime} finished execution"

      "execution.failed" ->
        reason = event.payload["error"] || event.payload[:error] || "unknown error"
        "Runtime #{runtime} failed: #{reason}"

      "execution.abandoned" ->
        "Runtime #{runtime} abandoned execution"

      "execution.dispatch_stageless" ->
        case event.payload["description"] || event.payload[:description] do
          description when is_binary(description) ->
            "TaskRouter recorded a stage-less dispatch: #{description}"

          _ ->
            "Runtime #{runtime} recorded a stage-less dispatch (no description in payload)"
        end

      "execution.dispatch_unanswered" ->
        case event.payload["description"] || event.payload[:description] do
          description when is_binary(description) ->
            "TaskRouter stage-less dispatch went unanswered: #{description}"

          _ ->
            "Runtime #{runtime} recorded an unanswered stage-less dispatch (no description in payload)"
        end

      other ->
        "Runtime #{runtime} event: #{other}"
    end
  end
end
