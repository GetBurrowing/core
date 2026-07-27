defmodule Mix.Tasks.Platform.HistorianAuditOversizeTest do
  @moduledoc """
  Discrimination coverage for `Platform.Agents.HistorianAudit` (task
  019fa1cc stage 1).

  The failure mode this module guards against is a diagnostic that returns
  a *constant*. The original hand-written investigation query classified
  every oversize window the same way and reported 87 messages lost where
  the digest-eligible count was zero. A test that seeds one fixture and
  asserts one classification would pass against a function that hardcodes
  that classification.

  So the discriminating test seeds all three fixtures in a single run and
  asserts all three classifications come back from one call. Every absence
  assertion is paired with a positive control in the same test —
  `Enum.all?/2` and `Enum.empty?/1` both return `true` on `[]`, so the
  collection is pinned non-empty and pinned to an exact length *before*
  anything is asserted over it.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.HistorianAudit
  alias Platform.Audit.Event
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo

  # Must match `ActivityDigest`'s empty-window line and
  # `HistorianDispatcher.@truncation_marker` verbatim — the audit tool
  # classifies on these strings.
  @empty_stub "_No activity in this window._"
  @truncation_marker "_(truncated — deep-summary rather than deep-curate)_"

  # Task 019fa1cc stage 4's replacement for the marker above. Same observer
  # convention as the two constants above it: duplicated deliberately so
  # this module keeps classifying historical rows correctly after the
  # emitters change their strings.
  @partial_marker "_(partial — 2 of 3 items included; the remainder re-dispatches next pass.)_"

  # Three adjacent one-hour spans, well in the past so nothing else the
  # suite inserts can land inside them.
  @base ~U[2026-03-01 00:00:00.000000Z]

  describe "audit_oversize_windows/1" do
    test "discriminates spurious, silent_loss and legitimate in one run" do
      {a_start, a_end} = span(0)
      {b_start, b_end} = span(1)
      {c_start, c_end} = span(2)

      system_space = insert_space("system")
      system_participant = insert_participant(system_space.id)

      # ── (a) SPURIOUS ───────────────────────────────────────────────────
      # Execution-kind chatter plus log_only rows: real bytes on disk, zero
      # of them digest-eligible. This is the shape of all 84 oversize
      # windows measured in prod.
      exec_space = insert_space("execution")
      exec_participant = insert_participant(exec_space.id)

      Enum.each(1..5, fn i ->
        insert_message!(exec_space.id, exec_participant.id,
          content: String.duplicate("x", 400),
          inserted_at: DateTime.add(a_start, i * 60, :second)
        )
      end)

      # log_only rows in a live channel — excluded by the digest predicate
      # for a different reason, so the fixture exercises two of the five
      # filters rather than one.
      chatter_channel = insert_space("channel")
      chatter_participant = insert_participant(chatter_channel.id)

      Enum.each(1..3, fn i ->
        insert_message!(chatter_channel.id, chatter_participant.id,
          content: String.duplicate("y", 400),
          log_only: true,
          inserted_at: DateTime.add(a_start, 1_800 + i * 60, :second)
        )
      end)

      insert_audit_event!("messages", a_start, a_end, day_bytes: 3_200, token_count: 30_000)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        a_start,
        a_end,
        oversize_body(@empty_stub)
      )

      # ── (b) SILENT LOSS ────────────────────────────────────────────────
      # One genuinely eligible channel message, and the dispatched body is
      # the empty stub anyway.
      live_channel = insert_space("channel")
      live_participant = insert_participant(live_channel.id)

      lost_content = String.duplicate("z", 137)

      insert_message!(live_channel.id, live_participant.id,
        content: lost_content,
        inserted_at: DateTime.add(b_start, 600, :second)
      )

      insert_audit_event!("messages", b_start, b_end, day_bytes: 137, token_count: 30_000)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        b_start,
        b_end,
        oversize_body(@empty_stub)
      )

      # ── (c) LEGITIMATE ─────────────────────────────────────────────────
      # An eligible channel message that IS present in the dispatched body.
      rendered_content = "the quarterly numbers came in ahead of plan"

      insert_message!(live_channel.id, live_participant.id,
        content: rendered_content,
        inserted_at: DateTime.add(c_start, 600, :second)
      )

      insert_audit_event!("messages", c_start, c_end, day_bytes: 43, token_count: 30_000)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        c_start,
        c_end,
        oversize_body(
          "## Chat since ...\n\n**#general**\n- Someone: #{rendered_content}\n" <>
            String.duplicate("padding ", 200)
        )
      )

      # ── Assertions ─────────────────────────────────────────────────────
      results =
        HistorianAudit.audit_oversize_windows(corpus: "messages", since: @base)

      # POSITIVE CONTROL FIRST. Both of the following would pass vacuously
      # on `[]`, so pin the collection before asserting over it.
      refute Enum.empty?(results)
      assert length(results) == 3

      by_start = Map.new(results, &{&1.window_start, &1})
      assert MapSet.new(Map.keys(by_start)) == MapSet.new([a_start, b_start, c_start])

      a = by_start[a_start]
      b = by_start[b_start]
      c = by_start[c_start]

      # (a) spurious: 8 raw rows in the span, none of them eligible.
      assert a.classification == :spurious
      assert a.raw_row_count == 8
      assert a.eligible_row_count == 0
      assert a.eligible_bytes == 0
      assert a.empty_stub?
      assert a.day_bytes == 3_200
      assert a.token_count == 30_000

      # (b) silent_loss: exactly the one channel message, with its bytes.
      assert b.classification == :silent_loss
      assert b.eligible_row_count == 1
      assert b.eligible_bytes == byte_size(lost_content)
      assert b.empty_stub?

      # (c) legitimate: eligible content present, body not the stub.
      assert c.classification == :legitimate
      assert c.eligible_row_count == 1
      assert c.eligible_bytes == byte_size(rendered_content)
      refute c.empty_stub?

      # Every window found its dispatched body — an audit row with no body
      # would classify off an empty string and silently read as
      # `:silent_loss`/`:spurious` for the wrong reason.
      assert Enum.all?(results, &is_binary(&1.dispatched_message_id))
      assert Enum.all?(results, &(&1.body_bytes > 0))

      # The three classifications are genuinely distinct — the function is
      # not returning a constant.
      assert results |> Enum.map(& &1.classification) |> Enum.uniq() |> length() == 3
    end

    test "summarize/1 attributes lost rows only to lossy classes" do
      {a_start, a_end} = span(10)
      {b_start, b_end} = span(11)
      {c_start, c_end} = span(12)

      system_space = insert_space("system")
      system_participant = insert_participant(system_space.id)

      exec_space = insert_space("execution")
      exec_participant = insert_participant(exec_space.id)

      # Spurious window: 40 execution rows, 0 eligible.
      Enum.each(1..40, fn i ->
        insert_message!(exec_space.id, exec_participant.id,
          content: String.duplicate("x", 1_000),
          inserted_at: DateTime.add(a_start, i * 60, :second)
        )
      end)

      insert_audit_event!("messages", a_start, a_end, day_bytes: 40_000, token_count: 30_000)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        a_start,
        a_end,
        oversize_body(@empty_stub)
      )

      # Silent-loss window: 2 eligible channel rows, empty stub dispatched.
      live_channel = insert_space("channel")
      live_participant = insert_participant(live_channel.id)

      lost = ["first real message", "second real message"]

      Enum.with_index(lost, 1)
      |> Enum.each(fn {content, i} ->
        insert_message!(live_channel.id, live_participant.id,
          content: content,
          inserted_at: DateTime.add(b_start, i * 60, :second)
        )
      end)

      insert_audit_event!("messages", b_start, b_end, day_bytes: 40, token_count: 30_000)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        b_start,
        b_end,
        oversize_body(@empty_stub)
      )

      # Legitimate window: 3 eligible channel rows that WERE rendered. This
      # window exists specifically so the loss fold has something non-zero
      # to wrongly absorb. A `:spurious` window alone cannot detect the bad
      # fold, because its `eligible_bytes` is 0 by definition — folding zero
      # in changes nothing. (Measured: without this fixture, replacing the
      # `Enum.filter/2` in `summarize/1` with the identity left all five
      # tests green.)
      rendered = ["rendered one", "rendered two", "rendered three"]
      rendered_bytes = rendered |> Enum.map(&byte_size/1) |> Enum.sum()

      Enum.with_index(rendered, 1)
      |> Enum.each(fn {content, i} ->
        insert_message!(live_channel.id, live_participant.id,
          content: content,
          inserted_at: DateTime.add(c_start, i * 60, :second)
        )
      end)

      insert_audit_event!("messages", c_start, c_end, day_bytes: 36, token_count: 30_000)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        c_start,
        c_end,
        oversize_body("**#general**\n" <> Enum.join(rendered, "\n"))
      )

      results = HistorianAudit.audit_oversize_windows(corpus: "messages", since: @base)

      refute Enum.empty?(results)
      assert length(results) == 3

      summary = HistorianAudit.summarize(results)

      assert summary.total == 3
      assert summary.spurious == 1
      assert summary.silent_loss == 1
      assert summary.truncated_loss == 0
      assert summary.legitimate == 1

      # POSITIVE CONTROL: the loss figure is non-zero and is EXACTLY the
      # eligible bytes of the lossy window — not the legitimate window's,
      # and not the spurious window's raw 40_000. Folding non-lossy windows
      # into the loss total is precisely how the task's original "87
      # messages lost" claim was manufactured.
      expected_bytes = lost |> Enum.map(&byte_size/1) |> Enum.sum()
      assert rendered_bytes > 0
      assert summary.lost_rows == 2
      assert summary.lost_bytes == expected_bytes
      assert summary.lost_bytes > 0
      assert summary.lost_bytes < expected_bytes + rendered_bytes
      assert summary.lost_bytes < 40_000

      assert summary.corpora == %{"messages" => 3}

      assert HistorianAudit.summary_line(summary) =~
               "3 oversize windows: 1 spurious, 1 silent_loss"
    end

    test "classifies :truncated_loss on the byte cap, not on the marker or on digest compression" do
      # Three windows, one per trap, asserted in the same run so the
      # classifier is proven to discriminate between them:
      #   (t) body AT the cap          → :truncated_loss
      #   (m) marker but body under cap → :legitimate  (trap 1)
      #   (z) eligible_bytes >> body_bytes, body under cap → :legitimate
      #       (trap 2 — this is the shape that produced 16 false
      #        `:truncated_loss` verdicts on the first prod run)
      {t_start, t_end} = span(20)
      {m_start, m_end} = span(21)
      {z_start, z_end} = span(22)

      system_space = insert_space("system")
      system_participant = insert_participant(system_space.id)

      live_channel = insert_space("channel")
      live_participant = insert_participant(live_channel.id)

      # (t) token_count 200 → cap 800 bytes. Body is 1_000 bytes, i.e. the
      # digest reached the cut point.
      insert_message!(live_channel.id, live_participant.id,
        content: String.duplicate("t", 4_000),
        inserted_at: DateTime.add(t_start, 60, :second)
      )

      insert_audit_event!("messages", t_start, t_end, day_bytes: 4_000, token_count: 200)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        t_start,
        t_end,
        @truncation_marker <> "\n\n" <> String.duplicate("t", 1_000)
      )

      # (m) same 800-byte cap, body only ~120 bytes — the marker is present
      # (the dispatcher prepends it unconditionally) but nothing was cut.
      insert_message!(live_channel.id, live_participant.id,
        content: "short",
        inserted_at: DateTime.add(m_start, 60, :second)
      )

      insert_audit_event!("messages", m_start, m_end, day_bytes: 5, token_count: 200)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        m_start,
        m_end,
        @truncation_marker <> "\n\nshort"
      )

      # (z) 20 eligible messages of 1_000 bytes = 20_000 eligible bytes,
      # rendered into a ~600-byte body. That is `ActivityDigest.preview/1`
      # (280-char cap) and `@per_space_message_cap` doing their job — a
      # digest summarising, NOT a window losing content. Body is under the
      # 800-byte cap, so this must NOT classify as loss.
      Enum.each(1..20, fn i ->
        insert_message!(live_channel.id, live_participant.id,
          content: String.duplicate("z", 1_000),
          inserted_at: DateTime.add(z_start, i * 60, :second)
        )
      end)

      insert_audit_event!("messages", z_start, z_end, day_bytes: 20_000, token_count: 200)

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        z_start,
        z_end,
        @truncation_marker <> "\n\n" <> String.duplicate("z", 600)
      )

      results = HistorianAudit.audit_oversize_windows(corpus: "messages", since: @base)

      # POSITIVE CONTROL before any per-window assertion.
      refute Enum.empty?(results)
      assert length(results) == 3

      by_start = Map.new(results, &{&1.window_start, &1})
      t = by_start[t_start]
      m = by_start[m_start]
      z = by_start[z_start]

      # All three carry the marker — so the marker cannot be what separates
      # them. Asserting this makes the discrimination claim non-vacuous.
      assert t.truncation_marker?
      assert m.truncation_marker?
      assert z.truncation_marker?
      assert t.truncation_cap_bytes == 800
      assert m.truncation_cap_bytes == 800
      assert z.truncation_cap_bytes == 800

      assert t.classification == :truncated_loss
      assert t.body_bytes >= t.truncation_cap_bytes

      assert m.classification == :legitimate
      assert m.body_bytes < m.truncation_cap_bytes

      # The load-bearing one: hugely compressed, still not loss.
      assert z.classification == :legitimate
      assert z.eligible_row_count == 20
      assert z.eligible_bytes == 20_000
      assert z.digest_compressed?
      assert z.eligible_bytes > z.body_bytes
      assert z.body_bytes < z.truncation_cap_bytes

      summary = HistorianAudit.summarize(results)
      assert summary.truncated_loss == 1
      assert summary.legitimate == 2
      assert summary.silent_loss == 0
    end

    test "classifies post-fix rows from the audit trail, not from read-time eligibility" do
      # Task 019fa1cc stage 4 made the dispatcher state its own outcome on
      # the `window_dispatched` row. This is the test that the flags are
      # ACTED ON rather than merely present: every window below is
      # constructed so that the pre-stage-4 heuristics would reach a
      # DIFFERENT verdict, and all three are asserted in one run so the
      # classifier is proven to discriminate rather than to return a
      # constant.
      {o_start, o_end} = span(50)
      {p_start, p_end} = span(51)
      {l_start, l_end} = span(52)

      system_space = insert_space("system")
      system_participant = insert_participant(system_space.id)

      live_channel = insert_space("channel")
      live_participant = insert_participant(live_channel.id)

      # ── (o) oversize_empty ─────────────────────────────────────────────
      # The dispatcher found nothing digestible. An eligible row exists in
      # the span TODAY (it was archived/undeleted since, or simply written
      # after the fact) — exactly the read-time-eligibility caveat the
      # moduledoc warns about. Without the flag this reads `:legitimate`.
      insert_message!(live_channel.id, live_participant.id,
        content: "written into the span after the window was dispatched",
        inserted_at: DateTime.add(o_start, 600, :second)
      )

      insert_audit_event!("messages", o_start, o_end,
        day_bytes: 240_749,
        token_count: 30_000,
        extra: %{"oversize_empty" => "true", "truncated" => "false"}
      )

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        o_start,
        o_end,
        "## Chat since ... (UTC)\n\n_Window exceeded the digest budget; " <>
          "no digestible activity in scope (87 raw rows out of scope)._"
      )

      # ── (p) partial_deferred ───────────────────────────────────────────
      # Deliberately carries the OLD truncation marker AND a body at the
      # 800-byte cap, so the pre-stage-4 heuristic would call this
      # `:truncated_loss`. The flag must win — post-fix the withheld rows
      # were deferred behind a held cursor, not lost.
      Enum.each(1..3, fn i ->
        insert_message!(live_channel.id, live_participant.id,
          content: String.duplicate("d", 500),
          inserted_at: DateTime.add(p_start, i * 60, :second)
        )
      end)

      insert_audit_event!("messages", p_start, p_end,
        day_bytes: 1_500,
        token_count: 200,
        extra: %{"truncated" => "true", "oversize_empty" => "false"}
      )

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        p_start,
        p_end,
        @truncation_marker <>
          "\n\n" <> @partial_marker <> "\n\n" <> String.duplicate("d", 1_000)
      )

      # ── (l) legitimate control ─────────────────────────────────────────
      # Post-fix row with both flags false. Without this the two new
      # clauses could be a constant and nothing would notice.
      rendered = "the quarterly numbers came in ahead of plan"

      insert_message!(live_channel.id, live_participant.id,
        content: rendered,
        inserted_at: DateTime.add(l_start, 600, :second)
      )

      insert_audit_event!("messages", l_start, l_end,
        day_bytes: 43,
        token_count: 30_000,
        extra: %{"truncated" => "false", "oversize_empty" => "false"}
      )

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        l_start,
        l_end,
        "## Chat since ... (UTC)\n\n#### #general\n- 00:10 @Auditee: #{rendered}"
      )

      results = HistorianAudit.audit_oversize_windows(corpus: "messages", since: @base)

      # POSITIVE CONTROL FIRST.
      refute Enum.empty?(results)
      assert length(results) == 3

      by_start = Map.new(results, &{&1.window_start, &1})
      o = by_start[o_start]
      p = by_start[p_start]
      l = by_start[l_start]

      assert o.oversize_empty?
      assert o.classification == :spurious
      # The load-bearing part: read-time eligibility says otherwise.
      assert o.eligible_row_count == 1
      refute o.empty_stub?

      assert p.truncated?
      assert p.classification == :partial_deferred
      # The pre-stage-4 heuristic would have fired here.
      assert p.truncation_marker?
      assert p.body_bytes >= p.truncation_cap_bytes
      assert p.eligible_row_count == 3

      refute l.truncated?
      refute l.oversize_empty?
      assert l.classification == :legitimate

      assert results |> Enum.map(& &1.classification) |> Enum.uniq() |> length() == 3

      summary = HistorianAudit.summarize(results)
      assert summary.partial_deferred == 1
      assert summary.spurious == 1
      assert summary.legitimate == 1
      assert summary.truncated_loss == 0
      assert summary.silent_loss == 0

      # Deferral is not loss. POSITIVE CONTROL: the deferred window has 3
      # eligible rows / 1_500 bytes, so folding it into the loss total
      # would be plainly visible rather than a no-op on zero.
      assert p.eligible_bytes == 1_500
      assert summary.lost_rows == 0
      assert summary.lost_bytes == 0
    end

    test "ignores window_dispatched rows that are not oversize" do
      {start_at, end_at} = span(30)

      # POSITIVE CONTROL: an oversize row in an adjacent span IS returned,
      # so an empty result below means "filtered", not "query broken".
      {control_start, control_end} = span(31)

      system_space = insert_space("system")
      system_participant = insert_participant(system_space.id)

      insert_audit_event!("messages", start_at, end_at,
        day_bytes: 100,
        token_count: 30_000,
        oversize: false
      )

      insert_audit_event!("messages", control_start, control_end,
        day_bytes: 100,
        token_count: 30_000
      )

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        control_start,
        control_end,
        oversize_body(@empty_stub)
      )

      results = HistorianAudit.audit_oversize_windows(corpus: "messages", since: @base)

      refute Enum.empty?(results)
      assert length(results) == 1
      assert hd(results).window_start == control_start
    end

    test "skips audit rows whose day_span cannot be parsed rather than crashing" do
      {control_start, control_end} = span(40)

      system_space = insert_space("system")
      system_participant = insert_participant(system_space.id)

      insert_audit_event!("messages", control_start, control_end,
        day_bytes: 1,
        token_count: 30_000
      )

      insert_dispatched_body!(
        system_space,
        system_participant,
        "messages",
        control_start,
        control_end,
        oversize_body(@empty_stub)
      )

      Repo.insert!(%Event{
        event_type: "platform.historian.window_dispatched",
        actor_type: "system",
        action: "window_dispatched",
        resource_type: "workspace",
        resource_id: Ecto.UUID.generate(),
        metadata: %{"oversize" => "true", "corpus" => "messages", "day_span" => "not-a-span"}
      })

      results = HistorianAudit.audit_oversize_windows(corpus: "messages", since: @base)

      # POSITIVE CONTROL: the parseable row still comes back. Without it
      # this assertion would pass against a function that returned `[]`.
      refute Enum.empty?(results)
      assert length(results) == 1
      assert hd(results).window_start == control_start
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp span(index) do
    start_at = DateTime.add(@base, index * 3_600, :second)
    {start_at, DateTime.add(start_at, 3_600, :second)}
  end

  defp oversize_body(digest_body) do
    @truncation_marker <> "\n\n## Chat since ... (UTC)\n\n" <> digest_body
  end

  defp insert_space(kind) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Audit #{kind} #{System.unique_integer([:positive])}",
        slug: "audit-#{kind}-#{System.unique_integer([:positive])}",
        kind: kind
      })

    space
  end

  defp insert_participant(space_id) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Auditee",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp insert_message!(space_id, participant_id, opts) do
    attrs = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: Keyword.get(opts, :content_type, "text"),
      content: Keyword.fetch!(opts, :content),
      log_only: Keyword.get(opts, :log_only, false),
      metadata: Keyword.get(opts, :metadata, %{}),
      author_display_name: "Auditee"
    }

    %Message{}
    |> Message.changeset(attrs)
    |> Ecto.Changeset.put_change(:inserted_at, Keyword.fetch!(opts, :inserted_at))
    |> Repo.insert!()
  end

  # The dispatched instruction message the Historian dispatcher writes into
  # its own system space. `inserted_at` is deliberately pushed well past
  # every audited span so the body itself never counts as corpus content.
  defp insert_dispatched_body!(space, participant, corpus, window_start, window_end, content) do
    insert_message!(space.id, participant.id,
      content: content,
      inserted_at: DateTime.add(@base, 400 * 3_600, :second),
      metadata: %{
        "source" => "system_event",
        "event_type" => "historian",
        "oversize" => true,
        "token_estimate" => 30_000,
        "cursor" => %{
          "namespace" => corpus,
          "window_start" => DateTime.to_iso8601(window_start),
          "window_end" => DateTime.to_iso8601(window_end)
        }
      }
    )
  end

  defp insert_audit_event!(corpus, window_start, window_end, opts) do
    oversize = Keyword.get(opts, :oversize, true)
    extra = Keyword.get(opts, :extra, %{})

    Repo.insert!(%Event{
      event_type: "platform.historian.window_dispatched",
      actor_type: "system",
      action: "window_dispatched",
      resource_type: "workspace",
      resource_id: Ecto.UUID.generate(),
      metadata:
        %{
          "corpus" => corpus,
          # The telemetry handler's `ensure_json_safe/1` stringifies atoms,
          # and `true` IS an atom — so prod rows carry the STRING "true"
          # here, not a JSON boolean. Reproduce that exactly.
          "oversize" => to_string(oversize),
          "day_span" =>
            DateTime.to_iso8601(window_start) <> "/" <> DateTime.to_iso8601(window_end),
          "day_bytes" => Keyword.fetch!(opts, :day_bytes),
          "token_count" => Keyword.fetch!(opts, :token_count),
          "window_index" => 0,
          "workspace_id" => Ecto.UUID.generate()
        }
        |> Map.merge(extra)
    })
  end
end
