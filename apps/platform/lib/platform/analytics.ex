defmodule Platform.Analytics do
  @moduledoc "Context for agent usage analytics."

  import Ecto.Query

  alias Platform.Analytics.UsageEvent
  alias Platform.Repo

  @doc "Insert a new usage event."
  @spec record_usage_event(map()) :: {:ok, UsageEvent.t()} | {:error, Ecto.Changeset.t()}
  def record_usage_event(attrs) do
    %UsageEvent{}
    |> UsageEvent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns aggregated usage stats.

  Filters: `:agent_id`, `:space_id`, `:from` (DateTime), `:to` (DateTime)
  """
  @spec usage_summary(map()) :: %{
          total_requests: integer(),
          total_tokens: integer(),
          total_input_tokens: integer(),
          total_output_tokens: integer(),
          total_cache_read_tokens: integer(),
          total_cache_write_tokens: integer(),
          total_cost: float(),
          avg_latency_ms: float()
        }
  def usage_summary(filters \\ %{}) do
    query =
      from(e in UsageEvent,
        select: %{
          total_requests: count(e.id),
          total_tokens: coalesce(sum(e.total_tokens), 0),
          total_input_tokens: coalesce(sum(e.input_tokens), 0),
          total_output_tokens: coalesce(sum(e.output_tokens), 0),
          total_cache_read_tokens: coalesce(sum(e.cache_read_tokens), 0),
          total_cache_write_tokens: coalesce(sum(e.cache_write_tokens), 0),
          total_cost: coalesce(sum(e.cost_usd), 0.0),
          avg_latency_ms: coalesce(avg(e.latency_ms), 0.0)
        }
      )
      |> apply_filters(filters)

    result = Repo.one(query)

    %{
      total_requests: result.total_requests || 0,
      total_tokens: result.total_tokens || 0,
      total_input_tokens: result.total_input_tokens || 0,
      total_output_tokens: result.total_output_tokens || 0,
      total_cache_read_tokens: result.total_cache_read_tokens || 0,
      total_cache_write_tokens: result.total_cache_write_tokens || 0,
      total_cost: result.total_cost || 0.0,
      avg_latency_ms:
        if(is_number(result.avg_latency_ms),
          do: Float.round(result.avg_latency_ms / 1, 1),
          else: 0.0
        )
    }
  end

  @doc """
  Returns time-bucketed usage data.

  Granularity: `:hour` or `:day` (default `:day`).
  """
  @spec usage_time_series(map(), :hour | :day) :: [
          %{
            period: Date.t() | DateTime.t(),
            requests: integer(),
            tokens: integer(),
            cost: float()
          }
        ]
  def usage_time_series(filters \\ %{}, granularity \\ :day) do
    query =
      case granularity do
        :hour -> time_series_query_hour()
        _ -> time_series_query_day()
      end
      |> apply_filters(filters)

    Repo.all(query)
  end

  defp time_series_query_day do
    from(e in UsageEvent,
      group_by: fragment("date_trunc('day', ?)", e.inserted_at),
      order_by: fragment("date_trunc('day', ?)", e.inserted_at),
      select: %{
        period: fragment("date_trunc('day', ?)", e.inserted_at),
        requests: count(e.id),
        tokens: coalesce(sum(e.total_tokens), 0),
        cost: coalesce(sum(e.cost_usd), 0.0)
      }
    )
  end

  defp time_series_query_hour do
    from(e in UsageEvent,
      group_by: fragment("date_trunc('hour', ?)", e.inserted_at),
      order_by: fragment("date_trunc('hour', ?)", e.inserted_at),
      select: %{
        period: fragment("date_trunc('hour', ?)", e.inserted_at),
        requests: count(e.id),
        tokens: coalesce(sum(e.total_tokens), 0),
        cost: coalesce(sum(e.cost_usd), 0.0)
      }
    )
  end

  @doc "Returns recent usage events, most recent first."
  @spec recent_events(map(), integer()) :: [UsageEvent.t()]
  def recent_events(filters \\ %{}, limit \\ 50) do
    from(e in UsageEvent, order_by: [desc: e.inserted_at], limit: ^limit)
    |> apply_filters(filters)
    |> Repo.all()
  end

  @doc "List all agents that have usage events (for filter dropdowns)."
  @spec agents_with_usage() :: [%{agent_id: binary(), agent_name: String.t() | nil}]
  def agents_with_usage do
    from(e in UsageEvent,
      where: not is_nil(e.agent_id),
      distinct: e.agent_id,
      left_join: a in Platform.Agents.Agent,
      on: a.id == e.agent_id,
      select: %{agent_id: e.agent_id, agent_name: a.name}
    )
    |> Repo.all()
  end

  # ── Private helpers ──────────────────────────────────────────────

  defp apply_filters(query, filters) do
    query
    |> maybe_filter(:agent_id, filters)
    |> maybe_filter(:space_id, filters)
    |> maybe_filter_from(filters)
    |> maybe_filter_to(filters)
  end

  defp maybe_filter(query, field, filters) do
    case Map.get(filters, field) do
      nil -> query
      "" -> query
      value -> where(query, [e], field(e, ^field) == ^value)
    end
  end

  defp maybe_filter_from(query, %{from: %DateTime{} = from}),
    do: where(query, [e], e.inserted_at >= ^from)

  defp maybe_filter_from(query, _), do: query

  defp maybe_filter_to(query, %{to: %DateTime{} = to}),
    do: where(query, [e], e.inserted_at <= ^to)

  defp maybe_filter_to(query, _), do: query
end
