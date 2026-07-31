defmodule Platform.Agents.HistorianDispatcher do
  @moduledoc """
  Shared dispatch helpers for the Historian agent (ADR-0041 / T6).

  Multiple call sites can trigger a Historian run — `SystemEventScheduler`
  fires on the every-6h staggered cadence and on the 100k-token threshold
  sweep; `MeetingHistorianHandler` fires on `:meeting_ended` PubSub events
  per project. This module owns the dispatch pipeline so each caller only
  has to pick the right `template_slug` + metadata payload — agent lookup,
  runtime reachability check, system space + participant resolution,
  prompt rendering, and the final `AgentResponder.maybe_dispatch/1` call
  all live here once.

  ## Template slugs

  Callers pass a DB-backed prompt template slug:

    * `"historian.scheduled"` — every-6h anchor fire
    * `"historian.meeting_ended"` — `:meeting_ended` PubSub fire
    * `"historian.threshold"` — 100k-token sweep fire

  When the template row is missing (empty DB / first boot before
  `seed_defaults`), `post_instruction/4` falls back to the literal default
  documented in `SystemEventScheduler` so dispatch still succeeds.

  ## Metadata

  Extra metadata (e.g. `%{trigger: "meeting_ended", meeting_id: id,
  project_id: pid, chat_space_id: sid}`) is forwarded into the rendered
  template's variable map AND stamped on both the chat message metadata
  and the AgentResponder signal metadata so downstream tools see it.
  """

  require Logger

  alias Platform.Agents.{ActivityDigest, Agent, Historian}
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks.Projects

  @daily_window_hours 24

  # ── Windowed dispatch (task 019f4f55) ──────────────────────────────────

  # Ordering the slicer emits within a single day. Deterministic so
  # per-corpus cursor advance stays monotonic across ticks even when
  # multiple corpora fire on the same day.
  @corpus_order [:pages, :journal, :messages, :transcripts]

  # Corpus tiebreaker for sort — mirrors `@corpus_order` positionally.
  @corpus_index %{pages: 0, journal: 1, messages: 2, transcripts: 3}

  # Default lookback bound when a corpus's cursor is unset. Prevents
  # the slicer from paying enumerate-a-decade-of-calendar-days cost on
  # a fresh workspace. Deeper backfill is a bootstrap concern, not a
  # sweep-tick concern.
  @default_lookback_seconds 30 * 86_400

  # Smallest sub-window the halving loop is willing to emit. Below
  # this, if the estimated tokens still exceed budget, the window is
  # flagged `oversize: true` and the digest-build path truncates it
  # item-wise, holding the cursor at the digested watermark.
  @min_sub_window_seconds 3_600

  @type window :: %{
          corpus: :pages | :journal | :messages | :transcripts,
          window_start: DateTime.t(),
          window_end: DateTime.t(),
          token_estimate: non_neg_integer(),
          oversize: boolean(),
          day_bytes: non_neg_integer()
        }

  # Literal default used as a fallback for empty DB (when prompt_templates
  # has no `historian.*` row yet). DB-backed templates take precedence via
  # `PromptTemplates.render_template/2`.
  @default_historian_instruction """
  You are the Historian. Below is the activity from the last 24 hours \
  across all non-DM spaces in the organisation.

  {activity_digest}

  ## Intentionally deleted paths

  Do NOT re-create these; treat broken links to them as a signal to \
  clean up the referring page, not to restore the target:

  {deleted_paths_notice}

  Review recent journal entries and short-term memory. Curate durable \
  knowledge into pages under `org/page/`, `project/<id>/page/`, and \
  `space/<id>/page/`. Write transient notes to today's journal at \
  `org/journal/{date}.md`. Be selective: only promote genuinely new \
  insights and preserve existing content that is still relevant.
  """

  # Post-render body oversize headroom. `budget_tokens` is a per-corpus
  # digest ceiling; the rendered message body carries additional template
  # chrome (prompt scaffold, instructions, cursor metadata paragraph)
  # that shouldn't count against the digest ceiling itself. 10k tokens is
  # comfortably larger than any static prompt template the Historian
  # ships with.
  @body_headroom_tokens 10_000

  @system_participant_sentinel "00000000-0000-0000-0000-000000000001"

  # Task 019f5e7d stage 5 — no-op pass event. Fires whenever a windowed
  # dispatch resolves to zero work (no historian agent pinned OR slicer
  # returned zero windows). This is the deterministic audit signal
  # replacing the pre-fix template-driven "backlog drained" journal
  # write. Registered under the `[:platform, :agents, :historian | _]`
  # namespace in `Platform.Audit.TelemetryHandler.@events` — see stage 5
  # rationale there for why the 4-element path over 3.
  @no_op_pass_event [:platform, :agents, :historian, :no_op_pass]

  @doc """
  Dispatch the historian event end-to-end.

  Resolves the active historian-flagged agent, ensures the runtime is
  reachable, opens / reuses the agent's `system-<slug>` space, posts a
  synthetic instruction message rendered from the `template_slug`, then
  hands off to `AgentResponder.maybe_dispatch/1`.

  Returns `:ok` when no historian agent is configured (no crash — the
  feature is opt-in via agent config). Returns `{:error, reason}` on any
  resolved failure (runtime offline, space/participant creation failed,
  template render failed catastrophically, etc).
  """
  @spec dispatch(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def dispatch(event_type, template_slug, extra_metadata)
      when is_binary(event_type) and is_binary(template_slug) and is_map(extra_metadata) do
    case agent_for_event(event_type) do
      %Agent{} = agent ->
        Logger.info("[HistorianDispatcher] dispatching #{event_type} to agent=#{agent.slug}")
        dispatch_to_agent(agent, event_type, template_slug, extra_metadata)

      nil ->
        Logger.info("[HistorianDispatcher] no active agent flagged for #{event_type}, skipping")

        :ok
    end
  end

  @doc """
  Windowed threshold dispatch — one digest message per bounded window
  with per-window cursor advance.

  Consumed by `SystemEventScheduler.fire_threshold/2` (stage 3) after
  the every-6h and per-meeting fire paths already run through `dispatch/3`.
  The pipeline:

    1. Look up the historian agent (skip cleanly with `{:ok, %{dispatched:
       0, remaining: 0}}` when nobody is pinned — mirrors `dispatch/3`).
    2. Ensure the agent's system space + system participant + agent
       participant (idempotent — same helpers as `dispatch_to_agent/4`).
    3. `slice_windows(workspace_id, now: now)` and take up to
       `max_windows_per_pass/0` chronological windows.
    4. For each window in order:
         a. `ActivityDigest.build_windowed_result(window)` → corpus-scoped
            body plus the item accounting. The digest admits rows in
            corpus-clock order until the next one would push the running
            byte total past `budget_tokens * 4`, so the body is always a
            whole-item prefix — never a mid-item byte cut.
         b. `post_instruction/5` with per-window `extra_metadata` carrying
            `cursor: %{namespace, window_start, window_end}`,
            `window_index`, `window_of`, `token_estimate`, `oversize`,
            `truncated`, `oversize_empty`. The pre-built digest is passed
            through the `:activity_digest` opt so the 24h fallback path in
            `post_instruction/5` doesn't fire.
         c. Dispatch `AgentResponder.maybe_dispatch/1` so the agent
            processes each windowed message independently.
         d. `Historian.advance_cursor(workspace_id, corpus, nil,
            cursor_target/2)` — BEFORE returning to the loop so a crash
            mid-pass resumes at the next unread window rather than
            replaying already-dispatched work. `cursor_target/2` reaches
            `window_end` only when nothing was withheld; see its
            definition for the invariant.

  Returns `{:ok, %{dispatched: n, remaining: total_windows - n}}` so
  `SystemEventScheduler` can log/telemeter the cap-hit for the next tick.
  Any per-window post_instruction failure short-circuits the loop with
  `{:error, reason}`; already-dispatched windows keep their cursor
  advance, so the next tick picks up cleanly at the next window.

  ## Options

    * `:now` — sweep window end, defaults to `DateTime.utc_now/0`. Injected
      by tests so the day-boundary enumeration stays deterministic; the
      value is handed straight to `slice_windows/2`, which is the single
      place the sweep's calendar-day fanout is decided. Mirrors the
      long-standing `:now` option on `slice_windows/2` — this arity is
      what carries it across the integration boundary.

  The 4-arity clause delegates here with `[]`, so every production caller
  (notably `SystemEventScheduler.fire_threshold/2`) keeps the real
  `DateTime.utc_now/0` sweep end and is unaffected by this option.
  """
  @spec dispatch_windowed(String.t(), String.t(), map(), binary() | nil) ::
          {:ok, %{dispatched: non_neg_integer(), remaining: non_neg_integer()}}
          | {:error, term()}
  def dispatch_windowed(event_type, template_slug, extra_metadata, workspace_id),
    do: dispatch_windowed(event_type, template_slug, extra_metadata, workspace_id, [])

  @doc """
  `dispatch_windowed/4` with an options keyword. See that function for the
  pipeline and for the supported options; `:now` is the only one today.
  """
  @spec dispatch_windowed(String.t(), String.t(), map(), binary() | nil, keyword()) ::
          {:ok, %{dispatched: non_neg_integer(), remaining: non_neg_integer()}}
          | {:error, term()}
  def dispatch_windowed(event_type, template_slug, extra_metadata, workspace_id, opts)
      when is_binary(event_type) and is_binary(template_slug) and is_map(extra_metadata) and
             is_list(opts) do
    t0 = System.monotonic_time(:millisecond)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case agent_for_event(event_type) do
      %Agent{} = agent ->
        Logger.info(
          "[HistorianDispatcher] windowed dispatch #{event_type} → agent=#{agent.slug} " <>
            "workspace=#{inspect(workspace_id)}"
        )

        do_dispatch_windowed(
          agent,
          event_type,
          template_slug,
          extra_metadata,
          workspace_id,
          t0,
          now
        )

      nil ->
        Logger.info(
          "[HistorianDispatcher] no active agent flagged for windowed #{event_type}, skipping"
        )

        emit_no_op_pass(
          workspace_id,
          event_type,
          template_slug,
          System.monotonic_time(:millisecond) - t0,
          %{reason: "no_agent"}
        )

        {:ok, %{dispatched: 0, remaining: 0}}
    end
  end

  @doc """
  Look up the single active agent pinned to the Historian role.

  Consults `Platform.Roles.agent_id_for_role("historian")` — the closed
  role roster (M4/ADR-0041) is now the source of truth for who owns the
  Historian responsibility. The `event_type` argument is preserved in the
  signature so `SystemEventScheduler.fire_now/1` and
  `MeetingHistorianHandler` keep compiling, but it is intentionally
  ignored: all three T6 events (`"historian"`, legacy `"daily_summary"`,
  legacy `"dreaming"`) resolve to the same Roles Historian. The
  `SystemEventScheduler` normalises legacy names to `"historian"` before
  we're called, so no legacy-key mapping lives here.

  Returns the `%Agent{}` when a Historian is pinned AND that agent's
  `status == "active"`; returns `nil` otherwise. The one-agent-per-role
  invariant is enforced by the `role_assignments.role_key` unique index,
  so the multi-agent-tiebreak branch of the old query is dead code and
  has been removed.
  """
  @spec agent_for_event(String.t()) :: Agent.t() | nil
  def agent_for_event(event_type) when is_binary(event_type) do
    case Roles.agent_id_for_role("historian") do
      nil ->
        nil

      agent_id when is_binary(agent_id) ->
        case Repo.get(Agent, agent_id) do
          %Agent{status: "active"} = agent ->
            agent

          %Agent{} ->
            # Role is pinned but the agent is paused/archived — treat as
            # "nobody home". Callers already log the skip via `dispatch/3`.
            nil

          nil ->
            # Shouldn't happen — the FK on `role_assignments.agent_id`
            # blocks this — but be defensive so a lost race doesn't crash
            # the every-6h fire.
            Logger.warning(
              "[HistorianDispatcher] historian role pinned to agent_id=#{agent_id} " <>
                "for event=#{event_type} but agent row not found; treating as unassigned"
            )

            nil
        end
    end
  end

  # ── Windowed slicing (stage 1 of 4) ───────────────────────────────────────

  @doc """
  Config-aware `slice_windows/2`. Reads `budget_tokens` from
  `:historian_window_token_budget` and uses `DateTime.utc_now/0` as the
  sweep window end. Equivalent to `slice_windows(workspace_id, [])`.
  """
  @spec slice_windows(binary() | nil) :: [window()]
  def slice_windows(workspace_id), do: slice_windows(workspace_id, [])

  @doc """
  Slice the workspace's pending backlog into a chronological list of
  token-budgeted windows the sweep loop dispatches one-at-a-time.

  A pure helper — the runtime dispatch path stays untouched. Stage 2
  wires this into the threshold sweep; stages 3–4 wire the per-window
  cursor advance and telemetry. This stage only tests the slicing
  primitive.

  ## Options

    * `:budget_tokens` — max estimated tokens per emitted window.
      Defaults to `Application.get_env(:platform,
      :historian_window_token_budget, 30_000)`.
    * `:now` — sweep window end, defaults to `DateTime.utc_now/0`. Injected
      by tests so the day-boundary enumeration stays deterministic.
    * `:input_fn` — 1-arity function taking `workspace_id` and returning
      the same shape as `Historian.pending_windows_input/1`. Defaults to
      `&Historian.pending_windows_input/1`. Test-only injection point
      so the slicer can be exercised without hitting the DB.
    * `:per_day_fn` — 3-arity function taking `(corpus_string, start_at,
      end_at)` and returning `%{Date.t() => non_neg_integer()}` — the
      per-calendar-day byte sums used by `slice_by_calendar_day/6` to
      attribute density to the days that actually own it. Defaults to a
      closure over the caller's `workspace_id` that delegates to
      `Historian.pending_bytes_per_day/4` — so workspace-scoped corpora
      (pages / journal) query with the right filter. Tests inject an
      arity-3 stub that ignores `workspace_id` for DB-free coverage.
    * `:range_bytes_fn` — 3-arity function taking `(corpus_string,
      start_at, end_at)` and returning a single `non_neg_integer()` — the
      REAL byte sum of that arbitrary sub-day span, used by
      `halve_until_fits/7` to measure each half instead of assuming the
      day's bytes are uniformly dense. Defaults to a closure over the
      caller's `workspace_id` delegating to
      `Historian.pending_bytes_in_range/4`. Same test-injection shape as
      `:per_day_fn`; any test that drives the halving path must stub it or
      it will hit the DB.

  ## Behaviour

    * Corpora with `pending_bytes == 0` are skipped entirely.
    * A corpus whose whole pending range fits under `budget_tokens` in one
      window emits ONE window `[last_at, now)` — small backlogs don't
      pay per-day fanout cost.
    * A corpus that overflows the budget is sliced into UTC calendar days
      first, asking `per_day_fn` for the actual per-day byte sum. Days
      the aggregator omits (no rows) contribute nothing; a single busy
      day carries its own real density rather than a smeared average.
    * If a single calendar day still overflows, that day is halved
      recursively; **each half is re-measured with `range_bytes_fn`**
      rather than charged half the parent's bytes, so a day whose whole
      mass sits in one hour hands that hour all of it and hands the
      quiet hours zero. Halving continues until either the sub-window
      fits or the span drops to `@min_sub_window_seconds`. A sub-window
      that STILL overflows at the minimum span is emitted with
      `oversize: true` and its `token_estimate` clamped to
      `budget_tokens` — the truncation marker is applied downstream at
      message-body render time.
    * A sub-window that measures zero bytes emits nothing, exactly as a
      zero-byte calendar day does. Under the old halved-estimate this
      case could not arise: every half of a non-empty day was non-empty
      by construction.
    * Emitted windows are sorted `(window_start ASC, corpus_order ASC)`
      so multi-corpus + multi-day traffic dispatches oldest-first with
      a stable per-day corpus order (`pages`, `journal`, `messages`,
      `transcripts`).
    * When a corpus's `last_processed_at` is nil, the slicer bounds the
      lookback at `@default_lookback_seconds` (30 days). Deeper backfill
      is a fresh-workspace bootstrap concern — a separate cursor-seeder
      should stamp `last_processed_at` before the sweep runs.
  """
  @spec slice_windows(binary() | nil, keyword()) :: [window()]
  def slice_windows(workspace_id, opts) when is_list(opts) do
    budget_tokens = Keyword.get(opts, :budget_tokens, window_budget_tokens())
    now = Keyword.get(opts, :now, DateTime.utc_now())
    input_fn = Keyword.get(opts, :input_fn, &Historian.pending_windows_input/1)

    per_day_fn =
      Keyword.get(opts, :per_day_fn, fn corpus, start_at, end_at ->
        Historian.pending_bytes_per_day(corpus, start_at, end_at, workspace_id)
      end)

    range_bytes_fn =
      Keyword.get(opts, :range_bytes_fn, fn corpus, start_at, end_at ->
        Historian.pending_bytes_in_range(corpus, start_at, end_at, workspace_id)
      end)

    input = input_fn.(workspace_id)

    @corpus_order
    |> Enum.flat_map(
      &slice_corpus_from_input(input, &1, now, budget_tokens, per_day_fn, range_bytes_fn)
    )
    |> Enum.sort_by(fn w ->
      {DateTime.to_unix(w.window_start, :microsecond), Map.get(@corpus_index, w.corpus, 99)}
    end)
  end

  @doc """
  The window token budget the slicer / dispatcher read from application
  config. Public so callers (tests, telemetry sites) can log the effective
  budget without re-reading the raw `Application.get_env/3` call.
  """
  @spec window_budget_tokens() :: pos_integer()
  def window_budget_tokens do
    Application.get_env(:platform, :historian_window_token_budget, 30_000)
  end

  @doc """
  The per-sweep cap on windows the stage-3 loop will dispatch before
  yielding to the next scheduler tick. Public for the same reason as
  `window_budget_tokens/0`.
  """
  @spec max_windows_per_pass() :: pos_integer()
  def max_windows_per_pass do
    Application.get_env(:platform, :historian_max_windows_per_pass, 20)
  end

  defp slice_corpus_from_input(input, corpus, now, budget_tokens, per_day_fn, range_bytes_fn) do
    case Map.get(input, corpus) do
      nil ->
        []

      {_last_at, bytes} when not is_integer(bytes) or bytes <= 0 ->
        []

      {last_at, bytes} ->
        start_at = corpus_start_at(last_at, now)

        if DateTime.compare(start_at, now) != :lt do
          []
        else
          slice_corpus_range(
            corpus,
            start_at,
            now,
            bytes,
            budget_tokens,
            per_day_fn,
            range_bytes_fn
          )
        end
    end
  end

  defp corpus_start_at(nil, now) do
    DateTime.add(now, -@default_lookback_seconds, :second)
  end

  defp corpus_start_at(%DateTime{} = last_at, now) do
    # Guard against a cursor written into the future by a clock skew —
    # never emit a window with a negative span.
    if DateTime.compare(last_at, now) == :lt, do: last_at, else: now
  end

  defp slice_corpus_range(
         corpus,
         start_at,
         end_at,
         total_bytes,
         budget_tokens,
         per_day_fn,
         range_bytes_fn
       ) do
    total_tokens = div(total_bytes, 4)

    cond do
      total_tokens <= budget_tokens ->
        [
          %{
            corpus: corpus,
            window_start: start_at,
            window_end: end_at,
            token_estimate: total_tokens,
            oversize: false,
            # `day_bytes: 0` for a fits-in-one-window emission because this
            # branch may span multiple UTC days — the density is not yet
            # attributed per-day. The per-day fanout branch (below) is the
            # only path that has a real day-bucketed byte count.
            day_bytes: 0
          }
        ]

      true ->
        slice_by_calendar_day(
          corpus,
          start_at,
          end_at,
          budget_tokens,
          per_day_fn,
          range_bytes_fn
        )
    end
  end

  # Per-day fanout using REAL byte sums from `per_day_fn` (defaults to
  # `Historian.pending_bytes_per_day/3`). Empty-map days contribute
  # nothing — a 30-day lookback with one concentrated day attributes all
  # the density to that day rather than smearing 1/30 to each. The
  # partial-day clip in `enumerate_day_ranges/2` still uses
  # `DateTime.to_date(day_start)` as the map key, which lines up 1:1
  # with the aggregator's `date_trunc('day', ...)` UTC keying — no
  # boundary math needed.
  defp slice_by_calendar_day(corpus, start_at, end_at, budget_tokens, per_day_fn, range_bytes_fn) do
    day_ranges = enumerate_day_ranges(start_at, end_at)
    per_day_bytes = per_day_fn.(Atom.to_string(corpus), start_at, end_at)

    Enum.flat_map(day_ranges, fn {day_start, day_end} ->
      day_bytes = Map.get(per_day_bytes, DateTime.to_date(day_start), 0)
      day_tokens = div(day_bytes, 4)

      cond do
        day_bytes == 0 ->
          []

        day_tokens <= budget_tokens ->
          [
            %{
              corpus: corpus,
              window_start: day_start,
              window_end: day_end,
              token_estimate: day_tokens,
              oversize: false,
              day_bytes: day_bytes
            }
          ]

        true ->
          # `day_bytes` at the top of the halving recursion is the real
          # per-day byte sum. Sub-windows emitted by `halve_until_fits`
          # stamp the SAME `day_bytes` value on every emitted map so a
          # single day's telemetry can be reconstructed downstream —
          # `day_bytes` is a telemetry field, NOT the oversize input, and
          # stage 3 deliberately left its meaning alone. The oversize
          # decision reads `total_bytes`, which from here down is
          # re-measured per half by `range_bytes_fn`.
          halve_until_fits(
            corpus,
            day_start,
            day_end,
            day_bytes,
            budget_tokens,
            day_bytes,
            range_bytes_fn
          )
      end
    end)
  end

  defp enumerate_day_ranges(start_at, end_at) do
    start_day = DateTime.to_date(start_at)
    end_day = DateTime.to_date(end_at)

    Date.range(start_day, end_day)
    |> Enum.map(fn date ->
      day_open = utc_midnight(date)
      day_close = date |> Date.add(1) |> utc_midnight()

      s = if DateTime.compare(day_open, start_at) == :lt, do: start_at, else: day_open
      e = if DateTime.compare(day_close, end_at) == :gt, do: end_at, else: day_close
      {s, e}
    end)
    |> Enum.reject(fn {s, e} -> DateTime.compare(s, e) != :lt end)
  end

  defp utc_midnight(%Date{} = date) do
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end

  # Each half is MEASURED, not assumed. The previous implementation set
  # `left_bytes = div(total_bytes, 2)` and `right_bytes = total_bytes -
  # left_bytes` and never re-queried, so at recursion depth N the oversize
  # decision ran against `day_bytes / 2^N`. That is a uniform-density
  # fiction: a day with all its traffic in one hour charged every quiet
  # hour an equal share and drove them to `@min_sub_window_seconds`, where
  # they were stamped `oversize: true` and dispatched a stub. Two real
  # `range_bytes_fn` calls per split cost at most ~2^5 aggregates for one
  # pathological day (depth is bounded by
  # `log2(86_400 / @min_sub_window_seconds)`), and only on days that
  # already overflowed the budget.
  defp halve_until_fits(
         corpus,
         start_at,
         end_at,
         total_bytes,
         budget_tokens,
         day_bytes,
         range_bytes_fn
       ) do
    span_seconds = DateTime.diff(end_at, start_at, :second)
    total_tokens = div(total_bytes, 4)

    cond do
      # A measured-empty half emits nothing — the same rule
      # `slice_by_calendar_day/6` applies to a zero-byte day. Unreachable
      # before this stage: every half of a non-empty day was non-empty by
      # construction when the halves were arithmetic rather than measured.
      total_bytes <= 0 ->
        []

      total_tokens <= budget_tokens ->
        [
          %{
            corpus: corpus,
            window_start: start_at,
            window_end: end_at,
            token_estimate: total_tokens,
            oversize: false,
            day_bytes: day_bytes
          }
        ]

      span_seconds <= @min_sub_window_seconds ->
        # Cannot slice smaller; downstream digest-build applies the
        # truncation marker. `token_estimate` is clamped to the budget
        # because the emitted digest will be trimmed to that ceiling.
        [
          %{
            corpus: corpus,
            window_start: start_at,
            window_end: end_at,
            token_estimate: budget_tokens,
            oversize: true,
            day_bytes: day_bytes
          }
        ]

      true ->
        mid_seconds = div(span_seconds, 2)
        mid = DateTime.add(start_at, mid_seconds, :second)
        corpus_string = Atom.to_string(corpus)

        left_bytes = range_bytes_fn.(corpus_string, start_at, mid)
        right_bytes = range_bytes_fn.(corpus_string, mid, end_at)

        halve_until_fits(
          corpus,
          start_at,
          mid,
          left_bytes,
          budget_tokens,
          day_bytes,
          range_bytes_fn
        ) ++
          halve_until_fits(
            corpus,
            mid,
            end_at,
            right_bytes,
            budget_tokens,
            day_bytes,
            range_bytes_fn
          )
    end
  end

  # ── Implementation ────────────────────────────────────────────────────────

  defp do_dispatch_windowed(
         %Agent{} = agent,
         event_type,
         template_slug,
         extra_metadata,
         workspace_id,
         t0,
         %DateTime{} = now
       ) do
    with :ok <- ensure_runtime_reachable(agent, event_type),
         {:ok, space} <- ensure_system_space(agent),
         {:ok, system_participant} <- ensure_system_participant(space),
         {:ok, agent_participant} <-
           Chat.add_agent_participant(space.id, agent, display_name: agent.name) do
      all_windows = slice_windows(workspace_id, now: now)
      cap = max_windows_per_pass()
      taken = Enum.take(all_windows, cap)
      total_taken = length(taken)
      total_windows = length(all_windows)
      budget = window_budget_tokens()

      # Pass-scoped telemetry — bracketed by :pass_completed / :error below.
      # Stage 2's audit bridge (task 019f5bc4) uses these to record a
      # per-workspace historian dispatch trail in `audit_events`.
      emit_telemetry(
        :pass_started,
        %{total_windows: total_windows, taken: total_taken, budget_tokens: budget},
        %{event_type: event_type, agent_id: agent.id},
        workspace_id
      )

      Enum.reduce_while(Enum.with_index(taken, 1), {:ok, 0}, fn {window, idx}, {:ok, count} ->
        case dispatch_one_window(
               space,
               system_participant,
               agent_participant,
               agent,
               event_type,
               template_slug,
               extra_metadata,
               window,
               idx,
               total_taken,
               budget,
               workspace_id
             ) do
          :ok ->
            {:cont, {:ok, count + 1}}

          {:error, reason} ->
            Logger.error(
              "[HistorianDispatcher] windowed dispatch failed at window #{idx}/#{total_taken}: " <>
                inspect(reason)
            )

            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, dispatched} ->
          elapsed_ms = System.monotonic_time(:millisecond) - t0

          # A dispatched-zero pass with zero windows to slice is the
          # deterministic "backlog drained" signal — emit no_op_pass so
          # the audit trail records a suppressed pass alongside the
          # ordinary pass_completed envelope.
          if total_windows == 0 do
            emit_no_op_pass(
              workspace_id,
              event_type,
              template_slug,
              elapsed_ms,
              %{agent_id: agent.id, reason: "no_windows"}
            )
          end

          emit_telemetry(
            :pass_completed,
            %{
              dispatched: dispatched,
              remaining: max(total_windows - dispatched, 0),
              elapsed_ms: elapsed_ms
            },
            %{event_type: event_type, agent_id: agent.id},
            workspace_id
          )

          {:ok, %{dispatched: dispatched, remaining: max(total_windows - dispatched, 0)}}

        {:error, _} = err ->
          err
      end
    else
      {:error, reason} = err ->
        Logger.error(
          "[HistorianDispatcher] windowed dispatch setup failed for #{event_type}: " <>
            inspect(reason)
        )

        emit_telemetry(
          :error,
          %{},
          %{stage: "setup", reason: inspect(reason), event_type: event_type},
          workspace_id
        )

        err
    end
  end

  defp dispatch_one_window(
         space,
         system_participant,
         agent_participant,
         _agent,
         event_type,
         template_slug,
         extra_metadata,
         window,
         idx,
         total_taken,
         budget_tokens,
         workspace_id
       ) do
    {:ok, body, digest} =
      ActivityDigest.build_windowed_result(Map.put(window, :budget_tokens, budget_tokens))

    corpus_string = Atom.to_string(window.corpus)

    per_window_meta =
      extra_metadata
      |> Map.merge(%{
        cursor: %{
          namespace: corpus_string,
          window_start: DateTime.to_iso8601(window.window_start),
          window_end: DateTime.to_iso8601(window.window_end)
        },
        window_index: idx,
        window_of: total_taken,
        token_estimate: window.token_estimate,
        oversize: window.oversize,
        # The two flags a consumer acts on. `truncated` says the cursor was
        # held short of `window_end` and a re-dispatch is coming;
        # `oversize_empty` says this window could not be digested, as opposed
        # to having had nothing to digest. `HistorianAudit.classify/1` reads
        # both off the `window_dispatched` audit row.
        truncated: digest.truncated?,
        oversize_empty: digest.oversize_empty?,
        item_count: digest.item_count,
        included_count: digest.included_count
      })

    case post_instruction(
           space,
           system_participant,
           event_type,
           template_slug,
           per_window_meta,
           activity_digest: body
         ) do
      {:ok, message} ->
        # Emit per-window telemetry BEFORE the cursor advance so an
        # advance failure still surfaces the intent to dispatch. Split
        # numeric measurements from identifier metadata per Suite
        # convention (see `SystemEventScheduler.emit_telemetry/3`).
        # `resource_type`/`resource_id`/`action` come from `emit_telemetry`
        # — stage 2's audit bridge (task 019f5bc4) keys off them.
        day_span =
          DateTime.to_iso8601(window.window_start) <>
            "/" <> DateTime.to_iso8601(window.window_end)

        emit_telemetry(
          :window_dispatched,
          %{
            token_count: window.token_estimate,
            window_index: idx,
            day_bytes: Map.get(window, :day_bytes, 0),
            item_count: digest.item_count,
            included_count: digest.included_count
          },
          %{
            day_span: day_span,
            corpus: window.corpus,
            oversize: window.oversize,
            truncated: digest.truncated?,
            oversize_empty: digest.oversize_empty?
          },
          workspace_id
        )

        {cursor_at, skipped} = cursor_target(window, digest)

        if digest.truncated? do
          emit_telemetry(
            :window_truncated,
            %{
              item_count: digest.item_count,
              included_count: digest.included_count,
              withheld_count: digest.item_count - digest.included_count
            },
            %{
              day_span: day_span,
              corpus: corpus_string,
              cursor_at: DateTime.to_iso8601(cursor_at)
            },
            workspace_id
          )
        end

        # A skip must be a named, queryable audit row — never a silent
        # advance. It fires only when one item (or one timestamp-tied group)
        # exceeds the whole window budget on its own, which no amount of
        # further slicing can fix: `@min_sub_window_seconds` exists precisely
        # because unbounded halving cannot terminate.
        if skipped do
          emit_telemetry(
            :item_skipped,
            %{bytes: skipped.bytes, item_count: skipped.count},
            %{
              corpus: corpus_string,
              message_id: to_string(skipped.id),
              window_start: DateTime.to_iso8601(window.window_start),
              skipped_at: DateTime.to_iso8601(skipped.at)
            },
            workspace_id
          )
        end

        # Advance cursor BEFORE agent dispatch so a crash inside
        # AgentResponder still leaves the cursor stamped — the next tick
        # picks up at the next window instead of replaying this one.
        case Historian.advance_cursor(workspace_id, corpus_string, nil, cursor_at) do
          {:ok, _cursor} ->
            emit_telemetry(
              :cursor_advanced,
              %{window_index: idx, total_windows: total_taken},
              %{
                corpus: corpus_string,
                # The instant the cursor actually landed on — equal to the
                # window end only when the whole window was digested.
                window_end: DateTime.to_iso8601(cursor_at),
                held_short: digest.truncated?
              },
              workspace_id
            )

            signal = %{
              participant_id: agent_participant.id,
              message_id: message.id,
              space_id: space.id,
              reason: :system_event,
              metadata: Map.merge(%{event_type: event_type}, stringify_keys(per_window_meta))
            }

            AgentResponder.maybe_dispatch(signal)
            :ok

          {:error, reason} ->
            Logger.error(
              "[HistorianDispatcher] failed to advance cursor for #{corpus_string} " <>
                "at cursor_at=#{inspect(cursor_at)}: #{inspect(reason)}"
            )

            emit_telemetry(
              :error,
              %{},
              %{
                stage: "cursor_advance",
                reason: inspect(reason),
                corpus: corpus_string,
                window_end: DateTime.to_iso8601(cursor_at)
              },
              workspace_id
            )

            {:error, {:cursor_advance_failed, reason}}
        end

      {:error, reason} ->
        emit_telemetry(
          :error,
          %{},
          %{
            stage: "post_instruction",
            reason: inspect(reason),
            corpus: corpus_string,
            event_type: event_type
          },
          workspace_id
        )

        {:error, reason}
    end
  end

  # ── The cursor invariant (task 019fa1cc stage 4) ──────────────────────────
  #
  # **The cursor must never advance past content that was never digested.**
  #
  # This used to be an unconditional `advance_cursor(…, window.window_end)`
  # called milliseconds after `maybe_truncate_digest/3` may have chopped the
  # body with `binary_part(body, 0, cap)` — a byte-offset cut that both threw
  # content away silently and could split a multi-byte grapheme into invalid
  # UTF-8 on the way into a Postgres `text` column. Stages 2 and 3 made the
  # oversize flag rare and honest; neither made this safe.
  #
  # `ActivityDigest.build_windowed_result/1` now truncates item-wise before
  # rendering and hands back the watermark. Three cases:
  #
  #   1. Nothing withheld → the whole window was digested → `window_end`.
  #   2. Something withheld and something included → land one microsecond
  #      past the last included row. Strictly forward (the digest admits
  #      whole timestamp groups, so no withheld row shares that instant) and
  #      provably not past anything undigested. Advancing to the watermark
  #      itself would re-read that row forever whenever the budget admits
  #      exactly one item — the invariant must not be bought with a livelock.
  #   3. Nothing included because one row exceeds the budget alone → step
  #      past exactly that row and emit `:item_skipped`. Splitting cannot
  #      terminate here and stalling would wedge every later window in the
  #      corpus behind it, which is a worse failure than the one being fixed
  #      because it is total rather than partial.
  @spec cursor_target(window(), map()) :: {DateTime.t(), map() | nil}
  defp cursor_target(window, %{truncated?: false}), do: {window.window_end, nil}

  defp cursor_target(_window, %{last_included_at: %DateTime{} = watermark}),
    do: {DateTime.add(watermark, 1, :microsecond), nil}

  defp cursor_target(_window, %{skipped: %{at: %DateTime{} = at} = skipped}),
    do: {DateTime.add(at, 1, :microsecond), skipped}

  # Unreachable by construction: `truncated?` is `included_count <
  # item_count`, so `item_count > 0`, so either something was included (and
  # `last_included_at` is set) or the first group was skipped. Kept total
  # rather than raising — a Historian sweep is not worth crashing over — and
  # it holds the cursor where it is rather than guessing forward.
  defp cursor_target(window, _digest), do: {window.window_start, nil}

  defp dispatch_to_agent(%Agent{} = agent, event_type, template_slug, extra_metadata) do
    with :ok <- ensure_runtime_reachable(agent, event_type),
         {:ok, space} <- ensure_system_space(agent),
         {:ok, system_participant} <- ensure_system_participant(space),
         {:ok, agent_participant} <-
           Chat.add_agent_participant(space.id, agent, display_name: agent.name),
         {:ok, message} <-
           post_instruction(space, system_participant, event_type, template_slug, extra_metadata) do
      signal = %{
        participant_id: agent_participant.id,
        message_id: message.id,
        space_id: space.id,
        reason: :system_event,
        metadata: Map.merge(%{event_type: event_type}, stringify_keys(extra_metadata))
      }

      AgentResponder.maybe_dispatch(signal)
    else
      {:error, reason} ->
        Logger.error(
          "[HistorianDispatcher] failed to dispatch #{event_type} to #{agent.slug}: " <>
            inspect(reason)
        )

        {:error, reason}
    end
  end

  # Skip dispatch when the external agent's runtime is known to be offline
  # — avoids posting an instruction that will dead-letter immediately.
  # Built-in agents always pass this check.
  defp ensure_runtime_reachable(
         %Agent{runtime_type: "external", runtime_id: runtime_pk} = agent,
         event_type
       )
       when is_binary(runtime_pk) do
    case Federation.get_runtime(runtime_pk) do
      %{runtime_id: runtime_id} ->
        if RuntimePresence.online?(runtime_id) do
          :ok
        else
          Logger.warning(
            "[HistorianDispatcher] skipping #{event_type}: external runtime " <>
              "#{runtime_id} is offline"
          )

          {:error, :runtime_offline}
        end

      nil ->
        Logger.warning(
          "[HistorianDispatcher] skipping #{event_type}: agent #{agent.slug} " <>
            "runtime row not found (pk=#{runtime_pk})"
        )

        {:error, :runtime_not_found}
    end
  end

  defp ensure_runtime_reachable(%Agent{}, _event_type), do: :ok

  defp ensure_system_space(%Agent{} = agent) do
    slug = "system-#{agent.slug}"

    case Chat.get_space_by_slug(slug) do
      %Chat.Space{} = space ->
        {:ok, space}

      nil ->
        Chat.create_space(%{
          name: "#{agent.name} — System Events",
          slug: slug,
          kind: "system",
          metadata: %{"system_event_space" => true, "agent_id" => agent.id}
        })
    end
  end

  defp ensure_system_participant(space) do
    case Repo.get_by(Chat.Participant,
           space_id: space.id,
           participant_type: "user",
           participant_id: @system_participant_sentinel
         ) do
      %Chat.Participant{} = p ->
        {:ok, p}

      nil ->
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: @system_participant_sentinel,
          display_name: "System",
          joined_at: DateTime.utc_now()
        })
    end
  end

  defp post_instruction(
         space,
         system_participant,
         event_type,
         template_slug,
         extra_metadata,
         opts \\ []
       ) do
    date = Date.to_iso8601(Date.utc_today())
    digest = Keyword.get(opts, :activity_digest) || activity_digest()
    deleted_paths_notice = render_deleted_paths_notice()

    # Dreaming templates (`historian.dreaming` + legacy `memory.dreaming.v1`)
    # carry a `{{rejected_exemplars}}` placeholder that must be pre-rendered
    # from `Platform.Memory.Proposals.rejected_exemplars/1` so the model
    # sees prior rejections as few-shot calibration. Other templates never
    # reference the key — `interpolate/2` treats unreferenced keys as
    # no-ops, so the extra assign is safe to include unconditionally, but
    # the DB read is only worth doing on dreaming dispatches.
    rejected_exemplars =
      case dreaming_template?(template_slug) do
        true ->
          workspace_id =
            Map.get(extra_metadata, :workspace_id) || Map.get(extra_metadata, "workspace_id")

          render_rejected_exemplars(workspace_id: workspace_id, limit: 3)

        false ->
          ""
      end

    template_vars =
      Map.merge(
        %{
          date: date,
          activity_digest: digest,
          deleted_paths_notice: deleted_paths_notice,
          rejected_exemplars: rejected_exemplars
        },
        extra_metadata
      )

    content =
      case PromptTemplates.render_template(template_slug, template_vars) do
        {:ok, rendered} ->
          rendered

        {:error, :not_found} ->
          @default_historian_instruction
          |> String.replace("{date}", date)
          |> String.replace("{activity_digest}", digest)
          |> String.replace("{deleted_paths_notice}", deleted_paths_notice)
      end

    case guard_body_size(content, event_type, template_slug) do
      :ok ->
        Chat.post_message(%{
          space_id: space.id,
          participant_id: system_participant.id,
          content_type: "text",
          content: content,
          metadata:
            Map.merge(
              # `skip_mention_scan: true` prevents AttentionRouter from
              # tokenising `@[Name]` occurrences in the embedded 24h activity
              # digest as real mentions — those are historical references, not
              # live pings. Without this, every named participant in the last
              # 24h of chat activity received a `:multi_mention` notification
              # into Higgins's system space on every Historian pass (surfaced
              # 2026-07-10 by Rowan noticing Dalton was receiving Historian
              # dispatches meant for Higgins).
              # See `Platform.Chat.AttentionRouter.mention_scan_enabled?/1`.
              %{
                "source" => "system_event",
                "event_type" => event_type,
                "skip_mention_scan" => true
              },
              stringify_keys(extra_metadata)
            )
        })

      {:error, _reason} = err ->
        err
    end
  end

  # Body-size sanity check applied to every rendered instruction (both the
  # 24h-anchor and per-window paths). Rejects at `budget_tokens +
  # @body_headroom_tokens` — the corpus digest is separately budgeted, so
  # this guard exists to catch runaway template renders / math errors
  # BEFORE we persist a message we know downstream small-model runtimes
  # can't process. Rejecting here also skips `Chat.post_message/1` so we
  # never write an orphan `chat_messages` row that the AgentResponder
  # would then dead-letter on.
  @spec guard_body_size(String.t(), String.t(), String.t()) ::
          :ok | {:error, {:oversize_body, non_neg_integer()}}
  defp guard_body_size(content, event_type, template_slug) when is_binary(content) do
    body_size_tokens = div(byte_size(content), 4)
    hard_cap = window_budget_tokens() + @body_headroom_tokens

    if body_size_tokens > hard_cap do
      Logger.error(
        "[HistorianDispatcher] rejecting oversize body: event=#{event_type} " <>
          "template=#{template_slug} tokens=#{body_size_tokens} cap=#{hard_cap}"
      )

      {:error, {:oversize_body, body_size_tokens}}
    else
      :ok
    end
  end

  # Coerce atom/integer/etc metadata values into the shape AgentResponder /
  # downstream consumers expect (string keys); leave atom values alone.
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp activity_digest do
    window_end = DateTime.utc_now()
    window_start = DateTime.add(window_end, -@daily_window_hours * 3_600, :second)
    ActivityDigest.build(window_start, window_end)
  end

  # Render the "Intentionally deleted paths" body from the recent
  # `feedback_kind: "delete"` rows in the memory-feedback corpus
  # (task 019f6381 stage 5). Signals to the Historian which paths were
  # intentionally removed so it doesn't restore backlink targets that
  # were purposefully cleaned up.
  #
  # Interpolated into every dispatched instruction — the corresponding
  # `{{deleted_paths_notice}}` placeholder is currently only referenced
  # by the `historian.scheduled` template body; other templates that
  # don't reference the placeholder silently drop the extra var (this
  # is by design — `interpolate/2` treats unreferenced keys as no-ops).
  # Empty window renders `(none in the recent window)` so the section
  # header never leaves a dangling placeholder in the rendered content.
  # Identify the two dreaming templates that carry the `{{rejected_exemplars}}`
  # placeholder — kept as a helper (instead of an inlined guard) so a future
  # dreaming variant slug only has to be added here.
  @dreaming_template_slugs ~w(historian.dreaming memory.dreaming.v1)

  @spec dreaming_template?(String.t()) :: boolean()
  defp dreaming_template?(slug) when is_binary(slug),
    do: slug in @dreaming_template_slugs

  defp dreaming_template?(_), do: false

  # Render prior rejected proposals as a bulleted list of `{body, feedback}`
  # pairs — the few-shot exemplars the dreaming prompt consumes via the
  # `{{rejected_exemplars}}` placeholder. Bounded to 3 exemplars per prompt
  # (matches the default in `Platform.Memory.Proposals.rejected_exemplars/1`).
  #
  # The database read is best-effort: a failed lookup (bad workspace scope,
  # Repo unavailable during boot) renders as the empty-window placeholder
  # so a dreaming dispatch never fails hard because the exemplars couldn't
  # be assembled.
  @spec render_rejected_exemplars(keyword()) :: String.t()
  defp render_rejected_exemplars(opts) do
    exemplars =
      try do
        Platform.Memory.Proposals.rejected_exemplars(opts)
      rescue
        error ->
          Logger.warning(
            "[HistorianDispatcher] Proposals.rejected_exemplars/1 raised: " <>
              Exception.message(error)
          )

          []
      end

    case exemplars do
      [] ->
        "(no prior rejections in the recent window)"

      rows ->
        rows
        |> Enum.map(fn %{body: body, feedback: feedback, category: category} ->
          feedback_line =
            case feedback do
              nil -> ""
              "" -> ""
              text -> "\n  - Rowan's feedback: #{text}"
            end

          "- [#{category}] #{body}#{feedback_line}"
        end)
        |> Enum.join("\n")
    end
  end

  @spec render_deleted_paths_notice() :: String.t()
  defp render_deleted_paths_notice do
    deleted =
      Platform.MemoryFeedback.list_recent(
        namespace: "org_context",
        feedback_kind: "delete",
        limit: 20
      )

    case deleted do
      [] ->
        "(none in the recent window)"

      rows ->
        rows
        |> Enum.map(fn r ->
          reason =
            if r.reason_text in [nil, ""], do: "", else: " — #{r.reason_text}"

          "- #{r.path}#{reason}"
        end)
        |> Enum.join("\n")
    end
  rescue
    error ->
      Logger.warning(
        "[HistorianDispatcher] MemoryFeedback.list_recent/1 raised: " <>
          Exception.message(error)
      )

      "(none in the recent window)"
  end

  # ── Telemetry helper (task 019f5bc4 stage 1) ──────────────────────────────
  #
  # Shared emitter so every historian dispatch event carries the same
  # scoping envelope (`workspace_id`, `resource_type: "workspace"`,
  # `resource_id`, `action`). Stage 2's audit bridge
  # (`Platform.Audit.TelemetryHandler`) matches on this shape to persist
  # rows into `audit_events` — mirrors the plan-auto-approve convention
  # in `apps/platform/lib/platform/tasks.ex`.
  #
  # `event` is the terminal atom (e.g. `:pass_started`), lifted onto the
  # full `[:platform, :historian, event]` path here so callers stay
  # readable. `action` metadata is derived from the same atom so callers
  # cannot forget to keep the two in sync.
  @spec emit_telemetry(atom(), map(), map(), binary() | nil) :: :ok
  defp emit_telemetry(event, measurements, extra_metadata, workspace_id)
       when is_atom(event) and is_map(measurements) and is_map(extra_metadata) do
    metadata =
      Map.merge(
        %{
          workspace_id: workspace_id,
          resource_type: "workspace",
          resource_id: workspace_id,
          action: Atom.to_string(event)
        },
        extra_metadata
      )

    :telemetry.execute(
      [:platform, :historian, event],
      measurements,
      metadata
    )
  end

  # Emit the `[:platform, :agents, :historian, :no_op_pass]` event with a
  # scope-compliant envelope so `Platform.Audit.TelemetryHandler` persists
  # an audit row. `nil` workspace_id (the org-scope case) is coerced to
  # the org-scope sentinel so `scope_check/2` in the audit handler passes
  # — dropping a legitimately-scoped no-op pass would defeat the whole
  # observability point of this event.
  @spec emit_no_op_pass(binary() | nil, String.t(), String.t(), non_neg_integer(), map()) :: :ok
  defp emit_no_op_pass(workspace_id, event_type, template_slug, elapsed_ms, extra_metadata)
       when is_binary(event_type) and is_binary(template_slug) and is_integer(elapsed_ms) and
              is_map(extra_metadata) do
    ws = workspace_id || Projects.org_scope_workspace_id()

    metadata =
      Map.merge(
        %{
          workspace_id: ws,
          resource_type: "workspace",
          resource_id: ws,
          action: "no_op_pass",
          trigger: template_slug,
          event_type: event_type
        },
        extra_metadata
      )

    :telemetry.execute(@no_op_pass_event, %{elapsed_ms: elapsed_ms}, metadata)
  end
end
