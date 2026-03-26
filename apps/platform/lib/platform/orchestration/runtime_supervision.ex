defmodule Platform.Orchestration.RuntimeSupervision do
  @moduledoc """
  Persistence and normalization for federated runtime execution events.

  This is the first slice of the execution-lease contract from ADR 0028:
  runtimes can publish normalized events and Suite records durable lease state
  instead of inferring liveness from chat silence alone.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Platform.Orchestration.{ExecutionLease, ExecutionSpace, RuntimeEvent}
  alias Platform.Repo
  alias Platform.Tasks

  @active_statuses ~w(active blocked)
  @event_statuses %{
    "assignment.accepted" => nil,
    "assignment.rejected" => "abandoned",
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
            RuntimeEvent.changeset(%RuntimeEvent{}, %{
              task_id: task.id,
              lease_id: lease && lease.id,
              phase: attrs.phase,
              runtime_id: attrs.runtime_id,
              event_type: attrs.event_type,
              occurred_at: attrs.occurred_at,
              idempotency_key: attrs.idempotency_key,
              payload: attrs.payload
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

  def current_lease_for_task(task_id) do
    expire_stale_leases(Repo, task_id: task_id)

    ExecutionLease
    |> where([l], l.task_id == ^task_id and l.status in ^@active_statuses)
    |> where([l], l.expires_at > ^DateTime.utc_now())
    |> order_by([l], desc: l.inserted_at)
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
    |> where([l], l.expires_at > ^DateTime.utc_now())
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
        where: l.task_id == ^task_id and l.phase == ^phase and l.status in ^@active_statuses,
        where: l.expires_at > ^now
      )
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

  defp normalize_attrs(attrs) do
    phase = Map.get(attrs, :phase) || Map.get(attrs, "phase") || "execution"
    runtime_id = Map.get(attrs, :runtime_id) || Map.get(attrs, "runtime_id")
    event_type = Map.get(attrs, :event_type) || Map.get(attrs, "event_type")
    task_id = Map.get(attrs, :task_id) || Map.get(attrs, "task_id")
    payload = Map.get(attrs, :payload) || Map.get(attrs, "payload") || %{}
    worker_ref = Map.get(attrs, :runtime_worker_ref) || Map.get(attrs, "runtime_worker_ref")

    occurred_at =
      parse_datetime(Map.get(attrs, :occurred_at) || Map.get(attrs, "occurred_at")) ||
        DateTime.utc_now()

    idempotency_key =
      Map.get(attrs, :idempotency_key) ||
        Map.get(attrs, "idempotency_key") ||
        "#{runtime_id}:#{task_id}:#{phase}:#{event_type}:#{DateTime.to_unix(occurred_at, :microsecond)}"

    %{
      task_id: task_id,
      phase: phase,
      runtime_id: runtime_id,
      event_type: event_type,
      occurred_at: occurred_at,
      idempotency_key: idempotency_key,
      payload: payload,
      runtime_worker_ref: worker_ref,
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
        {:ok, current_active_lease(repo, attrs.task_id, attrs.phase, attrs.runtime_id)}

      true ->
        lease = current_active_lease(repo, attrs.task_id, attrs.phase, attrs.runtime_id)
        persist_lease(repo, lease, status, attrs)
    end
  end

  defp current_active_lease(repo, task_id, phase, runtime_id) do
    expire_stale_leases(repo, task_id: task_id, runtime_id: runtime_id, phase: phase)

    ExecutionLease
    |> where([l], l.task_id == ^task_id and l.phase == ^phase and l.runtime_id == ^runtime_id)
    |> where([l], l.status in ^@active_statuses)
    |> where([l], l.expires_at > ^DateTime.utc_now())
    |> order_by([l], desc: l.inserted_at)
    |> limit(1)
    |> repo.one()
  end

  defp persist_lease(repo, nil, status, attrs) do
    %ExecutionLease{}
    |> ExecutionLease.changeset(%{
      task_id: attrs.task_id,
      phase: attrs.phase,
      runtime_id: attrs.runtime_id,
      runtime_worker_ref: attrs.runtime_worker_ref,
      status: status,
      started_at: attrs.occurred_at,
      last_heartbeat_at: heartbeat_at(status, attrs),
      last_progress_at: progress_at(attrs.event_type, attrs.occurred_at),
      expires_at: expires_at(attrs.phase, attrs.occurred_at, status),
      block_reason: block_reason(status, attrs),
      metadata: attrs.payload || %{}
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
      expires_at: expires_at(attrs.phase, attrs.occurred_at, status),
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

  defp expires_at(phase, occurred_at, status) when status in ["active", "blocked"] do
    ttl_ms =
      case phase do
        "planning" -> 20 * 60_000
        "review" -> 30 * 60_000
        _ -> 15 * 60_000
      end

    DateTime.add(occurred_at, ttl_ms, :millisecond)
  end

  defp expires_at(_phase, occurred_at, _status), do: occurred_at

  defp expire_stale_leases(repo, filters) do
    now = DateTime.utc_now()
    task_id = Keyword.get(filters, :task_id)
    runtime_id = Keyword.get(filters, :runtime_id)
    phase = Keyword.get(filters, :phase)

    query =
      ExecutionLease
      |> where([l], l.status in ^@active_statuses)
      |> where([l], l.expires_at <= ^now)
      |> maybe_filter(:task_id, task_id)
      |> maybe_filter(:runtime_id, runtime_id)
      |> maybe_filter(:phase, phase)

    repo.update_all(query, set: [status: "expired", updated_at: now])
    :ok
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :task_id, value), do: where(query, [l], l.task_id == ^value)
  defp maybe_filter(query, :runtime_id, value), do: where(query, [l], l.runtime_id == ^value)
  defp maybe_filter(query, :phase, value), do: where(query, [l], l.phase == ^value)

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

      "execution.started" ->
        "Runtime #{runtime} started execution (worker=#{(lease && lease.runtime_worker_ref) || "unknown"})"

      "execution.heartbeat" ->
        "Runtime heartbeat received from #{runtime}"

      "execution.progress" ->
        details = event.payload["summary"] || event.payload[:summary]

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
