defmodule Platform.Experiments.Results do
  @moduledoc """
  Turns an experiment into the figures a reader may see, and decides which of
  them have been EARNED. Task 019fe6ba, ADR-0048.

  ## Core, not web (task 01a0d415 stage 2)

  This module used to be `PlatformWeb.ExperimentResults`. It moved into the
  context so the MCP tool `experiment_results` (`Platform.Experiments.Tools`)
  can serve the same rows the page renders without core depending on the web
  layer. `PlatformWeb.ExperimentResults` now delegates here; there is ONE
  implementation of "earned", so the page and the tool cannot disagree about
  whether a figure exists.

  This module exists because two things the UI needs are genuinely absent
  from the context layer, and inventing them inside a template would scatter
  the decision across every call site:

    * `experiments.primary_metric` is a free-text string and nothing upstream
      maps it onto a `Platform.Experiments.Metric` implementation; and
    * `experiments.stop_rule` is an unconstrained `:map` with no evaluator.

  Both are resolved here, once, so there is a single place to change when the
  context grows its own registry.

  ## The stop rule fails CLOSED

  `min_subjects/1` reads `stop_rule["min_subjects"]`. An experiment whose
  stop rule is empty, malformed, or names no subject count has **not** earned
  a figure and never will until someone writes one down.

  The alternative — treating "no stop rule" as "no threshold to clear", and
  therefore printing the number — is the failure ADR-0048 is about. It makes
  the honest state the one that requires configuration and the misleading
  state the default, so every experiment created in a hurry reports a
  confident figure over four subjects. Absent evidence of sufficiency is not
  evidence of sufficiency.

  ## `n` is the metric's count, and the stop rule is measured against IT

  The comparison is `Result.n >= min_subjects`, not `assignment count >=
  min_subjects`. Those differ, deliberately and by a lot: `n` counts units
  actually measured (resolved validations, plans, tasks — each metric's
  moduledoc says which) after excluded subjects have left both sides, while
  the assignment count includes subjects whose work has not been evaluated
  yet. Comparing the stop rule against assignments would clear the threshold
  on the strength of data nobody has measured, which is a figure with a
  smaller basis than it claims.

  The assignment counts are still reported alongside — see
  `PlatformWeb.ExperimentsLive` — because a reader needs both "how many
  subjects are in this arm" and "how much of that has been measured", and
  neither substitutes for the other.

  ## No comparison between arms, and no projection

  Every variant's figure is computed and presented on its own. There is no
  lift, no delta against control, no projection, and no extrapolation to a
  final value — for the reason `Platform.Experiments.Metric` gives at
  length: an effect size over forty subjects lends a precision the data does
  not have, and a projected lift is the specific shape that makes noise read
  as measurement.
  """

  alias Platform.Experiments
  alias Platform.Experiments.Assignments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Metric.Result

  @typedoc """
  One variant's row on the results view.

  `earned?` is the ONLY thing the view may branch on to decide whether a
  number appears; `value`/`unit` are nil unless it is true, so a caller that
  ignores the flag still has nothing to print.
  """
  @type row :: %{
          variant_slug: String.t(),
          earned?: boolean(),
          value: float() | nil,
          unit: atom() | nil,
          n: non_neg_integer(),
          subjects: non_neg_integer(),
          excluded: non_neg_integer(),
          min_subjects: pos_integer() | nil,
          pending: non_neg_integer(),
          reason: :measured | :insufficient_data | :below_stop_rule | :no_stop_rule | :no_metric
        }

  # The registry now lives in `Platform.Experiments.Metrics`. These two
  # functions stay because callers and tests use them by name, but they hold
  # NO list of their own — a second copy is how you get a metric that can be
  # selected in the UI and resolves to `:no_metric` when computed.
  @doc "The metric slugs this UI can compute. Delegates to the context."
  @spec known_metrics() :: [String.t()]
  defdelegate known_metrics(), to: Platform.Experiments.Metrics

  @doc "Resolves `primary_metric` to a module, or nil when unrecognised."
  @spec metric_module(String.t() | nil) :: module() | nil
  defdelegate metric_module(slug), to: Platform.Experiments.Metrics

  @doc """
  The subject count a figure must reach before it may be shown, or nil.

  Fails closed — see the moduledoc. Accepts the integer under either an
  atom or string key, because `stop_rule` is a `:map` column and round-trips
  through JSON as strings while an in-memory changeset may still hold atoms.
  """
  @spec min_subjects(Experiment.t()) :: pos_integer() | nil
  def min_subjects(%Experiment{stop_rule: stop_rule}) when is_map(stop_rule) do
    case Map.get(stop_rule, "min_subjects", Map.get(stop_rule, :min_subjects)) do
      n when is_integer(n) and n > 0 -> n
      _ -> nil
    end
  end

  def min_subjects(_), do: nil

  @doc """
  Human-readable stop rule, always a sentence — never blank.

  A missing stop rule renders as a statement that none is set, not as an
  empty string: the basis line has to say something in every state, or the
  reader cannot tell "no threshold recorded" from "the label failed to
  render".
  """
  @spec stop_rule_label(Experiment.t()) :: String.t()
  def stop_rule_label(%Experiment{} = experiment) do
    case min_subjects(experiment) do
      nil -> "no stop rule set"
      n -> "stop rule #{n}"
    end
  end

  @doc """
  Every variant's row for one experiment, control first.

  Control is ordered first because it is the thing the others are read
  against; the remainder stay in slug order so the list does not reshuffle
  between renders.
  """
  @spec rows(Experiment.t()) :: [row()]
  def rows(%Experiment{} = experiment) do
    assignments = Assignments.list_assignments(experiment)

    experiment
    |> Experiments.list_variants()
    |> Enum.sort_by(&{&1.slug != Experiment.control_slug(), &1.slug})
    |> Enum.map(&row(experiment, &1.slug, assignments))
  end

  @doc """
  The experiment's headline row — the control arm's, or a metric-less
  placeholder when there are no variants yet.

  A draft with no variants still gets a row, so the list renders a complete
  cell for it rather than a hole. That is the sparse state, and a page that
  looks broken when data is thin gets assumed broken.
  """
  @spec headline_row(Experiment.t()) :: row()
  def headline_row(%Experiment{} = experiment) do
    case rows(experiment) do
      [] -> empty_row(experiment)
      [first | _] -> first
    end
  end

  defp empty_row(experiment) do
    %{
      variant_slug: Experiment.control_slug(),
      earned?: false,
      value: nil,
      unit: nil,
      n: 0,
      subjects: 0,
      excluded: 0,
      min_subjects: min_subjects(experiment),
      pending: 0,
      reason: :insufficient_data
    }
  end

  defp row(experiment, variant_slug, assignments) do
    arm = Enum.filter(assignments, &(&1.variant_slug == variant_slug))
    excluded = Enum.count(arm, &(&1.excluded_reason != nil))
    minimum = min_subjects(experiment)

    base = %{
      variant_slug: variant_slug,
      earned?: false,
      value: nil,
      unit: nil,
      n: 0,
      # Every assigned subject, excluded ones included. The excluded count
      # sits beside it rather than being subtracted out of sight: rule 4 of
      # ADR-0048 is that an exclusion stays legible in the denominator it
      # left.
      subjects: length(arm),
      excluded: excluded,
      min_subjects: minimum,
      # Subjects still inside an outcome metric's observation window. They
      # are in neither the numerator nor `n`, and they are NOT non-responses.
      pending: 0,
      reason: :insufficient_data
    }

    case compute(experiment, variant_slug) do
      {:ok, %Result{value: value, n: n, unit: unit} = result} ->
        earned? = is_integer(minimum) and n >= minimum

        %{
          base
          | n: n,
            pending: result.pending || 0,
            # value/unit are carried ONLY when the figure was earned. A view
            # that forgets to check `earned?` still has nil to render, so the
            # stop rule is enforced here rather than trusted to every caller.
            value: if(earned?, do: value),
            unit: if(earned?, do: unit),
            earned?: earned?,
            reason: reason_for(earned?, minimum)
        }

      {:insufficient_data, pending} ->
        %{base | pending: pending, reason: :insufficient_data}

      :no_metric ->
        %{base | reason: :no_metric}
    end
  end

  defp reason_for(true, _minimum), do: :measured
  defp reason_for(false, nil), do: :no_stop_rule
  defp reason_for(false, _minimum), do: :below_stop_rule

  # `Metrics.compute_spec/2` reads the experiment's `metric_spec` and falls
  # back to `primary_metric` as the `registered` kind, so an experiment that
  # predates metric specs computes exactly what it computed before. A spec
  # that no longer parses has nothing to measure: `:no_metric`, never 0.0.
  defp compute(experiment, variant_slug) do
    case Platform.Experiments.Metrics.compute_spec(experiment, variant_slug) do
      {:ok, %Result{}} = ok -> ok
      # A windowed kind reports its pending subjects even when none is yet
      # eligible; dropping them here is how an in-window arm read 0 pending.
      {:insufficient_data, %{pending: pending}} -> {:insufficient_data, pending}
      :insufficient_data -> {:insufficient_data, 0}
      _no_metric_or_error -> :no_metric
    end
  end

  # ── Per-agent breakdown (task 01a114a8 stage 4) ─────────────────────────

  @by_agent_fields [
    {"suite_tool_calls", "mean"},
    {"suite_tool_calls", "median"},
    {"client_turns", "mean"},
    {"client_tokens_in", "mean"},
    {"client_tokens_out", "mean"},
    {"wall_ms", "mean"},
    {"wall_ms", "median"},
    {"outcome_first_pass", "mean"},
    {"tool_calls_error", "mean"}
  ]

  @doc """
  One row per (dispatched agent x arm) for an experiment whose subjects are
  tasks, built from `Platform.Orchestration.DispatchMetrics.for_tasks/2`
  over each arm's assigned, non-excluded tasks. Written for the
  `dispatch.code_mode` surface (`code_mode_report`) and usable on any
  task-subject experiment.

  Each row carries:

    * `agent_id`, `variant_slug`, `suite_run_arm` (the arm payload's
      `"suite_run"`, nil when the arm has no such key), `tasks` (distinct
      assigned tasks the agent was dispatched on) and `n` (dispatches);
    * `metrics`: `"<field>_<agg>"` => `%{value, n, reason}` for every
      field `DispatchUsage` aggregates. `n` is how many dispatches carried
      the field. `value` is nil, never 0, when none did
      (`reason: :insufficient_data`), and nil below the experiment's stop
      rule (`:below_stop_rule`, or `:no_stop_rule` when none is set), the
      same "earned" rule as `rows/1`;
    * `suite_run_dispatches` (dispatches with at least one suite_run call),
      `suite_run_adoption_rate` (share of those, only on an arm whose
      payload says `suite_run: true`) and `control_suite_run_violations`
      (the same count, only on an arm whose payload says `suite_run: false`);
    * `coverage`: how much of the agent is measurable. `unit_source`
      counts dispatches per source (`ack`, `stage_row`, `lease`) and
      `ack_pct` their ack share; a runtime that cannot call `task_ack`
      shows as stage_row-only. `client_report_pct` is the share of
      dispatches with a usage report. `attribution_pct` / `attribution_by_rung`
      are the agent's model-issued tool calls since the experiment's first
      assignment
      (all tasks, both arms: an unattributed call cannot be tied to a task),
      so the two arms of one agent carry the same figure.

  Excluded subjects are left out of every row, and no arm is compared with
  another here: the rows sit side by side for a reader.
  """
  @spec by_agent(Experiment.t(), keyword()) :: [map()]
  def by_agent(%Experiment{} = experiment, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    assignments = experiment |> Assignments.list_assignments() |> Enum.filter(&measured?/1)
    arm_by_task = Map.new(assignments, &{&1.subject_id, &1.variant_slug})
    payloads = arm_payloads(experiment)

    dispatches =
      arm_by_task
      |> Map.keys()
      |> Platform.Orchestration.DispatchMetrics.for_tasks(now: now)

    coverage = attribution_by_agent(experiment, assignments, now)
    minimum = min_subjects(experiment)

    groups = Enum.group_by(dispatches, &{&1.agent_id, Map.fetch!(arm_by_task, &1.task_id)})

    # A cohort agent with no dispatch in an arm still gets that row, with
    # n 0: an enrolled agent producing no data must be visible, not absent.
    empty =
      for agent_id <- cohort_agent_ids(experiment.assignment_policy),
          slug <- Map.keys(payloads),
          not Map.has_key?(groups, {agent_id, slug}),
          into: %{},
          do: {{agent_id, slug}, []}

    groups
    |> Map.merge(empty)
    |> Enum.map(fn {{agent_id, slug}, rows} ->
      agent_row(
        agent_id,
        slug,
        rows,
        Map.get(payloads, slug),
        Map.get(coverage, agent_id),
        minimum
      )
    end)
    |> Enum.sort_by(
      &{to_string(&1.agent_id), &1.variant_slug != Experiment.control_slug(), &1.variant_slug}
    )
  end

  # The agent ids a task_cohort names, at any depth of a composite policy.
  defp cohort_agent_ids(%{} = policy) do
    own =
      case Map.get(policy, "cohort") do
        %{"agent_id" => ids} when is_list(ids) -> Enum.filter(ids, &is_binary/1)
        %{"agent_id" => id} when is_binary(id) -> [id]
        _ -> []
      end

    nested =
      case Map.get(policy, "policies") do
        list when is_list(list) -> Enum.flat_map(list, &cohort_agent_ids/1)
        _ -> []
      end

    Enum.uniq(own ++ nested)
  end

  defp cohort_agent_ids(_policy), do: []

  defp measured?(%{subject_type: "task", excluded_reason: nil}), do: true
  defp measured?(_assignment), do: false

  defp arm_payloads(experiment) do
    experiment
    |> Experiments.list_variants()
    |> Map.new(fn variant -> {variant.slug, variant.payload || %{}} end)
  end

  # The window opens at the experiment's first assignment (an experiment
  # has no started_at column), else at its creation.
  defp attribution_by_agent(%Experiment{} = experiment, assignments, now) do
    from =
      case assignments do
        [] -> experiment.inserted_at
        rows -> rows |> Enum.map(& &1.assigned_at) |> Enum.min(DateTime)
      end

    %{from: from, to: now}
    |> Platform.Orchestration.DispatchMetrics.attribution_coverage_for()
    |> Map.new(&{&1.agent_id, &1})
  end

  defp agent_row(agent_id, slug, rows, payload, attribution, minimum) do
    n = length(rows)
    suite_run_arm = suite_run_flag(payload)
    with_suite_run = Enum.count(rows, &((&1.suite_run_calls || 0) > 0))
    sources = Enum.frequencies_by(rows, & &1.unit_source)
    reported = Enum.count(rows, &((&1.client_reports || 0) > 0))

    %{
      agent_id: agent_id,
      variant_slug: slug,
      suite_run_arm: suite_run_arm,
      tasks: rows |> Enum.map(& &1.task_id) |> Enum.uniq() |> length(),
      n: n,
      metrics: Map.new(@by_agent_fields, &metric(rows, &1, minimum)),
      suite_run_dispatches: with_suite_run,
      suite_run_adoption_rate: if(suite_run_arm == true, do: ratio(with_suite_run, n)),
      control_suite_run_violations: if(suite_run_arm == false, do: with_suite_run),
      coverage: %{
        unit_source: Map.new(~w(ack stage_row lease), &{&1, Map.get(sources, &1, 0)}),
        ack_pct: pct(Map.get(sources, "ack", 0), n),
        client_report_pct: pct(reported, n),
        attribution_tool_calls: attribution && attribution.tool_calls,
        attribution_pct: attribution && attribution.pct,
        attribution_by_rung: (attribution && attribution.by_rung) || %{}
      }
    }
  end

  defp suite_run_flag(%{"suite_run" => flag}) when is_boolean(flag), do: flag
  defp suite_run_flag(_payload), do: nil

  # The stop rule gates every per-agent figure exactly as it gates `rows/1`:
  # `value` is carried only when `n >= min_subjects`, and a missing stop
  # rule earns nothing. `n` is always present.
  defp metric(rows, {field, agg}, minimum) do
    key = field <> "_" <> agg

    case Platform.Experiments.MetricKinds.DispatchUsage.aggregate(rows, field, agg) do
      {:ok, %Result{value: value, n: n}} ->
        earned? = is_integer(minimum) and n >= minimum

        {key,
         %{
           value: if(earned?, do: value),
           n: n,
           reason: reason_for(earned?, minimum)
         }}

      :insufficient_data ->
        {key, %{value: nil, n: 0, reason: :insufficient_data}}
    end
  end

  defp ratio(_count, 0), do: nil
  defp ratio(count, n), do: count / n

  defp pct(_count, 0), do: nil
  defp pct(count, n), do: Float.round(count * 100 / n, 1)

  @doc """
  Why a figure is absent, in the reader's words.

  Rule 3 of ADR-0048 — the view states its own insufficiency next to where
  the number would be — is only implementable if the absence has a specific
  cause attached. "No effect yet" alone does not tell a reader whether to
  wait, to fix the stop rule, or to fix the metric slug.
  """
  @spec confound(row()) :: String.t()
  def confound(%{reason: :no_metric}),
    do: "no metric configured — nothing is being measured"

  def confound(%{reason: :no_stop_rule}),
    do: "no stop rule set, so no figure has been earned"

  def confound(%{reason: :insufficient_data, subjects: 0}),
    do: "no subjects assigned yet"

  def confound(%{reason: :insufficient_data}),
    do: "subjects assigned but nothing measured yet"

  def confound(%{reason: :below_stop_rule, n: n, min_subjects: minimum}),
    do: "#{n} of #{minimum} measured"

  def confound(%{reason: :measured}), do: ""

  @doc """
  Formats an earned figure. Returns nil for an unearned row, so this cannot
  be used to smuggle a number past the stop rule.
  """
  @spec figure(row()) :: String.t() | nil
  def figure(%{earned?: false}), do: nil
  def figure(%{value: nil}), do: nil

  def figure(%{value: value, unit: :ratio}),
    do: "#{:erlang.float_to_binary(value * 100, decimals: 1)}%"

  def figure(%{value: value, unit: :seconds}), do: duration(value)

  def figure(%{value: value, unit: _}),
    do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp duration(seconds) when seconds < 3600,
    do: "#{:erlang.float_to_binary(seconds / 60, decimals: 1)} min"

  defp duration(seconds) when seconds < 86_400,
    do: "#{:erlang.float_to_binary(seconds / 3600, decimals: 1)} h"

  defp duration(seconds), do: "#{:erlang.float_to_binary(seconds / 86_400, decimals: 1)} d"

  @doc "The unit's label, for the basis line."
  @spec unit_label(atom()) :: String.t()
  def unit_label(:ratio), do: "of resolved validations"
  def unit_label(:seconds), do: "mean"
  def unit_label(:count), do: "mean"
  def unit_label(_), do: ""
end
