defmodule Platform.Responsibilities.Handlers.ExperimentsScientist do
  @moduledoc """
  `experiments.scientist` responsibility provider (task `01a0d415` stage 5,
  the experimentation-layer ADR-0052): the agent that pursues a goal. It proposes,
  configures, interprets, and stops or requests promotion of experiments, all
  inside the guardrails.

  Structure and `register/0` shape mirror
  `Platform.Responsibilities.Handlers.AgentsGoalHeartbeat`, the verified-live
  cron exemplar. It deliberately does NOT mirror `Handlers.TaskTriage`, whose
  `gather_context/2` is a stub.

  ## Spec

    * `key` — `"experiments.scientist"`
    * `trigger_kind` — `cron`, `0 */6 * * *` (every six hours)
    * `metadata.role` — `scientist`. Assignment IS the enable signal: the
      Router resolves the assignee through `Roles.assignee_for/1`, so with
      no agent pinned to `scientist` a fire returns `{:ok, :unfilled}` and
      dispatches nothing, whatever the cadence.
    * `default_prompt_template` — `"experiments.scientist.v1"`, in
      `PromptTemplates.do_default_templates/0` and seeded by
      `20260924210000_seed_experiments_scientist_prompt.exs`.

  ## What the Scientist sees

  `gather_context/2` returns, for every `active` goal:

    * the goal statement and its `org_id` / `project_id` columns;
    * its live (`draft`, `running`) and recently ended (`stopped`,
      `concluded`, last 30 days) experiments, each with its `Results`
      rows — every figure travels with its `n`, `pending` and `excluded`
      counts, `value` is nil unless earned, and the reason is carried as
      WORDS (`insufficient_data` reads "not yet", never 0.0);
    * a stopped experiment's `stop_feedback` — the stopping person's own
      words, which the prompt tells the Scientist to answer before it
      proposes the next experiment (Rowan, 2026-09-24; ADR section 11);
    * signal counts by status and label, plus the last 20
      `{label, subject_id, confidence, reason}` tuples;
    * the guardrails that apply to the goal's org, with the live count.

  Plus the registered surface list (key, subject_type, path, payload
  schema, targets) and every recently stopped experiment's feedback,
  including experiments with no goal.

  ## Scoped to the assignee's org

  The `scientist` role has one assignee per install and the
  responsibility's `scope` is `global`, but the context is narrowed to the
  org of the agent the role resolves to (`Roles.assignee_for/1`), using the
  SAME home-org check as the stage-2 tools (`Platform.Experiments.Tools.home_org/1`):

    * a TENANT-pinned assignee (`metadata["org_id"]` naming a non-root org)
      sees only its own org's goals, experiments, signals, stop feedback and
      guardrails, plus install-wide (org_id null) goals and experiments;
    * an unpinned or root-pinned assignee is install-wide and sees every org.

  Before this, one cron dispatch carried the goals, figures and label
  reasons of three orgs to a single runtime (task 01a0d415 review). The
  cron fire's `trigger_meta` names no org, so the assignee is the only
  tenancy signal there is. With no assignee the Router returns `:unfilled`
  before it gathers context, so the root-equivalent default for `nil`
  (mirrored from the tools) is never dispatched.

  ## What the Scientist never sees

  Mail bodies, or any `mail_inbound_messages` field. The signal query
  SELECTS only `label`, `subject_id`, `confidence`, `reason` and `status`; it
  never loads `source_id`, and nothing here reads the inbound table. This is
  the injection boundary of ADR section 9: untrusted text reaches the blind
  labeler, which cannot change an experiment, and never the Scientist, which
  can. The `reason` it does see was sanitised, mention-escaped and capped by
  `Platform.Experiments.Labeler`.

  ## Why writes go through the MCP tools, not `handle_output/3`

  Native dispatch (`Router.dispatch_native/5`, router.ex ~1657) never calls
  `invoke_handle_output/3`; that seam runs only after the external HTTP round
  trip. The `AgentsGoalHeartbeat` moduledoc documents the defect that cost
  (task `01a0c332`): a side effect placed in `handle_output/3` is
  unreachable for a native assignee. So the Scientist acts through the
  stage-2 `experiments` MCP tools, which already enforce the guardrails, and
  there is no second write path that could skip them. `handle_output/3` is
  a logged no-op.

  The Scientist's runtime must hold the `experiments` bundle; without it
  every tool is refused above `execute/3` (`Platform.Experiments.Tools`).
  """
  @behaviour Platform.Responsibilities.Provider

  import Ecto.Query

  require Logger

  alias Platform.Experiments
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Goal
  alias Platform.Experiments.Guardrails
  alias Platform.Experiments.Results
  alias Platform.Experiments.Signal
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Tools
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles

  @key "experiments.scientist"
  @feature "experiments"
  @template_slug "experiments.scientist.v1"
  @cron "0 */6 * * *"

  @live_statuses ~w(draft running)
  @ended_statuses ~w(stopped concluded)
  @recent_days 30
  @recent_per_goal 10
  @recent_signals 20
  @recent_stops 20

  @system "You are the Scientist. You pursue the goals below by running experiments " <>
            "inside the guardrails, and you act only through the experiment_* tools. " <>
            "Never read a figure without its n, and never treat missing data as zero."

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc "Canonical prompt template slug backing this responsibility."
  @spec template_slug() :: String.t()
  def template_slug, do: @template_slug

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: @feature,
        trigger_kind: "cron",
        # Every six hours. Dispatch is gated by the `scientist` role assignee
        # via `Roles.assignee_for/1` in the Router, so with nobody pinned this
        # costs nothing.
        #
        # `trigger_config` is in `Responsibilities.@upsert_replace_fields`:
        # `register/0` REPLACES the stored row on every boot. Change the
        # schedule here, not only in the row.
        trigger_config: %{"expression" => @cron},
        scope: "global",
        context_provided: ["goals", "experiments", "results", "signals", "guardrails", "surfaces"],
        # No reply contract is applied: the Scientist writes through the
        # `experiments` MCP tools. The summary is informational.
        output_contract: %{"summary" => "string"},
        default_prompt_template: @template_slug,
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.experiments",
          "status" => "active",
          "role" => "scientist",
          "task" => "01a0d415"
        }
      }
    ]
  end

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def gather_context(_responsibility, ctx) when is_map(ctx), do: {:ok, gather_context(ctx)}
  def gather_context(_responsibility, _ctx), do: {:ok, gather_context(%{})}

  @doc """
  Assemble the Scientist's context. Public so tests can read the shape
  without the Router. See the moduledoc for what is and is not included.
  """
  @spec gather_context(map()) :: map()
  def gather_context(ctx \\ %{}) when is_map(ctx) do
    since = DateTime.add(DateTime.utc_now(), -@recent_days * 86_400, :second)
    home = Tools.home_org(Roles.assignee_for(@key))

    %{
      goals: home |> active_goals() |> Enum.map(&goal_entry(&1, since, home)),
      recent_stops: recent_stops(since, home),
      surfaces: surfaces()
    }
  end

  @impl true
  @spec build_prompt(map()) :: {:ok, %{system: String.t(), user: String.t()}}
  def build_prompt(context) when is_map(context) do
    {:ok, %{system: @system, user: render_instruction(context)}}
  end

  @doc """
  Render the instruction from the seeded template, falling back to the source
  descriptor when no row exists (the heartbeat's pattern). The whole context
  is one assign, `state`, rendered as JSON: nil stays `null`, which the
  template defines, rather than becoming an empty string.
  """
  @spec render_instruction(map()) :: String.t()
  def render_instruction(context) when is_map(context) do
    assigns = %{"state" => render_state(context)}

    case PromptTemplates.render_template(@template_slug, assigns) do
      {:ok, rendered} when is_binary(rendered) and rendered != "" ->
        rendered

      _ ->
        case PromptTemplates.render_default(@template_slug, assigns) do
          {:ok, body} -> body
          _ -> assigns["state"]
        end
    end
  end

  @doc "The context as the JSON the template interpolates."
  @spec render_state(map()) :: String.t()
  def render_state(context) when is_map(context) do
    context
    |> Map.take([:goals, :recent_stops, :surfaces])
    |> Jason.encode!(pretty: true)
  end

  @impl true
  def handle_output(responsibility, output), do: handle_output(responsibility, output, %{})

  @impl true
  def handle_output(_responsibility, _output, _trigger_meta) do
    # Unreachable for a native assignee (see the moduledoc) and deliberately
    # inert for an external one: every Scientist write goes through the
    # guardrailed `experiments` MCP tools, never through this callback.
    Logger.info(
      "[experiments.scientist] output ignored by design; the Scientist acts through " <>
        "the experiments MCP tools, which enforce the guardrails."
    )

    :ok
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  # The tools' read rule (`Platform.Experiments.Tools`): a tenant sees its
  # own org's rows and install-wide ones; root sees everything.
  defp visible(query, :root), do: query

  defp visible(query, {:tenant, org_id}),
    do: where(query, [r], is_nil(r.org_id) or r.org_id == ^org_id)

  defp active_goals(home) do
    from(g in Goal, where: g.status == "active", order_by: [asc: g.inserted_at, asc: g.id])
    |> visible(home)
    |> Repo.all()
  end

  defp goal_entry(%Goal{} = goal, since, home) do
    rails = Guardrails.for_org(goal.org_id)

    %{
      goal: %{
        id: goal.id,
        statement: goal.statement,
        org_id: goal.org_id,
        project_id: goal.project_id,
        metric_spec: goal.metric_spec
      },
      guardrails: %{
        max_live: rails.max_live,
        live: Guardrails.live_count(goal.org_id),
        allowed_surfaces: rails.allowed_surfaces,
        require_human_approval: rails.require_human_approval,
        allow_auto_promote: rails.allow_auto_promote
      },
      experiments: goal.id |> goal_experiments(since, home) |> Enum.map(&experiment_entry/1)
    }
  end

  # Filtered on the EXPERIMENT's org too: an install-wide goal can own
  # experiments in several orgs, and a tenant must not see the others.
  defp goal_experiments(goal_id, since, home) do
    live =
      from(e in Experiment,
        where: e.goal_id == ^goal_id and e.status in @live_statuses,
        order_by: [asc: e.inserted_at, asc: e.id]
      )
      |> visible(home)
      |> Repo.all()

    ended =
      from(e in Experiment,
        where: e.goal_id == ^goal_id and e.status in @ended_statuses and e.updated_at >= ^since,
        order_by: [desc: e.updated_at, desc: e.id],
        limit: @recent_per_goal
      )
      |> visible(home)
      |> Repo.all()

    live ++ ended
  end

  defp experiment_entry(%Experiment{} = e) do
    %{
      id: e.id,
      slug: e.slug,
      name: e.name,
      hypothesis: e.hypothesis,
      status: e.status,
      approval_state: e.approval_state,
      surface_key: e.surface_key,
      surface_target: e.surface_target,
      org_id: e.org_id,
      project_id: e.project_id,
      metric_spec: e.metric_spec,
      stop_rule: e.stop_rule,
      observation_window_days: e.observation_window_days,
      stop_feedback: e.stop_feedback,
      stopped_at: e.stopped_at,
      variants: variants(e),
      results: results(e),
      signals: signals(e)
    }
  end

  defp variants(experiment) do
    experiment
    |> Experiments.list_variants()
    |> Enum.map(&%{slug: &1.slug, weight: &1.weight})
  end

  defp results(experiment) do
    experiment |> Results.rows() |> Enum.map(&result_row/1)
  rescue
    error ->
      Logger.warning(
        "[experiments.scientist] results unavailable experiment=#{experiment.id} " <>
          "error=#{Exception.message(error)}"
      )

      []
  end

  @doc """
  One results row as the Scientist reads it. `value` is nil unless the figure
  was earned; `reading` states the row in words so a missing figure can
  never be read as zero.
  """
  @spec result_row(Results.row()) :: map()
  def result_row(row) do
    %{
      variant_slug: row.variant_slug,
      value: row.value,
      n: row.n,
      pending: Map.get(row, :pending, 0),
      excluded: row.excluded,
      subjects: row.subjects,
      min_subjects: row.min_subjects,
      reason: to_string(row.reason),
      reading: reading(row)
    }
  end

  defp reading(%{reason: :measured} = row),
    do: "#{Results.figure(row)} · n=#{row.n} (#{row.excluded} excluded, #{pending(row)} pending)"

  defp reading(%{reason: :insufficient_data} = row),
    do:
      "insufficient data — not yet, not no effect: #{Results.confound(row)} · n=#{row.n}, " <>
        "#{pending(row)} pending"

  defp reading(row),
    do: "no figure yet: #{Results.confound(row)} · n=#{row.n}, #{pending(row)} pending"

  defp pending(row), do: Map.get(row, :pending, 0)

  # SELECTS five columns only. `source_type` / `source_id` are never loaded,
  # so no path from here reaches the inbound mail row.
  defp signals(%Experiment{id: id}) do
    counts =
      from(s in Signal,
        where: s.experiment_id == ^id,
        group_by: [s.status, s.label],
        select: {s.status, s.label, count(s.id)}
      )
      |> Repo.all()

    recent =
      from(s in Signal,
        where: s.experiment_id == ^id,
        order_by: [desc: s.inserted_at, desc: s.id],
        limit: @recent_signals,
        select: %{
          label: s.label,
          subject_id: s.subject_id,
          confidence: s.confidence,
          reason: s.reason
        }
      )
      |> Repo.all()

    %{
      by_status:
        Enum.reduce(counts, %{}, fn {status, _label, n}, acc ->
          Map.update(acc, status, n, &(&1 + n))
        end),
      by_label:
        counts
        |> Enum.reject(fn {_status, label, _n} -> is_nil(label) end)
        |> Enum.reduce(%{}, fn {_status, label, n}, acc ->
          Map.update(acc, label, n, &(&1 + n))
        end),
      recent: recent
    }
  end

  defp recent_stops(since, home) do
    from(e in Experiment,
      where: e.status == "stopped" and e.updated_at >= ^since,
      order_by: [desc: e.updated_at, desc: e.id],
      limit: @recent_stops,
      select: %{
        id: e.id,
        slug: e.slug,
        name: e.name,
        goal_id: e.goal_id,
        surface_key: e.surface_key,
        surface_target: e.surface_target,
        org_id: e.org_id,
        stop_feedback: e.stop_feedback,
        stopped_by_human: not is_nil(e.stopped_by_user_id),
        stopped_at: e.stopped_at
      }
    )
    |> visible(home)
    |> Repo.all()
  end

  defp surfaces do
    Enum.map(Surfaces.list(), fn surface ->
      %{
        key: surface.key(),
        subject_type: surface.subject_type(),
        path: to_string(surface.path()),
        payload_schema: surface.payload_schema(),
        targets: if(function_exported?(surface, :targets, 0), do: surface.targets())
      }
    end)
  end
end
