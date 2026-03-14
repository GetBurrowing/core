defmodule Platform.Audit do
  @moduledoc """
  Platform-wide event stream.

  Events are immutable facts stored in an append-only table. This module
  provides three access patterns:

  - `record/1`  — persist a single event (used by the telemetry handler)
  - `stream/1`  — lazy `Repo.stream` for replay and state derivation
  - `list/1`    — keyset-paginated listing for API consumers

  ## Replay and state derivation

      Repo.transaction(fn ->
        Audit.stream(actor_id: user_id, since: thirty_days_ago)
        |> Enum.reduce(initial_state, &apply_event/2)
      end)

  ## Telemetry emission (preferred entry point)

  Rather than calling `record/1` directly, emit `:telemetry` events
  following the `[:platform, domain, action]` convention. The
  `Audit.TelemetryHandler` bridges telemetry to this module automatically.
  """

  import Ecto.Query

  alias Platform.Audit.Event
  alias Platform.Repo

  @pubsub Platform.PubSub

  # -- Write --

  @doc """
  Persist an audit event and broadcast to PubSub subscribers.
  Returns `{:ok, event}` or `{:error, changeset}`.
  """
  def record(attrs) when is_map(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
    |> tap(fn
      {:ok, event} -> broadcast(event)
      _ -> :ok
    end)
  end

  # -- Read (streaming) --

  @doc """
  Returns a lazy stream of events matching `filters`.

  Must be called inside `Repo.transaction/1` — `Repo.stream` requires
  an open transaction for the cursor.

  ## Filters

  - `:actor_id`       — UUID
  - `:event_type`     — exact match or prefix with `*` (e.g. `"platform.auth.*"`)
  - `:resource_type`  — exact match
  - `:resource_id`    — exact match
  - `:session_id`     — exact match
  - `:since`          — `DateTime`, inclusive lower bound
  - `:until`          — `DateTime`, inclusive upper bound
  """
  def stream(filters \\ []) do
    filters
    |> build_query()
    |> Repo.stream()
  end

  # -- Read (paginated) --

  @doc """
  Returns a list of events with keyset pagination.

  ## Options

  All filters from `stream/1` plus:

  - `:limit`  — max results (default 50)
  - `:cursor` — `id` of the last seen event (exclusive lower bound)
  """
  def list(filters \\ []) do
    {limit, filters} = Keyword.pop(filters, :limit, 50)
    {cursor, filters} = Keyword.pop(filters, :cursor)

    filters
    |> build_query()
    |> maybe_cursor(cursor)
    |> limit(^limit)
    |> Repo.all()
  end

  # -- Query builder --

  defp build_query(filters) do
    Enum.reduce(filters, from(e in Event, order_by: [asc: e.id]), fn
      {:actor_id, id}, q ->
        where(q, [e], e.actor_id == ^id)

      {:event_type, type}, q ->
        apply_event_type_filter(q, type)

      {:resource_type, type}, q ->
        where(q, [e], e.resource_type == ^type)

      {:resource_id, id}, q ->
        where(q, [e], e.resource_id == ^id)

      {:session_id, sid}, q ->
        where(q, [e], e.session_id == ^sid)

      {:since, %DateTime{} = dt}, q ->
        where(q, [e], e.inserted_at >= ^dt)

      {:until, %DateTime{} = dt}, q ->
        where(q, [e], e.inserted_at <= ^dt)

      _other, q ->
        q
    end)
  end

  defp apply_event_type_filter(query, type) do
    if String.ends_with?(type, ".*") do
      prefix = String.trim_trailing(type, "*")
      where(query, [e], like(e.event_type, ^"#{prefix}%"))
    else
      where(query, [e], e.event_type == ^type)
    end
  end

  defp maybe_cursor(query, nil), do: query
  defp maybe_cursor(query, cursor), do: where(query, [e], e.id > ^cursor)

  # -- PubSub --

  @doc "Subscribe to audit events on the given topic."
  def subscribe(topic \\ "audit:all") do
    Phoenix.PubSub.subscribe(@pubsub, topic)
  end

  defp broadcast(%Event{} = event) do
    Phoenix.PubSub.broadcast(@pubsub, "audit:all", {:audit_event, event})
    Phoenix.PubSub.broadcast(@pubsub, "audit:#{event.event_type}", {:audit_event, event})

    if event.resource_type && event.resource_id do
      topic = "audit:#{event.resource_type}:#{event.resource_id}"
      Phoenix.PubSub.broadcast(@pubsub, topic, {:audit_event, event})
    end
  end
end
