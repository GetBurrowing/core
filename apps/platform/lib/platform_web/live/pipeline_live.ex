defmodule PlatformWeb.PipelineLive do
  @moduledoc """
  `/tasks/pipeline` — where the time between a task starting and finishing
  actually goes, and how much of it is the system waiting on a person.

  Reached from the cog in the Tasks module header. `ModuleGate` requires
  `tasks.manage`; `PipelineHealth.snapshot/2` re-checks that permission at
  `:all` because the figures span the install, not one project.

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
    * under `@distribution_floor` decomposable tasks the page says so in words
      where the distribution would be — and states the floor, so a reader can
      tell the chart is withheld deliberately and knows when it will appear. A
      threshold that fires silently is indistinguishable from a page that has
      no chart;
    * a segment too narrow for its label drops the label rather than
      truncating it, except on a human-wait segment where the label is an
      accessibility mitigation and its loss is a defect to report.

  Human wait is carried by the `--color-pipeline-human` token AND by a 45°
  texture AND by a visible numeric label on every segment AND by the plain
  table below — the light token is under the 3:1 contrast floor and may not be
  darkened, so the distinction may never rest on colour alone.
  """

  use PlatformWeb, :live_view

  require Logger

  alias Platform.Tasks.PipelineHealth

  @default_range "30"

  # The count below which no distribution is drawn. A log-binned distribution
  # with a `>7d` overflow bucket needs enough mass for shape to mean anything;
  # twenty is the smallest count where a bucket holding one task reads as a
  # tail rather than as the whole picture. Five was not a meaningfully
  # different claim from four. One name, so the floor is one line to change.
  @distribution_floor 20

  # Rough metrics for the in-segment label: 10px monospace is ~6px per glyph,
  # plus `px-1` either side. The bar is measured against the narrowest
  # viewport it must survive (390px less page padding) so a label does not
  # appear on desktop and vanish on mobile.
  @label_char_px 6
  @label_padding_px 8
  @bar_min_px 358

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

  # Reads through `PipelineHealth.snapshot/2`, which re-checks `tasks.manage`
  # over every resource in the context (task 01a1386d-fb6e stage 2). A refused
  # read assigns nothing from the aggregates and leaves the page.
  defp load_data(socket) do
    window = window_for(socket.assigns.range)

    case PipelineHealth.snapshot(window, socket.assigns[:access_scope]) do
      {:ok, data} ->
        socket
        |> assign(:cohort, data.cohort)
        |> assign(:breakdown, data.breakdown)
        |> assign(:distribution, data.distribution)
        |> assign(:throughput, data.throughput)
        |> assign(:agent_activity, data.agent_activity)
        |> assign(:sparse?, data.cohort.decomposable < @distribution_floor)

      {:error, :unauthorized} ->
        push_navigate(socket, to: "/access-denied?module=tasks")
    end
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

  # Same convention as `duration/1`: a missing denominator prints as an
  # absence, never as a zero.
  defp ratio(nil), do: "—"
  defp ratio(value) when is_number(value), do: round1(value)

  defp distribution_floor, do: @distribution_floor

  defp phase_label(phase), do: Map.get(@phase_labels, phase, phase)

  # A phase nobody visited has no actor to attribute either, so the kind column
  # is an absence too rather than a confident "engine".
  defp kind(%{p50_seconds: nil}), do: "—"
  defp kind(%{human: true}), do: "human wait"
  defp kind(%{human: false}), do: "engine"

  # The human token is under the 3:1 floor against the light surface, so its
  # in-segment label pairs with the token's own content colour rather than the
  # white used on the engine fill.
  defp segment_text(%{human: true}), do: "color: var(--color-pipeline-human-content)"
  defp segment_text(%{human: false}), do: "color: var(--color-info-content)"

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

  defp segment_percent(row, breakdown) do
    case total_seconds(breakdown) do
      total when total > 0 -> row.p50_seconds / total * 100
      _ -> 0.0
    end
  end

  defp segment_width(row, breakdown), do: "#{Float.round(segment_percent(row, breakdown), 3)}%"

  # Below the width that fits a label, drop the label rather than truncate it:
  # `36.0…` reads as an unfinished number and invites the reader to guess
  # whether it meant minutes or a decimal, while the numbers table one row
  # down still carries the exact value, so nothing is lost by dropping it.
  #
  # Not so on a human-wait segment. There the in-segment number is one of the
  # four non-colour carriers of the human/engine split — the human token is
  # 2.55:1 against the light surface, under the 3:1 floor, and may not be
  # darkened — so dropping it would silently weaken an accessibility
  # mitigation. A human-wait segment too narrow for its label is a layout
  # defect: keep the label, let it overflow visibly, and say so in the log.
  defp segment_label(row, breakdown) do
    label = duration(row.p50_seconds)

    cond do
      segment_percent(row, breakdown) >= label_min_percent(label) ->
        label

      row.human ->
        Logger.warning(
          "pipeline: human-wait segment #{row.phase} is too narrow for its label " <>
            "(#{Float.round(segment_percent(row, breakdown), 2)}% of the bar); keeping it, " <>
            "because the in-segment number is a contrast mitigation and may not be dropped"
        )

        label

      true ->
        nil
    end
  end

  defp label_min_percent(label),
    do: (String.length(label) * @label_char_px + @label_padding_px) / @bar_min_px * 100

  # Engine is a flat token fill; human wait is the same token family plus a 45°
  # texture, so the split survives greyscale, print and forced-colors.
  defp segment_fill(%{human: true}) do
    "background-color: var(--color-pipeline-human); " <>
      "background-image: repeating-linear-gradient(45deg, " <>
      "color-mix(in oklch, var(--color-base-100) 45%, transparent) 0 4px, " <>
      "transparent 4px 8px);"
  end

  defp segment_fill(%{human: false}), do: "background-color: var(--color-info);"

  defp axis_date(%{date: date}), do: Calendar.strftime(date, "%-d %b")

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
    <div
      data-role="pipeline-page"
      class="flex flex-col h-full overflow-y-auto p-4 md:p-6 space-y-6 clears-tab-bar"
    >
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
            <%!-- The sparse banner may only claim what the page then honours.
                  An earlier wording said the elapsed time could not be split
                  across phases yet and was immediately followed by a legend
                  splitting it engine/human and a table splitting it per phase.
                  What is actually unavailable is the PROPORTIONAL reading, so
                  that is what this says — and the legend is suppressed below,
                  rather than the sentence being contradicted twice. --%>
            <p :if={@sparse?} id="sparse-bar-note" class="text-sm text-base-content">
              {@cohort.decomposable} of {@cohort.tasks_in_window} tasks decomposable; a
              proportional split needs {distribution_floor()}. Too few for the shares of elapsed
              time to mean anything, so no bar is drawn — the per-phase medians measured so far
              are in the table below.
            </p>

            <div :if={not @sparse?} id="phase-bar" class="flex gap-[2px] h-10 w-full">
              <div
                :for={row <- measured(@breakdown)}
                id={"phase-segment-#{row.phase}"}
                class={[
                  "first:rounded-l flex items-center justify-center last:rounded-r",
                  if(row.human, do: "overflow-visible", else: "overflow-hidden")
                ]}
                style={"width: #{segment_width(row, @breakdown)}; border-radius: 4px; #{segment_fill(row)}"}
                title={"#{phase_label(row.phase)} — #{kind(row)} — median #{duration(row.p50_seconds)}"}
              >
                <span
                  :if={segment_label(row, @breakdown)}
                  class="font-mono text-[10px] font-semibold px-1 whitespace-nowrap"
                  style={segment_text(row)}
                >
                  {segment_label(row, @breakdown)}
                </span>
              </div>
            </div>

            <div :if={not @sparse?} class="flex gap-[2px] w-full">
              <div
                :for={row <- measured(@breakdown)}
                class="text-[10px] text-base-content/70 text-center truncate"
                style={"width: #{segment_width(row, @breakdown)}"}
                title={phase_label(row.phase)}
              >
                <%!-- Unlike the in-segment number, a clipped phase NAME is not
                      ambiguous — "depl…" cannot be misread as a different
                      value the way "36.0…" can be misread as 36 minutes. It
                      keeps its truncation and carries a title, and the full
                      name is in the table below. --%>
                {phase_label(row.phase)}
              </div>
            </div>

            <p
              :if={not @sparse?}
              id="legend"
              class="text-xs text-base-content flex flex-wrap items-center gap-x-4"
            >
              <span class="flex items-center gap-1">
                <span
                  class="inline-block size-3 rounded-sm"
                  style="background-color: var(--color-info)"
                >
                </span>
                <% engine = total_seconds(@breakdown) - human_seconds(@breakdown) %>
                <%= if engine > 0 do %>
                  engine {duration(engine)} ({round1(engine / total_seconds(@breakdown) * 100)}%)
                <% else %>
                  engine — none recorded in this cohort
                <% end %>
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
      <%!-- shrink-0 is load-bearing: this is a scroll container inside a
            flex-col page, and a scroll container's min-height resolves to 0,
            so without it the table collapses to zero height at narrow
            viewports and the colour-independent copy of the chart silently
            disappears. --%>
      <section class="bg-base-200 rounded-lg overflow-x-auto shrink-0">
        <%!-- min-w keeps the five columns readable at 390px: the table scrolls
              horizontally rather than collapsing, because it is the
              colour-independent copy of the chart and may not disappear. --%>
        <table class="table table-sm w-full min-w-[34rem]">
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
            {@cohort.decomposable} of {@cohort.tasks_in_window} tasks decomposable; a distribution
            needs {distribution_floor()}. The chart is withheld deliberately, not missing: bins
            are log-spaced with a &gt;7d overflow bucket, and below {distribution_floor()} tasks
            a bucket holding one task reads as the whole picture rather than as a tail. It
            appears at {distribution_floor()} tasks measured end to end.
          </p>

          <div :if={not @sparse?} id="cycle-time-histogram" class="space-y-2">
            <%!-- pt-5 reserves a band above the tallest bar for the two rule
                  labels, so they never sit on top of the bars or of the direct
                  count labels. --%>
            <div class="relative h-32 pt-5">
              <div class="flex items-end gap-1 h-full">
                <div
                  :for={bucket <- @distribution.buckets}
                  class="flex-1 flex flex-col justify-end items-center h-full"
                  title={"#{bucket.label}: #{bucket.count} tasks"}
                >
                  <%!-- Direct-labelled: you cannot read 11 from 1 by bar
                        height alone once one bucket dominates. --%>
                  <span
                    :if={bucket.count > 0}
                    class="font-mono text-[10px] text-base-content leading-none pb-0.5"
                  >
                    {bucket.count}
                  </span>
                  <%!-- min-height floor: the >7d bucket is a single task, and
                        that task is what drags the mean away from the median.
                        A 4px sliver made the mark that explains the whole
                        median/mean gap the least visible thing on the chart. --%>
                  <div
                    class="w-full rounded-t"
                    style={"height: #{bucket_height(bucket, @distribution.buckets)}; min-height: #{if bucket.count > 0, do: "6px", else: "0"}; background-color: var(--color-info)"}
                  >
                  </div>
                </div>
              </div>

              <%!-- The two labels sit at different heights and carry the panel
                    surface behind them: stacked at the same offset they
                    overlapped the bar they annotate. --%>
              <div
                :for={
                  {label, seconds, style, offset} <- [
                    {"median", @distribution.median_seconds, "border-left-style: solid", "-top-5"},
                    {"mean", @distribution.mean_seconds, "border-left-style: dashed", "-top-5"}
                  ]
                }
                :if={rule_position(seconds, @distribution.buckets)}
                id={"cycle-rule-#{label}"}
                class="absolute top-5 bottom-0 border-l-2 border-base-content"
                style={"left: #{rule_position(seconds, @distribution.buckets)}%; #{style}"}
              >
                <span class={[
                  "absolute left-1 whitespace-nowrap font-mono text-[10px]",
                  "text-base-content bg-base-200 px-1 rounded",
                  offset
                ]}>
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

          <%!-- An undated trend line is a shape without a domain: the first
                and last dates are the minimum that makes it readable. --%>
          <div
            :if={@throughput.series != []}
            id="throughput-axis"
            class="flex justify-between text-[10px] text-neutral font-mono"
          >
            <span>{axis_date(List.first(@throughput.series))}</span>
            <span>{axis_date(List.last(@throughput.series))}</span>
          </div>

          <p :if={@throughput.series == []} class="text-sm text-base-content">
            No completions recorded in this window.
          </p>

          <p class="text-xs text-neutral">
            Days with no completions are shown in the series and excluded from the divisor, so the
            rate is the pace the pipeline ran at rather than an average over idle days.
          </p>
        </section>

        <section
          id="agent-activity"
          class="bg-base-200 rounded-lg overflow-x-auto shrink-0 lg:col-span-2"
        >
          <h2 class="text-sm font-semibold uppercase tracking-wider p-4 pb-2">
            Agent activity
          </h2>

          <table :if={@agent_activity != []} class="table table-sm w-full">
            <thead>
              <tr>
                <th>Agent</th>
                <th class="text-right">Done</th>
                <th class="text-right">Blockers (human)</th>
                <th class="text-right">Blockers (no human)</th>
                <th class="text-right">Blockers per done</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @agent_activity} id={"agent-row-#{row.agent_id}"}>
                <td class="whitespace-nowrap">{row.agent_name}</td>
                <td class="text-right font-mono" data-role="completions">{row.completions}</td>
                <td class="text-right font-mono" data-role="blockers-needs-human">
                  {row.blockers_needs_human}
                </td>
                <td class="text-right font-mono" data-role="blockers-no-human">
                  {row.blockers_no_human}
                </td>
                <td class="text-right font-mono" data-role="ratio">
                  {ratio(row.blockers_per_completion)}
                </td>
              </tr>
            </tbody>
          </table>

          <p :if={@agent_activity == []} class="text-sm text-base-content px-4 pb-4">
            No agent activity in this window.
          </p>

          <p class="text-xs text-neutral px-4 pb-4">
            Done counts every task completed in the window, attributed to its current execution
            assignee. Blockers are the runtime events filed with report_blocker. An agent with
            no completions has no ratio.
          </p>
        </section>
      </div>
    </div>
    """
  end
end
