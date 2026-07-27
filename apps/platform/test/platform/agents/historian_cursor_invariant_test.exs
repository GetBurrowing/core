defmodule Platform.Agents.HistorianCursorInvariantTest do
  @moduledoc """
  The standing regression gate for task `019fa1cc`.

  ## Read this before you "fix" a failure here

  Stages 1-4 of `019fa1cc` fixed a defect with four distinct moving parts.
  This module exists so that undoing any one of them fails loudly rather
  than quietly reverting the Historian to dispatching an empty stub for an
  hour of real activity and stamping the cursor past it.

  **The invariant: the cursor must never advance past content that was
  never digested.**

  Every assertion here is chosen to fail against pre-stage-4 behaviour. That
  bar matters because the obvious test does NOT clear it — a test asserting
  only that the oversize path is *taken* passes against the broken code,
  which is why five reviewers read past the defect. Each test names, in a
  comment, the exact source edit that detonates it. If you change the
  dispatcher and this file stays green, either your change is behaviour
  preserving or the test stopped discriminating; check which before
  believing the first.

  ## The four things pinned

    * TEST 1 — the cursor lands on the watermark of content actually
      dispatched, and the withheld remainder re-dispatches on a later pass
      rather than being skipped. (Stage 4.)
    * TEST 2 — "there was nothing to digest" and "we could not digest this"
      render as two different strings. (Stage 4; the original defect is the
      conflation of the two.)
    * TEST 3 — a single row larger than the whole budget is named, audited
      and stepped past, so the invariant is not bought with a livelock.
      (Stage 4.)
    * TEST 4 — agent chatter cannot make a quiet hour look oversize.
      (Stages 2 + 3, stated end to end.)

  ## Fixture discipline

  Four stages of this task each had a mutation survive its first pass
  because the fixture handed the mutated thing a degenerate value (a
  `:spurious` window's eligible bytes are 0 by definition; every transcript
  fixture had `completed_at == updated_at`; two fixtures shared a 900-byte
  summary; every repo transcript fixture uses `segments: []`). For a
  cursor-watermark test the specific hazard is timestamps: if the seeded
  rows share an `inserted_at` then `last_included_at == window_end` and the
  whole invariant is untestable while every assertion passes. So the rows
  here carry **distinct** `inserted_at` values AND **uneven** byte sizes, so
  the budget cut lands mid-span rather than on a boundary that a
  cursor-to-`window_end` mutation would also satisfy.

  Complements `historian_dispatcher_test.exs` (behaviour-level coverage of
  the same paths). This file is the discriminating guard; that one is the
  description of what the feature does.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Agents.{ActivityDigest, Agent, Historian, HistorianCursor, HistorianDispatcher}
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks.Projects

  # V1 org-scope sentinel — see the same note in `historian_dispatcher_test.exs`.
  @org_workspace Projects.org_scope_workspace_id()

  # Verbatim from `historian_dispatcher_test.exs` — a no-op chat module so the
  # `AgentResponder.maybe_dispatch/1` call at the tail of each windowed post
  # doesn't reach for a real LLM.
  defmodule NoopAgentChat do
    def chat(_message, _opts), do: {:ok, %{content: "", model: "test", usage: %{}}}
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_budget = Application.get_env(:platform, :historian_window_token_budget)
    previous_cap = Application.get_env(:platform, :historian_max_windows_per_pass)

    Application.put_env(:platform, :chat_agent_module, NoopAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      restore_env(:chat_agent_module, previous_module)
      restore_env(:chat_agent_dispatch_mode, previous_mode)
      restore_env(:historian_window_token_budget, previous_budget)
      restore_env(:historian_max_windows_per_pass, previous_cap)
    end)

    agent = insert_historian_agent()

    {:ok, agent: agent}
  end

  # ── TEST 1 — the invariant ───────────────────────────────────────────────

  describe "cursor watermark invariant" do
    # DETONATION (verified during task 019fa1cc stage 5): revert
    # `HistorianDispatcher.cursor_target/2` to the pre-stage-4
    #
    #     Historian.advance_cursor(workspace_id, corpus_string, nil, window.window_end)
    #
    # and assertion (b) — `cursor < window_end` — MUST fail. It does: the
    # cursor lands on the window end, which is `now`-ish and after every
    # seeded row. If that assertion still passes, this test has stopped
    # discriminating and the gate is not doing its job.
    test "the cursor stops at the last digested row and the remainder re-dispatches",
         %{agent: agent} do
      # 200 tokens → an 800-byte cap. Stage 4 measured real withholding at
      # exactly this budget against live spans (12 windows held, 15 skipped,
      # 124 rows withheld), so the fixture genuinely exercises the hold
      # rather than sitting under it.
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("invariant")
      participant = insert_user_participant(space.id, "Ada")

      now = DateTime.utc_now()
      park_other_corpora(now)
      {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, hour_ago(now))

      # UNEVEN sizes at DISTINCT timestamps. Both properties are
      # load-bearing:
      #
      #   * distinct `inserted_at` — with a shared instant the watermark
      #     equals the window end and a cursor-to-`window_end` mutation is
      #     invisible;
      #   * uneven sizes — 120,125,…,165 bytes. The running total reaches
      #     795 of the 800-byte cap after six rows and the seventh (150 B)
      #     would overshoot, so the cut lands at row 6 — mid-span, not on
      #     the span boundary and not on a round half. The remaining four
      #     rows weigh 630 B, which fits one later window whole, so the
      #     second pass drains the corpus and the "only now does the cursor
      #     reach `window_end`" assertion below means what it says.
      sizes = [120, 125, 130, 135, 140, 145, 150, 155, 160, 165]
      seeded = seed_rows(space, participant, now, sizes)
      tags = Enum.map(seeded, & &1.tag)
      timestamps = Enum.map(seeded, & &1.at)

      assert length(Enum.uniq(timestamps)) == 10,
             "fixture is degenerate: the seeded rows must not share an instant"

      assert {:ok, %{dispatched: dispatched_1}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "pass-1"},
                 @org_workspace
               )

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      pass_1 = messages_corpus_messages(system_space)

      # (a) POSITIVE CONTROL, FIRST. An absence assertion on its own passes
      # against an unwired code path, and `Enum.all?/2` is `true` on `[]`.
      assert dispatched_1 >= 1
      refute Enum.empty?(pass_1)
      assert length(pass_1) == 1, "expected exactly one messages window in pass 1"

      body_1 = pass_1 |> Enum.map(& &1.content) |> Enum.join("\n")
      assert body_1 =~ Enum.at(tags, 0), "message 1 must be in the dispatched body"
      assert body_1 =~ "_(partial — "

      included = Enum.take_while(tags, &String.contains?(body_1, &1))
      withheld = Enum.drop(tags, length(included))

      # Both halves pinned non-empty before anything is concluded from
      # either. A fixture that included everything, or nothing, would make
      # the watermark assertions vacuous.
      refute Enum.empty?(included)
      refute Enum.empty?(withheld)

      # The exact split, not merely "some of each". A cut at 5/5 or 9/1
      # would still satisfy the two `refute`s above while meaning the
      # budget arithmetic had changed underneath the test.
      assert {length(included), length(withheld)} == {6, 4}

      # (d) Paired absence — meaningful only because (a) passed.
      Enum.each(withheld, fn tag ->
        refute body_1 =~ tag, "withheld row #{tag} must not appear in the dispatched body"
      end)

      window_end_1 = window_end_of(hd(pass_1))
      cursor_1 = messages_cursor()

      # (b) THE INVARIANT. The cursor did NOT reach the window end.
      assert DateTime.compare(cursor_1.last_processed_at, window_end_1) == :lt

      # (c) It landed exactly on the watermark of content actually
      # dispatched — plus one microsecond.
      #
      # The `+1µs` is not slack: `ActivityDigest` admits whole timestamp
      # groups, so no withheld row can share the watermark instant, and
      # `advance_cursor` bounds are half-open. Landing ON the watermark
      # would re-read that row forever whenever the budget admits exactly
      # one item; stage 4 refused to buy the invariant with a livelock.
      # Anything coarser than "one microsecond past the last included row"
      # is a bug of this class, so the assertion is equality, not `<=`.
      watermark = Enum.at(timestamps, length(included) - 1)

      assert DateTime.compare(
               cursor_1.last_processed_at,
               DateTime.add(watermark, 1, :microsecond)
             ) == :eq,
             "expected the cursor one microsecond past row #{length(included)} " <>
               "(#{watermark}), got #{cursor_1.last_processed_at}"

      assert DateTime.compare(cursor_1.last_processed_at, List.last(timestamps)) == :lt

      # (e) DEFERRED, NOT SKIPPED. This is the assertion that separates
      # "held the cursor back" from "held the cursor back and lost the tail".
      assert {:ok, %{dispatched: dispatched_2}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "pass-2"},
                 @org_workspace
               )

      assert dispatched_2 >= 1

      pass_2 = system_space |> messages_corpus_messages() |> Enum.drop(length(pass_1))
      refute Enum.empty?(pass_2)

      body_2 = pass_2 |> Enum.map(& &1.content) |> Enum.join("\n")

      Enum.each(withheld, fn tag ->
        assert body_2 =~ tag, "withheld row #{tag} never re-dispatched on pass 2"
      end)

      # ...and ONLY now does the cursor reach the window end.
      window_end_2 = window_end_of(List.last(pass_2))
      cursor_2 = messages_cursor()

      assert DateTime.compare(cursor_2.last_processed_at, window_end_2) == :eq
      assert DateTime.compare(cursor_2.last_processed_at, List.last(timestamps)) == :gt
    end
  end

  # ── TEST 2 — the two empty strings ───────────────────────────────────────

  describe "the two empty strings" do
    # DETONATION (verified during stage 5): collapse the `meta.oversize_empty?`
    # branch of `ActivityDigest.render_windowed/7` back into `@empty_line`
    # (i.e. delete the branch) and both the `refute body_b =~ @empty_line`
    # and `assert body_a != body_b` assertions fail. That collapse IS the
    # original defect: 55 prod windows dispatched `_No activity in this
    # window._` for spans the byte signal had just charged for real content.
    #
    # This is the same collapse ADR 0046 forbids under
    # `§ Per-step outcome` — `not_applicable` and `failed` must never be
    # conflated. One is the quiet path; the other is a gate that did not run.
    #
    # Driven at `build_windowed_result/1` rather than through
    # `dispatch_windowed/4` on purpose: stage 2 made "oversize with zero
    # eligible rows" unreachable from the slicer, which is the fix working.
    # The two strings still have to differ if it ever becomes reachable
    # again, so the seam that produces them is the honest place to pin it.
    test "'nothing to digest' and 'could not digest' are different strings" do
      quiet_start = ~U[2001-03-03 00:00:00Z]
      quiet_end = ~U[2001-03-03 01:00:00Z]
      packed_start = ~U[2001-03-04 00:00:00Z]
      packed_end = ~U[2001-03-04 01:00:00Z]

      # Window B's span: the exact shape that fired all 84 prod oversize
      # windows — a busy hour of agent chatter plus log-only rows. Every one
      # of these is invisible to the digest predicate.
      exec = insert_space_of_kind!("execution", "two-strings-exec")
      exec_p = insert_user_participant(exec.id, "Runner")
      live = insert_channel_space("two-strings-live")
      live_p = insert_user_participant(live.id, "Voice")

      for i <- 1..40 do
        insert_message_at!(exec.id, exec_p.id, String.duplicate("x", 500), at(packed_start, i))
      end

      for i <- 41..45 do
        insert_message_at!(
          live.id,
          live_p.id,
          String.duplicate("l", 400),
          at(packed_start, i),
          %{log_only: true}
        )
      end

      # FIXTURE CONTROL, not a code assertion. Without these three, "window B
      # renders the could-not-digest line" would pass just as well against an
      # empty span, and the raw row count in the rendered string would be the
      # degenerate 0.
      assert raw_message_bytes(packed_start, packed_end) == 40 * 500 + 5 * 400
      assert Historian.pending_bytes_in_range("messages", packed_start, packed_end, nil) == 0
      assert raw_message_count(packed_start, packed_end) == 45

      {:ok, body_a, meta_a} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: quiet_start,
          window_end: quiet_end,
          budget_tokens: 200,
          oversize: false
        })

      {:ok, body_b, meta_b} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: packed_start,
          window_end: packed_end,
          budget_tokens: 200,
          oversize: true
        })

      bodies = [body_a, body_b]

      # Pin the collection before iterating it — `Enum.all?/2` and
      # `Enum.empty?/1` are both `true` on `[]`.
      assert length(bodies) == 2
      assert Enum.all?(bodies, &(is_binary(&1) and byte_size(&1) > 0))

      # POSITIVE CONTROLS on the two metas, so the string assertions below
      # are about rendering and not about the fixture.
      assert meta_a.item_count == 0
      assert meta_a.oversize_empty? == false
      assert meta_b.item_count == 0
      assert meta_b.oversize_empty? == true

      # THE ASSERTION THAT MAKES THE ORIGINAL DEFECT IMPOSSIBLE TO
      # REINTRODUCE INVISIBLY.
      assert body_a =~ "_No activity in this window._"
      refute body_b =~ "_No activity in this window._"
      assert body_a != body_b

      # ...and window B says how much it could not see, so an operator
      # reading the digest can tell a quiet hour from an unreadable one
      # without re-querying the corpus.
      assert body_b =~ "45 raw rows out of scope"
    end
  end

  # ── TEST 3 — livelock guard ──────────────────────────────────────────────

  describe "livelock guard" do
    # DETONATION (verified during stage 5): change the skipped clause of
    # `HistorianDispatcher.cursor_target/2` to hold the cursor
    #
    #     defp cursor_target(window, %{skipped: %{}}), do: {window.window_start, nil}
    #
    # — the "retry with a smaller span" fix the stage-4 plan rejected — and
    # the forward-progress assertion fails: the cursor never passes the
    # unfittable row and the follower row is never dispatched, so the corpus
    # is wedged behind one message forever. Deleting the `:item_skipped`
    # emit instead detonates the `assert_received` below: an unaudited skip
    # is exactly the silent advance this task exists to remove.
    test "a row larger than the whole budget is named, audited and stepped past",
         %{agent: agent} do
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      space = insert_channel_space("livelock")
      participant = insert_user_participant(space.id, "Ada")

      now = DateTime.utc_now()
      park_other_corpora(now)
      {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, hour_ago(now))

      # 3_000 bytes against an 800-byte cap: no amount of further slicing
      # makes this row fit, which is precisely why `@min_sub_window_seconds`
      # exists. The follower is 100 bytes and lands later in the span.
      [giant, follower] =
        seed_rows(space, participant, now, [3_000, 100], tags: ["OVERSIZE-ROW", "FOLLOWER-ROW"])

      test_pid = self()
      handler_id = "historian-invariant-skip-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:platform, :historian, :item_skipped],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:item_skipped, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:ok, %{dispatched: dispatched_1}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "pass-1"},
                 @org_workspace
               )

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      pass_1 = messages_corpus_messages(system_space)

      # POSITIVE CONTROL FIRST.
      assert dispatched_1 >= 1
      refute Enum.empty?(pass_1)

      body_1 = pass_1 |> Enum.map(& &1.content) |> Enum.join("\n")

      # NAMED, not cut at a byte offset. `binary_part/3` could split a
      # multi-byte grapheme and hand Postgres invalid UTF-8 for a `text`
      # column; stage 4 removed it.
      assert body_1 =~ "_(skipped — "
      assert String.valid?(body_1)
      refute body_1 =~ "_No activity in this window._"

      # The skip is a queryable audit row naming the row it stepped over.
      assert_received {:item_skipped, %{bytes: bytes}, %{corpus: "messages"} = meta}
      assert bytes >= 3_000
      assert meta.message_id == to_string(giant.id)

      # FORWARD PROGRESS. Under the rejected "retry with a smaller span"
      # option this assertion is the one that livelocks.
      cursor_1 = messages_cursor()
      assert DateTime.compare(cursor_1.last_processed_at, giant.at) == :gt

      # ...and not one instant further than it had to go: the follower is
      # still ahead of the cursor, undigested.
      assert DateTime.compare(cursor_1.last_processed_at, follower.at) == :lt
      refute body_1 =~ follower.tag

      # POSITIVE CONTROL ON THE GUARD: the corpus was not wedged. The next
      # pass dispatches the following row from a later window.
      assert {:ok, %{dispatched: dispatched_2}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "pass-2"},
                 @org_workspace
               )

      assert dispatched_2 >= 1

      pass_2 = system_space |> messages_corpus_messages() |> Enum.drop(length(pass_1))
      refute Enum.empty?(pass_2)

      body_2 = pass_2 |> Enum.map(& &1.content) |> Enum.join("\n")
      assert body_2 =~ follower.tag

      cursor_2 = messages_cursor()
      assert DateTime.compare(cursor_2.last_processed_at, follower.at) == :gt
    end
  end

  # ── TEST 4 — spurious oversize at the seam ───────────────────────────────

  describe "spurious oversize at the eligibility seam" do
    # DETONATION (verified during stage 5): revert either half of stage 2 —
    # point `Historian.sum_corpus_bytes("messages", …)` or
    # `per_day_bytes_query("messages", …)` back at the bare
    # `from(m in "chat_messages")` schemaless source — and the
    # zero-oversize-windows assertion fails. 20_000 bytes of agent chatter
    # is 5_000 tokens against a 200-token budget, so the pre-stage-2 signal
    # drives this quiet hour to the halving floor and stamps it
    # `oversize: true`, exactly as it did 84 times on prod.
    #
    # Reverting stage 3's per-half re-measurement instead (restoring the
    # `div(total_bytes, 2)` smear in `halve_until_fits/7`) is not visible
    # here — stage 2 already zeroes the chatter, so there is nothing left to
    # smear. Stage 3 is pinned by
    # `historian_dispatcher_slice_windows_test.exs`; this test states the
    # end-to-end consequence of the two together.
    test "agent chatter cannot make a quiet hour look oversize", %{agent: agent} do
      Application.put_env(:platform, :historian_window_token_budget, 200)
      Application.put_env(:platform, :historian_max_windows_per_pass, 20)

      now = DateTime.utc_now()
      park_other_corpora(now)
      {:ok, _} = Historian.advance_cursor(@org_workspace, "messages", nil, hour_ago(now))

      exec = insert_space_of_kind!("execution", "seam-exec")
      exec_p = insert_user_participant(exec.id, "Runner")
      live = insert_channel_space("seam-live")
      live_p = insert_user_participant(live.id, "Voice")

      # 40 execution-kind rows × 500 bytes = 20_000 bytes of chatter, well
      # over the 800-byte budget, in the same hour as two ~100-byte channel
      # messages that are the only digestible thing that happened.
      for i <- 1..40 do
        insert_message_at!(exec.id, exec_p.id, String.duplicate("x", 500), fraction(now, i, 44))
      end

      a = insert_message_at!(live.id, live_p.id, tagged("CHAN-A", 100), fraction(now, 41, 44))
      b = insert_message_at!(live.id, live_p.id, tagged("CHAN-B", 100), fraction(now, 42, 44))

      # FIXTURE CONTROL: the chatter really is over budget by the raw
      # measure, so "zero oversize windows" below is a statement about the
      # predicate and not about a fixture that never had enough bytes.
      assert raw_message_bytes(hour_ago(now), now) > 200 * 4

      windows =
        @org_workspace
        |> HistorianDispatcher.slice_windows()
        |> Enum.filter(&(&1.corpus == :messages))

      # POSITIVE CONTROL FIRST: `Enum.all?/2` and `Enum.count/2` are both
      # happy to agree with any claim about an empty list.
      refute Enum.empty?(windows)

      assert Enum.any?(windows, fn w ->
               DateTime.compare(a.at, w.window_start) != :lt and
                 DateTime.compare(b.at, w.window_end) == :lt
             end),
             "expected an emitted window covering both channel messages"

      # THE REGRESSION. Not `> 0`, not "fewer than before" — zero.
      assert Enum.count(windows, & &1.oversize) == 0

      assert {:ok, %{dispatched: dispatched}} =
               HistorianDispatcher.dispatch_windowed(
                 "historian",
                 "historian.threshold",
                 %{trigger: "seam"},
                 @org_workspace
               )

      assert dispatched >= 1

      system_space = Chat.get_space_by_slug("system-#{agent.slug}")
      posted = messages_corpus_messages(system_space)
      refute Enum.empty?(posted)

      body = posted |> Enum.map(& &1.content) |> Enum.join("\n")

      # END-TO-END POSITIVE CONTROL: the quiet hour dispatched its actual
      # content, not a stub. Pre-stage-2 this body was
      # `_No activity in this window._` on a window flagged oversize.
      assert body =~ "CHAN-A"
      assert body =~ "CHAN-B"
      refute body =~ "_No activity in this window._"
      refute body =~ "_(partial — "

      assert Enum.all?(posted, &(&1.metadata["oversize"] == false))
      assert Enum.all?(posted, &(&1.metadata["truncated"] == false))
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Every seeded row lands inside ONE UTC calendar day, which is what keeps
  # these tests deterministic at any wall-clock time. The slice range is
  # always `[cursor, now)`; if the cursor sits an hour back across UTC
  # midnight, `enumerate_day_ranges/2` splits it in two — but the earlier
  # range holds no rows, `slice_by_calendar_day/6` drops zero-byte days, and
  # the surviving range is under `@min_sub_window_seconds`, so exactly one
  # window is emitted either way. Seeding rows before midnight is what would
  # break that, so `row_span_start/1` clamps to midnight.
  defp hour_ago(now), do: DateTime.add(now, -3_600, :second)

  defp row_span_start(now) do
    midnight = DateTime.new!(DateTime.to_date(now), ~T[00:00:00], "Etc/UTC")
    candidate = hour_ago(now)

    if DateTime.compare(candidate, midnight) == :lt, do: midnight, else: candidate
  end

  # The `i`-th of `of` evenly spaced instants strictly inside the row span.
  # Microsecond spacing rather than seconds so the span can be short (the
  # first minute of a UTC day) without two rows colliding — a shared
  # `inserted_at` is the degenerate fixture this whole module warns about.
  defp fraction(now, i, of) do
    start = row_span_start(now)
    step = max(div(DateTime.diff(now, start, :microsecond), of + 2), 1)
    DateTime.add(start, i * step, :microsecond)
  end

  defp at(%DateTime{} = base, i), do: DateTime.add(base, i * 1_000_000, :microsecond)

  # A content string of EXACTLY `bytes` bytes whose first characters are a
  # unique tag, so a body can be searched for the presence of one specific
  # row. All ASCII, so byte length is character length.
  defp tagged(tag, bytes) do
    tag <> String.duplicate("x", bytes - byte_size(tag))
  end

  # Seeds one row per entry in `sizes`, at distinct evenly spaced instants
  # inside the row span, and hands back the tag/timestamp/id of each.
  defp seed_rows(space, participant, now, sizes, opts \\ []) do
    count = length(sizes)

    tags =
      Keyword.get_lazy(opts, :tags, fn ->
        Enum.map(1..count, &("ROW-" <> String.pad_leading("#{&1}", 3, "0")))
      end)

    [tags, sizes]
    |> Enum.zip()
    |> Enum.with_index(1)
    |> Enum.map(fn {{tag, bytes}, i} ->
      message =
        insert_message_at!(
          space.id,
          participant.id,
          tagged(tag, bytes),
          fraction(now, i, count)
        )

      Map.put(message, :tag, tag)
    end)
  end

  # Park every corpus except `messages` beyond `now` so the only windows a
  # dispatch emits are the ones under test. The shared test DB carries
  # seeded org wiki rows whose own pending bytes would otherwise emit a
  # `pages` window that these tests say nothing about.
  defp park_other_corpora(now) do
    future = DateTime.add(now, 3_600, :second)

    Enum.each(~w(pages journal transcripts), fn corpus ->
      {:ok, _} = Historian.advance_cursor(@org_workspace, corpus, nil, future)
    end)
  end

  defp insert_historian_agent do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "historian-#{System.unique_integer([:positive])}",
        name: "Historian",
        status: "active"
      })
      |> Repo.insert!()

    case Roles.assign_role("historian", agent.id) do
      {:ok, _} -> :ok
      {:error, _} -> Roles.unassign_role("historian") && Roles.assign_role("historian", agent.id)
    end

    agent
  end

  defp insert_channel_space(name_suffix), do: insert_space_of_kind!("channel", name_suffix)

  defp insert_space_of_kind!(kind, name_suffix) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Space #{name_suffix}",
        slug: "#{kind}-#{System.unique_integer([:positive])}",
        kind: kind
      })

    space
  end

  defp insert_user_participant(space_id, display_name) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  # `inserted_at` is autogenerated, so a backdated row needs a raw
  # `update_all` — the same test-only escape hatch `historian_test.exs` uses.
  defp insert_message_at!(space_id, participant_id, content, %DateTime{} = at, attrs \\ %{}) do
    base = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      author_display_name: "Test"
    }

    {:ok, message} =
      %Message{}
      |> Message.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    {1, _} =
      Repo.update_all(
        from(m in Message, where: m.id == ^message.id),
        set: [inserted_at: at]
      )

    %{id: message.id, at: at, content: content, tag: content}
  end

  # Instruction messages the dispatcher posted for the `messages` corpus,
  # oldest first.
  defp messages_corpus_messages(%Chat.Space{id: space_id}) do
    Repo.all(
      from(m in Message,
        where: m.space_id == ^space_id and m.content_type == "text",
        order_by: [asc: m.inserted_at, asc: m.id]
      )
    )
    |> Enum.filter(&(get_in(&1.metadata, ["cursor", "namespace"]) == "messages"))
  end

  defp window_end_of(message) do
    {:ok, dt, _} = message.metadata |> get_in(["cursor", "window_end"]) |> DateTime.from_iso8601()
    dt
  end

  defp messages_cursor do
    Repo.one!(
      from(c in HistorianCursor,
        where: is_nil(c.workspace_id) and c.corpus == "messages"
      )
    )
  end

  # The PRE-stage-2 byte signal, reproduced verbatim: every `chat_messages`
  # row in the span, no eligibility predicate at all. Used as a fixture
  # control so "the unified signal sees 0 bytes" is a measured gap rather
  # than a hope.
  defp raw_message_bytes(window_start, window_end) do
    from(m in "chat_messages",
      where: m.inserted_at >= ^window_start and m.inserted_at < ^window_end,
      select: sum(fragment("octet_length(?)", m.content))
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp raw_message_count(window_start, window_end) do
    from(m in "chat_messages",
      where: m.inserted_at >= ^window_start and m.inserted_at < ^window_end,
      select: count()
    )
    |> Repo.one()
    |> Kernel.||(0)
  end

  defp restore_env(_key, nil), do: :ok
  defp restore_env(key, value), do: Application.put_env(:platform, key, value)
end
