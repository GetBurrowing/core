defmodule Platform.Agents.ActivityDigestTest do
  use Platform.DataCase

  alias Platform.Agents.ActivityDigest
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Meetings.Transcript
  alias Platform.Tasks.{Project, Task}

  @window_end ~U[2026-04-22 12:00:00.000000Z]
  @window_start ~U[2026-04-21 12:00:00.000000Z]

  describe "build/2" do
    test "returns empty fallback when no activity exists in the window" do
      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "## Activity since 2026-04-21 12:00:00"
      assert result =~ "_No activity in this window._"
    end

    test "includes messages from channels within the window" do
      space = insert_space(%{name: "Strategy", slug: "strategy", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Alice"})

      insert_message(space.id, participant.id, %{
        content: "Kicked off Q2 planning today",
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "### Chat"
      assert result =~ "#Strategy"
      assert result =~ "@Alice"
      assert result =~ "Kicked off Q2 planning today"
    end

    test "excludes DM messages" do
      space = insert_space(%{name: "DM", slug: "dm-1", kind: "dm"})
      participant = insert_participant(space.id, %{display_name: "Alice"})

      insert_message(space.id, participant.id, %{
        content: "private chat",
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "private chat"
      assert result =~ "_No activity in this window._"
    end

    test "excludes log_only messages" do
      space = insert_space()
      participant = insert_participant(space.id)

      insert_message(space.id, participant.id, %{
        content: "internal log tick",
        log_only: true,
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "internal log tick"
    end

    test "excludes deleted messages" do
      space = insert_space()
      participant = insert_participant(space.id)

      insert_message(space.id, participant.id, %{
        content: "retracted",
        deleted_at: within_window(),
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "retracted"
    end

    test "excludes messages outside the window" do
      space = insert_space()
      participant = insert_participant(space.id)

      insert_message(space.id, participant.id, %{
        content: "too old",
        inserted_at: ~U[2026-04-20 12:00:00.000000Z]
      })

      insert_message(space.id, participant.id, %{
        content: "too new",
        inserted_at: ~U[2026-04-22 13:00:00.000000Z]
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "too old"
      refute result =~ "too new"
    end

    test "applies per-space message cap with overflow marker" do
      space = insert_space(%{name: "Busy", slug: "busy"})
      participant = insert_participant(space.id, %{display_name: "Loud"})

      for i <- 1..45 do
        insert_message(space.id, participant.id, %{
          content: "message-#{i}",
          inserted_at: within_window()
        })
      end

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "message-1"
      assert result =~ "more messages — truncated"
    end

    test "truncates message content to preview length" do
      space = insert_space()
      participant = insert_participant(space.id, %{display_name: "Verbose"})
      long = String.duplicate("abc ", 200)

      insert_message(space.id, participant.id, %{
        content: long,
        inserted_at: within_window()
      })

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "…"
    end

    test "includes completed meeting transcripts in the window" do
      space = insert_space(%{name: "Board Room", slug: "board", kind: "channel"})

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: ~U[2026-04-22 10:00:00.000000Z],
        completed_at: ~U[2026-04-22 10:45:00.000000Z],
        summary: "Reviewed Q2 priorities and agreed on focus."
      })

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "### Meetings"
      assert result =~ "\"Board Room\""
      assert result =~ "Reviewed Q2 priorities"
      assert result =~ "45 min"
    end

    test "excludes in-progress and failed transcripts" do
      space = insert_space()

      insert_transcript(%{
        space_id: space.id,
        status: "recording",
        started_at: ~U[2026-04-22 10:00:00.000000Z],
        completed_at: ~U[2026-04-22 10:45:00.000000Z],
        summary: "should not appear"
      })

      insert_transcript(%{
        space_id: space.id,
        status: "failed",
        started_at: ~U[2026-04-22 10:00:00.000000Z],
        completed_at: ~U[2026-04-22 10:45:00.000000Z],
        summary: "also hidden"
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "should not appear"
      refute result =~ "also hidden"
    end

    test "includes tasks updated in the window" do
      project = insert_project()
      insert_task(project.id, %{title: "Ship release", status: "in_progress"})

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "### Tasks"
      assert result =~ "\"Ship release\""
      assert result =~ "→ in_progress"
    end

    test "excludes deleted tasks" do
      project = insert_project()
      insert_task(project.id, %{title: "Deleted task", deleted_at: within_window()})

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "Deleted task"
    end

    test "applies task event cap" do
      project = insert_project()

      for i <- 1..55 do
        insert_task(project.id, %{title: "task-#{i}"})
      end

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "more tasks — truncated"
    end

    test "composes chat, meetings, and tasks sections together" do
      project = insert_project()
      space = insert_space(%{name: "Mixed", slug: "mixed"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: "chat line",
        inserted_at: within_window()
      })

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: ~U[2026-04-22 09:00:00.000000Z],
        completed_at: ~U[2026-04-22 09:30:00.000000Z],
        summary: "meeting summary here"
      })

      insert_task(project.id, %{title: "Mixed task"})

      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "### Chat"
      assert result =~ "chat line"
      assert result =~ "### Meetings"
      assert result =~ "meeting summary here"
      assert result =~ "### Tasks"
      assert result =~ "Mixed task"
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp within_window, do: ~U[2026-04-22 06:00:00.000000Z]

  defp insert_space(attrs \\ %{}) do
    defaults = %{
      name: "Test Space",
      slug: "space-#{System.unique_integer([:positive])}",
      kind: "channel"
    }

    %Space{}
    |> Space.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_participant(space_id, attrs \\ %{}) do
    defaults = %{
      space_id: space_id,
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "User",
      joined_at: DateTime.utc_now()
    }

    %Participant{}
    |> Participant.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_message(space_id, participant_id, attrs) do
    participant = Repo.get!(Participant, participant_id)

    defaults = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: "hello",
      author_display_name: participant.display_name || "User"
    }

    params = Map.merge(defaults, Map.drop(attrs, [:inserted_at, :deleted_at]))
    changeset = Message.changeset(%Message{}, params)

    changeset =
      changeset
      |> maybe_put_change(:inserted_at, Map.get(attrs, :inserted_at))
      |> maybe_put_change(:deleted_at, Map.get(attrs, :deleted_at))

    Repo.insert!(changeset)
  end

  defp insert_transcript(attrs) do
    defaults = %{
      room_id: "room-#{System.unique_integer([:positive])}",
      status: "complete"
    }

    %Transcript{}
    |> Transcript.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_project(attrs \\ %{}) do
    # ADR 0042: projects require org_id. Default fixtures attach to the
    # root Fabrikam org unless the test overrides.
    defaults = %{
      name: "Test Project",
      description: "tests",
      org_id: Platform.TenancyFixtures.fabrikam_org_id()
    }

    %Project{}
    |> Project.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_task(project_id, attrs) do
    defaults = %{
      project_id: project_id,
      title: "Task",
      status: "in_progress"
    }

    params = Map.merge(defaults, Map.drop(attrs, [:deleted_at, :updated_at]))
    changeset = Task.changeset(%Task{}, params)

    updated_at = Map.get(attrs, :updated_at, within_window())

    changeset =
      changeset
      |> maybe_put_change(:deleted_at, Map.get(attrs, :deleted_at))
      |> Ecto.Changeset.put_change(:updated_at, updated_at)
      |> Ecto.Changeset.put_change(:inserted_at, updated_at)

    Repo.insert!(changeset)
  end

  defp maybe_put_change(changeset, _key, nil), do: changeset

  defp maybe_put_change(changeset, key, value),
    do: Ecto.Changeset.put_change(changeset, key, value)

  # ── External-user scope partition (M12, rbac-external-users) ─────────────

  defp external_user! do
    n = System.unique_integer([:positive])

    user =
      %Platform.Accounts.User{}
      |> Platform.Accounts.User.changeset(%{
        email: "hx-#{n}@example.com",
        name: "Ext #{n}",
        oidc_sub: "hx-#{n}"
      })
      |> Repo.insert!()

    {:ok, _} =
      Platform.Tenancy.mark_membership_external(%{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.tenant_org_id("sxi")
      })

    user
  end

  describe "build/3 :internal + build_external/3 (M12)" do
    setup do
      ext = external_user!()

      internal = insert_space(%{name: "fabrikam-eng"})
      ip = insert_participant(internal.id, %{display_name: "Fabrikam"})

      insert_message(internal.id, ip.id, %{
        content: "internal chatter",
        inserted_at: within_window()
      })

      insert_transcript(%{
        space_id: internal.id,
        summary: "internal meeting notes",
        started_at: within_window(),
        completed_at: within_window()
      })

      external = insert_space(%{name: "sxi-support"})
      ep = insert_participant(external.id, %{participant_id: ext.id, display_name: "Ext"})

      insert_message(external.id, ep.id, %{
        content: "external chatter",
        inserted_at: within_window()
      })

      insert_transcript(%{
        space_id: external.id,
        summary: "external meeting notes",
        started_at: within_window(),
        completed_at: within_window()
      })

      %{ext: ext}
    end

    test "build/2 (default :internal) keeps internal content, omits the external space" do
      result = ActivityDigest.build(@window_start, @window_end)

      assert result =~ "#fabrikam-eng"
      assert result =~ "internal chatter"
      assert result =~ "internal meeting notes"

      refute result =~ "external chatter"
      refute result =~ "external meeting notes"
      refute result =~ "sxi-support"
    end

    test "build_external/3 is the mirror — external content only, no internal", %{ext: ext} do
      result = ActivityDigest.build_external(ext.id, @window_start, @window_end)

      assert result =~ "external chatter"
      assert result =~ "external meeting notes"

      refute result =~ "internal chatter"
      refute result =~ "internal meeting notes"
      refute result =~ "fabrikam-eng"
    end
  end

  # ── build_windowed_result/1 (task 019fa1cc stage 4) ──────────────────────

  describe "build_windowed_result/1 — the two empty strings" do
    test "a quiet window and an undigestible window never render the same output" do
      # Window A: genuinely empty. No rows of any kind in the span.
      #
      # Window B: packed with rows the digest predicate rejects wholesale
      # (execution-kind space + log_only), arriving flagged `oversize: true`
      # the way the byte signal used to flag it. This is the shape of all 90
      # oversize rows measured in prod.
      b_start = ~U[2026-04-21 20:00:00.000000Z]
      b_end = ~U[2026-04-21 21:00:00.000000Z]
      a_start = ~U[2026-04-21 18:00:00.000000Z]
      a_end = ~U[2026-04-21 19:00:00.000000Z]

      exec = insert_space(%{name: "Exec", slug: "exec-b", kind: "execution"})
      exec_p = insert_participant(exec.id, %{display_name: "Runner"})

      Enum.each(1..7, fn i ->
        insert_message(exec.id, exec_p.id, %{
          content: String.duplicate("x", 4_000),
          inserted_at: DateTime.add(b_start, i * 60, :second)
        })
      end)

      {:ok, body_a, meta_a} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: a_start,
          window_end: a_end,
          oversize: false
        })

      {:ok, body_b, meta_b} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: b_start,
          window_end: b_end,
          oversize: true
        })

      # POSITIVE CONTROL on the fixture: window B really does hold rows. A
      # test that only asserted "B is not the quiet string" would pass just
      # as well against a fixture that seeded nothing at all.
      assert Platform.Agents.HistorianAudit.raw_row_count("messages", b_start, b_end) == 7

      # Both windows render zero items — that is precisely why the two were
      # conflated before this stage.
      assert meta_a.item_count == 0
      assert meta_b.item_count == 0

      # THE POINT OF THE STAGE.
      assert body_a =~ "_No activity in this window._"
      refute body_b =~ "_No activity in this window._"
      assert body_a != body_b

      # And the could-not-digest line names the condition and the raw rows
      # the byte signal was charging for.
      assert body_b =~ "exceeded the digest budget"
      assert body_b =~ "7 raw rows out of scope"

      # The flag a consumer branches on, not just a string difference.
      refute meta_a.oversize_empty?
      assert meta_b.oversize_empty?
    end
  end

  describe "build_windowed_result/1 — item-wise truncation" do
    setup do
      space = insert_space(%{name: "Budgeted", slug: "budgeted", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      # Five 200-byte messages at distinct one-minute marks. Distinct sizes
      # are not needed here (the budget is the thing under test) but distinct
      # TIMESTAMPS are: with every row sharing an instant the watermark would
      # equal the window end and the whole invariant would be untestable.
      rows =
        Enum.map(1..5, fn i ->
          content = String.pad_leading("#{i}", 3, "0") <> String.duplicate("x", 197)
          at = DateTime.add(@window_start, i * 60, :second)
          {insert_message(space.id, participant.id, %{content: content, inserted_at: at}), at}
        end)

      {:ok, rows: rows}
    end

    test "admits a chronological prefix and reports the watermark", %{rows: rows} do
      # 200 bytes per row, budget 200 tokens → 800-byte cap → exactly 4 rows.
      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true,
          budget_tokens: 200
        })

      assert meta.item_count == 5
      assert meta.included_count == 4
      assert meta.truncated?
      refute meta.oversize_empty?
      assert meta.skipped == nil

      {_row_4, at_4} = Enum.at(rows, 3)
      assert meta.last_included_at == at_4

      # POSITIVE CONTROL FIRST: the admitted rows are actually rendered.
      assert body =~ "001"
      assert body =~ "004"
      # Paired absence — meaningful only because the control above passed.
      refute body =~ "005"

      assert body =~ "_(partial — 4 of 5 items included"
      refute body =~ "_No activity in this window._"
    end

    test "a whole window under budget advances nothing short and carries no marker" do
      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      assert meta.item_count == 5
      assert meta.included_count == 5
      refute meta.truncated?
      assert body =~ "001"
      assert body =~ "005"
      refute body =~ "partial"
    end

    test "a single row larger than the whole budget is named, not silently cut" do
      # 12-byte cap: even one 200-byte row cannot be admitted. Under the old
      # `binary_part(body, 0, cap)` this window emitted a body cut at an
      # arbitrary byte offset and the cursor still advanced to window_end.
      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true,
          budget_tokens: 3
        })

      assert meta.item_count == 5
      assert meta.included_count == 0
      assert meta.truncated?
      assert meta.last_included_at == nil
      assert %{bytes: 200, count: 1} = meta.skipped
      assert is_binary(meta.skipped.id)

      assert body =~ "_(skipped —"
      refute body =~ "_No activity in this window._"
      # The body is valid UTF-8 and contains no fragment of a cut row.
      assert String.valid?(body)
      refute body =~ "001"
    end

    test "build_windowed/1 is the string projection of build_windowed_result/1" do
      input = %{
        corpus: :messages,
        window_start: @window_start,
        window_end: @window_end,
        oversize: true,
        budget_tokens: 200
      }

      {:ok, body, _meta} = ActivityDigest.build_windowed_result(input)
      assert ActivityDigest.build_windowed(input) == body
      assert body =~ "## Chat since 2026-04-21 12:00:00"
    end
  end

  describe "build_windowed_result/1 — watermark and render coverage" do
    test "no withheld row ever shares the watermark instant" do
      # Rows tied on `inserted_at`. The cursor advances to
      # `last_included_at + 1µs`, so admitting HALF of a tied group would
      # step straight over the other half — silently, and forever.
      #
      # This fixture exists because the distinct-timestamp fixtures above
      # cannot see that mutation: with every row on its own instant,
      # per-row and per-group admission produce identical results.
      space = insert_space(%{name: "Tied", slug: "tied", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      early = DateTime.add(@window_start, 60, :second)
      tied = DateTime.add(@window_start, 120, :second)

      insert_message(space.id, participant.id, %{
        content: "aaa" <> String.duplicate("x", 197),
        inserted_at: early
      })

      Enum.each(["bbb", "ccc"], fn tag ->
        insert_message(space.id, participant.id, %{
          content: tag <> String.duplicate("x", 197),
          inserted_at: tied
        })
      end)

      # 500-byte cap: the lone 200-byte row fits, the 400-byte tied pair
      # does not. Per-row admission would take `aaa` + `bbb` (400 ≤ 500)
      # and leave `ccc` behind the same watermark.
      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true,
          budget_tokens: 125
        })

      assert meta.item_count == 3
      assert meta.included_count == 1
      assert meta.last_included_at == early
      assert meta.truncated?

      # POSITIVE CONTROL, then the paired absences.
      assert body =~ "aaa"
      refute body =~ "bbb"
      refute body =~ "ccc"

      # The property the cursor arithmetic depends on, stated directly.
      withheld_ats =
        ActivityDigest.corpus_items(:messages, @window_start, @window_end)
        |> Enum.drop(meta.included_count)
        |> Enum.map(& &1.at)

      refute Enum.empty?(withheld_ats)

      assert Enum.all?(withheld_ats, &(DateTime.compare(&1, meta.last_included_at) == :gt))
    end

    test "the windowed path renders every admitted row, past the per-space count cap" do
      # `build/2` caps each space at 40 messages and appends a
      # "_(N more messages — truncated)_" note. In the windowed path that
      # would be a SECOND, unaudited drop channel: rows counted as included
      # (so the cursor advanced past them) but never rendered. The budget is
      # the only truncation the windowed path is allowed to apply.
      space = insert_space(%{name: "Chatty", slug: "chatty", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      Enum.each(1..45, fn i ->
        insert_message(space.id, participant.id, %{
          content: "tag#{String.pad_leading("#{i}", 3, "0")}",
          inserted_at: DateTime.add(@window_start, i * 30, :second)
        })
      end)

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      assert meta.item_count == 45
      assert meta.included_count == 45
      refute meta.truncated?

      missing = Enum.reject(1..45, &(body =~ "tag#{String.pad_leading("#{&1}", 3, "0")}"))
      assert missing == []
      refute body =~ "more messages — truncated"

      # ...and `build/2` keeps its cap, unchanged. The 41st..45th rows are
      # summarised away there, which is fine: `build/2` has no cursor.
      assert ActivityDigest.build(@window_start, @window_end) =~ "more messages — truncated"
    end
  end

  describe "corpus_items/4" do
    test "weighs each row with the byte figure the Historian byte signal sums" do
      space = insert_space(%{name: "Weighed", slug: "weighed", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      # Deliberately DIFFERENT sizes: with equal sizes a mutation that
      # substituted one row's weight for another's would be invisible.
      sizes = [137, 900, 42]

      Enum.with_index(sizes, 1)
      |> Enum.each(fn {n, i} ->
        insert_message(space.id, participant.id, %{
          content: String.duplicate("w", n),
          inserted_at: DateTime.add(@window_start, i * 60, :second)
        })
      end)

      # Excluded by the digest predicate — must contribute no item and no
      # bytes. Positive control is the three rows above.
      insert_message(space.id, participant.id, %{
        content: String.duplicate("q", 5_000),
        log_only: true,
        inserted_at: DateTime.add(@window_start, 240, :second)
      })

      items = ActivityDigest.corpus_items(:messages, @window_start, @window_end)

      refute Enum.empty?(items)
      assert length(items) == 3
      assert Enum.map(items, & &1.bytes) == sizes
      assert Enum.map(items, & &1.at) == Enum.sort(Enum.map(items, & &1.at))

      # String corpus keys resolve to the same result — the audit tool and
      # the cursor rows carry strings, the slicer carries atoms.
      assert ActivityDigest.corpus_items("messages", @window_start, @window_end) == items
      assert ActivityDigest.corpus_items("nonsense", @window_start, @window_end) == []
    end

    test "a transcript weighs its summary AND its segments, and is clocked on completed_at" do
      # `segments: []` encodes to two bytes, so every fixture in this repo
      # that uses it gives the segments term a degenerate value: dropping
      # segments from the weight entirely is invisible against it. These
      # segments are deliberately fat, and the two rows are deliberately
      # different sizes so a substitution reads as a change.
      space = insert_space(%{name: "Board", slug: "board-w", kind: "channel"})

      big_segments = [%{"speaker" => "ada", "text" => String.duplicate("s", 500)}]
      small_segments = [%{"speaker" => "bob", "text" => "ok"}]

      early =
        insert_transcript(%{
          space_id: space.id,
          status: "complete",
          started_at: DateTime.add(@window_start, 60, :second),
          completed_at: DateTime.add(@window_start, 3_600, :second),
          summary: String.duplicate("a", 900),
          segments: big_segments
        })

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: DateTime.add(@window_start, 7_200, :second),
        completed_at: DateTime.add(@window_start, 10_800, :second),
        summary: String.duplicate("b", 300),
        segments: small_segments
      })

      # `completed_at <= updated_at` always — segments accumulate after a
      # recording completes. Push `updated_at` OUT of the window so a clock
      # swap changes which rows come back at all.
      {2, _} =
        Repo.update_all(Transcript, set: [updated_at: DateTime.add(@window_end, 86_400, :second)])

      items = ActivityDigest.corpus_items(:transcripts, @window_start, @window_end)

      refute Enum.empty?(items)
      assert length(items) == 2

      [first, second] = items

      # Clocked on completed_at, not updated_at.
      assert first.at == DateTime.add(@window_start, 3_600, :second)

      # POSITIVE CONTROL on the fixture: the segments payload is not a
      # rounding error next to the summary.
      big_json = byte_size(Jason.encode!(big_segments))
      assert big_json > 500

      assert first.bytes == 900 + big_json
      assert first.bytes > byte_size(early.summary)
      assert second.bytes == 300 + byte_size(Jason.encode!(small_segments))
      assert first.bytes != second.bytes
    end
  end

  describe "build_external/3 edges (M12)" do
    test "external user with no participations yields the empty fallback" do
      ext = external_user!()
      result = ActivityDigest.build_external(ext.id, @window_start, @window_end)
      assert result =~ "_No activity in this window._"
    end

    test "build/2 is unchanged with no external users (regression)" do
      internal = insert_space(%{name: "fabrikam-eng"})
      ip = insert_participant(internal.id, %{display_name: "Fabrikam"})

      insert_message(internal.id, ip.id, %{
        content: "internal chatter",
        inserted_at: within_window()
      })

      assert Platform.Chat.external_space_ids() == []

      result = ActivityDigest.build(@window_start, @window_end)
      assert result =~ "internal chatter"
    end
  end
end
