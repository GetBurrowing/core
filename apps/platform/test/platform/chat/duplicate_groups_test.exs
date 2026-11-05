defmodule Platform.Chat.DuplicateGroupsTest do
  @moduledoc """
  `Platform.Chat.DuplicateGroups` (task 01a1acea, stage 2): report lists
  live unnamed groups with equal member sets, apply folds each set into the
  keeper and archives the rest, a second apply changes nothing.

  Duplicates are seeded by direct insert (`Space.changeset` +
  `Chat.add_participant/2`), because since stage 1
  `create_group_conversation/3` refuses to create them.

  The `describe "advisory lock"` block runs outside the SQL sandbox
  (`Sandbox.unboxed_run/2`) for the reason stage 1's lock tests give: in the
  sandbox every process shares one connection, so no lock can block. It
  commits its fixtures and deletes them, and the audit rows the participant
  and archive telemetry wrote for them, in `on_exit`.

  Mutation checks (run when the stage shipped):
    * deleting the `pg_advisory_xact_lock` line from `merge_set/1` fails
      "apply waits while another connection holds the member-set lock";
    * dropping the `participant_id` remap in `merge_loser/3` fails "apply
      folds the loser into the keeper";
    * letting named groups into `candidate_query/0` fails "a named group and
      a promoted channel with the same members are untouched".
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.DuplicateGroups

  alias Platform.Chat.{
    Attachment,
    Canvas,
    Message,
    Participant,
    Pin,
    Reaction,
    Space,
    Thread
  }

  alias Platform.Repo

  @t0 ~U[2026-01-01 10:00:00.000000Z]

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "dup-groups-#{n}@example.com",
      name: "Dev #{label} #{n}",
      oidc_sub: "oidc-dup-groups-#{n}"
    })
    |> Repo.insert!()
  end

  defp seed_group!(users, attrs \\ %{}) do
    [creator | _] = users

    space =
      %Space{}
      |> Space.changeset(
        Map.merge(%{kind: "group", is_direct: false, created_by: creator.id}, attrs)
      )
      |> Repo.insert!()

    for user <- users do
      {:ok, _} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })
    end

    space
  end

  defp participant!(space, user) do
    [p] =
      Repo.all(
        from(p in Participant,
          where:
            p.space_id == ^space.id and p.participant_type == "user" and
              p.participant_id == ^user.id
        )
      )

    p
  end

  defp message!(space, user, seconds, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Message{
          space_id: space.id,
          participant_id: participant!(space, user).id,
          content_type: "text",
          content: "m#{seconds}",
          inserted_at: DateTime.add(@t0, seconds, :second)
        },
        attrs
      )
    )
  end

  # Two duplicate groups for {a, b, c}. A is older and gets the reaction,
  # pin, attachment, thread and canvas; B has the latest message (keeper).
  defp seed_pair!(users) do
    [a, b, _c] = users
    group_a = seed_group!(users)
    group_b = seed_group!(users)

    a1 = message!(group_a, a, 0)
    b1 = message!(group_b, b, 10)
    a2 = message!(group_a, b, 20)
    b2 = message!(group_b, a, 30)

    reaction =
      Repo.insert!(%Reaction{
        message_id: a1.id,
        participant_id: participant!(group_a, b).id,
        emoji: "+1"
      })

    pin =
      Repo.insert!(%Pin{
        space_id: group_a.id,
        message_id: a2.id,
        pinned_by: participant!(group_a, a).id
      })

    attachment =
      Repo.insert!(%Attachment{
        space_id: group_a.id,
        message_id: a1.id,
        filename: "notes.txt",
        content_type: "text/plain",
        byte_size: 5,
        storage_key: "dup-groups/#{System.unique_integer([:positive])}"
      })

    thread = Repo.insert!(%Thread{space_id: group_a.id, parent_message_id: a1.id})
    a3 = message!(group_a, a, 25, %{thread_id: thread.id})

    canvas =
      Repo.insert!(%Canvas{
        space_id: group_a.id,
        created_by: participant!(group_a, a).id,
        title: "plan"
      })

    a4 = message!(group_a, b, 5, %{canvas_id: canvas.id})

    %{
      group_a: group_a,
      group_b: group_b,
      messages: [a1, a4, b1, a2, a3, b2],
      reaction: reaction,
      pin: pin,
      attachment: attachment,
      thread: thread,
      canvas: canvas
    }
  end

  # Every row the merge could touch, for the fixture spaces.
  defp snapshot(space_ids) do
    message_ids = Repo.all(from(m in Message, where: m.space_id in ^space_ids, select: m.id))

    %{
      spaces:
        Repo.all(
          from(s in Space,
            where: s.id in ^space_ids,
            order_by: s.id,
            select: {s.id, s.kind, s.name, s.archived_at, s.updated_at}
          )
        ),
      participants:
        Repo.all(
          from(p in Participant,
            where: p.space_id in ^space_ids,
            order_by: p.id,
            select:
              {p.id, p.space_id, p.participant_type, p.participant_id, p.display_name,
               p.last_read_message_id}
          )
        ),
      messages:
        Repo.all(
          from(m in Message,
            where: m.space_id in ^space_ids,
            order_by: m.id,
            select: {m.id, m.space_id, m.participant_id, m.thread_id, m.canvas_id}
          )
        ),
      reactions:
        Repo.all(
          from(r in Reaction,
            where: r.message_id in ^message_ids,
            order_by: r.id,
            select: {r.id, r.message_id, r.participant_id}
          )
        ),
      pins:
        Repo.all(
          from(p in Pin,
            where: p.space_id in ^space_ids,
            order_by: p.id,
            select: {p.id, p.space_id, p.pinned_by}
          )
        ),
      attachments:
        Repo.all(
          from(a in Attachment,
            where: a.space_id in ^space_ids,
            order_by: a.id,
            select: {a.id, a.space_id, a.updated_at}
          )
        ),
      threads:
        Repo.all(
          from(t in Thread,
            where: t.space_id in ^space_ids,
            order_by: t.id,
            select: {t.id, t.space_id, t.updated_at}
          )
        ),
      canvases:
        Repo.all(
          from(c in Canvas,
            where: c.space_id in ^space_ids,
            order_by: c.id,
            select: {c.id, c.space_id, c.created_by, c.updated_at}
          )
        ),
      totals: totals()
    }
  end

  defp totals do
    for schema <- [Space, Participant, Message, Reaction, Pin, Attachment, Thread, Canvas],
        into: %{},
        do: {schema, Repo.aggregate(schema, :count)}
  end

  defp set_for(report, space_id) do
    Enum.find(report.sets, fn set -> space_id in [set.keeper_id | set.loser_ids] end)
  end

  defp reload(%Space{id: id}), do: hd(Repo.all(from(s in Space, where: s.id == ^id)))

  setup do
    users = for label <- ~w(Alice Bob Carol), do: user!(label)
    %{users: users}
  end

  # ── report/0 ─────────────────────────────────────────────────────────────

  describe "report/0" do
    test "lists the seeded pair with the latest-message group as keeper and writes nothing",
         %{users: users} do
      seeded = seed_pair!(users)
      ids = [seeded.group_a.id, seeded.group_b.id]
      before = snapshot(ids)

      report = DuplicateGroups.report()
      set = set_for(report, seeded.group_a.id)

      assert set.keeper_id == seeded.group_b.id
      assert set.loser_ids == [seeded.group_a.id]
      assert set.size == 3
      assert set.key == Chat.group_member_set_lock_key(for u <- users, do: {"user", u.id})

      assert [%{id: keeper_id, message_count: 2}, %{id: loser_id, message_count: 4}] =
               set.spaces

      assert keeper_id == seeded.group_b.id
      assert loser_id == seeded.group_a.id
      assert report.total_sets >= 1

      assert snapshot(ids) == before
    end

    test "a single group, or groups with different members, are not a duplicate set",
         %{users: [a, b, c] = users} do
      only = seed_group!(users)
      smaller = seed_group!([a, b, user!("Dan")])
      _ = c

      report = DuplicateGroups.report()
      assert set_for(report, only.id) == nil
      assert set_for(report, smaller.id) == nil
    end
  end

  # ── apply/0 ──────────────────────────────────────────────────────────────

  describe "apply/0" do
    test "apply folds the loser into the keeper", %{users: users} do
      seeded = seed_pair!(users)
      %{group_a: loser, group_b: keeper} = seeded
      message_count = Repo.aggregate(Message, :count)

      result = DuplicateGroups.apply()
      merged = Enum.find(result.sets, &(&1.keeper_id == keeper.id))

      assert merged.loser_ids == [loser.id]

      assert merged.counts.messages == 4
      assert merged.counts.reactions == 1
      assert merged.counts.pins == 1
      assert merged.counts.pins_skipped == 0
      assert merged.counts.attachments == 1
      assert merged.counts.threads == 1
      assert merged.counts.canvases == 1
      assert merged.counts.participants_created == 0
      assert merged.counts.archived == 1

      # One live group for the set; the loser archived, not deleted.
      assert DuplicateGroups.report() |> set_for(keeper.id) == nil
      assert reload(keeper).archived_at == nil
      assert %Space{archived_at: %DateTime{}} = reload(loser)
      assert Repo.aggregate(Message, :count) == message_count

      # Every message from both groups, in inserted_at order.
      keeper_messages =
        Repo.all(from(m in Message, where: m.space_id == ^keeper.id, order_by: m.inserted_at))

      expected = Enum.sort_by(seeded.messages, &DateTime.to_unix(&1.inserted_at, :microsecond))
      assert Enum.map(keeper_messages, & &1.id) == Enum.map(expected, & &1.id)
      assert Repo.aggregate(from(m in Message, where: m.space_id == ^loser.id), :count) == 0

      # Every moved message's participant_id belongs to the keeper, and is the
      # same person.
      keeper_participants =
        Repo.all(from(p in Participant, where: p.space_id == ^keeper.id))
        |> Map.new(&{&1.id, &1})

      original_authors =
        Map.new(seeded.messages, fn m ->
          [p] = Repo.all(from(p in Participant, where: p.id == ^m.participant_id))
          {m.id, p.participant_id}
        end)

      for m <- keeper_messages do
        assert %Participant{} = kp = Map.get(keeper_participants, m.participant_id),
               "message #{m.id} participant_id #{m.participant_id} is not a keeper participant"

        assert kp.participant_id == Map.fetch!(original_authors, m.id)
      end

      # Reaction, pin, attachment, thread and canvas sit on the keeper.
      [reaction] = Repo.all(from(r in Reaction, where: r.id == ^seeded.reaction.id))
      assert Map.has_key?(keeper_participants, reaction.participant_id)
      assert reaction.message_id in Enum.map(keeper_messages, & &1.id)

      [pin] = Repo.all(from(p in Pin, where: p.id == ^seeded.pin.id))
      assert pin.space_id == keeper.id
      assert Map.has_key?(keeper_participants, pin.pinned_by)

      [attachment] = Repo.all(from(a in Attachment, where: a.id == ^seeded.attachment.id))
      assert attachment.space_id == keeper.id

      [thread] = Repo.all(from(t in Thread, where: t.id == ^seeded.thread.id))
      assert thread.space_id == keeper.id

      [canvas] = Repo.all(from(c in Canvas, where: c.id == ^seeded.canvas.id))
      assert canvas.space_id == keeper.id
      assert Map.has_key?(keeper_participants, canvas.created_by)

      # The loser keeps its participant rows.
      assert Repo.aggregate(from(p in Participant, where: p.space_id == ^loser.id), :count) == 3
    end

    test "a second apply finds zero sets and changes no row", %{users: users} do
      seeded = seed_pair!(users)
      ids = [seeded.group_a.id, seeded.group_b.id]

      assert %{total_sets: n} = DuplicateGroups.apply()
      assert n >= 1
      before = snapshot(ids)

      assert %{total_sets: 0, sets: []} = DuplicateGroups.apply()
      assert DuplicateGroups.report().total_sets == 0
      assert snapshot(ids) == before
    end

    test "after apply, starting the same group returns the keeper", %{users: [a, b, c] = users} do
      seeded = seed_pair!(users)
      DuplicateGroups.apply()

      assert {:ok, %Space{id: id}} =
               Chat.create_group_conversation(b.id, [
                 %{type: "user", id: c.id},
                 %{type: "user", id: a.id}
               ])

      assert id == seeded.group_b.id
    end

    test "three duplicates merge into the one with the latest message", %{users: [a | _] = users} do
      g1 = seed_group!(users)
      g2 = seed_group!(users)
      g3 = seed_group!(users)
      message!(g1, a, 0)
      message!(g2, a, 50)
      message!(g3, a, 10)

      result = DuplicateGroups.apply()
      merged = Enum.find(result.sets, &(&1.keeper_id == g2.id))
      assert Enum.sort(merged.loser_ids) == Enum.sort([g1.id, g3.id])
      assert merged.counts.messages == 2
      assert merged.counts.archived == 2
      assert reload(g2).archived_at == nil
      assert reload(g1).archived_at
      assert reload(g3).archived_at
    end

    test "with no messages anywhere the later space is the keeper", %{users: users} do
      older = seed_group!(users)
      newer = seed_group!(users)

      Repo.update_all(from(s in Space, where: s.id == ^older.id),
        set: [inserted_at: DateTime.add(@t0, -3600, :second)]
      )

      set = DuplicateGroups.report() |> set_for(older.id)
      assert set.keeper_id == newer.id
      assert set.loser_ids == [older.id]
    end

    test "a pin on a message the keeper already pins is skipped and counted", %{users: users} do
      seeded = seed_pair!(users)
      [a | _] = users

      # The keeper already carries a pin for the loser's pinned message.
      Repo.insert!(%Pin{
        space_id: seeded.group_b.id,
        message_id: seeded.pin.message_id,
        pinned_by: participant!(seeded.group_b, a).id
      })

      merged =
        DuplicateGroups.apply().sets |> Enum.find(&(&1.keeper_id == seeded.group_b.id))

      assert merged.counts.pins == 0
      assert merged.counts.pins_skipped == 1
      [pin] = Repo.all(from(p in Pin, where: p.id == ^seeded.pin.id))
      assert pin.space_id == seeded.group_a.id
    end

    test "a loser-only system participant gets a keeper row so its messages can move",
         %{users: [a | _] = users} do
      loser = seed_group!(users)
      keeper = seed_group!(users)
      message!(keeper, a, 100)
      system_id = Ecto.UUID.generate()

      {:ok, sys} =
        Chat.add_participant(loser.id, %{
          participant_type: "system",
          participant_id: system_id,
          display_name: "Dev System",
          joined_at: DateTime.utc_now()
        })

      moved =
        Repo.insert!(%Message{
          space_id: loser.id,
          participant_id: sys.id,
          content_type: "text",
          content: "notice",
          inserted_at: @t0
        })

      merged = DuplicateGroups.apply().sets |> Enum.find(&(&1.keeper_id == keeper.id))
      assert merged.counts.participants_created == 1

      [m] = Repo.all(from(m in Message, where: m.id == ^moved.id))
      [p] = Repo.all(from(p in Participant, where: p.id == ^m.participant_id))

      assert {p.space_id, p.participant_type, p.participant_id} ==
               {keeper.id, "system", system_id}
    end

    test "a named group and a promoted channel with the same members are untouched",
         %{users: users} do
      named = seed_group!(users, %{name: "launch"})
      promoted = seed_group!(users)

      n = System.unique_integer([:positive])

      {:ok, promoted} =
        Chat.promote_to_channel(promoted, %{name: "promoted-#{n}", slug: "promoted-#{n}"})

      unnamed_old = seed_group!(users)
      unnamed_new = seed_group!(users)

      Repo.update_all(from(s in Space, where: s.id in ^[named.id, promoted.id]),
        set: [inserted_at: DateTime.add(@t0, -3600, :second)]
      )

      ids = [named.id, promoted.id]
      before = snapshot(ids)

      report = DuplicateGroups.report()
      assert set_for(report, named.id) == nil
      assert set_for(report, promoted.id) == nil
      assert %{keeper_id: keeper_id} = set_for(report, unnamed_old.id)
      assert keeper_id == unnamed_new.id

      result = DuplicateGroups.apply()

      for set <- result.sets do
        refute named.id in [set.keeper_id | set.loser_ids]
        refute promoted.id in [set.keeper_id | set.loser_ids]
      end

      assert Enum.find(result.sets, &(&1.keeper_id == unnamed_new.id))
      assert Map.delete(snapshot(ids), :totals) == Map.delete(before, :totals)
      assert %Space{name: "launch", kind: "group", archived_at: nil} = reload(named)
      assert %Space{kind: "channel", archived_at: nil} = reload(promoted)
    end
  end

  # ── Advisory lock ────────────────────────────────────────────────────────

  describe "advisory lock" do
    setup do
      {users, user_ids} =
        unboxed(fn ->
          users = for label <- ~w(Alice Bob Carol), do: user!(label)
          {users, Enum.map(users, & &1.id)}
        end)

      on_exit(fn ->
        unboxed(fn ->
          space_ids =
            Repo.all(from(s in Space, where: s.created_by in ^user_ids, select: s.id))

          Repo.delete_all(from(m in Message, where: m.space_id in ^space_ids))
          Repo.delete_all(from(p in Participant, where: p.space_id in ^space_ids))
          Repo.delete_all(from(s in Space, where: s.id in ^space_ids))

          # Participant telemetry (resource_type "chat") and the archive's
          # lifecycle telemetry (resource_type "chat_space") commit audit
          # rows outside the sandbox too; Platform.AuditTest counts rows.
          Repo.delete_all(
            from(e in Platform.Audit.Event,
              where: e.resource_type in ["chat", "chat_space"] and e.resource_id in ^space_ids
            )
          )

          Repo.delete_all(from(u in User, where: u.id in ^user_ids))
        end)
      end)

      %{users: users}
    end

    # A fresh process: the test process is already allowed on the sandbox
    # owner, so `unboxed_run/2` from it would silently run inside it.
    defp unboxed(fun) do
      Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
      |> Task.await(30_000)
    end

    defp unboxed_task(fun), do: Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)

    test "apply waits while another connection holds the member-set lock", %{users: users} do
      parent = self()
      [a | _] = users

      {loser, keeper} =
        unboxed(fn ->
          loser = seed_group!(users)
          keeper = seed_group!(users)
          message!(keeper, a, 0)
          {loser, keeper}
        end)

      key = Chat.group_member_set_lock_key(for u <- users, do: {"user", u.id})

      holder =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
            send(parent, :locked)

            receive do
              :release -> :ok
            after
              10_000 -> :timeout
            end
          end)
        end)

      assert_receive :locked, 5_000

      merger = unboxed_task(fn -> DuplicateGroups.apply() end)

      assert Task.yield(merger, 300) == nil,
             "DuplicateGroups.apply/0 returned while the member-set lock was held"

      assert unboxed(fn -> reload(loser).archived_at end) == nil

      send(holder.pid, :release)
      assert {:ok, :ok} = Task.await(holder, 5_000)

      result = Task.await(merger, 10_000)
      assert Enum.find(result.sets, &(&1.keeper_id == keeper.id and &1.loser_ids == [loser.id]))
      assert unboxed(fn -> reload(loser).archived_at end)
    end

    test "a start racing a merge lands on the keeper and leaves one live group",
         %{users: [a, b, c] = users} do
      parent = self()

      {loser, keeper} =
        unboxed(fn ->
          loser = seed_group!(users)
          keeper = seed_group!(users)
          message!(keeper, a, 0)
          {loser, keeper}
        end)

      tasks =
        for job <- [
              fn -> DuplicateGroups.apply() end,
              fn ->
                Chat.create_group_conversation(c.id, [
                  %{type: "user", id: a.id},
                  %{type: "user", id: b.id}
                ])
              end
            ] do
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> job.()
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
      Enum.each(tasks, &send(&1.pid, :go))

      [_apply_result, start_result] = Enum.map(tasks, &Task.await(&1, 10_000))
      assert {:ok, %Space{id: started_id}} = start_result
      assert started_id == keeper.id

      live =
        unboxed(fn ->
          Repo.all(
            from(s in Space,
              where: s.id in ^[loser.id, keeper.id] and is_nil(s.archived_at),
              select: s.id
            )
          )
        end)

      assert live == [keeper.id]
    end
  end
end
