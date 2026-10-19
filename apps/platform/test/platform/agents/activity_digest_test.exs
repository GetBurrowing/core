defmodule Platform.Agents.ActivityDigestTest do
  use Platform.DataCase

  alias Platform.Agents.ActivityDigest
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Meetings.Transcript
  alias Platform.Tasks.{Project, Task}

  @window_end ~U[2026-04-22 12:00:00.000000Z]
  @window_start ~U[2026-04-21 12:00:00.000000Z]
  @withheld_marker "[WITHHELD: credential-shaped span]"

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

    # Task 01a0a12e: meeting transcripts are excluded from the digest by
    # default, at `Meetings.digest_eligible_transcripts_query/1`. A complete,
    # in-window, small transcript — eligible on every other filter — does
    # not render.
    test "excludes completed meeting transcripts in the window by default" do
      space = insert_space(%{name: "Board Room", slug: "board", kind: "channel"})

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: ~U[2026-04-22 10:00:00.000000Z],
        completed_at: ~U[2026-04-22 10:45:00.000000Z],
        summary: "Reviewed Q2 priorities and agreed on focus."
      })

      result = ActivityDigest.build(@window_start, @window_end)

      refute result =~ "### Meetings"
      refute result =~ "\"Board Room\""
      refute result =~ "Reviewed Q2 priorities"
      assert result =~ "_No activity in this window._"
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
      # Task 01a0a12e: the meetings section is empty by default.
      refute result =~ "### Meetings"
      refute result =~ "meeting summary here"
      assert result =~ "### Tasks"
      assert result =~ "Mixed task"
    end
  end

  # ── Skip notice wording (task 01a0a12e, ticket clause 10) ────────────────
  #
  # The notice says WHY the item was skipped and that the skip is audited,
  # and stops there. It must not tell the handler to go and get the skipped
  # content by another route: the size cap is what stopped the 2026-09-14
  # one-to-one, and a notice that points around it defeats it.
  describe "build_windowed_result/1 — skip notice wording" do
    test "names the skip and its audit row, and never points at the skipped content" do
      space = insert_space(%{name: "Sprint", slug: "sprint-skip", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      content = String.duplicate("lorem ", 1700)
      bytes = byte_size(content)
      assert bytes > 10_000

      insert_message(space.id, participant.id, %{content: content, inserted_at: within_window()})

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true,
          budget_tokens: 500
        })

      # Behaviour unchanged: the row is skipped, nothing is included.
      assert %{count: 1} = meta.skipped
      assert meta.included_count == 0

      # The notice still says what happened, with every figure.
      assert body =~ "_(skipped —"
      assert body =~ "#{bytes} bytes"
      assert body =~ "2000-byte window budget"
      assert body =~ "0 of 1 items included"
      assert body =~ "item_skipped"

      # ...and no route to the skipped content.
      refute body =~ ~r/read/i
      refute body =~ ~r/directly/i
      refute body =~ ~r/memory_view/
      refute body =~ ~r/fetch/i
      refute body =~ "lorem"
    end
  end

  describe "build_windowed_result/1 — preview-weighted admission (01a0ee1d)" do
    # Anti-vacuity A. One org page bigger than the whole 120_000-byte default
    # window budget. The digest renders it as a single 280-char preview line,
    # so admission must charge that line, not the page's raw content. Before
    # 01a0ee1d this window rendered `_(skipped —` with 0 of 1 items included.
    test "a single page larger than the window budget is admitted as its preview line" do
      content = "OVERSIZE-TAG " <> String.duplicate("a", 130_000 - 13)
      assert byte_size(content) == 130_000

      page = insert_org_page!("oversize/page", content)

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :pages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true
        })

      assert meta.item_count == 1
      assert meta.included_count == 1
      assert meta.skipped == nil
      assert meta.truncated? == false
      assert meta.last_included_at == within_window()

      assert body =~ page.file_key
      assert body =~ "OVERSIZE-TAG"
      refute body =~ "_(skipped —"
    end

    # Anti-vacuity B, the discrimination control. With an 800-byte budget and
    # five pages whose preview lines each weigh more than 200 bytes, admission
    # must still stop part-way. A test asserting only "included" would pass if
    # admission were simply disabled; this one would not.
    test "a tight budget still truncates page previews at a whole-line boundary" do
      pages =
        Enum.map(1..5, fn i ->
          content = "P#{i}-TAG " <> String.duplicate("word ", 400)
          at = DateTime.add(@window_start, i * 60, :second)
          {insert_org_page!("tight/page-#{i}", content, at), at}
        end)

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :pages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true,
          budget_tokens: 200
        })

      lines =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "- "))

      # Each rendered line weighs more than 200 bytes, so the fixture cannot
      # fit wholesale under 800.
      assert Enum.all?(lines, &(byte_size(&1) > 200))

      assert meta.item_count == 5
      assert meta.truncated? == true
      assert meta.included_count >= 1
      assert meta.included_count < 5
      assert meta.skipped == nil
      assert length(lines) == meta.included_count

      {_last_page, last_at} = Enum.at(pages, meta.included_count - 1)
      assert meta.last_included_at == last_at

      # The section opens with the partial marker, directly under the header.
      [_header, section] = String.split(body, "\n\n", parts: 2)
      assert String.starts_with?(section, "_(partial —")

      # Bound: the budget still bounds the rendered body.
      assert byte_size(Enum.join(lines, "\n")) <= 800

      # Admitted pages are rendered; the first withheld one is not.
      {first_page, _} = hd(pages)
      assert body =~ first_page.file_key
      {withheld_page, _} = Enum.at(pages, meta.included_count)
      refute body =~ withheld_page.file_key
    end

    test "an oversized page's preview row names the page and its raw size" do
      content = "OVERSIZE-TAG " <> String.duplicate("a", 130_000 - 13)
      raw_bytes = byte_size(content)
      page = insert_org_page!("oversize/named", content)

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :pages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true
        })

      assert meta.included_count == 1
      assert body =~ page.file_key
      assert body =~ "preview only"
      assert body =~ "page `#{page.file_key}` is #{raw_bytes} bytes"
      assert body =~ "120000-byte window budget"
      refute body =~ "_(skipped —"
      refute body =~ "_No activity in this window._"
    end

    test "an under-budget page's row carries no preview-only note" do
      page = insert_org_page!("small/page", "SMALL-TAG a short page body")

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :pages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false
        })

      # Positive control first: the row IS rendered.
      assert meta.included_count == 1
      assert body =~ page.file_key
      assert body =~ "SMALL-TAG"
      refute body =~ "preview only"
    end

    test "a page whose preview line alone exceeds the budget is skipped by name" do
      content = "TINY-BUDGET-TAG " <> String.duplicate("b", 2_000)
      raw_bytes = byte_size(content)
      page = insert_org_page!("tiny/budget", content)

      # 20 tokens = 80 bytes, smaller than any preview line.
      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :pages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true,
          budget_tokens: 20
        })

      assert meta.item_count == 1
      assert meta.included_count == 0
      assert meta.skipped.path == page.file_key
      assert meta.skipped.bytes == raw_bytes

      assert body =~ "_(skipped — page `#{page.file_key}` weighs #{raw_bytes} bytes"
      assert body =~ "80-byte window budget"
      assert body =~ "item_skipped"
      refute body =~ "TINY-BUDGET-TAG"
    end

    # Admission weighs the line as RENDERED, i.e. after credential
    # withholding swaps the content for the marker. Weighed before it, each
    # of these rows would be charged a full 280-char preview (~340 B) and
    # only two would fit in 800 bytes; rendered, each is a short marker line
    # and all five fit.
    test "a credential-withheld page is weighed by its withheld line" do
      pages =
        Enum.map(1..5, fn i ->
          content =
            "export KEY=" <> synthetic_credential() <> " " <> String.duplicate("word ", 140)

          at = DateTime.add(@window_start, i * 60, :second)
          insert_org_page!("cred/page-#{i}", content, at)
        end)

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :pages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: true,
          budget_tokens: 200
        })

      lines =
        body
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "- "))

      assert meta.credential_withheld_count == 5
      assert meta.included_count == 5
      refute meta.truncated?
      assert Enum.all?(pages, &(body =~ &1.file_key))
      assert Enum.all?(lines, &(&1 =~ @withheld_marker))
      assert byte_size(Enum.join(lines, "\n")) <= 800
      # Every row is under the budget raw, so no preview-only note inflates it.
      refute body =~ "preview only"
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
    # root Acme org unless the test overrides.
    defaults = %{
      name: "Test Project",
      description: "tests",
      org_id: Platform.TenancyFixtures.acme_org_id()
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
        org_id: Platform.TenancyFixtures.tenant_org_id("globex")
      })

    user
  end

  describe "build/3 :internal + build_external/3 (M12)" do
    setup do
      ext = external_user!()

      internal = insert_space(%{name: "acme-eng"})
      ip = insert_participant(internal.id, %{display_name: "Acme"})

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

      external = insert_space(%{name: "globex-support"})
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

      assert result =~ "#acme-eng"
      assert result =~ "internal chatter"
      # Task 01a0a12e: transcripts are excluded by default in either scope.
      refute result =~ "internal meeting notes"

      refute result =~ "external chatter"
      refute result =~ "external meeting notes"
      refute result =~ "globex-support"
    end

    test "build_external/3 is the mirror — external content only, no internal", %{ext: ext} do
      result = ActivityDigest.build_external(ext.id, @window_start, @window_end)

      assert result =~ "external chatter"
      # Task 01a0a12e: transcripts are excluded by default in either scope.
      refute result =~ "external meeting notes"

      refute result =~ "internal chatter"
      refute result =~ "internal meeting notes"
      refute result =~ "acme-eng"
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

    # Task 01a0a12e: `corpus_items(:transcripts, ...)` composes
    # `Meetings.list_transcripts_since/2` without `:meeting_transcripts`, so
    # it returns nothing by default — however fat the rows. The
    # summary+segments weight (`transcript_bytes/1`) is unreachable from
    # here while the corpus is excluded; the fixture stays so the rows are
    # eligible on every OTHER filter (complete, in-window on completed_at).
    test "transcripts are excluded by default: corpus_items(:transcripts) is empty" do
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

      assert ActivityDigest.corpus_items(:transcripts, @window_start, @window_end) == []
      assert ActivityDigest.corpus_items("transcripts", @window_start, @window_end) == []

      # POSITIVE CONTROL: both rows are eligible apart from the exclusion,
      # clocked on completed_at (updated_at is out of the window).
      included =
        Platform.Meetings.list_transcripts_since(@window_start,
          window_end: @window_end,
          meeting_transcripts: :included
        )

      assert length(included) == 2
      assert hd(included).id == early.id
      assert byte_size(Jason.encode!(big_segments)) > 500
      assert small_segments != []
    end
  end

  describe "build_external/3 edges (M12)" do
    test "external user with no participations yields the empty fallback" do
      ext = external_user!()
      result = ActivityDigest.build_external(ext.id, @window_start, @window_end)
      assert result =~ "_No activity in this window._"
    end

    test "build/2 is unchanged with no external users (regression)" do
      internal = insert_space(%{name: "acme-eng"})
      ip = insert_participant(internal.id, %{display_name: "Acme"})

      insert_message(internal.id, ip.id, %{
        content: "internal chatter",
        inserted_at: within_window()
      })

      assert Platform.Chat.external_space_ids() == []

      result = ActivityDigest.build(@window_start, @window_end)
      assert result =~ "internal chatter"
    end
  end

  # ── Credential withholding (task 01a09c9b stage 2) ───────────────────────
  #
  # EVERY test here seeds BOTH halves into the SAME window and asserts both
  # in the same block: the synthetic credential must be gone, the benign
  # sentinel must still be there. The positive control is load-bearing, not
  # decoration — `refute body =~ secret` alone is an absence-shaped
  # assertion that any upstream failure satisfies. A digest that is empty,
  # broken, or never assembled passes the refute and fails the assert.
  #
  # Fixtures are SYNTHETIC and generated at test time. Nothing here is, or
  # has ever been, a real credential.
  describe "credential withholding — build/3 (call site 1)" do
    test "a credential-shaped message body is replaced by the marker; benign traffic survives" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "Eng", slug: "eng-w1", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      # Fixture guard: if these two flip, every assertion below is vacuous.
      assert Platform.Agents.CredentialShape.credential_shaped?(secret)
      refute Platform.Agents.CredentialShape.credential_shaped?(benign)

      insert_message(space.id, participant.id, %{
        content: "here is the key: " <> secret,
        inserted_at: within_window()
      })

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: within_window()
      })

      body = ActivityDigest.build(@window_start, @window_end)

      refute body =~ secret
      assert body =~ benign

      # The marker occupies the message's POSITION — author, space and
      # timestamp survive. Never a blank, never a silent drop.
      assert body =~ "[WITHHELD: credential-shaped span]"
      assert body =~ "@Ada"
      assert body =~ "#Eng"
      refute body =~ "_No activity in this window._"
    end

    # Task 01a0a12e: transcripts no longer reach build/3 at all, so neither
    # the credential-shaped nor the benign summary renders and nothing is
    # withheld on this corpus. The message-corpus withholding tests above
    # still pin the redactor at this call site.
    test "transcript summaries (credential-shaped or benign) are excluded by default" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "Board", slug: "board-w1", kind: "channel"})

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: DateTime.add(@window_start, 60, :second),
        completed_at: DateTime.add(@window_start, 600, :second),
        summary: "rotation discussed, value " <> secret,
        segments: []
      })

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: DateTime.add(@window_start, 1_200, :second),
        completed_at: DateTime.add(@window_start, 1_800, :second),
        summary: benign,
        segments: []
      })

      body = ActivityDigest.build(@window_start, @window_end)

      refute body =~ secret
      refute body =~ benign
      refute body =~ "[WITHHELD: credential-shaped span]"
      refute body =~ "### Meetings"
    end
  end

  describe "credential withholding — build_external/3 (call site 2)" do
    # This is the call site that gets skipped. An external-user digest
    # reaches a WIDER audience than the internal one, so a leak here is
    # strictly worse. Deleting the `build_external/3` call MUST turn this
    # red — which is why it drives `build_external/3` directly rather than
    # asserting through `build/3`.
    test "the external digest withholds credential-shaped content and keeps benign content" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      ext = external_user!()
      space = insert_space(%{name: "globex-support", slug: "globex-w1", kind: "channel"})
      ep = insert_participant(space.id, %{participant_id: ext.id, display_name: "Ext"})

      insert_message(space.id, ep.id, %{
        content: "creds for the sandbox: " <> secret,
        inserted_at: within_window()
      })

      insert_message(space.id, ep.id, %{
        content: benign,
        inserted_at: within_window()
      })

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: DateTime.add(@window_start, 60, :second),
        completed_at: DateTime.add(@window_start, 600, :second),
        summary: "handover, token " <> secret,
        segments: []
      })

      body = ActivityDigest.build_external(ext.id, @window_start, @window_end)

      refute body =~ secret
      assert body =~ benign
      assert body =~ "[WITHHELD: credential-shaped span]"
      assert body =~ "@Ext"
      refute body =~ "_No activity in this window._"
    end
  end

  describe "credential withholding — windowed_body (call site 3)" do
    test "applies to :messages after the budget, so the count reflects what is RENDERED" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "Win", slug: "win-w1", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: "key " <> secret,
        inserted_at: DateTime.add(@window_start, 60, :second)
      })

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 120, :second)
      })

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      refute body =~ secret
      assert body =~ benign
      assert body =~ "[WITHHELD: credential-shaped span]"

      # A FOURTH state. The row was eligible, within budget and rendered —
      # only its body was removed. So it still counts as included and it
      # does NOT set truncated?, because the cursor has passed it and must
      # not re-dispatch it.
      assert meta.credential_withheld_count == 1
      assert meta.included_count == 2
      assert meta.item_count == 2
      refute meta.truncated?
    end

    test "the count is of RENDERED rows — a budget-withheld credential row is not counted" do
      # The ordering assertion: withholding runs AFTER take_within_budget/2.
      # If it ran on `items` instead of `included`, this count would be 2.
      secret = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "Ord", slug: "ord-w1", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      # Row 1 fits the cap. Rows 2 is pushed out by it.
      insert_message(space.id, participant.id, %{
        content: "k1 " <> secret <> String.duplicate("x", 120),
        inserted_at: DateTime.add(@window_start, 60, :second)
      })

      insert_message(space.id, participant.id, %{
        content: "k2 " <> secret <> String.duplicate("y", 120),
        inserted_at: DateTime.add(@window_start, 120, :second)
      })

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 180, :second)
      })

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 45
        })

      refute body =~ secret
      assert meta.included_count == 1
      assert meta.credential_withheld_count == 1
      assert meta.truncated?

      # `withheld` (budget) and `credential_withheld_count` are DIFFERENT
      # quantities and the module must not collapse them: the partial line
      # renders ALONGSIDE the marker, never instead of it.
      assert body =~ "partial —"
      assert body =~ "[WITHHELD: credential-shaped span]"

      # Positive control: the benign row is genuinely in this window and is
      # excluded by the BUDGET, not by the redactor.
      assert meta.item_count == 3
      refute body =~ benign
    end

    # Task 01a0a12e: the :transcripts window is empty by default, so there
    # is nothing to withhold. Both rows are eligible on every other filter.
    test ":transcripts window is empty by default (nothing rendered, nothing withheld)" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "Mtg", slug: "mtg-w1", kind: "channel"})

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: DateTime.add(@window_start, 60, :second),
        completed_at: DateTime.add(@window_start, 600, :second),
        summary: "rotate " <> secret,
        segments: []
      })

      insert_transcript(%{
        space_id: space.id,
        status: "complete",
        started_at: DateTime.add(@window_start, 1_200, :second),
        completed_at: DateTime.add(@window_start, 1_800, :second),
        summary: benign,
        segments: []
      })

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :transcripts,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      refute body =~ secret
      refute body =~ benign
      assert body =~ "_No activity in this window._"
      assert meta.credential_withheld_count == 0
      assert meta.item_count == 0
    end

    test "applies to :pages" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      insert_org_page!("runbook/deploy", "export KEY=" <> secret)
      insert_org_page!("runbook/notes", benign)

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :pages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      refute body =~ secret
      assert body =~ benign
      assert meta.credential_withheld_count == 1
    end

    test "applies to :journal" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      insert_org_journal!("pasted " <> secret)
      insert_org_journal!(benign)

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :journal,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      refute body =~ secret
      assert body =~ benign
      assert meta.credential_withheld_count == 1
    end
  end

  describe "credential withholding — the digest stays useful" do
    test "ordinary traffic carrying task ids, commit shas and memory paths is NOT redacted" do
      # A redactor that eats ordinary traffic gets switched off, and a
      # switched-off redactor is worse than none because the ticket reads
      # as closed. These four shapes cross our channels hourly.
      ordinary = [
        "task 01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def moved to in_review",
        "deployed 2910fad5c681e3f6ece7c6e1b375a424f9ee31ee to staging",
        "promoted org/page/evidence-and-measurement-discipline.md",
        "see https://suite.example.org/tasks for the board"
      ]

      space = insert_space(%{name: "Ops", slug: "ops-w1", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      ordinary
      |> Enum.with_index(1)
      |> Enum.each(fn {content, i} ->
        insert_message(space.id, participant.id, %{
          content: content,
          inserted_at: DateTime.add(@window_start, i * 60, :second)
        })
      end)

      body = ActivityDigest.build(@window_start, @window_end)

      refute body =~ "[WITHHELD: credential-shaped span]"
      assert Enum.reject(ordinary, &(body =~ &1)) == []
    end
  end

  # ── The incompleteness notice (stage 3) ──────────────────────────────────
  #
  # Without it a careful Historian does the wrong thing CORRECTLY: sees a
  # marker, respects it, curates around it, and publishes an org-wide page
  # that silently omits what the withheld span was about. Every test here
  # pins one of the three properties an implementer drops — ONCE, at the
  # TOP, carrying the COUNT.
  describe "credential withholding — the incompleteness notice" do
    @notice_head "> **This window is INCOMPLETE:"

    test "appears exactly once, above the first marker, carrying the count" do
      secret_a = synthetic_credential()
      secret_b = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "Not", slug: "not-w1", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      [{"k1 " <> secret_a, 60}, {"k2 " <> secret_b, 120}, {benign, 180}]
      |> Enum.each(fn {content, offset} ->
        insert_message(space.id, participant.id, %{
          content: content,
          inserted_at: DateTime.add(@window_start, offset, :second)
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

      assert meta.credential_withheld_count == 2

      # ONCE — not once per marker. Two markers, one notice.
      assert length(String.split(body, @notice_head)) - 1 == 1
      assert length(String.split(body, @withheld_marker)) - 1 == 2

      # THE COUNT, rendered — and it is the credential count, not the row
      # count and not the budget-withheld count.
      assert body =~
               "> **This window is INCOMPLETE: 2 message(s) withheld — " <>
                 "credential-shaped content removed before delivery.**"

      assert body =~
               "> **Do not publish a summary that implies full coverage of this window.**"

      # AT THE TOP — under the header, before the first marker AND before
      # any message line. A footer arrives after the reader has already
      # formed the summary.
      [notice_at, marker_at, benign_at] =
        Enum.map([@notice_head, @withheld_marker, benign], fn needle ->
          {at, _len} = :binary.match(body, needle)
          at
        end)

      assert notice_at < marker_at
      assert notice_at < benign_at
      assert String.starts_with?(body, "## ")

      assert body
             |> String.split("\n\n", parts: 2)
             |> List.last()
             |> String.starts_with?(@notice_head)

      # Positive control, same run: benign traffic still delivered.
      assert body =~ benign
      refute body =~ secret_a
      refute body =~ secret_b
    end

    test "the rendered count is the count of RENDERED withholdings, not of queried rows" do
      # Pins the notice's count to the same pipeline position stage 2 pinned
      # `credential_withheld_count` to. If the notice were assembled from a
      # count taken BEFORE take_within_budget/2 this would read 2, not 1 —
      # so this fails on a count computed at the wrong point, not merely on
      # a count that is absent.
      secret = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "NotOrd", slug: "not-ord-w1", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: "k1 " <> secret <> String.duplicate("x", 120),
        inserted_at: DateTime.add(@window_start, 60, :second)
      })

      insert_message(space.id, participant.id, %{
        content: "k2 " <> secret <> String.duplicate("y", 120),
        inserted_at: DateTime.add(@window_start, 120, :second)
      })

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 180, :second)
      })

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 45
        })

      assert meta.item_count == 3
      assert meta.credential_withheld_count == 1
      assert body =~ "> **This window is INCOMPLETE: 1 message(s) withheld"
      refute body =~ "INCOMPLETE: 2 message(s)"
      refute body =~ "INCOMPLETE: 3 message(s)"

      # A FOURTH state rendered ALONGSIDE the third, never instead of it.
      assert body =~ "partial —"
    end

    test "build/3 carries the notice at the top with its count" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "NotB", slug: "not-b1", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: "key " <> secret,
        inserted_at: DateTime.add(@window_start, 60, :second)
      })

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 120, :second)
      })

      body = ActivityDigest.build(@window_start, @window_end)

      refute body =~ secret
      assert body =~ benign
      assert body =~ "> **This window is INCOMPLETE: 1 message(s) withheld"
      assert length(String.split(body, @notice_head)) - 1 == 1

      assert body
             |> String.split("\n\n", parts: 2)
             |> List.last()
             |> String.starts_with?(@notice_head)
    end

    test "build_external/3 carries the notice at the top with its count" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      ext = external_user!()
      space = insert_space(%{name: "NotE", slug: "not-e1", kind: "channel"})
      ep = insert_participant(space.id, %{participant_id: ext.id, display_name: "Ext"})

      insert_message(space.id, ep.id, %{
        content: "key " <> secret,
        inserted_at: DateTime.add(@window_start, 60, :second)
      })

      insert_message(space.id, ep.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 120, :second)
      })

      body = ActivityDigest.build_external(ext.id, @window_start, @window_end)

      refute body =~ secret
      assert body =~ benign
      assert body =~ "> **This window is INCOMPLETE: 1 message(s) withheld"
      assert length(String.split(body, @notice_head)) - 1 == 1
    end

    test "a clean window renders NO notice and NO marker" do
      # The regression that protects the digest's usefulness: a notice on a
      # window that lost nothing trains the reader to read past it, at which
      # point the notice is decoration.
      benign = benign_sentinel()

      space = insert_space(%{name: "NotC", slug: "not-c1", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 60, :second)
      })

      insert_message(space.id, participant.id, %{
        content: "task 01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def at 2910fad5",
        inserted_at: DateTime.add(@window_start, 120, :second)
      })

      {:ok, windowed, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      assert meta.credential_withheld_count == 0
      refute windowed =~ "INCOMPLETE"
      refute windowed =~ @withheld_marker
      assert windowed =~ benign

      built = ActivityDigest.build(@window_start, @window_end)
      refute built =~ "INCOMPLETE"
      refute built =~ @withheld_marker
      assert built =~ benign
    end
  end

  # ── Stage 4: the acceptance clause, both halves in one assertion block ───
  #
  # Every test here asserts BOTH halves together:
  #
  #     credential-shaped string  MUST NOT appear verbatim
  #     benign sentinel           MUST still appear in the SAME window
  #
  # The second clause is load-bearing. A bare `refute body =~ secret` is an
  # absence-shaped assertion: it passes when the digest is empty, broken, or
  # never assembled at all, so it certifies any upstream failure as a pass.
  # Splitting the two halves across two tests loses the property, because
  # neither test then observes the window the other one did.
  describe "credential withholding — acceptance clause (stage 4)" do
    test "windowed pass withholds the credential and keeps the benign sentinel" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      # Fixture guard: if the detector's verdict on either fixture flips,
      # both halves below go vacuous in opposite directions.
      assert Platform.Agents.CredentialShape.credential_shaped?(secret)
      refute Platform.Agents.CredentialShape.credential_shaped?(benign)

      space = insert_space(%{name: "Acc", slug: "acc-s4-win", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: "rotate this: " <> secret,
        inserted_at: DateTime.add(@window_start, 60, :second)
      })

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 120, :second)
      })

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      refute body =~ secret
      assert body =~ benign

      assert body =~ @withheld_marker
      assert meta.credential_withheld_count == 1
    end

    test "24h build/3 withholds the credential and keeps the benign sentinel" do
      secret = synthetic_credential()
      benign = benign_sentinel()

      assert DateTime.diff(@window_end, @window_start) == 86_400

      space = insert_space(%{name: "Acc24", slug: "acc-s4-24h", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: "sandbox creds " <> secret,
        inserted_at: within_window()
      })

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: within_window()
      })

      body = ActivityDigest.build(@window_start, @window_end, scope: :internal)

      refute body =~ secret
      assert body =~ benign

      assert body =~ @withheld_marker
      assert body =~ "@Ada"
    end

    test "build_external/3 withholds the credential and keeps the benign sentinel" do
      # Driven DIRECTLY, never through `build/3`. The two entry points hold
      # separate call sites, so a test that reaches this path via `build/3`
      # stays green when the `build_external/3` call site alone is deleted —
      # and that is the site an implementer skips, on the wider audience.
      secret = synthetic_credential()
      benign = benign_sentinel()

      ext = external_user!()
      space = insert_space(%{name: "AccX", slug: "acc-s4-ext", kind: "channel"})
      ep = insert_participant(space.id, %{participant_id: ext.id, display_name: "Ext"})

      insert_message(space.id, ep.id, %{
        content: "handover token " <> secret,
        inserted_at: within_window()
      })

      insert_message(space.id, ep.id, %{
        content: benign,
        inserted_at: within_window()
      })

      body = ActivityDigest.build_external(ext.id, @window_start, @window_end)

      refute body =~ secret
      assert body =~ benign

      assert body =~ @withheld_marker
      assert body =~ "@Ext"
    end

    test "a re-dispatched window withholds on every pass" do
      # The property that makes this ticket critical rather than a one-off.
      # Chunked passes re-dispatch ADJACENT, overlapping windows until the
      # value is dead or the message is removed, so a fix that only holds on
      # first delivery is not a fix: the second pass over the same row is
      # a second delivery of the same credential.
      secret = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "AccR", slug: "acc-s4-redis", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: "key " <> secret,
        inserted_at: DateTime.add(@window_start, 120, :second)
      })

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 180, :second)
      })

      pass = fn ws, we ->
        {:ok, body, meta} =
          ActivityDigest.build_windowed_result(%{
            corpus: :messages,
            window_start: ws,
            window_end: we,
            oversize: false,
            budget_tokens: 30_000
          })

        {body, meta}
      end

      # Two overlapping spans, each covering BOTH rows.
      {first_body, first_meta} =
        pass.(@window_start, DateTime.add(@window_start, 300, :second))

      {second_body, second_meta} =
        pass.(
          DateTime.add(@window_start, 60, :second),
          DateTime.add(@window_start, 600, :second)
        )

      # Both passes really did see the row — otherwise "withheld on the
      # second pass" would be satisfied by an empty second window.
      assert first_meta.included_count == 2
      assert second_meta.included_count == 2

      refute first_body =~ secret
      assert first_body =~ benign

      refute second_body =~ secret
      assert second_body =~ benign

      assert first_meta.credential_withheld_count == 1
      assert second_meta.credential_withheld_count == 1
      assert second_body =~ @withheld_marker
    end

    test "the incompleteness notice appears once, at the top, carrying the count" do
      secret_a = synthetic_credential()
      secret_b = synthetic_credential()
      benign = benign_sentinel()

      space = insert_space(%{name: "AccN", slug: "acc-s4-notice", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      [{"k1 " <> secret_a, 60}, {"k2 " <> secret_b, 120}, {benign, 180}]
      |> Enum.each(fn {content, offset} ->
        insert_message(space.id, participant.id, %{
          content: content,
          inserted_at: DateTime.add(@window_start, offset, :second)
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

      refute body =~ secret_a
      refute body =~ secret_b
      assert body =~ benign

      # EXACTLY ONE occurrence — not one per marker.
      assert length(String.split(body, @notice_head)) - 1 == 1
      assert length(String.split(body, @withheld_marker)) - 1 == 2

      # Byte offset PRECEDES the first marker, and the first body line.
      {notice_at, _} = :binary.match(body, @notice_head)
      {marker_at, _} = :binary.match(body, @withheld_marker)
      {benign_at, _} = :binary.match(body, benign)
      assert notice_at < marker_at
      assert notice_at < benign_at

      # The RENDERED count equals the number withheld — and it is
      # `meta.credential_withheld_count`, NOT the budget-withheld set that
      # `windowed_body/4` binds to `withheld`, and not the row count.
      assert meta.credential_withheld_count == 2
      assert body =~ "> **This window is INCOMPLETE: 2 message(s) withheld"
      refute body =~ "INCOMPLETE: 3 message(s)"
      assert meta.item_count == 3
    end

    test "a window with no credential-shaped content renders no notice and no marker" do
      # The regression that protects the digest's USEFULNESS. A redactor
      # that eats ordinary traffic gets switched off, and a switched-off
      # redactor is worse than none, because the ticket still reads closed.
      benign = benign_sentinel()

      space = insert_space(%{name: "AccC", slug: "acc-s4-clean", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      insert_message(space.id, participant.id, %{
        content: benign,
        inserted_at: DateTime.add(@window_start, 60, :second)
      })

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      assert meta.credential_withheld_count == 0
      assert body =~ benign
      refute body =~ @withheld_marker
      refute body =~ "INCOMPLETE"

      # Nothing at all is inserted between the header and the body: the
      # section that follows the header is the corpus section itself, byte
      # for byte what a clean window rendered before this ticket.
      [header, rest] = String.split(body, "\n\n", parts: 2)
      assert String.starts_with?(header, "## ")
      assert String.starts_with?(rest, "### Chat\n\n")
      refute rest =~ ">"
    end

    test "UUIDs, git SHAs and memory paths survive the window intact" do
      # Named allowlist regression, asserted in the SAME window as a real
      # withholding so a detector that has stopped firing altogether cannot
      # satisfy it.
      secret = synthetic_credential()

      ordinary = [
        "task 01a09c9b-5d2d-7001-b7bd-0ea5b3fb1def moved to in_review",
        "deployed 9c1726764c1e6a2d0d1e5b1f0a9c2d3e4f5a6b7c to staging",
        "promoted org/page/evidence-and-measurement-discipline.md",
        "space/01a0aa6d-8ea4-7001-a442-97d8c187d03b/journal/2026-09-16.md"
      ]

      space = insert_space(%{name: "AccA", slug: "acc-s4-allow", kind: "channel"})
      participant = insert_participant(space.id, %{display_name: "Ada"})

      ordinary
      |> Enum.with_index(1)
      |> Enum.each(fn {content, i} ->
        insert_message(space.id, participant.id, %{
          content: content,
          inserted_at: DateTime.add(@window_start, i * 60, :second)
        })
      end)

      insert_message(space.id, participant.id, %{
        content: "and the key is " <> secret,
        inserted_at: DateTime.add(@window_start, 600, :second)
      })

      {:ok, body, meta} =
        ActivityDigest.build_windowed_result(%{
          corpus: :messages,
          window_start: @window_start,
          window_end: @window_end,
          oversize: false,
          budget_tokens: 30_000
        })

      refute body =~ secret
      assert Enum.reject(ordinary, &(body =~ &1)) == []
      assert meta.credential_withheld_count == 1
    end
  end

  # ── Synthetic fixtures ───────────────────────────────────────────────────

  # Generated at test time from `:crypto.strong_rand_bytes/1`. A `ghp_`
  # prefix plus a 30-character base32 body is tier-1 credential-shaped and
  # is not, and cannot be, anyone's real token.
  defp synthetic_credential do
    body =
      32
      |> :crypto.strong_rand_bytes()
      |> Base.encode32(padding: false)
      |> binary_part(0, 30)

    "ghp_" <> body
  end

  # Distinctive ordinary prose. Every run in it is short and space
  # separated, so no tier can reach it — asserted directly by the fixture
  # guard in the first test.
  defp benign_sentinel do
    "the kettle boiled at dawn marker #{System.unique_integer([:positive])}"
  end

  defp insert_org_page!(file_key, content, ts \\ within_window()) do
    attrs = %{
      workspace_id: nil,
      file_key: "#{file_key}-#{System.unique_integer([:positive])}",
      content: content
    }

    page =
      %Platform.Org.WikiPage{}
      |> Platform.Org.WikiPage.changeset(attrs)
      |> Repo.insert!()

    {1, _} =
      Repo.update_all(
        from(p in Platform.Org.WikiPage, where: p.id == ^page.id),
        set: [updated_at: ts, inserted_at: ts]
      )

    page
  end

  defp insert_org_journal!(content) do
    row =
      %Platform.Org.WikiJournalEntry{}
      |> Platform.Org.WikiJournalEntry.changeset(%{
        workspace_id: nil,
        content: content,
        date: DateTime.to_date(within_window())
      })
      |> Repo.insert!()

    ts = within_window()

    {1, _} =
      Repo.update_all(
        from(e in Platform.Org.WikiJournalEntry, where: e.id == ^row.id),
        set: [inserted_at: ts]
      )

    row
  end
end
