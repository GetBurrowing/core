defmodule Platform.InboxTest do
  use Platform.DataCase, async: true

  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "User #{n}",
      email: "user-#{n}@example.com",
      oidc_sub: "sub-#{n}"
    })
  end

  defp valid_attrs(user, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user.id,
        kind: "chat_mention",
        source_type: "chat_message",
        source_id: Ecto.UUID.generate(),
        title: "You were mentioned",
        body: "Alex mentioned you",
        url: "/chat/123"
      },
      overrides
    )
  end

  describe "emit/1" do
    test "inserts exactly one row and returns {:ok, item}" do
      user = insert_user()

      assert {:ok, %Item{} = item} = Inbox.emit(valid_attrs(user))
      assert item.user_id == user.id
      assert item.kind == "chat_mention"
      assert is_nil(item.dismissed_at)
      assert is_nil(item.read_at)

      assert Repo.aggregate(from(i in Item, where: i.user_id == ^user.id), :count) == 1
    end

    test "broadcasts {:inbox_item_added, item} on the user's inbox topic" do
      user = insert_user()
      :ok = Inbox.subscribe(user.id)

      assert {:ok, %Item{id: id}} = Inbox.emit(valid_attrs(user))
      assert_receive {:inbox_item_added, %Item{id: ^id}}
    end

    test "rejects a kind outside the enum and inserts no row" do
      user = insert_user()

      assert {:error, changeset} = Inbox.emit(valid_attrs(user, %{kind: "not_a_real_kind"}))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :kind)
      assert Repo.aggregate(from(i in Item, where: i.user_id == ^user.id), :count) == 0
    end

    # `inbox_items.title` is varchar(255) and producers prefix user text
    # ("You're now sponsoring: <255-char task title>"). Uncut, the insert
    # raised 22001 and aborted the caller's transaction (prod, 2026-10-23).
    test "a title longer than the column inserts, cut to 255 characters ending in …" do
      user = insert_user()
      title = String.duplicate("a", 300)

      assert {:ok, %Item{} = item} = Inbox.emit(valid_attrs(user, %{title: title}))

      stored = Repo.get!(Item, item.id).title
      assert String.length(stored) == 255
      assert stored == String.duplicate("a", 254) <> "…"
    end

    test "a title that fits is stored unchanged; a cut never splits a grapheme" do
      user = insert_user()
      exact = String.duplicate("b", 255)

      assert {:ok, %Item{} = item} = Inbox.emit(valid_attrs(user, %{title: exact}))
      assert Repo.get!(Item, item.id).title == exact

      # "é" as e + combining acute: one grapheme, two code points (Postgres
      # counts code points).
      decomposed = String.duplicate("é", 200)
      cut = Item.truncate_title(decomposed)
      assert length(String.codepoints(cut)) <= 255
      assert String.ends_with?(cut, "…")
      assert cut |> String.trim_trailing("…") |> String.graphemes() |> Enum.all?(&(&1 == "é"))

      assert {:ok, %Item{}} = Inbox.emit(valid_attrs(user, %{title: decomposed}))
    end
  end

  # An invite gets its own typed row so it can be grouped and counted as an
  # invite; `meeting_starting` means something else (starting NOW) and a
  # `chat_mention` cannot be counted as an invite at all.
  describe "the meeting_invited kind" do
    test "emit/1 accepts meeting_invited, and STILL rejects a bogus kind" do
      user = insert_user()

      invite_attrs =
        valid_attrs(user, %{
          kind: "meeting_invited",
          source_type: "meeting",
          source_id: Ecto.UUID.generate(),
          title: "Alex invited you to Weekly sync",
          url: "/meetings/weekly-sync"
        })

      assert {:ok, %Item{} = item} = Inbox.emit(invite_attrs)
      assert item.kind == "meeting_invited"
      assert item.source_type == "meeting"

      # Both sides. Asserting only the positive passes just as well against an
      # implementation that deleted `validate_inclusion(:kind, @kinds)` outright
      # — which would accept every typo as a new kind forever.
      assert {:error, changeset} = Inbox.emit(valid_attrs(user, %{kind: "not_a_kind"}))
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :kind)

      # Exactly the one invite row landed.
      assert Repo.aggregate(from(i in Item, where: i.user_id == ^user.id), :count) == 1
    end

    test "meeting_invited is a member of kinds/0 and distinct from meeting_starting" do
      kinds = Item.kinds()

      assert "meeting_invited" in kinds
      assert "meeting_starting" in kinds
      refute "not_a_kind" in kinds
    end
  end

  describe "list_unread_for_user/2" do
    test "excludes dismissed, includes read-but-not-dismissed, honors :kind and desc order" do
      user = insert_user()

      # 1ms spacing guarantees distinct microsecond inserted_at so the
      # desc-inserted_at ordering assertions are deterministic.
      {:ok, a} = Inbox.emit(valid_attrs(user, %{kind: "chat_mention", title: "A"}))
      Process.sleep(1)
      {:ok, b} = Inbox.emit(valid_attrs(user, %{kind: "chat_mention", title: "B"}))
      Process.sleep(1)
      {:ok, c} = Inbox.emit(valid_attrs(user, %{kind: "meeting_starting", title: "C"}))
      Process.sleep(1)
      {:ok, d} = Inbox.emit(valid_attrs(user, %{kind: "chat_mention", title: "D"}))

      {:ok, _} = Inbox.mark_read(b.id, user.id)
      {:ok, _} = Inbox.mark_dismissed(d.id, user.id)

      # Unfiltered: A, B, C present (D dismissed excluded), read B still included,
      # newest first.
      ids = Inbox.list_unread_for_user(user.id) |> Enum.map(& &1.id)
      assert ids == [c.id, b.id, a.id]

      # kind-filtered: only chat_mention, not dismissed -> A and B, desc order.
      kind_ids = Inbox.list_unread_for_user(user.id, kind: "chat_mention") |> Enum.map(& &1.id)
      assert kind_ids == [b.id, a.id]
    end
  end

  describe "unread_count/1" do
    # HISTORY — these tests have flipped twice, and both flips are intentional.
    #
    # Written for #589/#592 (badge and list disagreed about read rows), they
    # asserted that reading decremented the count. Task `01a00108` stage 4
    # made `unread_scope/1` key on `dismissed_at` alone and inverted them.
    # Task `01a11703` split the badge from the list: `unread_count/1` now
    # aggregates `badge_scope/1` (the list's rows with `read_at` nil), so
    # reading decrements the BADGE again while the row stays LISTED. What
    # survives from #589/#592 is that the badge is built ON the list scope,
    # so it can never count a row the list does not show.

    test "counts undismissed, unopened rows — reading one decrements it, dismissing too" do
      user = insert_user()

      assert Inbox.unread_count(user.id) == 0

      {:ok, a} = Inbox.emit(valid_attrs(user, %{title: "A"}))
      {:ok, _b} = Inbox.emit(valid_attrs(user, %{title: "B"}))
      {:ok, c} = Inbox.emit(valid_attrs(user, %{title: "C"}))

      assert Inbox.unread_count(user.id) == 3

      # Seen leaves the badge. It does not leave the list.
      {:ok, _} = Inbox.mark_read(a.id, user.id)
      assert Inbox.unread_count(user.id) == 2
      assert user.id |> Inbox.unread_scope() |> Repo.aggregate(:count) == 3

      {:ok, _} = Inbox.mark_dismissed(c.id, user.id)
      assert Inbox.unread_count(user.id) == 1

      # Dismissing the row that was already read does not move the badge.
      {:ok, _} = Inbox.mark_dismissed(a.id, user.id)
      assert Inbox.unread_count(user.id) == 1
    end

    test "badge is the unread subset of the list the Inbox surface renders" do
      user = insert_user()

      {:ok, _a} = Inbox.emit(valid_attrs(user, %{title: "A"}))
      {:ok, b} = Inbox.emit(valid_attrs(user, %{title: "B"}))
      {:ok, c} = Inbox.emit(valid_attrs(user, %{title: "C"}))

      # Read one, dismiss one — leaving two rows on the surface, one of them read.
      {:ok, _} = Inbox.mark_read(b.id, user.id)
      {:ok, _} = Inbox.mark_dismissed(c.id, user.id)

      # The surface renders `unread_scope/1` (see `InboxLive.load_items/1`);
      # `unread_count/1` aggregates `badge_scope/1`, composed on it.
      rendered = user.id |> Inbox.unread_scope() |> Repo.all()

      assert length(rendered) == 2
      assert b.id in Enum.map(rendered, & &1.id)
      assert Inbox.unread_count(user.id) == Enum.count(rendered, &is_nil(&1.read_at))
      assert Inbox.unread_count(user.id) == 1
    end

    test "is scoped per user — a second user's rows do not leak into the count" do
      u1 = insert_user()
      u2 = insert_user()

      {:ok, _} = Inbox.emit(valid_attrs(u1))
      {:ok, _} = Inbox.emit(valid_attrs(u1))
      {:ok, _} = Inbox.emit(valid_attrs(u2))

      assert Inbox.unread_count(u1.id) == 2
      assert Inbox.unread_count(u2.id) == 1
    end
  end

  describe "mark_read/2 and mark_dismissed/2" do
    test "set the corresponding timestamps and return {:ok, item}" do
      user = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(user))

      assert {:ok, read} = Inbox.mark_read(item.id, user.id)
      assert %DateTime{} = read.read_at

      assert {:ok, dismissed} = Inbox.mark_dismissed(item.id, user.id)
      assert %DateTime{} = dismissed.dismissed_at
    end

    test "cross-user guard: wrong user_id is a no-op returning {:error, :not_found}" do
      u1 = insert_user()
      u2 = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(u1))

      assert {:error, :not_found} = Inbox.mark_read(item.id, u2.id)
      assert {:error, :not_found} = Inbox.mark_dismissed(item.id, u2.id)

      reloaded = Repo.get!(Item, item.id)
      assert is_nil(reloaded.read_at)
      assert is_nil(reloaded.dismissed_at)

      # Correct owner still works.
      assert {:ok, read} = Inbox.mark_read(item.id, u1.id)
      assert %DateTime{} = read.read_at
    end

    test "mark_dismissed broadcasts {:inbox_item_dismissed, item} on the user's topic" do
      user = insert_user()
      {:ok, %Item{id: id} = item} = Inbox.emit(valid_attrs(user))

      :ok = Inbox.subscribe(user.id)

      assert {:ok, %Item{id: ^id}} = Inbox.mark_dismissed(item.id, user.id)
      assert_receive {:inbox_item_dismissed, %Item{id: ^id}}
    end

    test "a cross-user dismiss miss broadcasts nothing" do
      u1 = insert_user()
      u2 = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(u1))

      :ok = Inbox.subscribe(u1.id)

      assert {:error, :not_found} = Inbox.mark_dismissed(item.id, u2.id)
      refute_receive {:inbox_item_dismissed, _}
    end
  end

  describe "dismiss_by_source/4 — the kind filter" do
    # A source triple is not unique per kind: task_sponsor_assigned and
    # task_plan_review both carry source_type "task" and the same task id. A
    # caller that owns one kind must be able to clear only that one.
    setup do
      user = insert_user()
      source_id = Ecto.UUID.generate()

      {:ok, review} =
        Inbox.emit(
          valid_attrs(user, %{kind: "task_plan_review", source_type: "task", source_id: source_id})
        )

      {:ok, sponsor} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_sponsor_assigned",
            source_type: "task",
            source_id: source_id
          })
        )

      %{user: user, source_id: source_id, review: review, sponsor: sponsor}
    end

    defp dismissed?(id), do: not is_nil(Repo.get!(Inbox.Item, id).dismissed_at)

    test "kind: clears that kind and leaves the sibling standing", ctx do
      assert {:ok, 1} =
               Inbox.dismiss_by_source(ctx.user.id, "task", ctx.source_id,
                 kind: "task_plan_review"
               )

      assert dismissed?(ctx.review.id)
      refute dismissed?(ctx.sponsor.id)
    end

    # CONTROL. Without this, a filter that matched nothing would pass the case
    # above by dismissing neither row, and the count assertion is what tells
    # "filtered correctly" apart from "matched nothing".
    test "no kind: still clears every row for the source, as callers rely on", ctx do
      assert {:ok, 2} = Inbox.dismiss_by_source(ctx.user.id, "task", ctx.source_id)

      assert dismissed?(ctx.review.id)
      assert dismissed?(ctx.sponsor.id)
    end

    test "a kind nothing matches dismisses nothing", ctx do
      assert {:ok, 0} =
               Inbox.dismiss_by_source(ctx.user.id, "task", ctx.source_id, kind: "chat_mention")

      refute dismissed?(ctx.review.id)
      refute dismissed?(ctx.sponsor.id)
    end
  end

  describe "dismiss_many/2 and restore_many/2" do
    # The returned id list — not the table — is what stage 3's undo replays, so
    # every assertion here reads the RETURNED list. Re-querying the table would
    # pass whether or not the row was in the result, and prove nothing.
    test "returns exactly the ids it changed, omitting a row dismissed before the call" do
      user = insert_user()

      {:ok, first} = Inbox.emit(valid_attrs(user))
      {:ok, second} = Inbox.emit(valid_attrs(user))
      {:ok, already} = Inbox.emit(valid_attrs(user))

      {:ok, _} = Inbox.mark_dismissed(already.id, user.id)

      assert {:ok, changed} = Inbox.dismiss_many(user.id, [first.id, second.id, already.id])

      # `already` WAS passed in, so its absence is the filter working, not the
      # id never having been offered.
      refute already.id in changed
      assert Enum.sort(changed) == Enum.sort([first.id, second.id])

      assert dismissed?(first.id)
      assert dismissed?(second.id)
    end

    test "a row belonging to another user is untouched even when its id is passed" do
      user = insert_user()
      other = insert_user()

      {:ok, mine} = Inbox.emit(valid_attrs(user))
      {:ok, theirs} = Inbox.emit(valid_attrs(other))

      assert {:ok, changed} = Inbox.dismiss_many(user.id, [mine.id, theirs.id])

      assert changed == [mine.id]
      refute theirs.id in changed
      assert dismissed?(mine.id)
      refute dismissed?(theirs.id)
    end

    test "restore_many/2 clears exactly the given ids and leaves a separately-dismissed row dismissed" do
      user = insert_user()

      {:ok, first} = Inbox.emit(valid_attrs(user))
      {:ok, second} = Inbox.emit(valid_attrs(user))
      {:ok, separate} = Inbox.emit(valid_attrs(user))

      {:ok, _} = Inbox.dismiss_many(user.id, [first.id, second.id])
      {:ok, _} = Inbox.mark_dismissed(separate.id, user.id)

      assert {:ok, restored} = Inbox.restore_many(user.id, [first.id, second.id])
      assert Enum.sort(restored) == Enum.sort([first.id, second.id])

      refute dismissed?(first.id)
      refute dismissed?(second.id)
      assert dismissed?(separate.id)
    end

    test "a bulk dismiss broadcasts ONE {:inbox_changed, user_id}, not one per row" do
      user = insert_user()

      {:ok, first} = Inbox.emit(valid_attrs(user))
      {:ok, second} = Inbox.emit(valid_attrs(user))
      {:ok, third} = Inbox.emit(valid_attrs(user))

      # Subscribe after the emits so their add-broadcasts are not in the mailbox.
      :ok = Inbox.subscribe(user.id)
      user_id = user.id

      assert {:ok, changed} = Inbox.dismiss_many(user.id, [first.id, second.id, third.id])
      assert length(changed) == 3

      assert_receive {:inbox_changed, ^user_id}
      refute_received {:inbox_changed, ^user_id}
    end
  end

  describe "dismiss_all_unread/1" do
    # Same posture as dismiss_many/2 above: the RETURNED list is what stage 3's
    # undo replays, so it is what gets asserted on.
    test "sweeps the whole unread scope and returns exactly those ids" do
      user = insert_user()

      {:ok, a} = Inbox.emit(valid_attrs(user))
      {:ok, b} = Inbox.emit(valid_attrs(user, %{kind: "task_plan_review", source_type: "task"}))

      {:ok, c} =
        Inbox.emit(valid_attrs(user, %{kind: "meeting_starting", source_type: "meeting"}))

      assert {:ok, changed} = Inbox.dismiss_all_unread(user.id)
      assert Enum.sort(changed) == Enum.sort([a.id, b.id, c.id])

      assert dismissed?(a.id)
      assert dismissed?(b.id)
      assert dismissed?(c.id)
      assert Inbox.unread_count(user.id) == 0
    end

    test "omits a row dismissed before the call, so undo cannot resurrect it" do
      user = insert_user()

      {:ok, live_row} = Inbox.emit(valid_attrs(user))
      {:ok, already} = Inbox.emit(valid_attrs(user))
      {:ok, _} = Inbox.mark_dismissed(already.id, user.id)

      assert {:ok, changed} = Inbox.dismiss_all_unread(user.id)

      assert changed == [live_row.id]
      refute already.id in changed

      # Replaying the returned list is exactly what the undo does — the
      # earlier-dismissed row stays dismissed through it.
      {:ok, _} = Inbox.restore_many(user.id, changed)
      refute dismissed?(live_row.id)
      assert dismissed?(already.id)
    end

    test "SWEEPS a read-but-not-dismissed row — it is on the surface, so the button named it" do
      # INVERTED by task `01a00108` stage 4. This asserted the exact opposite —
      # that a read row is spared — on the reasoning that it was absent from
      # /inbox and from the badge, so a button counting the rendered sections
      # could not have named it. That reasoning is unchanged and still governs;
      # what changed is that a read row IS now rendered and IS now counted, so
      # sparing it would be the lie the original test guarded against.
      user = insert_user()

      {:ok, unread} = Inbox.emit(valid_attrs(user))
      {:ok, read} = Inbox.emit(valid_attrs(user))
      {:ok, _} = Inbox.mark_read(read.id, user.id)

      # Both are on the surface, so the button's count is 2, not 1. (The
      # badge, `unread_count/1`, is 1 since task `01a11703`: the read row is
      # listed and not counted.)
      assert user.id |> Inbox.unread_scope() |> Repo.aggregate(:count) == 2
      assert Inbox.unread_count(user.id) == 1

      assert {:ok, changed} = Inbox.dismiss_all_unread(user.id)

      assert Enum.sort(changed) == Enum.sort([unread.id, read.id])
      assert dismissed?(unread.id)
      assert dismissed?(read.id)
      assert Inbox.unread_count(user.id) == 0
    end

    test "another user's rows are untouched" do
      user = insert_user()
      other = insert_user()

      {:ok, mine} = Inbox.emit(valid_attrs(user))
      {:ok, theirs} = Inbox.emit(valid_attrs(other))

      assert {:ok, changed} = Inbox.dismiss_all_unread(user.id)

      assert changed == [mine.id]
      refute dismissed?(theirs.id)
    end

    test "broadcasts ONE {:inbox_changed, user_id} for the sweep, and nothing when empty" do
      user = insert_user()

      {:ok, _} = Inbox.emit(valid_attrs(user))
      {:ok, _} = Inbox.emit(valid_attrs(user))

      :ok = Inbox.subscribe(user.id)
      user_id = user.id

      assert {:ok, changed} = Inbox.dismiss_all_unread(user.id)
      assert length(changed) == 2

      assert_receive {:inbox_changed, ^user_id}
      refute_received {:inbox_changed, ^user_id}

      # A second sweep changes nothing, so it stays quiet.
      assert {:ok, []} = Inbox.dismiss_all_unread(user.id)
      refute_received {:inbox_changed, ^user_id}
    end
  end

  describe "dismiss = gone; @mention = back" do
    test "re-emitting the same source triple after dismissal yields a NEW row" do
      user = insert_user()
      source_id = Ecto.UUID.generate()

      attrs =
        valid_attrs(user, %{kind: "task_plan_review", source_type: "task", source_id: source_id})

      {:ok, first} = Inbox.emit(attrs)
      {:ok, _} = Inbox.mark_dismissed(first.id, user.id)

      assert Inbox.list_unread_for_user(user.id) == []

      {:ok, second} = Inbox.emit(attrs)
      assert second.id != first.id
      assert is_nil(second.dismissed_at)

      ids = Inbox.list_unread_for_user(user.id) |> Enum.map(& &1.id)
      assert ids == [second.id]
      refute first.id in ids
    end
  end

  # ── reconcile_for_user/1 ──────────────────────────────────────────────────
  #
  # EVERY kind gets an assertion on BOTH sides. A reconciler that clears
  # unconditionally passes every positive case on its own, so a clears-when-
  # resolved test proves nothing without its survives-while-live twin.

  defp live_ids(user),
    do: Inbox.list_unread_for_user(user.id) |> Enum.map(& &1.id) |> MapSet.new()

  defp reconciled_ids(user) do
    assert :ok = Inbox.reconcile_for_user(user.id)
    live_ids(user)
  end

  defp project! do
    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Reconcile #{System.unique_integer([:positive])}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    project
  end

  defp task_with_plan!(plan_status) do
    {:ok, task} = Platform.Tasks.create_task(%{project_id: project!().id, title: "Reconciled"})

    {:ok, _plan} =
      %Platform.Tasks.Plan{}
      |> Platform.Tasks.Plan.changeset(%{task_id: task.id, version: 1, status: plan_status})
      |> Repo.insert()

    task
  end

  describe "reconcile_for_user/1 — chat_mention" do
    # ONE fixture, TWO messages with distinct UUIDv7 ids and the read watermark
    # between them: the earlier mention is read (clears), the later is not
    # (survives). A single-message fixture cannot separate the two.
    test "clears a mention at or below the read watermark, keeps one above it" do
      user = insert_user()

      {:ok, space} =
        Platform.Chat.create_space(%{
          name: "Reconcile",
          slug: "reconcile-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, me} =
        Platform.Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          joined_at: DateTime.utc_now()
        })

      {:ok, author} =
        Platform.Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          joined_at: DateTime.utc_now()
        })

      {:ok, earlier} =
        Platform.Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "first"
        })

      {:ok, later} =
        Platform.Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "second"
        })

      assert earlier.id < later.id
      :ok = Platform.Chat.mark_space_read(me.id, earlier.id)

      {:ok, read_row} =
        Inbox.emit(valid_attrs(user, %{source_id: earlier.id, title: "Mentioned (read)"}))

      {:ok, unread_row} =
        Inbox.emit(valid_attrs(user, %{source_id: later.id, title: "Mentioned (unread)"}))

      survivors = reconciled_ids(user)

      refute MapSet.member?(survivors, read_row.id)
      assert MapSet.member?(survivors, unread_row.id)
    end
  end

  describe "reconcile_for_user/1 — task_plan_review" do
    test "survives while the plan is still pending_review" do
      user = insert_user()
      task = task_with_plan!("pending_review")

      {:ok, row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_plan_review",
            source_type: "task",
            source_id: task.id,
            title: "Plan ready for review"
          })
        )

      assert MapSet.member?(reconciled_ids(user), row.id)
    end

    test "clears once the plan is approved" do
      user = insert_user()
      task = task_with_plan!("approved")

      {:ok, row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_plan_review",
            source_type: "task",
            source_id: task.id,
            title: "Plan ready for review"
          })
        )

      refute MapSet.member?(reconciled_ids(user), row.id)
    end

    # Both terminal verdicts, not just approval: an approval-only test leaves
    # the rejection path silently broken and its rows stuck forever.
    test "clears once the plan is rejected" do
      user = insert_user()
      task = task_with_plan!("rejected")

      {:ok, row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_plan_review",
            source_type: "task",
            source_id: task.id,
            title: "Plan ready for review"
          })
        )

      refute MapSet.member?(reconciled_ids(user), row.id)
    end
  end

  describe "reconcile_for_user/1 — meeting_starting" do
    defp reconcile_meeting! do
      {:ok, meeting} =
        Platform.Meetings.create_meeting(%{
          project_id: project!().id,
          name: "Standup #{System.unique_integer([:positive])}"
        })

      meeting
    end

    # The gap this closes: a meeting that ENDS without you ever joining.
    # `Meetings.maybe_dismiss_meeting_inbox/2` fires at join time only, so
    # nothing else would ever clear this row.
    test "survives while the meeting is live, clears once it has ended" do
      user = insert_user()
      {:ok, live} = Platform.Meetings.start_meeting(reconcile_meeting!())

      {:ok, row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "meeting_starting",
            source_type: "meeting",
            source_id: live.id,
            title: "Meeting started"
          })
        )

      assert MapSet.member?(reconciled_ids(user), row.id)

      {:ok, _ended} = Platform.Meetings.end_meeting(live)

      refute MapSet.member?(reconciled_ids(user), row.id)
    end
  end

  describe "reconcile_for_user/1 — task_sponsor_assigned is deliberately never reconciled" do
    # THIS TEST PINS A DECISION. Sponsorship has no resolution EVENT — it is an
    # ongoing state. Task completion is the only candidate trigger and it is
    # exactly wrong: the row means "you now own this", which gets MORE relevant
    # while the task runs. If this detonates, someone has added a reconciler
    # clause for the kind, and the decision must be REOPENED, not the test
    # adjusted.
    # (Opening the task as its sponsor DOES dismiss the row — a user action, not
    # reconciliation; see tasks_live_sponsor_inbox_dismiss_test.exs, task 01a116ff.)
    test "a sponsor row survives reconciliation, including after its task completes" do
      user = insert_user()
      {:ok, task} = Platform.Tasks.create_task(%{project_id: project!().id, title: "Sponsored"})

      {:ok, row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_sponsor_assigned",
            source_type: "task",
            source_id: task.id,
            title: "You are the sponsor"
          })
        )

      assert MapSet.member?(reconciled_ids(user), row.id)

      task |> Platform.Tasks.Task.changeset(%{status: "done"}) |> Repo.update!()

      assert MapSet.member?(reconciled_ids(user), row.id)
    end
  end

  describe "reconcile_for_user/1 — review_request_pending (behaviour unchanged)" do
    setup do
      {:ok, task} = Platform.Tasks.create_task(%{project_id: project!().id, title: "Reviewed"})
      {:ok, plan} = Platform.Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Platform.Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "UI"})
      {:ok, _} = Platform.Tasks.PlanEngine.start_stage(stage.id)

      {:ok, validation} =
        Platform.Tasks.create_validation(%{stage_id: stage.id, kind: "manual_approval"})

      %{task: task, validation: validation}
    end

    defp review_row(user, task_id) do
      {:ok, row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "review_request_pending",
            source_type: "task_review",
            source_id: task_id,
            title: "Reviews awaiting you"
          })
        )

      row
    end

    test "survives while the task still has a pending review request", ctx do
      user = insert_user()

      {:ok, _request} =
        Platform.Tasks.ReviewRequests.create_review_request(%{
          validation_id: ctx.validation.id,
          task_id: ctx.task.id,
          items: [%{label: "Desktop"}]
        })

      row = review_row(user, ctx.task.id)

      assert MapSet.member?(reconciled_ids(user), row.id)
    end

    test "clears once the task has no pending review request", ctx do
      user = insert_user()
      row = review_row(user, ctx.task.id)

      refute MapSet.member?(reconciled_ids(user), row.id)
    end
  end

  describe "reconcile_for_user/1 — nothing unconfirmed is ever dismissed" do
    # The governing rule, one row per way of being unconfirmable: a mention
    # with no watermark to compare against, a legacy `review_request` row whose
    # request resolves to no task, a task and a meeting that no longer exist
    # (ABSENT, which the stage-1 predicates cannot tell apart from SETTLED —
    # hence the existence conjuncts in `row_stale?/1`), and two kinds the
    # reconciler has no clause for at all.
    #
    # This is the assertion that fails if anyone makes reconciliation
    # optimistic. All five reconcilable kinds are represented on the survives
    # side somewhere in this file; without that, a reconciler that dismissed
    # everything would pass every clears-when-resolved test above.
    test "rows whose subject cannot be positively confirmed dead all survive" do
      user = insert_user()

      rows =
        for attrs <- [
              %{kind: "chat_mention", source_type: "chat_message"},
              %{kind: "review_request_pending", source_type: "review_request"},
              %{kind: "task_plan_review", source_type: "task"},
              %{kind: "meeting_starting", source_type: "meeting"},
              %{kind: "meeting_invited", source_type: "meeting"},
              %{kind: "lifecycle_step_failed", source_type: "task"}
            ] do
          {:ok, row} =
            Inbox.emit(valid_attrs(user, Map.put(attrs, :source_id, Ecto.UUID.generate())))

          row
        end

      survivors = reconciled_ids(user)

      for row <- rows, do: assert(MapSet.member?(survivors, row.id))
    end

    # The existence conjunct in `row_stale?/1` is load-bearing, and this is what
    # detonates if someone deletes it as redundant: with only
    # `not plan_pending_review?/1` and `not meeting_live?/1`, BOTH rows above
    # would be dismissed on a subject nobody confirmed dead. Pinned here
    # separately from the survives list so the failure names the cause.
    test "an absent task or meeting is NOT the same answer as a settled one" do
      user = insert_user()

      refute Platform.Tasks.task_exists?(Ecto.UUID.generate())
      refute Platform.Meetings.meeting_exists?(Ecto.UUID.generate())

      settled = task_with_plan!("approved")
      assert Platform.Tasks.task_exists?(settled.id)
      refute Platform.Tasks.plan_pending_review?(settled.id)

      {:ok, ended} =
        Platform.Meetings.end_meeting(
          elem(Platform.Meetings.start_meeting(reconcile_meeting!()), 1)
        )

      assert Platform.Meetings.meeting_exists?(ended.id)
      refute Platform.Meetings.meeting_live?(ended.id)

      # And the settled pair really does clear, so the conjunct has not simply
      # switched reconciliation off for these kinds.
      {:ok, plan_row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_plan_review",
            source_type: "task",
            source_id: settled.id,
            title: "Plan ready for review"
          })
        )

      refute MapSet.member?(reconciled_ids(user), plan_row.id)
    end

    test "leaves another user's rows alone" do
      mine = insert_user()
      theirs = insert_user()
      task = task_with_plan!("approved")

      stale = %{
        kind: "task_plan_review",
        source_type: "task",
        source_id: task.id,
        title: "Plan ready for review"
      }

      {:ok, my_row} = Inbox.emit(valid_attrs(mine, stale))
      {:ok, their_row} = Inbox.emit(valid_attrs(theirs, stale))

      refute MapSet.member?(reconciled_ids(mine), my_row.id)
      assert MapSet.member?(live_ids(theirs), their_row.id)
    end
  end

  # ---------------------------------------------------------------------
  # Task 01a00066 stage 4 — reachability-aware counting.
  #
  # THE RULE: a count never includes something the viewer has no way to act
  # on. An external user is fenced off `/inbox` by `ExternalUserScope`, so a
  # `task_sponsor_assigned` row is a promise their surface cannot keep; a
  # `chat_mention` is reachable because the conversation is on their host.
  # For an internal viewer this is `unread_scope/1` verbatim.
  #
  # ONE ASSERTION PER SIDE throughout: a filter that excluded EVERYTHING and
  # a filter that excluded NOTHING both pass a one-sided test.
  # ---------------------------------------------------------------------
  describe "reachable_unread_scope/1,2 and reachable_unread_count/1" do
    defp external_user! do
      user = insert_user()
      n = System.unique_integer([:positive])

      org =
        Repo.insert!(%Platform.Tenancy.Org{
          name: "Reach Tenant #{n}",
          slug: "tenant_reach_#{n}",
          parent_org_id: Platform.TenancyFixtures.acme_org_id()
        })

      {:ok, _} = Platform.Tenancy.mark_membership_external(%{user_id: user.id, org_id: org.id})
      # The predicate the branch keys off — pinned so the fixture cannot be
      # the reason a filter appears (or fails) to apply.
      assert Platform.Tenancy.external_user?(user)
      user
    end

    # The mixed row set used on BOTH sides: one unreachable kind
    # (`task_sponsor_assigned`) and one reachable kind (`chat_mention`).
    # Same rows, different viewer — so a difference in the count can only be
    # the reachability rule.
    defp mixed_rows!(user) do
      {:ok, sponsor} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_sponsor_assigned",
            source_type: "task",
            source_id: Ecto.UUID.generate(),
            title: "You are the sponsor"
          })
        )

      {:ok, mention} =
        Inbox.emit(valid_attrs(user, %{kind: "chat_mention", source_id: Ecto.UUID.generate()}))

      %{sponsor: sponsor, mention: mention}
    end

    test "an external user with ONLY an unreachable row counts 0" do
      user = external_user!()

      {:ok, sponsor} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_sponsor_assigned",
            source_type: "task",
            source_id: Ecto.UUID.generate(),
            title: "You are the sponsor"
          })
        )

      # The row IS live — the raw scope still sees it. The rule changes what
      # the badge counts, it does not dismiss anything.
      assert Inbox.unread_count(user.id) == 1
      assert MapSet.member?(live_ids(user), sponsor.id)

      # ...and the reachable count is 0, which is what makes the badge node
      # leave the DOM (`IconRail.badge_text/1` returns nil at 0).
      assert Inbox.reachable_unread_count(user.id) == 0
    end

    test "OTHER SIDE: the same external user's chat_mention IS counted" do
      user = external_user!()
      %{mention: mention} = mixed_rows!(user)

      # Two live rows, exactly one of them reachable — so this separates the
      # rule from a filter that drops everything.
      assert Inbox.unread_count(user.id) == 2
      assert Inbox.reachable_unread_count(user.id) == 1

      reachable = Inbox.reachable_unread_scope(user.id) |> Repo.all() |> MapSet.new(& &1.id)
      assert MapSet.member?(reachable, mention.id)
    end

    test "DIRECTION CONTROL: an internal user with the SAME row set counts every kind" do
      user = insert_user()
      refute Platform.Tenancy.external_user?(user)
      %{sponsor: sponsor, mention: mention} = mixed_rows!(user)

      # No filter, no behaviour change: identical to `unread_count/1`.
      assert Inbox.reachable_unread_count(user.id) == 2
      assert Inbox.reachable_unread_count(user.id) == Inbox.unread_count(user.id)

      reachable = Inbox.reachable_unread_scope(user.id) |> Repo.all() |> MapSet.new(& &1.id)
      assert MapSet.member?(reachable, sponsor.id)
      assert MapSet.member?(reachable, mention.id)
    end

    test "the arity-2 form takes the externality as given, both ways" do
      user = insert_user()
      mixed_rows!(user)

      # Same user, same rows — only the flag differs, so this pins that the
      # branch is the externality and nothing else.
      assert Repo.aggregate(Inbox.reachable_unread_scope(user.id, true), :count) == 1
      assert Repo.aggregate(Inbox.reachable_unread_scope(user.id, false), :count) == 2
    end

    test "the internal scope is `unread_scope/1` verbatim; the internal COUNT is `unread_count/1`" do
      # Task `01a00108` stage 4 made reading leave a row in this scope; task
      # `01a11703` made the COUNT (`reachable_badge_scope/1`) drop read rows.
      # Both still compose on `unread_scope/1`, so for an internal viewer the
      # scope is the list and the count is the badge.
      user = insert_user()
      %{sponsor: sponsor, mention: mention} = mixed_rows!(user)

      {:ok, _} = Inbox.mark_read(mention.id, user.id)
      assert Repo.aggregate(Inbox.reachable_unread_scope(user.id), :count) == 2
      assert Inbox.reachable_unread_count(user.id) == 1
      assert Inbox.reachable_unread_count(user.id) == Inbox.unread_count(user.id)

      {:ok, _} = Inbox.mark_dismissed(sponsor.id, user.id)
      assert Inbox.reachable_unread_count(user.id) == 0
      assert Repo.aggregate(Inbox.reachable_unread_scope(user.id), :count) == 1

      {:ok, _} = Inbox.mark_dismissed(mention.id, user.id)
      assert Repo.aggregate(Inbox.reachable_unread_scope(user.id), :count) == 0
    end

    test "an external user's reachable count drops to 0 when the mention is read, and stays 0 on dismiss" do
      user = external_user!()
      %{mention: mention} = mixed_rows!(user)

      assert Inbox.reachable_unread_count(user.id) == 1

      # Task `01a11703`: reading takes it out of the badge; it stays in the
      # reachable LIST scope until dismissed.
      {:ok, _} = Inbox.mark_read(mention.id, user.id)
      assert Inbox.reachable_unread_count(user.id) == 0
      assert Repo.aggregate(Inbox.reachable_unread_scope(user.id, true), :count) == 1

      {:ok, _} = Inbox.mark_dismissed(mention.id, user.id)
      assert Repo.aggregate(Inbox.reachable_unread_scope(user.id, true), :count) == 0

      # Nothing reachable left → 0 → no badge at all, not a zero and not a
      # dot. The unreachable sponsor row is still live and still uncounted.
      assert Inbox.reachable_unread_count(user.id) == 0
      assert Inbox.unread_count(user.id) == 1
    end
  end

  # ── Task 01a11703 stage 1: acknowledge on open ─────────────────────────

  describe "action_kinds/0" do
    # A literal list on purpose. Adding a kind to `Item.kinds/0` turns this
    # red, which forces the author to decide whether opening the new kind
    # acknowledges it (the default) or leaves it listed (an action kind).
    test "every kind outside the action allowlist is acknowledged on open" do
      assert Item.kinds() -- Inbox.action_kinds() == [
               "chat_mention",
               "meeting_starting",
               "meeting_invited",
               "task_sponsor_assigned",
               "lifecycle_step_failed"
             ]

      assert Inbox.action_kinds() == [
               "task_plan_review",
               "review_request_pending",
               "briefing",
               "meeting_briefing"
             ]

      assert Inbox.core_action_kinds() == Platform.Mobile.AppEntities.approval_kinds()
    end

    # Task 01a15ee1 stage 1: a briefing stays listed when opened, but it is
    # not an approval, so Mobile (core_action_kinds) never sees it.
    test "briefing is listed on open but is not a core (Mobile approval) action kind" do
      assert "briefing" in Inbox.action_kinds()
      refute "briefing" in Inbox.core_action_kinds()
      refute "briefing" in Platform.Mobile.AppEntities.approval_kinds()
    end
  end

  # ── Task 01a15ee1 stage 1: the daily briefing row ──────────────────────

  describe "upsert_briefing_item/2 and the briefing kind" do
    alias Platform.Memory.Briefing

    defp briefing!(user, date \\ ~D[2026-10-21], items \\ %{"k1" => Ecto.UUID.generate()}) do
      %Briefing{}
      |> Briefing.changeset(%{user_id: user.id, digest_date: date, items: items})
      |> Repo.insert!()
    end

    defp briefing_rows(user),
      do: Repo.all(from(i in Item, where: i.user_id == ^user.id and i.kind == "briefing"))

    test "inserts the day's row once, then updates the SAME row" do
      user = insert_user()
      user_id = user.id
      briefing = briefing!(user)
      :ok = Inbox.subscribe(user.id)

      assert {:ok, %Item{} = item, :created} =
               Inbox.upsert_briefing_item(briefing, %{total: 1, calls: 1})

      assert item.kind == "briefing"
      assert item.source_type == "briefing"
      assert item.source_id == briefing.id
      assert item.title == "Today's briefing"
      assert item.body == "1 item · 1 needs your call"
      assert item.url == "/inbox/briefing/2026-10-21"
      assert_receive {:inbox_changed, ^user_id}

      {:ok, _} = Inbox.open_item(item.id, user.id)

      assert {:ok, %Item{id: id, read_at: nil, body: "3 items · 2 need your call"}, :updated} =
               Inbox.upsert_briefing_item(briefing, %{total: 3, calls: 2})

      assert id == item.id
      assert [_one] = briefing_rows(user)

      # No new items: the text refreshes, the read stays.
      {:ok, _} = Inbox.open_item(item.id, user.id)

      assert {:ok, %Item{read_at: %DateTime{}}, :updated} =
               Inbox.upsert_briefing_item(briefing, %{total: 3, calls: 0, new_items?: false})

      assert [%Item{body: "3 items · FYI only"}] = briefing_rows(user)
    end

    test "open_item/2 on a briefing row stamps read_at and leaves it listed" do
      user = insert_user()
      {:ok, item, :created} = Inbox.upsert_briefing_item(briefing!(user), %{})

      assert {:ok, %Item{read_at: %DateTime{}, dismissed_at: nil}} =
               Inbox.open_item(item.id, user.id)

      assert [%Item{id: id}] = user.id |> Inbox.unread_scope() |> Repo.all()
      assert id == item.id
      assert Inbox.unread_count(user.id) == 0
    end

    test "another user's briefing row is never listed for you" do
      owner = insert_user()
      other = insert_user()
      {:ok, item, :created} = Inbox.upsert_briefing_item(briefing!(owner), %{})

      assert other.id |> Inbox.unread_scope() |> Repo.all() == []
      assert {:error, :not_found} = Inbox.open_item(item.id, other.id)
    end
  end

  describe "reconcile_for_user/1 — briefing (ADR 0049)" do
    alias Platform.Memory.Briefing
    alias Platform.Memory.Insight
    alias Platform.Memory.Insights.Disseminator

    defp today, do: Disseminator.local_date(DateTime.utc_now())

    defp insight_row!(state) do
      n = System.unique_integer([:positive])

      %Insight{}
      |> Insight.changeset(%{
        journal_path: "org/journal/2026-10-21.md",
        block_hash: "hash-#{n}",
        run_id: Ecto.UUID.generate(),
        action_type: "briefing",
        confidence: "high",
        body: "Line #{n}.",
        state: state
      })
      |> Repo.insert!()
    end

    defp briefing_with!(user, date, insights, receipts \\ %{}) do
      items = Map.new(insights, &{"k-" <> &1.id, &1.id})

      briefing =
        %Briefing{}
        |> Briefing.changeset(%{
          user_id: user.id,
          digest_date: date,
          items: items,
          receipts: receipts
        })
        |> Repo.insert!()

      {:ok, item, :created} = Inbox.upsert_briefing_item(briefing, %{})
      {briefing, item}
    end

    defp listed?(user, item),
      do: Enum.any?(Inbox.unread_scope(user.id) |> Repo.all(), &(&1.id == item.id))

    test "today's briefing with an unhandled item is NOT stale (control)" do
      user = insert_user()
      handled = insight_row!("done")
      open = insight_row!("open")
      {_briefing, item} = briefing_with!(user, today(), [handled, open])

      :ok = Inbox.reconcile_for_user(user.id)
      assert listed?(user, item)
    end

    # Stage 6 reversed stage 1 here: stage 1 cleared the row once every item
    # was handled; the prototype inventory keeps it listed for the day as
    # "All done · nothing waiting", so all-handled is NOT stale.
    test "NOT stale once every item is handled: the row stays listed for the day" do
      user = insert_user()
      done = insight_row!("done")
      dismissed = insight_row!("dismissed")
      receipted = insight_row!("open")
      receipts = %{("k-" <> receipted.id) => %{"verb" => "answer"}}

      {briefing, item} =
        briefing_with!(user, today(), [done, dismissed, receipted], receipts)

      refute Platform.Memory.Insights.Briefings.inbox_row_stale?(briefing.id)
      refute Platform.Memory.Insights.Briefings.open_item?(briefing)

      :ok = Inbox.reconcile_for_user(user.id)
      assert listed?(user, item)
      assert %Item{dismissed_at: nil} = Repo.get!(Item, item.id)
    end

    test "an all-handled briefing past the TTL is still stale (the age rule is kept)" do
      user = insert_user()
      ttl = Insight.default_ttl_days()
      done = insight_row!("done")
      {briefing, item} = briefing_with!(user, Date.add(today(), -(ttl + 1)), [done])

      assert Platform.Memory.Insights.Briefings.inbox_row_stale?(briefing.id)
      :ok = Inbox.reconcile_for_user(user.id)
      refute listed?(user, item)
    end

    test "relist_briefing_item/1 clears dismissed_at on that briefing's row only" do
      user = insert_user()
      {briefing, item} = briefing_with!(user, today(), [insight_row!("open")])
      {_other, other} = briefing_with!(user, Date.add(today(), -1), [insight_row!("open")])
      {:ok, _} = Inbox.mark_dismissed(item.id, user.id)
      {:ok, _} = Inbox.mark_dismissed(other.id, user.id)

      assert :ok = Inbox.relist_briefing_item(briefing)
      assert %Item{dismissed_at: nil} = Repo.get!(Item, item.id)
      assert %Item{dismissed_at: %DateTime{}} = Repo.get!(Item, other.id)
    end

    test "stale once digest_date is older than the insight TTL, whatever its items" do
      user = insert_user()
      ttl = Insight.default_ttl_days()
      open = insight_row!("open")

      {_b, old} = briefing_with!(user, Date.add(today(), -(ttl + 1)), [open])
      {_b, edge} = briefing_with!(user, Date.add(today(), -ttl), [insight_row!("open")])

      :ok = Inbox.reconcile_for_user(user.id)
      refute listed?(user, old)
      # Exactly TTL days old is not yet past it.
      assert listed?(user, edge)
    end

    test "a purged item with no receipt is NOT confirmation" do
      user = insert_user()
      gone = insight_row!("done")
      {_briefing, item} = briefing_with!(user, today(), [gone])
      Repo.delete!(gone)

      :ok = Inbox.reconcile_for_user(user.id)
      assert listed?(user, item)
    end
  end

  describe "badge_scope/1 vs unread_scope/1" do
    test "one unread row, one read action row, one read non-action row: badge 1, list 3" do
      user = insert_user()

      {:ok, _unread} = Inbox.emit(valid_attrs(user, %{title: "unread"}))

      {:ok, action} =
        Inbox.emit(valid_attrs(user, %{kind: "task_plan_review", source_type: "task"}))

      {:ok, non_action} = Inbox.emit(valid_attrs(user, %{title: "read mention"}))

      {:ok, _} = Inbox.mark_read(action.id, user.id)
      {:ok, _} = Inbox.mark_read(non_action.id, user.id)

      assert Inbox.unread_count(user.id) == 1
      assert Repo.aggregate(Inbox.badge_scope(user.id), :count) == 1
      assert length(user.id |> Inbox.unread_scope() |> Repo.all()) == 3
    end
  end

  describe "open_item/2" do
    test "a non-action kind is read AND dismissed in one write, with equal timestamps" do
      user = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(user))
      :ok = Inbox.subscribe(user.id)

      assert {:ok, %Item{read_at: %DateTime{} = r, dismissed_at: %DateTime{} = d}} =
               Inbox.open_item(item.id, user.id)

      assert r == d
      assert %Item{read_at: ^r, dismissed_at: ^d} = Repo.get!(Item, item.id)

      item_id = item.id
      assert_receive {:inbox_item_dismissed, %Item{id: ^item_id}}
      assert Inbox.unread_count(user.id) == 0
      assert user.id |> Inbox.unread_scope() |> Repo.all() == []
    end

    test "an action kind is only read: listed, not counted, and broadcasts :inbox_changed" do
      user = insert_user()
      user_id = user.id

      {:ok, item} =
        Inbox.emit(valid_attrs(user, %{kind: "review_request_pending", source_type: "task"}))

      :ok = Inbox.subscribe(user.id)

      assert {:ok, %Item{read_at: %DateTime{}, dismissed_at: nil}} =
               Inbox.open_item(item.id, user.id)

      assert_receive {:inbox_changed, ^user_id}
      refute_received {:inbox_item_dismissed, _}
      assert Inbox.unread_count(user.id) == 0
      assert [%Item{}] = user.id |> Inbox.unread_scope() |> Repo.all()
    end

    test "an already-dismissed row keeps its dismissed_at" do
      user = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(user))
      {:ok, dismissed} = Inbox.mark_dismissed(item.id, user.id)

      assert {:ok, %Item{dismissed_at: d, read_at: %DateTime{}}} =
               Inbox.open_item(item.id, user.id)

      assert d == dismissed.dismissed_at
    end

    test "a malformed id is :not_found, not a raise" do
      user = insert_user()
      assert {:error, :not_found} = Inbox.open_item("not-a-uuid", user.id)
      assert {:error, :not_found} = Inbox.mark_read("not-a-uuid", user.id)
    end

    test "another user's id is :not_found, writes nothing and broadcasts nothing" do
      owner = insert_user()
      other = insert_user()
      {:ok, item} = Inbox.emit(valid_attrs(owner))
      :ok = Inbox.subscribe(owner.id)

      assert {:error, :not_found} = Inbox.open_item(item.id, other.id)
      assert %Item{read_at: nil, dismissed_at: nil} = Repo.get!(Item, item.id)
      refute_receive {:inbox_item_dismissed, _}, 100
      refute_received {:inbox_changed, _}
    end
  end

  # ── Phone list author slot (redesign rung 14, task 01a1557a-ad2d) ─────

  describe "mention_authors/1" do
    defp mention_space! do
      {:ok, space} =
        Platform.Chat.create_space(%{
          name: "Authors",
          slug: "authors-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      space
    end

    defp author!(space, type, name, avatar_url \\ nil) do
      {:ok, participant} =
        Platform.Chat.add_participant(space.id, %{
          participant_type: type,
          participant_id: Ecto.UUID.generate(),
          display_name: name,
          avatar_url: avatar_url,
          joined_at: DateTime.utc_now()
        })

      participant
    end

    defp message!(space, participant, content) do
      {:ok, message} =
        Platform.Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: content
        })

      message
    end

    test "returns a user author and an agent author, keyed by item id" do
      user = insert_user()
      space = mention_space!()
      person = author!(space, "user", "Pat Person", "https://example.test/pat.png")
      agent = author!(space, "agent", "Pixel")

      from_person = message!(space, person, "hi @you")
      from_agent = message!(space, agent, "hello @you")

      {:ok, person_row} = Inbox.emit(valid_attrs(user, %{source_id: from_person.id}))
      {:ok, agent_row} = Inbox.emit(valid_attrs(user, %{source_id: from_agent.id}))

      authors = Inbox.mention_authors([person_row, agent_row])

      assert authors == %{
               person_row.id => %{
                 name: "Pat Person",
                 avatar_url: "https://example.test/pat.png",
                 agent?: false
               },
               agent_row.id => %{name: "Pixel", avatar_url: nil, agent?: true}
             }
    end

    test "omits a deleted message, a missing message and a non-mention row" do
      user = insert_user()
      space = mention_space!()
      person = author!(space, "user", "Pat Person")

      live = message!(space, person, "still here")
      gone = message!(space, person, "deleted later")
      {:ok, _} = Platform.Chat.delete_message(gone)

      {:ok, live_row} = Inbox.emit(valid_attrs(user, %{source_id: live.id}))
      {:ok, gone_row} = Inbox.emit(valid_attrs(user, %{source_id: gone.id}))
      {:ok, missing_row} = Inbox.emit(valid_attrs(user, %{source_id: Ecto.UUID.generate()}))

      # Same message as `live_row`, but not a mention: the kind gates the lookup.
      {:ok, other_kind} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "meeting_invited",
            source_type: "meeting",
            source_id: Ecto.UUID.generate()
          })
        )

      authors = Inbox.mention_authors([live_row, gone_row, missing_row, other_kind])

      # Positive control first: the lookup can hit in this fixture.
      assert Map.keys(authors) == [live_row.id]
      refute Map.has_key?(authors, gone_row.id)
      refute Map.has_key?(authors, missing_row.id)
      refute Map.has_key?(authors, other_kind.id)
    end

    test "[] gives %{}" do
      assert Inbox.mention_authors([]) == %{}
    end
  end

  describe "source_titles/1" do
    test "maps task and meeting rows to their source's title; mentions get none" do
      user = insert_user()

      {:ok, task} =
        Platform.Tasks.create_task(%{project_id: project!().id, title: "Ship the inbox"})

      {:ok, meeting} =
        Platform.Meetings.create_meeting(%{project_id: project!().id, name: "Design sync"})

      {:ok, task_row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "task_plan_review",
            source_type: "task",
            source_id: task.id,
            title: "Plan ready for review: Ship the inbox"
          })
        )

      {:ok, meeting_row} =
        Inbox.emit(
          valid_attrs(user, %{
            kind: "meeting_invited",
            source_type: "meeting",
            source_id: meeting.id,
            title: "Invited"
          })
        )

      {:ok, mention_row} = Inbox.emit(valid_attrs(user))

      assert Inbox.source_titles([task_row, meeting_row, mention_row]) == %{
               task_row.id => "Ship the inbox",
               meeting_row.id => "Design sync"
             }

      assert Inbox.source_titles([]) == %{}
    end
  end

  # ── Task 01a1694a stage 2: the meeting briefing row ───────────────────────

  describe "upsert_meeting_briefing_item/3 and reconcile_for_user/1 — meeting_briefing (ADR 0049)" do
    alias Platform.Meetings.Meeting
    alias Platform.Meetings.MeetingBriefing
    alias Platform.Meetings.MeetingBriefings

    defp ended_meeting!(ended_at) do
      n = System.unique_integer([:positive])
      {:ok, project} = Platform.Tasks.create_project(%{name: "MB Inbox #{n}"})

      {:ok, meeting} =
        Platform.Meetings.create_meeting(%{project_id: project.id, name: "MB #{n}"})

      {:ok, live} =
        meeting
        |> Meeting.status_changeset("live", %{started_at: DateTime.add(ended_at, -3600, :second)})
        |> Repo.update()

      {:ok, ended} =
        live |> Meeting.status_changeset("ended", %{ended_at: ended_at}) |> Repo.update()

      ended
    end

    defp meeting_briefing_row!(user, ended_at) do
      meeting = ended_meeting!(ended_at)

      briefing =
        Repo.insert!(%MeetingBriefing{meeting_id: meeting.id, attendee_user_ids: [user.id]})

      {:ok, item, :created} =
        Inbox.upsert_meeting_briefing_item(briefing, user.id, %{
          title: meeting.name,
          body: "1 item",
          url: "/inbox/meeting/" <> meeting.id
        })

      {briefing, item}
    end

    defp ttl_days, do: Platform.Memory.Insight.default_ttl_days()

    defp live_row?(item), do: is_nil(Repo.get!(Item, item.id).dismissed_at)

    test "one row per attendee: a second upsert updates, and re-lists only when new_items?" do
      user = insert_user()
      {briefing, item} = meeting_briefing_row!(user, DateTime.utc_now())

      assert item.kind == "meeting_briefing"
      assert item.source_type == "meeting_briefing"
      assert item.source_id == briefing.id

      {:ok, _} = Inbox.mark_dismissed(item.id, user.id)

      assert {:ok, _, :updated} =
               Inbox.upsert_meeting_briefing_item(briefing, user.id, %{body: "2 items"})

      refute live_row?(item), "a refresh that added nothing must not re-list the row"

      assert {:ok, _, :updated} =
               Inbox.upsert_meeting_briefing_item(briefing, user.id, %{new_items?: true})

      assert live_row?(item)

      assert Repo.aggregate(
               from(i in Item, where: i.user_id == ^user.id and i.kind == "meeting_briefing"),
               :count
             ) == 1
    end

    test "a meeting that ended recently is NOT stale (control); one past the TTL is" do
      user = insert_user()
      {_fresh, fresh_item} = meeting_briefing_row!(user, DateTime.utc_now())

      {_old, old_item} =
        meeting_briefing_row!(user, DateTime.add(DateTime.utc_now(), -(ttl_days() + 1), :day))

      :ok = Inbox.reconcile_for_user(user.id)

      assert live_row?(fresh_item)
      refute live_row?(old_item)
    end

    test "a missing briefing row is not confirmation: the Inbox row stays" do
      user = insert_user()

      {:ok, item} =
        Inbox.emit(%{
          user_id: user.id,
          kind: "meeting_briefing",
          source_type: "meeting_briefing",
          source_id: Ecto.UUID.generate(),
          title: "Gone meeting",
          url: "/inbox/meeting/x"
        })

      :ok = Inbox.reconcile_for_user(user.id)
      assert live_row?(item)
      refute MeetingBriefings.inbox_row_stale?(item.source_id)
      refute MeetingBriefings.inbox_row_stale?("not-a-uuid")
    end

    test "the TTL edge: exactly the TTL is not stale, one second past it is" do
      ended_at = ~U[2026-10-01 12:00:00.000000Z]
      meeting = ended_meeting!(ended_at)
      briefing = Repo.insert!(%MeetingBriefing{meeting_id: meeting.id})
      edge = DateTime.add(ended_at, ttl_days() * 86_400, :second)

      refute MeetingBriefings.inbox_row_stale?(briefing.id, now: edge)
      assert MeetingBriefings.inbox_row_stale?(briefing.id, now: DateTime.add(edge, 1, :second))
    end

    test "meeting_briefing is listed on open but is not a core (Mobile approval) action kind" do
      assert "meeting_briefing" in Inbox.action_kinds()
      refute "meeting_briefing" in Inbox.core_action_kinds()
      refute "meeting_briefing" in Platform.Mobile.AppEntities.approval_kinds()
    end
  end
end

defmodule Platform.InboxPushTest do
  @moduledoc """
  Task 01a10882 stage 2: `Inbox.emit/1` pushes the approval kinds.

  A `task_plan_review` or `review_request_pending` row fires exactly ONE
  `fan_out_to_user/2` with the one notification model. A `chat_mention` row
  fires NONE: `AttentionRouter` already pushes every mention, so a push from
  its inbox row would double-notify. Push is observed through a Recorder
  double injected via `:notifications_module` (the real `fan_out_to_user/3`
  short-circuits in :test env); `async: false` because that is app env.
  """
  use Platform.DataCase, async: false

  alias Platform.Inbox
  alias Platform.Push.Notification
  alias Platform.Repo

  defmodule Recorder do
    @moduledoc "Records `fan_out_to_user/3` as `{:notif, user_id, payload}`."
    def install(pid), do: :persistent_term.put({__MODULE__, :owner}, pid)

    def fan_out_to_user(user_id, payload, _opts \\ []) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        nil -> :ok
        owner -> send(owner, {:notif, user_id, payload})
      end

      :ok
    end
  end

  setup do
    Application.put_env(:platform, :notifications_module, Recorder)
    Recorder.install(self())

    on_exit(fn ->
      Application.delete_env(:platform, :notifications_module)
      :persistent_term.erase({Recorder, :owner})
    end)

    :ok
  end

  defp insert_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Push User #{n}",
      email: "inbox-push-#{n}@example.com",
      oidc_sub: "sub-inbox-push-#{n}"
    })
  end

  defp emit!(user, kind, source_type \\ "task") do
    {:ok, item} =
      Inbox.emit(%{
        user_id: user.id,
        kind: kind,
        source_type: source_type,
        source_id: Ecto.UUID.generate(),
        title: "Label: Ship the iOS app",
        body: "body",
        url: "/tasks/x"
      })

    item
  end

  test "a task_plan_review emit fires exactly one fan_out with the plan notification" do
    user = insert_user()
    item = emit!(user, "task_plan_review")

    assert_received {:notif, user_id, %Notification{} = n}
    assert user_id == user.id
    assert n.kind == "task_plan_review"
    assert n.title == "Plan ready to approve"
    assert n.inbox_item_id == item.id
    refute_received {:notif, _, _}
  end

  test "a review_request_pending emit fires exactly one fan_out" do
    user = insert_user()
    emit!(user, "review_request_pending", "task_review")

    assert_received {:notif, _,
                     %Notification{kind: "review_request_pending", title: "Review requested"}}

    refute_received {:notif, _, _}
  end

  test "a chat_mention emit fires no fan_out (the attention router already pushes it)" do
    user = insert_user()
    emit!(user, "chat_mention", "chat_message")

    refute_received {:notif, _, _}
  end

  test "other kinds fire no fan_out from emit" do
    user = insert_user()
    emit!(user, "meeting_invited", "meeting")
    emit!(user, "task_sponsor_assigned")

    refute_received {:notif, _, _}
  end

  test "a failed emit fires no fan_out" do
    user = insert_user()

    assert {:error, _} =
             Inbox.emit(%{user_id: user.id, kind: "task_plan_review", source_type: "task"})

    refute_received {:notif, _, _}
  end

  test "push_kinds excludes chat_mention" do
    assert Inbox.push_kinds() == ~w(task_plan_review review_request_pending)
  end

  describe "briefing_summary/1 (task 01a161f9)" do
    test "nothing open reads all done, whatever the total" do
      assert Inbox.briefing_summary(%{total: 6, open: 0, calls: 0}) ==
               "All done · nothing waiting"
    end

    test "otherwise it is briefing_summary/2 of total and calls" do
      assert Inbox.briefing_summary(%{total: 12, open: 3, calls: 3}) ==
               "12 items · 3 need your call"

      assert Inbox.briefing_summary(%{total: 5, open: 4, calls: 0}) == "5 items · FYI only"

      assert Inbox.briefing_summary(%{total: 2, open: 1, calls: 1}) ==
               "2 items · 1 needs your call"
    end
  end
end
