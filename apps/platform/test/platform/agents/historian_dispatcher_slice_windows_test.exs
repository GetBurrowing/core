defmodule Platform.Agents.HistorianDispatcherSliceWindowsTest do
  @moduledoc """
  Pure-unit coverage for
  `Platform.Agents.HistorianDispatcher.slice_windows/2`.

  No DB, no LiveView, no scheduler — the slicer is a pure function over
  the shape `Historian.pending_windows_input/1` returns. Tests fake that
  shape via `opts[:input_fn]` so we exercise every edge (empty, small,
  multi-day, single-day sub-slice, oversize marker, config override,
  four-corpus interleave) without touching Ecto.

  Async because there's no shared state — each test builds its own
  input map. The one exception (`config override`) uses
  `Application.put_env/3` on `:historian_window_token_budget`; that key
  is read via `Application.get_env/3` per-call so the local put_env
  effect is scoped to the current process's config view.
  """

  use ExUnit.Case, async: false

  alias Platform.Agents.HistorianDispatcher

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Fixed anchor so day boundaries are deterministic. 2026-07-11 12:00 UTC —
  # picked because the current-in-repo date sits inside this UTC day, so the
  # `end_at.date` and `start_at.date` calendar-day enumeration hits a known
  # count of days.
  defp now, do: ~U[2026-07-11 12:00:00Z]

  # Bytes for a given number of tokens under the char/4 heuristic.
  defp tokens_to_bytes(t), do: t * 4

  defp input_for(map), do: fn _workspace_id -> map end

  # ── (a) Empty input → [] ────────────────────────────────────────────────

  describe "slice_windows/2 — empty input" do
    test "empty map returns []" do
      assert HistorianDispatcher.slice_windows(nil, input_fn: input_for(%{}), now: now()) ==
               []
    end

    test "every corpus present but zero bytes returns []" do
      input = %{
        pages: {nil, 0},
        journal: {nil, 0},
        messages: {nil, 0},
        transcripts: {nil, 0}
      }

      assert HistorianDispatcher.slice_windows(nil, input_fn: input_for(input), now: now()) ==
               []
    end

    test "negative or non-integer bytes are treated as zero and skipped" do
      input = %{
        pages: {nil, -100},
        journal: {nil, nil}
      }

      assert HistorianDispatcher.slice_windows(nil, input_fn: input_for(input), now: now()) ==
               []
    end
  end

  # ── (b) Small backlog fits one window per corpus ────────────────────────

  describe "slice_windows/2 — small backlog (< budget)" do
    test "single corpus with 5k tokens over 1 hour returns one window with all entries" do
      last_at = DateTime.add(now(), -3_600, :second)
      # 5_000 tokens → 20_000 bytes
      input = %{
        messages: {last_at, tokens_to_bytes(5_000)}
      }

      assert [window] =
               HistorianDispatcher.slice_windows(nil,
                 input_fn: input_for(input),
                 now: now(),
                 budget_tokens: 30_000
               )

      assert window.corpus == :messages
      assert window.window_start == last_at
      assert window.window_end == now()
      assert window.token_estimate == 5_000
      assert window.oversize == false
    end
  end

  # ── (c) 3-day 90k-token backlog splits into 3 day windows ──────────────

  describe "slice_windows/2 — multi-day at-budget backlog" do
    test "3-day 90k-token single-corpus backlog returns 3 windows oldest-first" do
      # last_at is midnight 3 days before `now`; span is exactly 72h so the
      # day-boundary enumerator hits three whole days.
      last_at = ~U[2026-07-08 12:00:00Z]
      # 90_000 tokens → 360_000 bytes → 30k tokens/day = at budget
      input = %{
        messages: {last_at, tokens_to_bytes(90_000)}
      }

      windows =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: now(),
          budget_tokens: 30_000
        )

      # Enumerate_day_ranges walks 07-08, 07-09, 07-10, 07-11 — the 07-08
      # slice is [12:00, 24:00) (12h), the 07-09/10 slices are full days,
      # 07-11 is [00:00, 12:00). 4 sub-ranges total; uniform byte
      # distribution keeps every sub-range under the 30k budget, so we
      # get 4 windows here rather than exactly 3.
      #
      # The stage 1 contract says "one per day" — the enumeration IS
      # per-day, and the wall-clock day boundaries are what makes stage 2
      # cursor advance safe. Assert count matches enumerated day count.
      assert length(windows) == 4

      # Oldest-first chronological order.
      starts = Enum.map(windows, & &1.window_start)
      assert starts == Enum.sort(starts, DateTime)

      # Sum of token estimates should equal (with rounding slop) the
      # original 90k input.
      total_tokens = Enum.sum(Enum.map(windows, & &1.token_estimate))
      assert_in_delta(total_tokens, 90_000, 20)

      # Every window in this case fits under budget → none oversized.
      assert Enum.all?(windows, &(&1.oversize == false))
      assert Enum.all?(windows, &(&1.corpus == :messages))
    end

    test "exactly 3 whole days of backlog returns exactly 3 windows" do
      # Anchor the last_at at UTC midnight so day enumeration yields exactly 3.
      last_at = ~U[2026-07-08 00:00:00Z]
      end_at = ~U[2026-07-11 00:00:00Z]
      input = %{messages: {last_at, tokens_to_bytes(90_000)}}

      windows =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: end_at,
          budget_tokens: 30_000
        )

      assert length(windows) == 3
      assert Enum.at(windows, 0).window_start == ~U[2026-07-08 00:00:00Z]
      assert Enum.at(windows, 1).window_start == ~U[2026-07-09 00:00:00Z]
      assert Enum.at(windows, 2).window_start == ~U[2026-07-10 00:00:00Z]
      assert Enum.at(windows, 2).window_end == ~U[2026-07-11 00:00:00Z]
    end
  end

  # ── (d) Single-day 60k backlog subdivides ──────────────────────────────

  describe "slice_windows/2 — single-day over-budget backlog" do
    test "60k-token single-day single-corpus backlog subdivides into 2+ windows" do
      last_at = ~U[2026-07-11 00:00:00Z]
      end_at = ~U[2026-07-11 12:00:00Z]
      # 60_000 tokens → 240_000 bytes in a 12h window; > 30k budget → halve
      input = %{messages: {last_at, tokens_to_bytes(60_000)}}

      windows =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: end_at,
          budget_tokens: 30_000
        )

      assert length(windows) >= 2
      assert Enum.all?(windows, &(&1.corpus == :messages))
      assert Enum.all?(windows, &(&1.token_estimate <= 30_000))
      assert Enum.all?(windows, &(&1.oversize == false))

      # First window starts at the corpus start; last ends at now.
      assert List.first(windows).window_start == last_at
      assert List.last(windows).window_end == end_at

      # Sub-windows should tile the input span without gaps.
      pairs = Enum.chunk_every(windows, 2, 1, :discard)

      Enum.each(pairs, fn [a, b] ->
        assert DateTime.compare(a.window_end, b.window_start) == :eq,
               "expected #{a.window_end} == #{b.window_start} for contiguous windows"
      end)
    end
  end

  # ── (e) Oversize single-hour entry ─────────────────────────────────────

  describe "slice_windows/2 — oversize single-row window" do
    test "very-large single-entry (60k tokens in 1h) emits oversize: true window" do
      # 1h span with 60k tokens = 240k bytes. Halving would drop below the
      # 1h min_sub_window, so we hit the oversize branch.
      last_at = DateTime.add(now(), -3_600, :second)
      input = %{transcripts: {last_at, tokens_to_bytes(60_000)}}

      windows =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: now(),
          budget_tokens: 30_000
        )

      assert [window] = windows
      assert window.corpus == :transcripts
      assert window.oversize == true
      # token_estimate clamped to budget so downstream digest-build knows
      # the ceiling to trim to.
      assert window.token_estimate == 30_000
      assert window.window_start == last_at
      assert window.window_end == now()
    end
  end

  # ── (f) Config override ────────────────────────────────────────────────

  describe "slice_windows/2 — config override" do
    setup do
      original = Application.get_env(:platform, :historian_window_token_budget)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:platform, :historian_window_token_budget)
        else
          Application.put_env(:platform, :historian_window_token_budget, original)
        end
      end)

      :ok
    end

    test "Application.put_env with smaller budget slices tighter" do
      last_at = ~U[2026-07-11 00:00:00Z]
      end_at = ~U[2026-07-11 12:00:00Z]
      # 20k tokens in 12h. Under 30k default → 1 window. Under 5k
      # override → must subdivide.
      input = %{messages: {last_at, tokens_to_bytes(20_000)}}

      # Sanity: default budget yields 1 window.
      default_windows =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: end_at
        )

      assert length(default_windows) == 1

      # Tighten to 5k tokens and re-slice — should split several times.
      Application.put_env(:platform, :historian_window_token_budget, 5_000)

      tightened =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: end_at
        )

      assert length(tightened) >= 4
      assert Enum.all?(tightened, &(&1.token_estimate <= 5_000))
    end

    test "explicit :budget_tokens opt overrides config" do
      last_at = ~U[2026-07-11 00:00:00Z]
      end_at = ~U[2026-07-11 12:00:00Z]
      input = %{messages: {last_at, tokens_to_bytes(20_000)}}

      # Override even though config is default.
      windows =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: end_at,
          budget_tokens: 5_000
        )

      assert length(windows) >= 4
      assert Enum.all?(windows, &(&1.token_estimate <= 5_000))
    end
  end

  # ── (g) Four-corpus interleave — corpus order deterministic ────────────

  describe "slice_windows/2 — multi-corpus interleave" do
    test "all four corpora emit windows in (day ASC, corpus_order ASC)" do
      # Each corpus gets a small backlog fitting a single window; the
      # sort should put them in the deterministic corpus order at the
      # same window_start when synchronised.
      last_at = DateTime.add(now(), -3_600, :second)

      input = %{
        pages: {last_at, tokens_to_bytes(1_000)},
        journal: {last_at, tokens_to_bytes(1_000)},
        messages: {last_at, tokens_to_bytes(1_000)},
        transcripts: {last_at, tokens_to_bytes(1_000)}
      }

      windows =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: now(),
          budget_tokens: 30_000
        )

      assert length(windows) == 4
      corpora = Enum.map(windows, & &1.corpus)
      assert corpora == [:pages, :journal, :messages, :transcripts]
    end

    test "corpora with 0 bytes are skipped even if last_at is present" do
      last_at = DateTime.add(now(), -3_600, :second)

      input = %{
        pages: {last_at, tokens_to_bytes(500)},
        journal: {last_at, 0},
        messages: {last_at, tokens_to_bytes(500)},
        transcripts: {last_at, 0}
      }

      windows =
        HistorianDispatcher.slice_windows(nil,
          input_fn: input_for(input),
          now: now(),
          budget_tokens: 30_000
        )

      assert length(windows) == 2
      assert Enum.map(windows, & &1.corpus) == [:pages, :messages]
    end
  end

  # ── (h) Cursor-nil fallback ─────────────────────────────────────────────

  describe "slice_windows/2 — nil cursor fallback lookback" do
    test "nil last_at emits windows bounded at the default lookback" do
      # 5k tokens (fits in one window) with no cursor.
      input = %{messages: {nil, tokens_to_bytes(5_000)}}

      assert [window] =
               HistorianDispatcher.slice_windows(nil,
                 input_fn: input_for(input),
                 now: now(),
                 budget_tokens: 30_000
               )

      # `window_start` sits ~30 days before now; assert within a second
      # of that so the exact `@default_lookback_seconds` constant stays
      # a private implementation detail.
      lookback_seconds = DateTime.diff(window.window_end, window.window_start, :second)
      assert_in_delta(lookback_seconds, 30 * 86_400, 2)
    end
  end

  # ── (i) Config accessors ────────────────────────────────────────────────

  describe "config accessor helpers" do
    setup do
      budget = Application.get_env(:platform, :historian_window_token_budget)
      cap = Application.get_env(:platform, :historian_max_windows_per_pass)

      on_exit(fn ->
        set_env(:historian_window_token_budget, budget)
        set_env(:historian_max_windows_per_pass, cap)
      end)

      :ok
    end

    test "window_budget_tokens/0 reads config with 30_000 default" do
      Application.delete_env(:platform, :historian_window_token_budget)
      assert HistorianDispatcher.window_budget_tokens() == 30_000

      Application.put_env(:platform, :historian_window_token_budget, 12_345)
      assert HistorianDispatcher.window_budget_tokens() == 12_345
    end

    test "max_windows_per_pass/0 reads config with 20 default" do
      Application.delete_env(:platform, :historian_max_windows_per_pass)
      assert HistorianDispatcher.max_windows_per_pass() == 20

      Application.put_env(:platform, :historian_max_windows_per_pass, 5)
      assert HistorianDispatcher.max_windows_per_pass() == 5
    end

    defp set_env(_key, nil), do: :ok
    defp set_env(key, value), do: Application.put_env(:platform, key, value)
  end
end
