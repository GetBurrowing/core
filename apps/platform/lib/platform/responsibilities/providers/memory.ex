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
  `meetings.summarize`), the `memory` feature owns two:

    * `memory.daily_summary` → handled by `Handlers.DailySummary`
    * `memory.dreaming` → handled by `Handlers.Dreaming`

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

  alias Platform.Responsibilities.Handlers.{DailySummary, Dreaming}
  alias Platform.Responsibilities.Responsibility

  @impl true
  def register do
    # Aggregate the per-handler register specs so a Registry that
    # walks this module (rather than the individual handlers) still
    # sees both rows. Both Handlers AND this shim being in the
    # provider list is harmless — `upsert_by_key/1` is idempotent.
    DailySummary.register() ++ Dreaming.register()
  end

  @impl true
  def gather_context(%Responsibility{key: key} = responsibility, ctx)
      when is_map(ctx) and is_binary(key) do
    case dispatch_module(key) do
      {:ok, mod} -> mod.gather_context(responsibility, ctx)
      :error -> {:ok, %{}}
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(%Responsibility{key: key} = responsibility, parsed)
      when is_binary(key) do
    case dispatch_module(key) do
      {:ok, mod} ->
        mod.handle_output(responsibility, parsed)

      :error ->
        Logger.warning(
          "[Providers.Memory] no per-key handler for key=#{inspect(key)} — skipping handle_output/2"
        )

        :ok
    end
  end

  def handle_output(_responsibility, _parsed), do: :ok

  @impl true
  def handle_output(%Responsibility{key: key} = responsibility, parsed, trigger_meta)
      when is_binary(key) and is_map(trigger_meta) do
    case dispatch_module(key) do
      {:ok, mod} ->
        mod.handle_output(responsibility, parsed, trigger_meta)

      :error ->
        Logger.warning(
          "[Providers.Memory] no per-key handler for key=#{inspect(key)} — skipping handle_output/3"
        )

        :ok
    end
  end

  def handle_output(_responsibility, _parsed, _trigger_meta), do: :ok

  # ── internals ─────────────────────────────────────────────────────────────

  defp dispatch_module("memory.daily_summary"), do: {:ok, DailySummary}
  defp dispatch_module("memory.dreaming"), do: {:ok, Dreaming}
  defp dispatch_module(_), do: :error
end
