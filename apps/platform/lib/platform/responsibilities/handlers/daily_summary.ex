defmodule Platform.Responsibilities.Handlers.DailySummary do
  @moduledoc """
  `memory.daily_summary` responsibility provider (ADR-0041 M8 stage 2).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  the nightly org journal write that historically lived in
  `Platform.Agents.SystemEventScheduler`'s legacy `daily_summary` event
  (collapsed into the unified `historian` event by T6, but still owed a
  dedicated responsibility row so an operator can assign a specific
  agent to "write the daily summary" rather than the broader historian
  bundle).

  ## Spec

    * `key` — `"memory.daily_summary"`
    * `feature` — `"memory"`
    * `trigger_kind` — `cron` with `expression: "0 23 * * *"` (23:00 UTC daily)
    * `scope` — `per_org`
    * `context_provided` — `["recent_journal", "org_identity"]`

  ## Output handling

  `handle_output/3` accepts the parsed LLM response and appends it to
  the org journal via `Platform.Org.Context.append_memory_entry/2`.
  Accepted payload shapes:

      %{"summary" => "Today we shipped X..."}
      %{summary: "Today we shipped X..."}

  Or a bare string. The handler validates the shape and converts it
  into a `%{content: ..., date: ..., metadata: ...}` map for the
  context module. Trigger metadata flows through `metadata.source =
  "responsibility:memory_daily_summary"` and `metadata.responsibility_key`
  so a cutover monitor can diff router-fired vs legacy entries on
  `metadata.source` alone.

  ## Cutover-deletion checklist (M8 follow-up)

  Per the M8 task description, `SystemEventScheduler` deletion happens
  AFTER cutover proven against a real run. The checklist (also surfaced
  by `mix responsibilities.cutover_report`) is:

    1. `Platform.Responsibilities.CutoverMonitor.report/0` shows
       `divergence_count: 0` for BOTH `memory.daily_summary` AND
       `memory.dreaming` for 7 consecutive days. Operators run
       `mix responsibilities.cutover_report` once a day and watch the
       output; the task exits non-zero on any divergence so a cron
       wrapper can alert without parsing.
    2. Flip `:responsibility_router_enabled` default to `true` in
       `config/prod.exs` (currently `false` in `config/config.exs`).
       Until this lands the router path is dual-write-only and the
       legacy scheduler remains the source of truth.
    3. Open a follow-up task to delete:
        * `apps/platform/lib/platform/agents/system_event_scheduler.ex`
          (the whole module)
        * `Platform.Agents.Agent.@valid_system_events` (the enum that
          legacy code paths key on)
        * the `system_events` column on the `agents` table (Ecto
          migration)
        * the dual-write shim itself
          (`maybe_dual_write/3` + `do_dual_write/3` +
          `emit_dual_write_telemetry/4`) once nothing emits to the
          `[:platform, :responsibilities, :dual_write]` event anymore.

  The cutover monitor + report task ship alongside this handler (M8
  stage 6); the moduledoc here is the single source of truth for the
  follow-up sequence so anyone grepping for "SystemEventScheduler
  delete" finds the actual gating signal.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Org.Context, as: OrgContext
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @key "memory.daily_summary"

  @doc "Canonical key for this responsibility — exposed so dual-write callers don't hard-code the string."
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
        # 23:00 UTC daily — preserves the legacy SystemEventScheduler
        # `daily_summary` event timing (per the M8 task description) even
        # though T6's historian rollup runs at [0, 6, 12, 18] UTC instead.
        # When the router-fired path proves stable the cutover follow-up
        # deletes the historian rollup; this row owns the 23:00 anchor
        # going forward.
        trigger_config: %{"expression" => "0 23 * * *"},
        scope: "per_org",
        context_provided: ["recent_journal", "org_identity"],
        output_contract: %{"summary" => "string"},
        default_prompt_template: "memory.daily_summary.v1",
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.memory",
          "legacy_event" => "daily_summary"
        }
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
    # Behaviour-required arity-2. We have no trigger_meta here — date
    # defaults to today, workspace_id to nil. The 3-arity version is the
    # preferred call site (Router probes for it first).
    handle_output(responsibility, parsed, %{kind: :unknown})
  end

  @impl true
  def handle_output(%Responsibility{} = responsibility, parsed, trigger_meta)
      when is_map(trigger_meta) do
    with {:ok, content} <- extract_summary(parsed) do
      append(responsibility, content, trigger_meta)
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp extract_summary(%{"summary" => text}) when is_binary(text) and text != "", do: {:ok, text}
  defp extract_summary(%{summary: text}) when is_binary(text) and text != "", do: {:ok, text}
  defp extract_summary(text) when is_binary(text) and text != "", do: {:ok, text}

  defp extract_summary(other) do
    Logger.warning(
      "[memory.daily_summary] handler rejected output — expected %{summary: string}; got " <>
        inspect(other)
    )

    {:error, :invalid_output_shape}
  end

  defp append(%Responsibility{} = responsibility, content, trigger_meta) do
    workspace_id = Map.get(trigger_meta, :workspace_id) || Map.get(trigger_meta, "workspace_id")
    date = Map.get(trigger_meta, :date) || Map.get(trigger_meta, "date") || Date.utc_today()

    attrs = %{
      content: content,
      date: date,
      workspace_id: workspace_id,
      metadata: %{
        "source" => "responsibility:#{responsibility.key}",
        "responsibility_key" => responsibility.key,
        "trigger_kind" => to_string(Map.get(trigger_meta, :kind) || "unknown")
      }
    }

    case OrgContext.append_memory_entry(attrs) do
      {:ok, entry} ->
        Logger.info(
          "[memory.daily_summary] appended entry id=#{entry.id} date=#{entry.date} " <>
            "workspace=#{inspect(workspace_id)}"
        )

        :ok

      {:error, changeset} ->
        Logger.warning(
          "[memory.daily_summary] append failed: #{inspect(changeset.errors)} " <>
            "workspace=#{inspect(workspace_id)}"
        )

        {:error, {:append_failed, changeset.errors}}
    end
  end
end
