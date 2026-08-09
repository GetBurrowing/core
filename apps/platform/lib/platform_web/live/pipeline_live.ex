defmodule PlatformWeb.PipelineLive do
  @moduledoc """
  `/control/pipeline` — where the time between a task starting and finishing
  actually goes, and how much of it is the system waiting on a person.

  This module reads `Platform.Tasks.PipelineHealth` and nothing else. It does
  no date arithmetic over task rows: a duration presented here was measured by
  a phase transition or it is not presented at all.

  Four presentation rules are load-bearing, not styling:

    * the cohort is stated as "m of n tasks decomposable" beside the chart, so
      a reader knows what fraction of the data the chart is drawn from;
    * a phase nobody visited is a GAP in the bar and an em-dash in the table —
      never `0.0 h`, which is indistinguishable from a phase that was fast;
    * cycle time is never a single number. The recorded baseline is a mean of
      161.7 h against a median of 13.1 h, so any hero figure is a lie; the
      distribution is log-binned and both rules are drawn;
    * under five decomposable tasks the page says so in words where the
      distribution would be, rather than drawing a confident chart from three
      points.

  Human wait is carried by the `--color-pipeline-human` token AND by a 45°
  texture AND by a visible numeric label on every segment AND by the plain
  table below — the light token is under the 3:1 contrast floor and may not be
  darkened, so the distinction may never rest on colour alone.
  """

  use PlatformWeb, :live_view

  alias Platform.Tasks.PipelineHealth

  @default_range "30"
  @sparse_threshold 5

  @phase_labels %{
    "planning" => "plan",
    "awaiting_plan_approval" => "awaiting plan approval",
    "in_progress" => "build",
    "awaiting_manual_approval" => "awaiting approval",
    "deploying" => "deploy"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Pipeline health")
     |> assign(:range, @default_range)
     |> load_data()}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("range_changed", %{"range" => range}, socket) when range in ~w(7 30 all) do
    {:noreply, socket |> assign(:range, range) |> load_data()}
  end

  def handle_event("range_changed", _params, socket), do: {:noreply, socket}

  defp load_data(socket) do
    window = window_for(socket.assigns.range)

    cohort = PipelineHealth.cohort(window)
    breakdown = PipelineHealth.phase_breakdown(window)

    socket
    |> assign(:cohort, cohort)
    |> assign(:breakdown, breakdown)
    |> assign(:distribution, PipelineHealth.cycle_time_distribution(window))
    |> assign(:throughput, PipelineHealth.throughput(window))
    |> assign(:sparse?, cohort.decomposable < @sparse_threshold)
  end

  # "all" still needs a lower bound; instrumentation is the only honest one,
  # and nothing before it can be decomposed anyway.
  defp window_for(range) do
    until = DateTime.utc_now()

    since =
      case range do
        "all" -> ~U[1970-01-01 00:00:00Z]
        days -> DateTime.add(until, -String.to_integer(days), :day)
      end

    %{since: since, until: until}
  end

  # ── Formatting ──────────────────────────────────────────────────
  #
  # `nil` is an absence, and prints as one. It is never coerced to a zero.

  defp duration(nil), do: "—"

  defp duration(seconds) when is_number(seconds) do
    cond do
      seconds >= 86_400 -> "#{round1(seconds / 86_400)} d"
      seconds >= 3_600 -> "#{round1(seconds / 3_600)} h"
      seconds >= 60 -> "#{round1(seconds / 60)} m"
      true -> "#{round(seconds)} s"
    end
  end

  defp round1(x), do: :erlang.float_to_binary(Float.round(x * 1.0, 1), decimals: 1)

  defp sparse_threshold, do: @sparse_threshold

  defp phase_label(phase), do: Map.get(@phase_labels, phase, phase)

  defp kind(%{human: true}), do: "human wait"
  defp kind(%{human: false}), do: "engine"

  defp measured(breakdown), do: Enum.reject(breakdown, &is_nil(&1.p50_seconds))

  defp total_seconds(breakdown),
    do: breakdown |> measured() |> Enum.map(& &1.p50_seconds) |> Enum.sum()

  defp human_seconds(breakdown),
    do:
      breakdown
      |> measured()
      |> Enum.filter(& &1.human)
      |> Enum.map(& &1.p50_seconds)
      |> Enum.sum()

  defp segment_width(row, breakdown) do
    case total_seconds(breakdown) do
      total when total > 0 -> "#{Float.round(row.p50_seconds / total * 100, 3)}%"
      _ -> "0%"
    end
  end

  # Engine is a flat token fill; human wait is the same token family plus a 45°
  # texture, so the split survives greyscale, print and forced-colors.
  defp segment_fill(%{human: true}) do
    "background-color: var(--color-pipeline-human); " <>
      "background-image: repeating-linear-gradient(45deg, " <>
      "color-mix(in oklch, var(--color-base-100) 45%, transparent) 0 4px, " <>
      "transparent 4px 8px);"
  end

  defp segment_fill(%{human: false}), do: "background-color: var(--color-info);"

  defp instrumented_label(nil), do: "not yet instrumented"
  defp instrumented_label(dt), do: Calendar.strftime(dt, "%-d %b %Y")

  defp bucket_height(%{count: count}, buckets) do
    max = buckets |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)

    case {count, max} do
      {0, _} -> "0%"
      {_, 0} -> "0%"
      {c, m} -> "#{Float.round(c / m * 100, 2)}%"
    end
  end

  # Position of a labelled rule on the log-binned axis, as a percentage of the
  # bucket track. Both median and mean are drawn; neither stands alone.
  defp rule_position(nil, _buckets), do: nil

  defp rule_position(seconds, buckets) do
    n = length(buckets)

    index =
      Enum.find_index(buckets, fn %{label: label} -> seconds < bucket_upper(label) end) ||
        n - 1

    Float.round((index + 0.5) / n * 100, 2)
  end

  defp bucket_upper("<1h"), do: 3_600
  defp bucket_upper("1-4h"), do: 14_400
  defp bucket_upper("4-12h"), do: 43_200
  defp bucket_upper("12h-1d"), do: 86_400
  defp bucket_upper("1-3d"), do: 259_200
  defp bucket_upper("3-7d"), do: 604_800
  defp bucket_upper(_), do: :infinity

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col h-full overflow-y-auto p-4 md:p-6 space-y-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h1 class="text-xl font-bold">Pipeline health</h1>

        <form phx-change="range_changed" class="flex gap-1">
          <label
            :for={{value, label} <- [{"7", "7d"}, {"30", "30d"}, {"all", "all"}]}
            class={["btn btn-sm", if(@range == value, do: "btn-primary", else: "btn-ghost")]}
          >
            <input type="radio" name="range" value={value} checked={@range == value} class="hidden" />
            {label}
          </label>
        </form>
      </div>

      <%!-- Signature element: one stacked bar, plus the exclusion line BESIDE it. --%>
      <section class="bg-base-200 rounded-lg p-4 space-y-3">
        <h2 class="text-sm font-semibold uppercase tracking-wider">Where the time goes</h2>

        <div class="flex flex-col lg:flex-row lg:items-start gap-4">
          <div class="flex-1 min-w-0 space-y-2">
            <p :if={@sparse?} id="sparse-bar-note" class="text-sm text-base-content">
              {@cohort.decomposable} of {@cohort.tasks_in_window} tasks in this window can be
              decomposed — too few to split the elapsed time across phases yet. The per-phase
              numbers measured so far are in the table below.
            </p>

            <div :if={not @sparse?} id="phase-bar" class="flex gap-[2px] h-10 w-full">
              <div
                :for={row <- measured(@breakdown)}
                id={"phase-segment-#{row.phase}"}
                class="first:rounded-l flex items-center justify-center overflow-hidden last:rounded-r"
                style={"width: #{segment_width(row, @breakdown)}; border-radius: 4px; #{segment_fill(row)}"}
                title={"#{phase_label(row.phase)} — #{kind(row)} — median #{duration(row.p50_seconds)}"}
              >
                <span class="font-mono text-[10px] px-1 truncate text-base-100 mix-blend-normal">
                  {duration(row.p50_seconds)}
                </span>
              </div>
            </div>

            <div :if={not @sparse?} class="flex gap-[2px] w-full">
              <div
                :for={row <- measured(@breakdown)}
                class="text-[10px] text-base-content/70 text-center truncate"
                style={"width: #{segment_width(row, @breakdown)}"}
              >
                {phase_label(row.phase)}
              </div>
            </div>

            <p id="legend" class="text-xs text-base-content flex flex-wrap items-center gap-x-4">
              <span class="flex items-center gap-1">
                <span
                  class="inline-block size-3 rounded-sm"
                  style="background-color: var(--color-info)"
                >
                </span>
                engine {duration(total_seconds(@breakdown) - human_seconds(@breakdown))}
              </span>
              <span class="flex items-center gap-1">
                <span class="inline-block size-3 rounded-sm" style={segment_fill(%{human: true})}>
                </span>
                <%= if human_seconds(@breakdown) > 0 do %>
                  human wait {duration(human_seconds(@breakdown))} ({round1(
                    human_seconds(@breakdown) / total_seconds(@breakdown) * 100
                  )}%)
                <% else %>
                  human wait — none recorded in this cohort
                <% end %>
              </span>
            </p>
          </div>

          <%!-- Constraint: this is the number that says how much to trust the
                chart, so it sits beside the chart and always names both. --%>
          <aside class="lg:w-56 shrink-0 space-y-1">
            <p id="exclusion-line" class="text-sm font-mono text-base-content">
              {@cohort.decomposable} of {@cohort.tasks_in_window} tasks decomposable
            </p>
            <p id="instrumentation-note" class="text-xs text-neutral">
              Phase timing is instrumented from {instrumented_label(@cohort.instrumented_from)}.
              Nothing before that date can be decomposed, so those tasks are counted in the cohort
              and excluded from every figure on this page.
            </p>
          </aside>
        </div>
      </section>

      <%!-- The same numbers as plain text: the human/engine split may never
            rest on colour alone. --%>
      <section class="bg-base-200 rounded-lg overflow-x-auto">
        <table class="table table-sm w-full">
          <thead>
            <tr class="text-xs text-neutral uppercase">
              <th>Phase</th>
              <th>Kind</th>
              <th>Median</th>
              <th>p75</th>
              <th>Tasks</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @breakdown} id={"phase-row-#{row.phase}"}>
              <td class="text-xs">{phase_label(row.phase)}</td>
              <td class="text-xs">{kind(row)}</td>
              <td id={"phase-median-#{row.phase}"} class="text-xs font-mono">
                {duration(row.p50_seconds)}
              </td>
              <td id={"phase-p75-#{row.phase}"} class="text-xs font-mono">
                {duration(row.p75_seconds)}
              </td>
              <td class="text-xs font-mono">{row.tasks}</td>
            </tr>
          </tbody>
        </table>
      </section>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <section class="bg-base-200 rounded-lg p-4 space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wider">Cycle time</h2>

          <p :if={@sparse?} id="sparse-distribution-note" class="text-sm text-base-content">
            {@cohort.decomposable} of {@cohort.tasks_in_window} tasks in this window can be
            decomposed. A distribution is not meaningful yet — this page will draw one once at
            least {sparse_threshold()} tasks have been measured end to end.
          </p>

          <div :if={not @sparse?} id="cycle-time-histogram" class="space-y-2">
            <div class="relative h-32">
              <div class="flex items-end gap-1 h-full">
                <div
                  :for={bucket <- @distribution.buckets}
                  class="flex-1 flex flex-col justify-end h-full"
                  title={"#{bucket.label}: #{bucket.count} tasks"}
                >
                  <div
                    class="w-full rounded-t"
                    style={"height: #{bucket_height(bucket, @distribution.buckets)}; background-color: var(--color-info)"}
                  >
                  </div>
                </div>
              </div>

              <div
                :for={
                  {label, seconds, style} <- [
                    {"median", @distribution.median_seconds, "border-left-style: solid"},
                    {"mean", @distribution.mean_seconds, "border-left-style: dashed"}
                  ]
                }
                :if={rule_position(seconds, @distribution.buckets)}
                id={"cycle-rule-#{label}"}
                class="absolute top-0 h-full border-l-2 border-base-content"
                style={"left: #{rule_position(seconds, @distribution.buckets)}%; #{style}"}
              >
                <span class="absolute -top-1 left-1 whitespace-nowrap font-mono text-[10px] text-base-content">
                  {label} {duration(seconds)}
                </span>
              </div>
            </div>

            <div class="flex gap-1 text-[10px] text-neutral font-mono">
              <span :for={bucket <- @distribution.buckets} class="flex-1 text-center truncate">
                {bucket.label}
              </span>
            </div>

            <p class="text-xs text-neutral">
              {@distribution.n} tasks. Bins are log-spaced; the last bucket is everything over
              seven days. Median and mean are both marked — the gap between them is the point.
            </p>
          </div>
        </section>

        <section class="bg-base-200 rounded-lg p-4 space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wider">Throughput</h2>

          <p id="throughput-rate" class="text-sm font-mono text-base-content">
            {round1(@throughput.per_active_day)} tasks done per active day
          </p>

          <div :if={@throughput.series != []} class="flex items-end gap-1 h-24">
            <div
              :for={day <- @throughput.series}
              class="flex-1 rounded-t"
              style={"height: #{Float.round(day.count / max(@throughput.best_day, 1) * 100, 2)}%; background-color: var(--color-info)"}
              title={"#{Calendar.strftime(day.date, "%-d %b")}: #{day.count}"}
            >
            </div>
          </div>

          <p :if={@throughput.series == []} class="text-sm text-base-content">
            No completions recorded in this window.
          </p>

          <p class="text-xs text-neutral">
            Days with no completions are shown in the series and excluded from the divisor, so the
            rate is the pace the pipeline ran at rather than an average over idle days.
          </p>
        </section>
      </div>
    </div>
    """
  end
end
