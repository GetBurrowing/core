defmodule Platform.Responsibilities.Providers.Memory do
  @moduledoc """
  Provider shim for the `memory` feature (ADR-0041 M8 stage 6).

  The Router resolves the per-feature provider module by camelcasing
  the responsibility's `feature` field
  (`Platform.Responsibilities.Router.provider_module_for/1`), so any
  row with `feature == "memory"` looks up
  `Platform.Responsibilities.Providers.Memory` — **this module** — for
  its `handle_output/3` callback.

  Unlike the `meetings` feature (which has exactly one responsibility:
  `meetings.summarize`), the `memory` feature owns three:

    * `memory.daily_summary` → handled by `Handlers.DailySummary`
    * `memory.dreaming` → handled by `Handlers.Dreaming`
    * `memory.propose_long_term` → handled by `Handlers.ProposeLongTerm`

  So this shim dispatches by `responsibility.key` to the right
  per-key handler. Adding a new `memory.*` responsibility means adding
  a clause here (plus the handler module) — single-source dispatch
  keeps the Router unaware of the per-key fan-out.

  ## Why a shim instead of one big "Memory" handler

  Each key has its own side effect (journal append vs context-file
  upsert), its own output contract (`summary` vs `memory_body`), and
  its own context_provided set. Collapsing them would lose the
  property that an operator can assign different agents to
  "write the daily summary" vs "curate org memory overnight". Keep
  the handlers as separate units; this module is the routing seam,
  not the implementation.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.Handlers.{DailySummary, Dreaming, ProposeLongTerm}
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register do
    # Aggregate the per-handler register specs so a Registry that
    # walks this module (rather than the individual handlers) still
    # sees all rows. Both Handlers AND this shim being in the
    # provider list is harmless — `upsert_by_key/1` is idempotent.
    DailySummary.register() ++ Dreaming.register() ++ ProposeLongTerm.register()
  end

  @doc """
  Return the concrete handler module for a given responsibility (or key).

  Public as of task 019f9b28 stage 4. This was a private
  `dispatch_module/1` returning `{:ok, mod} | :error`, which made
  `memory` the 1 in a 3-to-1 convention split — `Providers.Design`,
  `Providers.Meetings` and `Providers.Tasks` all expose a public
  `handler_for/1` returning `module() | nil`. The split mattered because
  `test/platform/responsibilities/provider_coverage_test.exs` walks every
  provider uniformly, and a guard with a special case is how the failure
  class comes back.

  Returns `nil` for any key not owned by this feature so callers can
  branch on the missing case explicitly.
  """
  @spec handler_for(Responsibility.t() | %{key: String.t()} | String.t() | any()) ::
          module() | nil
  def handler_for(%Responsibility{key: key}), do: handler_for(key)
  def handler_for(%{key: key}), do: handler_for(key)
  def handler_for("memory.daily_summary"), do: DailySummary
  def handler_for("memory.dreaming"), do: Dreaming
  def handler_for("memory.propose_long_term"), do: ProposeLongTerm
  def handler_for(_), do: nil

  @impl true
  def gather_context(%Responsibility{key: key} = responsibility, ctx)
      when is_map(ctx) and is_binary(key) do
    case handler_for(key) do
      nil -> {:ok, %{}}
      mod -> mod.gather_context(responsibility, ctx)
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(%Responsibility{key: key} = responsibility, parsed)
      when is_binary(key) do
    case handler_for(key) do
      nil ->
        Logger.warning(
          "[Providers.Memory] no per-key handler for key=#{inspect(key)} — skipping handle_output/2"
        )

        :ok

      mod ->
        mod.handle_output(responsibility, parsed)
    end
  end

  def handle_output(_responsibility, _parsed), do: :ok

  @impl true
  def handle_output(%Responsibility{key: key} = responsibility, parsed, trigger_meta)
      when is_binary(key) and is_map(trigger_meta) do
    case handler_for(key) do
      nil ->
        Logger.warning(
          "[Providers.Memory] no per-key handler for key=#{inspect(key)} — skipping handle_output/3"
        )

        :ok

      mod ->
        mod.handle_output(responsibility, parsed, trigger_meta)
    end
  end

  def handle_output(_responsibility, _parsed, _trigger_meta), do: :ok
end
