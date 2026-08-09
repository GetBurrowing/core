defmodule Platform.Lifecycle do
  @moduledoc """
  Reading of a project's configured lifecycle hook pipelines
  (ADR-0046 Amendment 1, task 019fe1b6 stage 3).

  Thin context. `resolve_pipeline/1` and `resolve_steps/2` return
  **data**. Nothing here calls a step, awaits one, honours a divert,
  halts a pipeline or enforces a budget — that is the runner member of
  this stack. It also holds the two budget knobs the runner will read.

  ## Two budgets, and one can kill a step inside the other

  `step_timeout_ms/0` bounds ONE step; `edge_budget_ms/0` bounds the WHOLE
  pipeline on an edge. They are separate knobs with separate env keys and
  neither is derived from the other.

  The consequence a step author must know (ADR-0046 Amendment 1 decision 5):
  **an edge budget can kill a step that was comfortably inside its own
  per-step budget.** You cannot reason about your step's timeout in
  isolation — the effective limit depends on what else is configured on the
  same edge, and on how long those steps happened to take on that run.

  ## Resolution consults exactly one source

  The pipeline comes from the project row's jsonb `config`, under
  `"lifecycle_pipeline"`, and from nowhere else. There is no org-tier
  lookup, no merge, and no fallback chain.

  Org-level defaults are deferred. `Platform.Tenancy.Org` has no config
  column, and ADR-0046 Amendment 1 records the blocking question as
  deliberately unresolved: orgs are hierarchical (`parent_org_id`), and
  the amendment does not say whether a child org inherits its parent's
  pipeline, replaces it, or whether org-tier inheritance is disallowed.
  Each answer implies a different migration.

  ## The gate for when org defaults do land

  Decision 8 records the intended semantics: **project config REPLACES
  org defaults wholesale.** No merge, no inheritance chain, no `locked`
  flag.

  The test that gates that change is specific, and is written down here
  because the weaker version of it is the natural one to write: seed an
  org that has defaults for an edge AND a project that has its own for
  the same edge, then assert the **org's steps are ABSENT** from the
  resolved pipeline. Asserting only that the project's steps are
  PRESENT would pass under merge semantics too, so it does not
  discriminate between replace and merge and is **not acceptable** as
  the gate.

  That test cannot be written in this member — there is no org-tier
  configuration to seed — and it must not be faked by adding an org
  config column to make it writable. What this member asserts instead
  is the single-source property: with no `lifecycle_pipeline` on the
  project, resolution returns `%{}` regardless of the org, having
  consulted the project row only.
  """

  alias Platform.Lifecycle.PipelineConfig
  alias Platform.Tasks.Project

  @config_key "lifecycle_pipeline"

  # ADR-0046 Amendment 1 decision 5 — TWO budgets, and neither is derived from
  # the other.
  #
  # A per-step budget alone does not bound an edge: three awaited agent steps
  # each comfortably inside a 30-minute step timeout is a 90-minute silent
  # stall in which no single component is misbehaving and there is nothing to
  # page on. Only the edge budget can observe the aggregate.
  #
  # The COST, stated where the code lives because a step author will not read
  # the ADR: an edge budget can kill a step that was well inside its own
  # budget. Nobody can reason about their step's timeout in isolation — the
  # effective limit depends on what else is configured on the same edge and on
  # how long those steps happened to take on that run.
  #
  # Deriving one from the other (`edge = n * step`, or `step = edge / n`)
  # collapses that into a single knob and would make the two distinct timeout
  # behaviours indistinguishable — both of the runner's budget tests would
  # pass on a one-budget implementation. Hence separate attributes and
  # separate env keys, asserted independent in `step_test.exs`.
  #
  # As in `Platform.Orchestration.TaskRouter`, the literal lives here and the
  # READ goes through `Application.get_env/3` so a test can inject a small
  # value per-case, and there is deliberately NO `config/test.exs` override —
  # a test-only value silently becoming the production one is the failure this
  # stack is written against. `default_*` exposes the shipped literal so a
  # guard can assert it independently of whatever a running test injected.
  @step_timeout_ms 1_800_000
  @edge_budget_ms 3_600_000

  # RE-ENTRY BOUND. Every edge can fire more than once per task: `done ->
  # planning` is legal and is the only edge out of `done`, and `blocked` is
  # enterable from six states. Without a bound the first reopen re-fires every
  # notify configured on the edge, and someone gets four duplicate webhooks
  # for one ticket.
  #
  # Shape generalised from `Platform.Tasks.ArchitectureRejection.reject_limit/0`
  # — attribute exposed as a function, callers (including tests) read the
  # accessor and never the literal, because a guard that hardcodes its own copy
  # of a limit is how the class comes back. The `Application.get_env/3` read
  # and the separate `default_*` accessor match the two budgets above.
  #
  # The count itself comes from PERSISTED ROWS (`Runs.run_count/2`, DISTINCT
  # `run_seq`), never from a counter column on the task. That is what makes
  # the bound survive a restart, and what makes it testable by FIRING the edge
  # rather than by inspecting a field.
  @edge_run_limit 3

  @doc """
  The project's configured pipeline map, or `%{}` when it has none.

  Always a map — never `nil` — so a caller can pass the result straight
  to `PipelineConfig.steps_for/2` without a nil branch.
  """
  @spec resolve_pipeline(Project.t() | struct()) :: map()
  def resolve_pipeline(%Project{config: config}) when is_map(config) do
    case Map.get(config, @config_key) do
      pipeline when is_map(pipeline) -> pipeline
      _absent_or_malformed -> %{}
    end
  end

  def resolve_pipeline(%Project{}), do: %{}

  @doc """
  The ordered step list configured on one edge for this project.

  Order is the declared order — it is the pipeline's semantics, not an
  incidental property of the encoding.
  """
  @spec resolve_steps(Project.t() | struct(), binary()) :: [map()]
  def resolve_steps(%Project{} = project, edge) when is_binary(edge) do
    project
    |> resolve_pipeline()
    |> PipelineConfig.steps_for(edge)
  end

  @doc "The `config` key a project's pipeline lives under."
  @spec config_key() :: binary()
  def config_key, do: @config_key

  @doc """
  How long ONE awaited step may take before the executor kills it and records
  `timed_out`, in milliseconds.

  Read through `Application.get_env/3` on every use so a test can inject a
  small value for one case without a `config/test.exs` entry.
  """
  @spec step_timeout_ms() :: pos_integer()
  def step_timeout_ms do
    Application.get_env(:platform, :lifecycle_step_timeout_ms, @step_timeout_ms)
  end

  @doc """
  The SHIPPED per-step budget (30 minutes), independent of any injected
  config. Exposed so a guard can prove a test-only value has not become the
  production one.
  """
  @spec default_step_timeout_ms() :: pos_integer()
  def default_step_timeout_ms, do: @step_timeout_ms

  @doc """
  How long the WHOLE pipeline on one edge may take before the executor stops
  it, in milliseconds.

  Independent of `step_timeout_ms/0` — not a multiple of it, not derived from
  it. This budget can kill a step that was inside its own; see the comment on
  `@edge_budget_ms`.
  """
  @spec edge_budget_ms() :: pos_integer()
  def edge_budget_ms do
    Application.get_env(:platform, :lifecycle_edge_budget_ms, @edge_budget_ms)
  end

  @doc """
  The SHIPPED per-edge budget (60 minutes), independent of any injected
  config. Exposed so a guard can prove a test-only value has not become the
  production one.
  """
  @spec default_edge_budget_ms() :: pos_integer()
  def default_edge_budget_ms, do: @edge_budget_ms

  @doc """
  How many times ONE edge may fire for ONE task before further firings are
  suppressed.

  Counted from persisted `lifecycle_step_runs` rows, not from a field on the
  task. Callers — including tests — read this accessor and never the literal.
  """
  @spec edge_run_limit() :: pos_integer()
  def edge_run_limit do
    Application.get_env(:platform, :lifecycle_edge_run_limit, @edge_run_limit)
  end

  @doc """
  The SHIPPED re-entry bound, independent of any injected config. Exposed so
  a guard can prove a test-only value has not become the production one.
  """
  @spec default_edge_run_limit() :: pos_integer()
  def default_edge_run_limit, do: @edge_run_limit
end
