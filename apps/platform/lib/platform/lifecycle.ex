defmodule Platform.Lifecycle do
  @moduledoc """
  Reading of a project's configured lifecycle hook pipelines
  (ADR-0046 Amendment 1, task 019fe1b6 stage 3).

  Thin context. `resolve_pipeline/1` and `resolve_steps/2` return
  **data**. Nothing here calls a step, awaits one, honours a divert,
  halts a pipeline or enforces a budget — that is the runner member of
  this stack.

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
end
