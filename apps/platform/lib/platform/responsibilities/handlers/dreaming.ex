defmodule Platform.Responsibilities.Handlers.Dreaming do
  @moduledoc """
  `memory.dreaming` responsibility provider (ADR-0041 M8 stages 2 + 7).

  Implements the M1 `Platform.Responsibilities.Provider` behaviour for
  the 05:00 America/Chicago "dreaming" run that consolidates recent
  journal entries into long-term curated knowledge. Historically lived
  in `Platform.Agents.SystemEventScheduler`'s legacy `dreaming` event
  (collapsed into `historian` by T6), now owns its own responsibility
  row so an agent can be assigned to "curate org memory overnight"
  independently of the broader historian bundle.

  ## Spec

    * `key` — `"memory.dreaming"`
    * `feature` — `"memory"`
    * `trigger_kind` — `cron` with `expression: "0 5 * * *"` and
      `timezone: "America/Chicago"` — 05:00 local daily, year-round.
      05:00 (not 03:00) so the run is clear of openclaw's 03:00 internal
      dreaming pass, and so 05:00 CDT ≈ 10:00 UTC lands *between* the
      SystemEventScheduler summary anchors (after 06:00, before 12:00) —
      no scheduled `historian.scheduled` summary is in-flight when it fires.
      Survives DST because the Router walks UTC minutes but evaluates
      the match predicate in the configured zone (task 019f70e9 stage 6).
    * `scope` — `per_org`
    * `context_provided` — `["recent_journal", "org_identity"]`

  ## Output handling — journal-scoped, no direct page writes

  Stage 7 flipped the write target: `handle_output/3` NEVER writes to
  `org/page/*` file_keys. It writes ONLY to today's org journal path
  (`org/journal/YYYY-MM-DD.md`), for two reasons:

    1. Page mutations from a dreaming run are emitted as
       `<synthesis-insight action="page_edit">` blocks, never written
       directly; acting on one is a separate, attributed step.

    2. The `Platform.Org.Context.upsert_context_file/3` write hook
       sweeps journal paths for `<synthesis-insight>` blocks and
       hands them to `Platform.Memory.Insights.ingest_from_journal/3`
       automatically (task 01a13867 stage 1; it used to ingest
       `<synthesis-proposal>` blocks) — so writing the LLM output to the
       journal is exactly the path that materialises open insights.

  ## Design choice: deterministic maintenance dispatch (not LLM-parsed)

  Stage 7's plan offered two options for triggering the
  `Platform.Memory.MaintenanceSubagent.spawn_*` calls: (a) parse
  maintenance-op invocations from the LLM output, or (b) invoke them
  from a deterministic `Platform.Memory.Integrity.scan/1`.

  We picked (b). Reasons:

    * Reproducible audit trail — the ops the subagents perform depend
      only on the DB state at scan time, not on LLM output that could
      hallucinate op invocations or drop valid ones.
    * Cleaner failure surface — a garbage LLM response can't break the
      maintenance loop, only the synthesis loop.
    * Load-bearing subagent-per-op discipline (acceptance criterion 10)
      is easier to enforce when the fan-out list comes from a pure DB
      read: the parent Historian context never sees the item list at
      all, just the summary count.

  The synthesis side (`<synthesis-proposal>` block emission) DOES flow
  through the LLM — that's the value the dreaming pass adds. The
  maintenance side (link-integrity repair, format normalization,
  retired-target cleanup) is pure code.

  ## Journal write shape

  The written journal body has two sections appended by this handler:

  1. The raw LLM synthesis output (contains `<synthesis-insight>`
     blocks that the sweep hook will ingest into the `memory_insights`
     table).

  2. An "auto-applied maintenance" section counting link_repair /
     format_normalize / retired_cleanup ops + failures. Human-readable
     and stable across dreaming runs so whoever reads the journal (or the
     `/memory/insights` tab, task 01a13867 stage 5) can spot when
     maintenance activity spiked.

  Both sections are written in one `upsert_file/1` call so the write is
  atomic — the sweep hook sees the complete body or none of it.
  """
  @behaviour Platform.Responsibilities.Provider

  require Logger

  alias Platform.Memory.Integrity
  alias Platform.Memory.MaintenanceSubagent
  alias Platform.Memory.Insights
  alias Platform.Org.Context, as: OrgContext
  alias Platform.Responsibilities.ContextProviders
  alias Platform.Responsibilities.Responsibility

  @key "memory.dreaming"

  @doc "Canonical key for this responsibility."
  @spec key() :: String.t()
  def key, do: @key

  @doc """
  Build today's org journal file_key.

  Public so tests + audit tooling can pin the exact file_key the
  handler will write to on a given date without duplicating the
  formatting rule.
  """
  @spec journal_file_key(Date.t()) :: String.t()
  def journal_file_key(%Date{} = date), do: "org/journal/" <> Date.to_iso8601(date) <> ".md"

  # ── Provider callbacks ─────────────────────────────────────────────────────

  @impl true
  def register do
    [
      %{
        key: @key,
        feature: "memory",
        trigger_kind: "cron",
        # 05:00 America/Chicago year-round. Moved 03:00 → 05:00
        # (task 019f905e) to stop two Historian-dreaming overlaps that
        # produced a zero-proposal run: 05:00 clears openclaw's 03:00
        # internal dreaming pass, and 05:00 CDT ≈ 10:00 UTC sits between
        # the SystemEventScheduler summary anchors (0/6/12/18 UTC) —
        # after the 06:00 anchor, before the 12:00 one — so no scheduled
        # `historian.scheduled` summary is in-flight when this fires.
        # Router.compute_next_fire pulls `timezone` out of trigger_config
        # and hands it to Cron.next_fire_after, which walks UTC minutes
        # but evaluates matches in the named zone so the fire time
        # survives DST transitions.
        trigger_config: %{
          "expression" => "0 5 * * *",
          "timezone" => "America/Chicago"
        },
        scope: "per_org",
        context_provided: ["recent_journal", "org_identity"],
        output_contract: %{"memory_body" => "string"},
        default_prompt_template: "memory.dreaming.v1",
        cost_profile: "low_freq_capable",
        metadata: %{
          "owner" => "platform.memory",
          "legacy_event" => "dreaming",
          # Stage 7 flipped the target: the handler now writes to the
          # journal path so the sweep hook can materialise proposals.
          # The exact key resolves at write time via journal_file_key/1
          # (varies with the current date).
          "target_kind" => "journal",
          "target_prefix" => "org/journal/"
        }
      }
    ]
  end

  @impl true
  def gather_context(%Responsibility{} = _responsibility, ctx) when is_map(ctx) do
    workspace_id = Map.get(ctx, :workspace_id) || Map.get(ctx, "workspace_id")

    opts =
      case workspace_id do
        nil -> []
        ws_id -> [workspace_id: ws_id]
      end

    with {:ok, %{recent_journal: journal}} <-
           ContextProviders.gather_context(:recent_journal, opts),
         {:ok, %{org_identity: identity}} <-
           ContextProviders.gather_context(:org_identity, opts) do
      # `memory.dreaming.v1` template body carries `{{rejected_exemplars}}`
      # so the legacy render path (ExternalAgents.Dispatcher.legacy_messages)
      # must include the pre-formatted exemplars in the context bindings.
      # Task 019f70e9 stage 5 — parity with HistorianDispatcher.post_instruction.
      rejected = render_rejected_exemplars(workspace_id: workspace_id, limit: 3)

      {:ok,
       %{
         recent_journal: journal,
         org_identity: identity,
         rejected_exemplars: rejected
       }}
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
    with {:ok, synthesis_body} <- extract_body(parsed) do
      workspace_id =
        Map.get(trigger_meta, :workspace_id) || Map.get(trigger_meta, "workspace_id")

      # Fan out maintenance ops from a deterministic scan (see the
      # module doc for why we don't parse ops out of LLM output). The
      # subagent runners record their own audit rows; the counts here
      # are only for the human-readable journal summary.
      maintenance_summary = run_maintenance(workspace_id)

      journal_body = compose_journal_body(synthesis_body, maintenance_summary)

      # Explicit invariant: this write MUST target a journal file_key
      # (org/journal/...), never org/page/*. The compile-time bound is
      # journal_file_key/1 — a caller that shuffles the write to a page
      # key would trip the T5 read-gate immediately, but the runtime
      # assertion here fails loud in tests before it can regress.
      journal_key = journal_file_key(Date.utc_today())
      :ok = ensure_journal_key!(journal_key)

      write_journal(responsibility, journal_key, journal_body, trigger_meta)
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  # Render prior verdicts (rejections and flags, with their reasons) for the
  # `{{rejected_exemplars}}` placeholder, followed by the
  # `memory.insight_synthesis` experiment directive for today's run (empty
  # for the control arm). Shares `Insights.render_exemplars/1` and
  # `Insights.directive_block/2` with
  # `Platform.Agents.HistorianDispatcher` so the two dreaming render paths
  # surface the same exemplars and the same arm to the model. The placeholder
  # name is kept: the template variables are owned elsewhere.
  @spec render_rejected_exemplars(keyword()) :: String.t()
  defp render_rejected_exemplars(opts) do
    Insights.render_exemplars(opts) <>
      Insights.directive_block(Keyword.get(opts, :workspace_id), Date.utc_today())
  end

  defp extract_body(%{"memory_body" => text}) when is_binary(text) and text != "",
    do: {:ok, text}

  defp extract_body(%{memory_body: text}) when is_binary(text) and text != "", do: {:ok, text}
  defp extract_body(%{"summary" => text}) when is_binary(text) and text != "", do: {:ok, text}
  defp extract_body(%{summary: text}) when is_binary(text) and text != "", do: {:ok, text}
  defp extract_body(text) when is_binary(text) and text != "", do: {:ok, text}

  defp extract_body(other) do
    Logger.warning(
      "[memory.dreaming] handler rejected output — expected %{memory_body: string}; got " <>
        inspect(other)
    )

    {:error, :invalid_output_shape}
  end

  # ── Maintenance fan-out ────────────────────────────────────────────────────

  # Run the deterministic integrity scan and dispatch a maintenance
  # subagent per non-empty bucket. Failures inside `Integrity.scan/1`
  # (Repo unavailable, misconfigured workspace) are logged and treated
  # as an empty scan — the synthesis half of the dreaming pass must
  # still land the journal write.
  defp run_maintenance(workspace_id) do
    scan_opts = if is_binary(workspace_id), do: [workspace_id: workspace_id], else: []

    report =
      try do
        Integrity.scan(scan_opts)
      rescue
        error ->
          Logger.warning(
            "[memory.dreaming] Integrity.scan/1 raised: " <>
              Exception.message(error) <> " — skipping maintenance fan-out"
          )

          %{broken: [], format_dirty: [], retired_target: []}
      end

    subagent_opts =
      [actor_slug: "historian.dreaming"]
      |> then(fn opts ->
        if is_binary(workspace_id), do: Keyword.put(opts, :workspace_id, workspace_id), else: opts
      end)

    link_results = MaintenanceSubagent.spawn_link_repair(report.broken, subagent_opts)

    format_results =
      MaintenanceSubagent.spawn_format_normalize(report.format_dirty, subagent_opts)

    retired_results =
      MaintenanceSubagent.spawn_retired_cleanup(report.retired_target, subagent_opts)

    %{
      link_repair: summarize(link_results),
      format_normalize: summarize(format_results),
      retired_cleanup: summarize(retired_results)
    }
  end

  defp summarize(results) when is_list(results) do
    Enum.reduce(results, %{ok: 0, error: 0}, fn
      {:ok, _event}, acc -> Map.update!(acc, :ok, &(&1 + 1))
      {:error, _reason, _item}, acc -> Map.update!(acc, :error, &(&1 + 1))
    end)
  end

  # ── Journal write ──────────────────────────────────────────────────────────

  defp compose_journal_body(synthesis_body, maintenance_summary) do
    synthesis_body <> "\n\n" <> render_maintenance_section(maintenance_summary)
  end

  defp render_maintenance_section(%{
         link_repair: %{ok: lr_ok, error: lr_err},
         format_normalize: %{ok: fn_ok, error: fn_err},
         retired_cleanup: %{ok: rc_ok, error: rc_err}
       }) do
    """
    ## Auto-applied maintenance (dreaming pass, deterministic)

    - link_repair:      #{lr_ok} succeeded, #{lr_err} failed
    - format_normalize: #{fn_ok} succeeded, #{fn_err} failed
    - retired_cleanup:  #{rc_ok} succeeded, #{rc_err} failed

    Detailed per-op audit rows are on the `platform.memory.maintenance.*` event
    stream. This summary is journal-scoped: it sits in the journal beside the
    day's synthesis insights, which surface on `/memory/insights`.
    """
  end

  # Runtime guard so a refactor that accidentally routes the write to a
  # page key trips loudly. The T5 read-gate would already reject a
  # page write here, but a loud failure at the handler layer is
  # easier to debug than a downstream rejection.
  @journal_prefix "org/journal/"

  defp ensure_journal_key!(file_key) when is_binary(file_key) do
    if String.starts_with?(file_key, @journal_prefix) do
      :ok
    else
      raise ArgumentError,
            "[memory.dreaming] refusing to write non-journal key from handle_output/3: " <>
              inspect(file_key)
    end
  end

  defp write_journal(%Responsibility{} = responsibility, journal_key, body, trigger_meta) do
    updated_by = Map.get(trigger_meta, :updated_by) || Map.get(trigger_meta, "updated_by")

    workspace_id =
      Map.get(trigger_meta, :workspace_id) || Map.get(trigger_meta, "workspace_id")

    # `upsert_file/1` is a simple wrapper on `upsert_context_file/3` and
    # doesn't accept workspace_id, so use the explicit context-file
    # call site directly when we need workspace scoping. Behaviour
    # matches: an existing journal for today is appended to (via
    # version-bumping content replacement); a first-write creates it.
    upsert_opts = if is_binary(workspace_id), do: [workspace_id: workspace_id], else: []

    case OrgContext.upsert_context_file(
           journal_key,
           %{content: body, updated_by: updated_by},
           upsert_opts
         ) do
      {:ok, file} ->
        Logger.info(
          "[memory.dreaming] journal upsert ok key=#{journal_key} version=#{file.version} " <>
            "responsibility=#{responsibility.key}"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[memory.dreaming] journal upsert failed key=#{journal_key} " <>
            "responsibility=#{responsibility.key} reason=#{inspect(reason)}"
        )

        {:error, {:journal_upsert_failed, reason}}
    end
  end
end
