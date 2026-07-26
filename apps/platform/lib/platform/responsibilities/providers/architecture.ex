defmodule Platform.Responsibilities.Providers.Architecture do
  @moduledoc """
  Provider shim for the `architecture` feature (task 019f9b28 stage 1,
  ADR-0046 prerequisite #2).

  The M6 Router resolves the per-feature provider module from the
  responsibility's `feature` field and the
  `Platform.Responsibilities.Providers.` namespace (see
  `Platform.Responsibilities.Router.provider_module_for/1`). So a row
  with `feature == "architecture"` looks up
  `Platform.Responsibilities.Providers.Architecture` — **this module** —
  for its Provider callbacks.

  Until this module existed there was nothing at that address, and the
  Router's fallbacks treat "module missing" exactly like "not
  applicable". The whole architecture chain degraded silently:

    * `gather_context_via_provider/3` fell back to the generic
      `ContextGatherer`, so the plan/diff payload never reached the
      handler that knows how to read it,
    * `build_prompt_via_provider/2` fell to `:legacy`, so each handler's
      own `build_prompt/1` never ran and the architect was sent an
      un-seeded template render instead,
    * `invoke_handle_output/3` logged "no output handler for
      architecture.review_plan" and returned `:ok`, discarding the
      answer we had just paid for.

  Meanwhile `Platform.Tasks` fires `architecture.review_plan` on every
  plan submission and `Platform.Tasks.PlanEngine` fires
  `architecture.audit_diff` on every successful stage. Both fire sites
  were live the whole time.

  The `architecture` feature owns three responsibilities that make up
  the Architect role bundle:

    * `architecture.review_plan` → handled by `Handlers.ArchitectureReviewPlan`
    * `architecture.audit_diff` → handled by `Handlers.ArchitectureAuditDiff`
    * `architecture.cron_sweep` → handled by `Handlers.ArchitectureCronSweep`

  So this shim dispatches on `responsibility.key` via `handler_for/1`
  and hands off to the concrete handler module. Any unmapped key logs a
  warning and returns `{:error, :unknown_architecture_responsibility}` —
  the smoke signal for a drift between the built-ins list and this
  dispatch table.

  ## Why `build_prompt/1` is implemented here and not on `Providers.Design`

  All three architecture handlers own their prompt end-to-end via
  `build_prompt/1`, and that is the entire point of this shim: the
  architect's prompt is *only* reachable through a provider module. A
  provider that omitted the callback would still leave the Router on the
  `:legacy` template path, which is the bug rather than a fix for it.

  Note the return contract, which is narrower than it looks. The Router
  treats `{:error, :no_build_prompt}` as "use the legacy template render"
  but treats **any other** `{:error, _}` as a refusal that short-circuits
  the dispatch entirely — it logs "provider build_prompt refused
  dispatch" and never fires the LLM call. So an unmapped or absent key
  must return exactly `{:error, :no_build_prompt}`; anything else would
  convert a routing miss into a dropped call, which is strictly worse
  than the bug this module fixes. Mirrors
  `Platform.Responsibilities.Providers.Meetings.build_prompt/1`.

  ## Why a shim instead of one big "Architecture" handler

  Each key has its own trigger (plan-submit event, stage-complete
  event, cron), its own context shape (plan payload vs stage diff vs a
  `gh` repo sweep), and its own output side effect (an execution-space
  annotation vs a filed task). Keeping them as separate handler units
  means an operator can assign different agents to "review this plan" vs
  "audit this diff" vs "sweep the repo". This module is the routing
  seam, not the implementation.

  ## Not wired here on purpose

  The `security.*` keys are also missing a provider module, but that is
  deliberate rather than drift: they are superseded by
  `Platform.Security.Sweeper`'s own scanner dispatch table and their
  handler moduledocs state the Router must never fire them. Wiring them
  through a shim would re-enable a path we intend to stay dead.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.ArchitectureAuditDiff
  alias Platform.Responsibilities.Handlers.ArchitectureCronSweep
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register do
    ArchitectureReviewPlan.register() ++
      ArchitectureAuditDiff.register() ++
      ArchitectureCronSweep.register()
  end

  @doc """
  Return the concrete handler module for a given responsibility (or key).

  Public so integration tests can assert the role → bundle →
  responsibility → handler wiring lands on the expected module without
  reaching through the M6 Router. Follows the `Providers.Design` /
  `Providers.Tasks` / `Providers.Meetings` convention rather than
  `Providers.Memory`'s private `dispatch_module/1`.

  Returns `nil` for any key not owned by this feature so callers can
  branch on the missing case explicitly.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("architecture.review_plan"), do: Handlers.ArchitectureReviewPlan
  def handler_for("architecture.audit_diff"), do: Handlers.ArchitectureAuditDiff
  def handler_for("architecture.cron_sweep"), do: Handlers.ArchitectureCronSweep
  def handler_for(_), do: nil

  @impl true
  def gather_context(%Responsibility{} = responsibility, ctx) when is_map(ctx) do
    case handler_for(responsibility) do
      nil -> unknown_key(responsibility)
      handler -> handler.gather_context(responsibility, ctx)
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    case handler_for(responsibility) do
      nil -> unknown_key(responsibility)
      handler -> handler.handle_output(responsibility, parsed)
    end
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    case handler_for(responsibility) do
      nil -> unknown_key(responsibility)
      handler -> handler.handle_output(responsibility, parsed, trigger_meta)
    end
  end

  @doc """
  Provider-level `build_prompt/1` — the callback that makes the
  architect's own prompt reachable at all.

  The Router's `dispatch_assignee/4` calls this after `gather_context/2`,
  for external *and* native/federated assignees alike. When it returns
  `{:ok, %{system:, user:}}` the rendered prompt is handed to the
  external dispatcher verbatim (or ridden along the native dispatch
  signal as `metadata.prompt`), skipping the un-seeded
  `default_prompt_template` render path.

  The Router stuffs the fired `Responsibility` into the context under
  `:__responsibility__` before calling us, so we dispatch by key. All
  three architecture handlers implement `build_prompt/1`, so a mapped
  key always delegates.

  An unmapped or absent key returns exactly `{:error, :no_build_prompt}`
  — the one error value the Router reads as "fall back to the legacy
  template render" instead of "refuse this dispatch". See the moduledoc.
  """
  @impl true
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, term()}
  def build_prompt(context) when is_map(context) do
    case handler_for(Map.get(context, :__responsibility__)) do
      nil -> {:error, :no_build_prompt}
      handler -> handler.build_prompt(context)
    end
  end

  def build_prompt(_), do: {:error, :no_build_prompt}

  # ── internals ─────────────────────────────────────────────────────────────

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[architecture provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add a clause to Providers.Architecture.handler_for/1 or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_architecture_responsibility}
  end
end
