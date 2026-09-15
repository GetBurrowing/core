defmodule Platform.Orchestration.Diagnostics do
  @moduledoc """
  Read-only query surface over the orchestration audit tables — `runtime_events`
  and `execution_leases` — scoped to a single task.

  This module deliberately contains NO writers. Both tables are written by
  `Platform.Orchestration.RuntimeSupervision` (and `LeaseManager`) inside the
  transaction that records the event; a second write path here would diverge on
  rollback. Everything below is a `SELECT`.

  ## The fact these queries exist to make findable

  A task can have many runtime events and ZERO execution leases, and that is
  NORMAL — not a missing-row defect. `RuntimeSupervision`'s `@event_statuses`
  map sends `"execution.acked" => nil` (as it does for `assignment.accepted`
  and `execution.alarm_silenced`), and `upsert_lease/2` short-circuits on a nil
  status: it returns whatever active lease already exists and inserts nothing.
  So a lease is only ever created by a path that maps to a real lifecycle
  status — in practice the blocker/started path — never by a plain dispatch-ack.

  Before these functions existed, establishing that required SSH plus a hand-written
  SQL query, which is exactly what a federated agent diagnosing a watchdog
  false-alarm does not have.
  """

  import Ecto.Query

  alias Platform.Orchestration.{ExecutionLease, RuntimeEvent}
  alias Platform.Repo

  @default_limit 50
  @max_limit 200

  @doc "Largest number of runtime events any single call may return."
  def max_limit, do: @max_limit

  @doc "Number of runtime events returned when the caller does not ask for a limit."
  def default_limit, do: @default_limit

  @doc """
  Resolve a caller-supplied `limit` to the value that will actually be applied.

  Public so a caller (the MCP tool surface) can REPORT the effective limit back
  in its response. A response saying `limit: 500` while the query ran with 200
  would be a lie about truncation.
  """
  def clamp_limit_for(limit), do: clamp_limit(limit)

  @doc """
  List a task's runtime events, NEWEST FIRST.

  Options:

    * `:event_type` — exact-match filter on `event_type`. An unrecognised value
      simply matches nothing; the event-type vocabulary is open-ended (new
      event types ship without a migration), so this is not validated.
    * `:limit` — clamped into `1..#{@max_limit}`. A caller asking for more than
      the cap silently receives the cap rather than an error; the cap exists to
      bound the response, not to reject the question.

  Ordering is `occurred_at desc, inserted_at desc` — `occurred_at` is
  runtime-reported and two events can share it, so `inserted_at` breaks the tie
  deterministically instead of leaving the order up to the planner.
  """
  def list_runtime_events(task_id, opts \\ []) do
    RuntimeEvent
    |> where([e], e.task_id == ^task_id)
    |> filter_event_type(Keyword.get(opts, :event_type))
    |> order_by([e], desc: e.occurred_at, desc: e.inserted_at)
    |> limit(^clamp_limit(Keyword.get(opts, :limit)))
    |> Repo.all()
  end

  @doc """
  List a task's execution leases, newest first.

  Options:

    * `:status` — must be one of `ExecutionLease.statuses/0`. Unlike
      `:event_type`, this vocabulary IS closed and validated by the lease
      changeset, so an unknown value returns `{:error, :invalid_status}` rather
      than an empty list. Silently returning "no leases" for a typo'd status is
      indistinguishable from the genuinely-empty case this tool exists to
      explain.
    * `:limit` — clamped into `1..#{@max_limit}`. Defaults to `#{@default_limit}`.
      A caller asking for more than the cap silently receives the cap rather
      than an error; the cap exists to bound the response, not to reject the
      question. The limit is applied AFTER the ordering, so a bounded read
      returns the NEWEST leases rather than an arbitrary slice.

  Returns `{:ok, leases}` or `{:error, :invalid_status}`.

  An empty list is a legitimate answer for a live, healthy task — see the
  moduledoc.
  """
  def list_execution_leases(task_id, opts \\ []) do
    case validate_status(Keyword.get(opts, :status)) do
      {:ok, status} ->
        leases =
          ExecutionLease
          |> where([l], l.task_id == ^task_id)
          |> filter_status(status)
          |> order_by([l], desc: l.started_at, desc: l.inserted_at)
          |> limit(^clamp_limit(Keyword.get(opts, :limit)))
          |> Repo.all()

        {:ok, leases}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp filter_event_type(query, nil), do: query
  defp filter_event_type(query, ""), do: query

  defp filter_event_type(query, type) when is_binary(type),
    do: where(query, [e], e.event_type == ^type)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: where(query, [l], l.status == ^status)

  defp validate_status(nil), do: {:ok, nil}
  defp validate_status(""), do: {:ok, nil}

  defp validate_status(status) when is_binary(status) do
    if status in ExecutionLease.statuses() do
      {:ok, status}
    else
      {:error, :invalid_status}
    end
  end

  defp validate_status(_), do: {:error, :invalid_status}

  # nil / absent → default. Anything unparseable → default rather than a crash:
  # `limit` is a convenience, and a malformed one should not deny the caller the
  # diagnostic they came for.
  defp clamp_limit(nil), do: @default_limit

  defp clamp_limit(limit) when is_integer(limit) do
    limit |> max(1) |> min(@max_limit)
  end

  defp clamp_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, _rest} -> clamp_limit(int)
      :error -> @default_limit
    end
  end

  defp clamp_limit(_), do: @default_limit
end
