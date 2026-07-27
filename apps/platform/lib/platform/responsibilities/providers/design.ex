defmodule Platform.Responsibilities.Providers.Design do
  @moduledoc """
  Provider shim for the `design` feature (task 019f2455 stage 1).

  The M6 Router resolves the per-feature provider module by camelcasing
  the responsibility's `feature` field and prepending
  `Platform.Responsibilities.Providers.` (see
  `Platform.Responsibilities.Router.provider_module_for/1`). So a row
  with `feature == "design"` looks up
  `Platform.Responsibilities.Providers.Design` — **this module** — for
  its Provider callbacks.

  The `design` feature owns four responsibilities that make up the
  Designer role bundle:

    * `design.critique` → handled by `Handlers.DesignCritique`
    * `design.spec_writer` → handled by `Handlers.DesignSpecWriter`
    * `design.brand_check` → handled by `Handlers.DesignBrandCheck`
    * `design.task_direction` → handled by `Handlers.DesignTaskDirection`
      (ADR-0046 stack member 7, task `019f9b29-5ecd` stage 3)

  So this shim dispatches on `responsibility.key` via `handler_for/1`
  and hands off to the concrete handler module. Any unmapped key logs a
  warning and returns `{:error, :unknown_design_responsibility}` — the
  smoke signal for a drift between the built-ins list and this
  dispatch table.

  ## `build_prompt/1` is per-key, not per-feature

  The Router probes `build_prompt/1` on the PROVIDER module, never on the
  handler (`Router.build_prompt_via_provider/2`), so a handler that owns
  its prompt end-to-end is unreachable unless this shim forwards to it.
  Only `design.task_direction` owns its prompt today; the other three are
  registration placeholders that still render through
  `default_prompt_template`.

  Note the narrow return contract. The Router reads
  `{:error, :no_build_prompt}` as "use the legacy template render", but
  reads **any other** `{:error, _}` as a refusal that short-circuits the
  dispatch and never fires the LLM call. So an unmapped key — or a mapped
  handler that ships no `build_prompt/1` — must return exactly
  `{:error, :no_build_prompt}`. Mirrors
  `Platform.Responsibilities.Providers.Architecture.build_prompt/1`, which
  can skip the `function_exported?/3` probe because all three of its
  handlers implement the callback.

  ## Why a shim instead of one big "Design" handler

  Each key has its own trigger regex, its own output contract (issues
  vs spec vs brand verdict), and its own context_provided set. Keeping
  them as separate handler units means an operator can assign
  different agents to "critique the design" vs "write the spec" vs
  "check the brand". This module is the routing seam, not the
  implementation.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.DesignBrandCheck
  alias Platform.Responsibilities.Handlers.DesignCritique
  alias Platform.Responsibilities.Handlers.DesignSpecWriter
  alias Platform.Responsibilities.Handlers.DesignTaskDirection
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register do
    DesignCritique.register() ++
      DesignSpecWriter.register() ++
      DesignBrandCheck.register() ++
      DesignTaskDirection.register()
  end

  @doc """
  Return the concrete handler module for a given responsibility (or key).
  Public so integration tests can assert the role → bundle →
  responsibility → handler wiring lands on the expected module without
  reaching through the M6 Router.

  Returns `nil` for any key not owned by this feature so callers can
  branch on the missing case explicitly.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("design.critique"), do: Handlers.DesignCritique
  def handler_for("design.spec_writer"), do: Handlers.DesignSpecWriter
  def handler_for("design.brand_check"), do: Handlers.DesignBrandCheck
  def handler_for("design.task_direction"), do: Handlers.DesignTaskDirection
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
  Provider-level `build_prompt/1` — the callback that makes a design
  handler's own prompt reachable at all.

  The Router stuffs the fired `Responsibility` into the context under
  `:__responsibility__` before calling us, so we dispatch by key. A key
  whose handler ships no `build_prompt/1` (the three placeholder handlers)
  returns exactly `{:error, :no_build_prompt}` — the one error value the
  Router reads as "fall back to the legacy template render" rather than
  "refuse this dispatch". See the moduledoc.
  """
  @impl true
  @spec build_prompt(map()) ::
          {:ok, %{system: String.t(), user: String.t()}} | {:error, term()}
  def build_prompt(context) when is_map(context) do
    handler = handler_for(Map.get(context, :__responsibility__))

    if is_atom(handler) and Code.ensure_loaded?(handler) and
         function_exported?(handler, :build_prompt, 1) do
      handler.build_prompt(context)
    else
      {:error, :no_build_prompt}
    end
  end

  def build_prompt(_context), do: {:error, :no_build_prompt}

  # ── internals ─────────────────────────────────────────────────────────────

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[design provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add a clause to Providers.Design.handler_for/1 or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_design_responsibility}
  end
end
