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

  The `design` feature owns three responsibilities that make up the
  Designer role bundle:

    * `design.critique` → handled by `Handlers.DesignCritique`
    * `design.spec_writer` → handled by `Handlers.DesignSpecWriter`
    * `design.brand_check` → handled by `Handlers.DesignBrandCheck`

  So this shim dispatches on `responsibility.key` via `handler_for/1`
  and hands off to the concrete handler module. Any unmapped key logs a
  warning and returns `{:error, :unknown_design_responsibility}` — the
  smoke signal for a drift between the built-ins list and this
  dispatch table.

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
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register do
    DesignCritique.register() ++
      DesignSpecWriter.register() ++
      DesignBrandCheck.register()
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

  # ── internals ─────────────────────────────────────────────────────────────

  defp unknown_key(%Responsibility{key: key}) do
    Logger.warning(
      "[design provider] unknown responsibility key=#{inspect(key)} — no handler mapped; " <>
        "add a clause to Providers.Design.handler_for/1 or drop the row from BuiltIns.providers/0"
    )

    {:error, :unknown_design_responsibility}
  end
end
