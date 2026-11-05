defmodule Platform.Chat.GroupConversationDedupeTest do
  @moduledoc """
  `Chat.create_group_conversation/3` reopens the live unnamed group whose
  current user + agent participant set equals `{initiator} ∪ specs`, instead
  of inserting a second group for the same people (task 01a1acea, stage 1).

  The sandboxed tests cover matching. The `describe "advisory lock"` block
  runs OUTSIDE the SQL sandbox (`Sandbox.unboxed_run/2`), because inside it
  every process shares one connection and one transaction, so a lock can
  never block anybody there and a race test would pass without the lock. It
  commits its fixtures and deletes them, and the audit rows the participant
  telemetry wrote for them, in `on_exit`.

  Mutation check (run when the stage shipped): deleting the
  `pg_advisory_xact_lock` line from `find_or_create_group_conversation/2`
  fails "a create waits while another connection holds the member-set lock".
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.{Org, OrgMembership}

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "group-dedupe-#{n}@example.com",
      name: "Dev #{label} #{n}",
      oidc_sub: "oidc-group-dedupe-#{n}"
    })
    |> Repo.insert!()
  end

  defp agent!(label) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "group-dedupe-#{n}", name: "Dev #{label} #{n}", status: "active"})
  end

  defp u(user), do: %{type: "user", id: user.id}

  defp group_rows_for(user_ids) do
    from(s in Space,
      join: p in Participant,
      on: p.space_id == s.id,
      where: s.kind == "group" and p.participant_type == "user" and p.participant_id in ^user_ids,
      group_by: s.id,
      having: count(p.id) == ^length(user_ids),
      select: s.id
    )
    |> Repo.all()
  end

  defp member_set(space_id) do
    from(p in Participant,
      where: p.space_id == ^space_id and p.participant_type in ["user", "agent"],
      select: {p.participant_type, p.participant_id}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp seed_group!(creator, others) do
    space =
      %Space{}
      |> Space.changeset(%{kind: "group", is_direct: false, created_by: creator.id})
      |> Repo.insert!()

    for user <- [creator | others] do
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

  defp message!(space, user, inserted_at) do
    participant =
      Repo.get_by!(Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      )

    Repo.insert!(%Message{
      space_id: space.id,
      participant_id: participant.id,
      content_type: "text",
      content: "hello",
      inserted_at: inserted_at
    })
  end

  defp counts, do: {Repo.aggregate(Space, :count), Repo.aggregate(Participant, :count)}

  # ── Matching ─────────────────────────────────────────────────────────────

  describe "same member set" do
    test "A with [B, C] and B with [C, A] land in the same space, one group row" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")

      assert {:ok, first} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      assert first.kind == "group"
      assert {:ok, second} = Chat.create_group_conversation(b.id, [u(c), u(a)])

      assert second.id == first.id
      assert group_rows_for([a.id, b.id, c.id]) == [first.id]
      assert MapSet.size(member_set(first.id)) == 3
    end

    test "string keys, atom keys and a duplicated spec are the same set" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")

      {:ok, first} = Chat.create_group_conversation(a.id, [u(b), u(c)])

      before = counts()

      assert {:ok, again} =
               Chat.create_group_conversation(c.id, [
                 %{"type" => "user", "id" => b.id},
                 %{type: "user", id: a.id},
                 %{"type" => "user", "id" => b.id},
                 u(c)
               ])

      assert again.id == first.id
      assert counts() == before, "reopening must insert no space or participant rows"
    end

    test "a slug and a UUID for the same agent are the same set" do
      a = user!("Alice")
      b = user!("Bob")
      agent = agent!("Helper")

      {:ok, first} =
        Chat.create_group_conversation(a.id, [u(b), %{type: "agent", id: agent.slug}])

      {:ok, second} =
        Chat.create_group_conversation(b.id, [%{"type" => "agent", "id" => agent.id}, u(a)])

      assert second.id == first.id
    end

    test "the same people plus an agent is a different set" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")
      agent = agent!("Helper")

      {:ok, without} = Chat.create_group_conversation(a.id, [u(b), u(c)])

      {:ok, with_agent} =
        Chat.create_group_conversation(a.id, [u(b), u(c), %{type: "agent", id: agent.id}])

      refute with_agent.id == without.id

      {:ok, again} =
        Chat.create_group_conversation(b.id, [%{type: "agent", id: agent.id}, u(a), u(c)])

      assert again.id == with_agent.id
    end

    test "one other member after dedupe goes through the DM seam" do
      a = user!("Alice")
      b = user!("Bob")

      assert {:ok, dm} = Chat.create_group_conversation(a.id, [u(b), u(b), u(a)])
      assert dm.kind == "dm"
      assert {:ok, ^dm} = Chat.find_or_create_dm(a.id, "user", b.id)
    end

    test "a participant row of another type does not change the set" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")

      {:ok, first} = Chat.create_group_conversation(a.id, [u(b), u(c)])

      {:ok, _} =
        Chat.add_participant(first.id, %{
          participant_type: "system",
          participant_id: Ecto.UUID.generate(),
          display_name: "System",
          joined_at: DateTime.utc_now()
        })

      assert {:ok, again} = Chat.create_group_conversation(c.id, [u(a), u(b)])
      assert again.id == first.id
    end
  end

  describe "current participants decide the match" do
    test "after a member leaves, the remaining set matches and the old full set does not" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")
      d = user!("Dan")

      {:ok, group} = Chat.create_group_conversation(a.id, [u(b), u(c), u(d)])

      leaving =
        Repo.get_by!(Participant,
          space_id: group.id,
          participant_type: "user",
          participant_id: d.id
        )

      {:ok, _} = Chat.remove_participant(leaving)

      assert {:ok, same} = Chat.create_group_conversation(b.id, [u(a), u(c)])
      assert same.id == group.id

      assert {:ok, fresh} = Chat.create_group_conversation(a.id, [u(b), u(c), u(d)])
      refute fresh.id == group.id
      assert MapSet.size(member_set(fresh.id)) == 4
    end

    test "a group that gained a member does not match the smaller set" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")
      agent = agent!("Helper")

      {:ok, group} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      {:ok, _} = Chat.add_agent_participant(group.id, agent)

      assert {:ok, fresh} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      refute fresh.id == group.id
    end
  end

  describe "never matched" do
    test "a named group" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")

      {:ok, named} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      named = named |> Space.changeset(%{name: "launch"}) |> Repo.update!()

      assert {:ok, fresh} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      refute fresh.id == named.id

      reloaded = Repo.get!(Space, named.id)
      assert reloaded.name == "launch"
      assert is_nil(reloaded.archived_at)
      assert member_set(named.id) == MapSet.new(for x <- [a, b, c], do: {"user", x.id})
    end

    test "an archived group" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")

      {:ok, group} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      {:ok, _} = Chat.archive_space(group)

      assert {:ok, fresh} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      refute fresh.id == group.id
    end

    test "a group promoted to a channel" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")

      {:ok, group} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      n = System.unique_integer([:positive])

      {:ok, promoted} =
        Chat.promote_to_channel(group, %{name: "Promoted #{n}", slug: "promoted-#{n}"})

      assert {:ok, fresh} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      refute fresh.id == promoted.id
      assert fresh.kind == "group"
    end
  end

  describe "existing duplicates" do
    test "the group with the latest message wins over a newer empty one" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")

      older = seed_group!(a, [b, c])
      newer = seed_group!(b, [a, c])
      now = DateTime.utc_now()
      message!(older, a, now)
      message!(newer, b, DateTime.add(now, -60, :second))

      assert {:ok, picked} = Chat.create_group_conversation(c.id, [u(a), u(b)])
      assert picked.id == older.id
    end

    test "with no messages the later space wins" do
      a = user!("Alice")
      b = user!("Bob")
      c = user!("Carol")

      first = seed_group!(a, [b, c])

      second =
        seed_group!(a, [b, c])
        |> Ecto.Changeset.change(inserted_at: DateTime.add(first.inserted_at, 60, :second))
        |> Repo.update!()

      assert {:ok, picked} = Chat.create_group_conversation(a.id, [u(b), u(c)])
      assert picked.id == second.id
    end
  end

  describe "refusals" do
    test "a malformed id or unknown type is :invalid_participant and writes nothing" do
      a = user!("Alice")
      b = user!("Bob")
      before = counts()

      assert {:error, :invalid_participant} =
               Chat.create_group_conversation(a.id, [u(b), %{type: "user", id: "not-a-uuid"}])

      assert {:error, :invalid_participant} =
               Chat.create_group_conversation(a.id, [
                 u(b),
                 %{type: "bot", id: Ecto.UUID.generate()}
               ])

      assert {:error, :invalid_participant} =
               Chat.create_group_conversation(a.id, [u(b), %{type: "agent", id: 42}])

      assert {:error, :invalid_participant} = Chat.create_group_conversation(a.id, [u(b), :nope])
      assert {:error, :invalid_participant} = Chat.create_group_conversation(a.id, [])
      assert counts() == before
    end

    test "an external initiator outside the allowlist is refused before any lookup or write" do
      acme = Tenancy.get_org_by_slug!("acme")
      n = System.unique_integer([:positive])

      org_a =
        %Org{}
        |> Org.changeset(%{name: "Tenant #{n}", slug: "tenant_a_#{n}", parent_org_id: acme.id})
        |> Repo.insert!()

      org_b =
        %Org{}
        |> Org.changeset(%{name: "Tenant b#{n}", slug: "tenant_b_#{n}", parent_org_id: acme.id})
        |> Repo.insert!()

      ext = user!("External")
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org_a.id})
      Tenancy.allow_dm(ext, org_a)

      ok_member = user!("Member")
      bad_member = user!("Outsider")

      for {user, org} <- [{ok_member, org_a}, {bad_member, org_b}] do
        %OrgMembership{}
        |> OrgMembership.changeset(%{user_id: user.id, org_id: org.id, role: "member"})
        |> Repo.insert!()
      end

      # An existing group with exactly that set: the refusal must not reveal it.
      _existing = seed_group!(ext, [ok_member, bad_member])
      before = counts()

      assert {:error, :dm_not_allowed} =
               Chat.create_group_conversation(ext.id, [u(ok_member), u(bad_member)])

      assert counts() == before
    end
  end

  # ── Advisory lock (outside the sandbox) ──────────────────────────────────

  describe "advisory lock" do
    setup do
      # Committed fixtures: created on a real connection, deleted on exit.
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

          # The audit telemetry handler commits a `chat.participant.added` row
          # per seat outside the sandbox too; Platform.AuditTest counts rows.
          Repo.delete_all(
            from(e in Platform.Audit.Event,
              where: e.resource_type == "chat" and e.resource_id in ^space_ids
            )
          )

          Repo.delete_all(from(u in User, where: u.id in ^user_ids))
        end)
      end)

      [a, b, c] = users
      %{a: a, b: b, c: c, user_ids: user_ids}
    end

    # The key, recomputed here from the documented formula rather than read
    # from the code under test.
    defp lock_key(user_ids) do
      key =
        user_ids
        |> Enum.map(&"user:#{&1}")
        |> Enum.sort()
        |> Enum.join(",")

      "chat:group_member_set:" <> key
    end

    # A fresh process: the test process is already allowed on the sandbox
    # owner, so `unboxed_run/2` from it would silently run inside the sandbox.
    defp unboxed(fun) do
      Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)
      |> Task.await(30_000)
    end

    defp unboxed_task(fun), do: Task.async(fn -> Sandbox.unboxed_run(Repo, fun) end)

    test "a create waits while another connection holds the member-set lock", ctx do
      parent = self()
      key = lock_key(ctx.user_ids)

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

      creator =
        unboxed_task(fn -> Chat.create_group_conversation(ctx.a.id, [u(ctx.b), u(ctx.c)]) end)

      assert Task.yield(creator, 300) == nil,
             "create_group_conversation returned while the member-set lock was held"

      send(holder.pid, :release)
      assert {:ok, {:ok, :ok}} = {:ok, Task.await(holder, 5_000)}
      assert {:ok, %Space{kind: "group"}} = Task.await(creator, 5_000)
    end

    test "two concurrent starts for the same set return the same space", ctx do
      parent = self()

      starts = [
        {ctx.a, [u(ctx.b), u(ctx.c)]},
        {ctx.b, [u(ctx.c), u(ctx.a)]}
      ]

      tasks =
        for {initiator, specs} <- starts do
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> Chat.create_group_conversation(initiator.id, specs)
            end
          end)
        end

      pids =
        for _ <- tasks do
          assert_receive {:ready, pid}, 5_000
          pid
        end

      Enum.each(pids, &send(&1, :go))

      assert [{:ok, s1}, {:ok, s2}] = Enum.map(tasks, &Task.await(&1, 10_000))
      assert s1.id == s2.id

      assert unboxed(fn -> group_rows_for(ctx.user_ids) end) == [s1.id]
    end
  end
end
