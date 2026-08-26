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
        body: "Rowan mentioned you",
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
          title: "Rowan invited you to Weekly sync",
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
    # HISTORY — the two tests below asserted the OPPOSITE until task `01a00108`
    # stage 4, and the inversion is intentional, not a broken guard.
    #
    # They were written for #589/#592, where the badge and the list disagreed
    # about read rows. That invariant — badge and list agree — is NOT retired
    # and is still what these assert. What changed underneath it is the
    # definition of a cleared row: `unread_scope/1` now keys on `dismissed_at`
    # alone, so reading an item no longer removes it from either side. The
    # tests had to move because they pinned the OLD definition (count decrements
    # on read) as well as the invariant. Do not read the diff as #589/#592
    # being reopened; a test asserting badge == rows is directly below.

    test "counts non-dismissed rows — reading one does NOT decrement it" do
      user = insert_user()

      assert Inbox.unread_count(user.id) == 0

      {:ok, a} = Inbox.emit(valid_attrs(user, %{title: "A"}))
      {:ok, _b} = Inbox.emit(valid_attrs(user, %{title: "B"}))
      {:ok, c} = Inbox.emit(valid_attrs(user, %{title: "C"}))

      assert Inbox.unread_count(user.id) == 3

      # Opening an item is not doing it. The row stays on the list, so it stays
      # in the badge — the badge and the list still agree, they just agree on a
      # larger set than they used to.
      {:ok, _} = Inbox.mark_read(a.id, user.id)
      assert Inbox.unread_count(user.id) == 3

      # Dismissal is now the only thing that decrements it.
      {:ok, _} = Inbox.mark_dismissed(c.id, user.id)
      assert Inbox.unread_count(user.id) == 2

      # Including dismissing the row that was already read.
      {:ok, _} = Inbox.mark_dismissed(a.id, user.id)
      assert Inbox.unread_count(user.id) == 1
    end

    test "badge equals the list the Inbox surface renders, read rows included" do
      user = insert_user()

      {:ok, _a} = Inbox.emit(valid_attrs(user, %{title: "A"}))
      {:ok, b} = Inbox.emit(valid_attrs(user, %{title: "B"}))
      {:ok, c} = Inbox.emit(valid_attrs(user, %{title: "C"}))

      # Read one, dismiss one — leaving two rows on the surface, one of them read.
      {:ok, _} = Inbox.mark_read(b.id, user.id)
      {:ok, _} = Inbox.mark_dismissed(c.id, user.id)

      # The surface renders `unread_scope/1` (see `InboxLive.load_items/1`) —
      # the same query `unread_count/1` aggregates, which is the whole point.
      rendered = user.id |> Inbox.unread_scope() |> Repo.all()

      assert length(rendered) == 2
      assert b.id in Enum.map(rendered, & &1.id)
      assert Inbox.unread_count(user.id) == length(rendered)
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

      # Both are on the surface, so the button's count is 2, not 1.
      assert Inbox.unread_count(user.id) == 2

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
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
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
          parent_org_id: Platform.TenancyFixtures.fabrikam_org_id()
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

    test "the internal scope is `unread_scope/1` verbatim — dismissed rows drop, read rows do not" do
      # Task `01a00108` stage 4: this used to assert that reading dropped a row
      # here too. The property under test is unchanged — this scope is
      # `unread_scope/1` verbatim for an internal viewer — so it inverts exactly
      # as `unread_scope/1` did, which is the point of composing on it.
      user = insert_user()
      %{sponsor: sponsor, mention: mention} = mixed_rows!(user)

      {:ok, _} = Inbox.mark_read(mention.id, user.id)
      assert Inbox.reachable_unread_count(user.id) == 2
      assert Inbox.reachable_unread_count(user.id) == Inbox.unread_count(user.id)

      {:ok, _} = Inbox.mark_dismissed(sponsor.id, user.id)
      assert Inbox.reachable_unread_count(user.id) == 1

      {:ok, _} = Inbox.mark_dismissed(mention.id, user.id)
      assert Inbox.reachable_unread_count(user.id) == 0
    end

    test "an external user's reachable count drops to 0 when the mention is DISMISSED, not read" do
      user = external_user!()
      %{mention: mention} = mixed_rows!(user)

      assert Inbox.reachable_unread_count(user.id) == 1

      # Reading it leaves it standing (stage 4: reading is not clearing).
      {:ok, _} = Inbox.mark_read(mention.id, user.id)
      assert Inbox.reachable_unread_count(user.id) == 1

      {:ok, _} = Inbox.mark_dismissed(mention.id, user.id)

      # Nothing reachable left → 0 → no badge at all, not a zero and not a
      # dot. The unreachable sponsor row is still live and still uncounted.
      assert Inbox.reachable_unread_count(user.id) == 0
      assert Inbox.unread_count(user.id) == 1
    end
  end
end
