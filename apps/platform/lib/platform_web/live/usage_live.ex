defmodule PlatformWeb.UsageLive do
  use PlatformWeb, :live_view

  alias Platform.Analytics
  alias Platform.Agents.Agent
  alias Platform.Repo

  import Ecto.Query

  @default_range "14"

  @impl true
  def mount(_params, _session, socket) do
    agents = list_agents()

    socket =
      socket
      |> assign(:page_title, "Usage")
      |> assign(:agents, agents)
      |> assign(:selected_agent_id, nil)
      |> assign(:date_range, @default_range)
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_changed", params, socket) do
    agent_id =
      case params["agent_id"] do
        "" -> nil
        id -> id
      end

    date_range = params["date_range"] || socket.assigns.date_range

    socket =
      socket
      |> assign(:selected_agent_id, agent_id)
      |> assign(:date_range, date_range)
      |> load_data()

    {:noreply, socket}
  end

  defp load_data(socket) do
    filters = build_filters(socket.assigns)
    days = String.to_integer(socket.assigns.date_range)

    summary = Analytics.usage_summary(filters)
    time_series = Analytics.usage_time_series(filters, :day)
    events = Analytics.recent_events(filters, 50)

    # Pad time series to cover full range
    padded_series = pad_time_series(time_series, days)

    socket
    |> assign(:summary, summary)
    |> assign(:time_series, padded_series)
    |> assign(:events, events)
  end

  defp build_filters(assigns) do
    days = String.to_integer(assigns.date_range)
    from = DateTime.utc_now() |> DateTime.add(-days, :day)

    filters = %{from: from}

    case assigns.selected_agent_id do
      nil -> filters
      id -> Map.put(filters, :agent_id, id)
    end
  end

  defp list_agents do
    from(a in Agent, where: a.status != "archived", order_by: [asc: a.name])
    |> Repo.all()
  rescue
    _ -> []
  end

  defp pad_time_series(data, days) do
    today = Date.utc_today()
    start_date = Date.add(today, -days + 1)

    existing =
      Map.new(data, fn row ->
        date =
          case row.period do
            %DateTime{} = dt -> DateTime.to_date(dt)
            %NaiveDateTime{} = ndt -> NaiveDateTime.to_date(ndt)
            %Date{} = d -> d
          end

        {date, row}
      end)

    Enum.map(0..(days - 1), fn offset ->
      date = Date.add(start_date, offset)

      case Map.get(existing, date) do
        nil -> %{period: date, requests: 0, tokens: 0, cost: 0.0}
        row -> %{row | period: date}
      end
    end)
  end

  # ── Formatting helpers ──────────────────────────────────────────

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"

  defp format_cost(c) when is_float(c), do: "$#{:erlang.float_to_binary(c, decimals: 4)}"
  defp format_cost(_), do: "$0.00"

  defp format_latency(nil), do: "-"
  defp format_latency(ms) when ms >= 1000, do: "#{Float.round(ms / 1000, 1)}s"
  defp format_latency(ms), do: "#{ms}ms"

  defp format_time(%{inserted_at: dt}) do
    Calendar.strftime(dt, "%m/%d %H:%M")
  end

  defp agent_name(nil, _agents), do: "-"

  defp agent_name(agent_id, agents) do
    case Enum.find(agents, &(&1.id == agent_id)) do
      %{name: name} -> name
      nil -> String.slice(agent_id, 0..7)
    end
  end

  # ── SVG chart helpers ───────────────────────────────────────────

  defp chart_max_tokens(series) do
    max = series |> Enum.map(& &1.tokens) |> Enum.max(fn -> 0 end)
    max(max, 1)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-y-auto p-4 md:p-6 space-y-6">
      <h1 class="text-xl font-bold">Usage Analytics</h1>

      <%!-- Filters --%>
      <form phx-change="filter_changed" class="flex flex-wrap items-center gap-4">
        <select name="agent_id" class="select select-sm select-bordered w-48">
          <option value="">All Agents</option>
          <%= for agent <- @agents do %>
            <option value={agent.id} selected={agent.id == @selected_agent_id}>
              {agent.name}
            </option>
          <% end %>
        </select>

        <div class="flex gap-1">
          <label
            :for={range <- ["7", "14", "30"]}
            class={[
              "btn btn-sm",
              if(@date_range == range, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            <input
              type="radio"
              name="date_range"
              value={range}
              checked={@date_range == range}
              class="hidden"
            />
            {range}d
          </label>
        </div>
      </form>

      <%!-- Summary cards --%>
      <div class="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div class="bg-base-200 rounded-lg p-4">
          <div class="text-xs text-base-content/50 uppercase tracking-wider">Requests</div>
          <div class="text-2xl font-bold mt-1">{@summary.total_requests}</div>
        </div>
        <div class="bg-base-200 rounded-lg p-4">
          <div class="text-xs text-base-content/50 uppercase tracking-wider">Tokens</div>
          <div class="text-2xl font-bold mt-1">{format_tokens(@summary.total_tokens)}</div>
          <div class="flex flex-wrap gap-x-3 mt-1 text-xs text-base-content/60">
            <span title="Input tokens">⬆ {format_tokens(@summary.total_input_tokens)}</span>
            <span title="Output tokens">⬇ {format_tokens(@summary.total_output_tokens)}</span>
            <span :if={@summary.total_cache_read_tokens > 0} title="Cache read tokens">
              ⚡ {format_tokens(@summary.total_cache_read_tokens)}
            </span>
          </div>
        </div>
        <div class="bg-base-200 rounded-lg p-4">
          <div class="text-xs text-base-content/50 uppercase tracking-wider">Cost</div>
          <div class="text-2xl font-bold mt-1">{format_cost(@summary.total_cost)}</div>
        </div>
        <div class="bg-base-200 rounded-lg p-4">
          <div class="text-xs text-base-content/50 uppercase tracking-wider">Avg Latency</div>
          <div class="text-2xl font-bold mt-1">{format_latency(@summary.avg_latency_ms)}</div>
        </div>
      </div>

      <%!-- Time series chart --%>
      <div class="bg-base-200 rounded-lg p-4">
        <h2 class="text-sm font-semibold mb-3">Token Usage ({@date_range} days)</h2>
        <svg
          viewBox={"0 0 #{length(@time_series) * 28 + 20} 160"}
          class="w-full h-40"
          role="img"
          aria-label="Token usage bar chart"
        >
          <% max_val = chart_max_tokens(@time_series) %>
          <%= for {day, i} <- Enum.with_index(@time_series) do %>
            <rect
              x={i * 28 + 10}
              y={150 - day.tokens / max_val * 140}
              width="20"
              height={max(day.tokens / max_val * 140, 1)}
              class="fill-primary/70 hover:fill-primary transition-colors"
              rx="2"
            >
              <title>
                {Calendar.strftime(day.period, "%b %d")}: {format_tokens(day.tokens)} tokens, {day.requests} requests, {format_cost(
                  day.cost
                )}
              </title>
            </rect>
            <text
              :if={rem(i, max(div(length(@time_series), 7), 1)) == 0}
              x={i * 28 + 20}
              y="158"
              text-anchor="middle"
              class="fill-base-content/40 text-[8px]"
            >
              {Calendar.strftime(day.period, "%m/%d")}
            </text>
          <% end %>
        </svg>
      </div>

      <%!-- Event log table --%>
      <div class="bg-base-200 rounded-lg overflow-x-auto">
        <table class="table table-sm w-full">
          <thead>
            <tr class="text-xs text-base-content/50 uppercase">
              <th>Time</th>
              <th class="hidden md:table-cell">Agent</th>
              <th>Model</th>
              <th>Input</th>
              <th class="hidden md:table-cell">Cached</th>
              <th>Output</th>
              <th>Cost</th>
              <th class="hidden md:table-cell">Latency</th>
              <th class="hidden lg:table-cell">Task</th>
            </tr>
          </thead>
          <tbody>
            <%= if @events == [] do %>
              <tr>
                <td colspan="9" class="text-center py-8 text-base-content/40">
                  No usage events recorded yet
                </td>
              </tr>
            <% end %>
            <%= for event <- @events do %>
              <tr class="hover">
                <td class="text-xs whitespace-nowrap">{format_time(event)}</td>
                <td class="hidden md:table-cell text-xs">{agent_name(event.agent_id, @agents)}</td>
                <td class="text-xs font-mono">{event.model}</td>
                <td class="text-xs">{format_tokens(event.input_tokens)}</td>
                <td class="hidden md:table-cell text-xs text-base-content/60">
                  {format_tokens(event.cache_read_tokens)}
                </td>
                <td class="text-xs">{format_tokens(event.output_tokens)}</td>
                <td class="text-xs">{format_cost(event.cost_usd)}</td>
                <td class="hidden md:table-cell text-xs">{format_latency(event.latency_ms)}</td>
                <td class="hidden lg:table-cell text-xs text-base-content/50">
                  {event.task_id || "-"}
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end
end
