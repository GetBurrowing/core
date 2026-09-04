defmodule Platform.Orchestration.RuntimeSupervision do
  @moduledoc """
  Persistence and normalization for federated runtime execution events.

  This is the first slice of the execution-lease contract from ADR 0028:
  runtimes can publish normalized events and Suite records durable lease state
  instead of inferring liveness from chat silence alone.
  """

  import Ecto.Query
  require Logger

  alias Ecto.Multi
  alias Platform.Orchestration.{ExecutionLease, ExecutionSpace, RuntimeEvent}
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
  def record_event(attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)
    maybe_log_owner_unknown_breadcrumb(attrs)

    with :ok <- validate_phase(attrs.phase),
         :ok <- validate_event_type(attrs.event_type),
         {:ok, task} <- fetch_task(attrs.task_id) do
      case Repo.get_by(RuntimeEvent, idempotency_key: attrs.idempotency_key) do
        %RuntimeEvent{} = event ->
          event = Repo.preload(event, :lease)
          broadcast_and_mirror(event, event.lease, attrs, duplicate: true)
          {:ok, event}

        nil ->
          Multi.new()
          |> Multi.run(:lease, fn repo, _changes -> upsert_lease(repo, attrs) end)
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
              payload: attrs.payload,
              invoked_by_user_id: attrs.invoked_by_user_id,
              owner_org_id: attrs.owner_org_id,
              owner_attribution_status: attrs.owner_attribution_status
            })
          end)
          |> Repo.transaction()
          |> case do
            {:ok, %{event: %RuntimeEvent{} = event, lease: lease}} ->
              event = Repo.preload(event, :lease)
              broadcast_and_mirror(event, lease, attrs)
              {:ok, event}

            {:error, :event, changeset, _changes} ->
              {:error, changeset}

            {:error, :lease, reason, _changes} ->
              {:error, reason}
          end
      end
    end
  end

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
    worker_ref = Map.get(attrs, :runtime_worker_ref) || Map.get(attrs, "runtime_worker_ref")

    # Stage-scoped lease keying (task 019f6791). The `report_blocker` MCP tool
    # (and every other runtime-event surface today) puts `stage_id` inside the
    # payload, so the payload is the source of truth; a top-level `stage_id`
    # attr is a convenience for direct Elixir callers.
    stage_id =
      Map.get(attrs, :stage_id) || Map.get(attrs, "stage_id") ||
        Map.get(payload, "stage_id") || Map.get(payload, :stage_id)

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
      payload: payload,
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

        persist_lease(repo, lease, status, attrs)
    end
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
      metadata: attrs.payload || %{},
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
      metadata: Map.merge(lease.metadata || %{}, attrs.payload || %{})
    })
    |> repo.update()
  end

  defp heartbeat_at("active", attrs), do: attrs.occurred_at
  defp heartbeat_at("blocked", attrs), do: attrs.occurred_at
  defp heartbeat_at(_, _attrs), do: nil

  defp progress_at(event_type, occurred_at)
       when event_type in ["execution.started", "execution.progress"], do: occurred_at

  defp progress_at(_event_type, _occurred_at), do: nil

  defp block_reason("blocked", attrs) do
    attrs.payload["description"] || attrs.payload[:description] || attrs.payload["block_reason"] ||
      attrs.payload[:block_reason]
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

  defp format_log_message(event, lease) do
    runtime = event.runtime_id

    case event.event_type do
      "assignment.accepted" ->
        "Runtime #{runtime} accepted assignment for #{event.phase}"

      "assignment.rejected" ->
        "Runtime #{runtime} rejected assignment for #{event.phase}"

      "execution.acked" ->
        "Runtime #{runtime} acked dispatch for #{event.phase}"

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

      other ->
        "Runtime #{runtime} event: #{other}"
    end
  end
end
