defmodule Platform.Responsibilities.Handlers.ProposeLongTerm do
  @moduledoc """
  `memory.propose_long_term` responsibility provider (ADR-0041 Historian
  bundle stage 2).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  the weekly (05:00 UTC Sunday) sweep that proposes candidate long-term
  entries the Historian might promote into `org/page/memory.md` on its
  next dreaming pass. Sits alongside the two existing Historian
  responsibilities (`memory.daily_summary` at 23:00 daily,
  `memory.dreaming` at 03:00 daily) and is intentionally out of phase
  with both so the three don't collide on shared context providers.

  ## Spec

    * `key` — `"memory.propose_long_term"`
    * `feature` — `"memory"`
    * `trigger_kind` — `cron` with `expression: "0 5 * * 0"` (05:00 UTC Sundays)
    * `scope` — `per_org`
    * `context_provided` — `["recent_journal", "org_identity"]`

  ## Output handling

  Unlike `daily_summary` (journal append) and `dreaming` (context-file
  upsert), the proposal handler has no per-key persistence side effect.
  The proposals surface as a suggestion the Historian folds into the
  org journal; Historian's next `memory.dreaming` pass decides which
  proposals land in `org/page/memory.md`. `handle_output/3` therefore
  logs the payload shape (benign log-and-return-:ok) and returns `:ok`
  for anything a downstream reader could reasonably observe.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @key "memory.propose_long_term"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: "memory",
        trigger_kind: "cron",
        # 05:00 UTC Sundays — weekly proposal pass, out of phase with the
        # 03:00 `memory.dreaming` and 23:00 `memory.daily_summary` firings
        # so the three Historian responsibilities don't collide on shared
        # context providers.
        trigger_config: %{"expression" => "0 5 * * 0"},
        scope: "per_org",
        context_provided: ["recent_journal", "org_identity"],
        output_contract: %{"proposals" => "list[string]"},
        default_prompt_template: "memory.propose_long_term.v1",
        cost_profile: "low_freq_capable",
        metadata: %{"owner" => "platform.memory"}
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = _responsibility, ctx) when is_map(ctx) do
    opts =
      case Map.get(ctx, :workspace_id) || Map.get(ctx, "workspace_id") do
        nil -> []
        ws_id -> [workspace_id: ws_id]
      end

    with {:ok, %{recent_journal: journal}} <-
           ContextProviders.gather_context(:recent_journal, opts),
         {:ok, %{org_identity: identity}} <-
           ContextProviders.gather_context(:org_identity, opts) do
      {:ok, %{recent_journal: journal, org_identity: identity}}
    end
  end

  def gather_context(_responsibility, _ctx), do: {:ok, %{}}

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed) do
    # Behaviour-required arity-2; Router prefers the 3-arity variant.
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    proposals = extract_proposals(parsed)

    Logger.info(
      "[memory.propose_long_term] received #{length(proposals)} proposal(s) " <>
        "responsibility=#{responsibility.key} trigger_kind=#{inspect(Map.get(trigger_meta, :kind))}"
    )

    :ok
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp extract_proposals(%{"proposals" => list}) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  defp extract_proposals(%{proposals: list}) when is_list(list),
    do: Enum.filter(list, &is_binary/1)

  defp extract_proposals(other) do
    Logger.warning(
      "[memory.propose_long_term] handler received unexpected output shape — " <>
        "expected %{proposals: [string]}; got " <> inspect(other)
    )

    []
  end
end
