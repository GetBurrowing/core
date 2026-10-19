defmodule Platform.Mobile.AppPeopleTest do
  @moduledoc """
  Task 01a111bb stage 1: the native app's people directory
  (`Platform.Mobile.AppPeople`).

  Every external case carries its positive control: the allow-listed person
  IS returned, so a refusal of the other one is a filter, not an empty list.
  """
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Mobile.AppPeople
  alias Platform.Repo

  defp agent!(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "people-agent-#{n}", name: name, status: "active"})
  end

  defp token, do: "Qz#{System.unique_integer([:positive])}"

  defp group!(members) do
    {:ok, space} = Chat.create_space(%{kind: "group"})

    participants =
      Map.new(members, fn
        {:agent, agent} -> {agent.id, add_agent!(space.id, agent.id)}
        user -> {user.id, add_user!(space.id, user.id)}
      end)

    {space, participants}
  end

  # Inserted directly so the test controls `inserted_at` and no send-seam
  # policy decides whether the row exists.
  defp message!(space_id, participant, at \\ DateTime.utc_now()) do
    Repo.insert!(%Message{
      space_id: space_id,
      participant_id: participant.id,
      content_type: "text",
      content: "x",
      inserted_at: at
    })
  end

  defp ids(rows), do: Enum.map(rows, & &1.id)

  describe "search (q given)" do
    test "finds humans and agents by name, never the caller, with no contact data" do
      t = token()
      me = create_user!(%{name: "#{t} Me"})
      dana = create_user!(%{name: "#{t} Dana"})
      bot = agent!("#{t} Bot")

      rows = AppPeople.list_people(me, q: t)

      assert ids(rows) == [bot.id, dana.id]
      refute me.id in ids(rows)

      for row <- rows do
        assert Map.keys(row) |> Enum.sort() == [:dm_space_id, :id, :kind, :name, :org_names]
      end

      assert %{kind: "user", name: name} = Enum.find(rows, &(&1.id == dana.id))
      assert name == dana.name
      assert %{kind: "agent"} = Enum.find(rows, &(&1.id == bot.id))
    end

    test "carries the person's org names and their existing DM with the caller" do
      t = token()
      org = Platform.Tenancy.get_org_by_slug!("globex")
      me = create_user!(%{name: "#{t} Me"})
      dana = create_user!(%{name: "#{t} Dana"})
      plain_member!(dana, org)
      {:ok, dm} = Chat.find_or_create_dm(me.id, "user", dana.id)

      [row] = AppPeople.list_people(me, q: "#{t} Dana")
      assert row.org_names == [org.name]
      assert row.dm_space_id == dm.id
    end

    test "limit is clamped" do
      t = token()
      me = create_user!(%{name: "Someone else"})
      for i <- 1..4, do: create_user!(%{name: "#{t} #{i}"})

      assert length(AppPeople.list_people(me, q: t, limit: "2")) == 2
      assert length(AppPeople.list_people(me, q: t, limit: "junk")) == 4
    end

    test "an external user finds the allow-listed person and not the other, and no agents" do
      world = external_world()
      t = token()
      {:ok, m} = Repo.update(Ecto.Changeset.change(world.m, name: "#{t} Allowed"))
      {:ok, n} = Repo.update(Ecto.Changeset.change(world.n, name: "#{t} Denied"))
      agent!("#{t} Bot")

      rows = AppPeople.list_people(world.ext, q: t)

      # Positive control: the allow-listed person IS returned.
      assert m.id in ids(rows)
      refute n.id in ids(rows)
      assert Enum.all?(rows, &(&1.kind == "user"))
    end
  end

  describe "recent collaborators (no q)" do
    test "people from DMs and groups the caller posted in, newest shared activity first" do
      me = create_user!()
      older = create_user!()
      newer = create_user!()
      bot = agent!("Recent Bot #{token()}")
      channel_mate = create_user!()

      {group, gp} = group!([me, older, {:agent, bot}])
      message!(group.id, gp[me.id], DateTime.add(DateTime.utc_now(), -3600, :second))

      {:ok, dm} = Chat.find_or_create_dm(me.id, "user", newer.id)
      me_in_dm = participant_pk!(dm.id, me.id)
      message!(dm.id, %{id: me_in_dm})

      # A channel is not a DM or a group: its members are not collaborators.
      channel = channel!()
      p_me = add_user!(channel.id, me.id)
      add_user!(channel.id, channel_mate.id)
      message!(channel.id, p_me)

      rows = AppPeople.list_people(me)

      assert ids(rows) |> Enum.take(1) == [newer.id]
      assert MapSet.new(ids(rows)) == MapSet.new([newer.id, older.id, bot.id])
      refute me.id in ids(rows)
      assert Enum.find(rows, &(&1.id == newer.id)).dm_space_id == dm.id
      assert Enum.find(rows, &(&1.id == bot.id)).kind == "agent"
    end

    test "a space where the caller has not posted in the last 30 days does not count" do
      me = create_user!()
      stale = create_user!()
      silent = create_user!()

      {old_group, op} = group!([me, stale])
      message!(old_group.id, op[me.id], DateTime.add(DateTime.utc_now(), -31 * 86_400, :second))

      # The caller never posted here; only the other person did.
      {quiet_group, qp} = group!([me, silent])
      message!(quiet_group.id, qp[silent.id])

      assert AppPeople.list_people(me) == []
    end

    test "caps at 20" do
      me = create_user!()
      others = for _ <- 1..22, do: create_user!()
      {group, gp} = group!([me | others])
      message!(group.id, gp[me.id])

      assert length(AppPeople.list_people(me)) == 20
    end

    test "goes through the same predicate: an external caller sees the allow-listed collaborator only" do
      world = external_world()
      bot = agent!("Ext Bot #{token()}")

      {group, gp} = group!([world.ext, world.m, world.n, {:agent, bot}])
      message!(group.id, gp[world.ext.id])

      rows = AppPeople.list_people(world.ext)

      # Positive control first.
      assert world.m.id in ids(rows)
      refute world.n.id in ids(rows)
      refute bot.id in ids(rows)
    end
  end

  describe "directory (scope: \"directory\", task 01a111bb stage 7)" do
    test "recent collaborators, space mates and org mates, with no shared space needed" do
      org = Platform.Tenancy.get_org_by_slug!("globex")
      me = create_user!(%{name: "Dir Me"})
      plain_member!(me, org)
      recent = create_user!(%{name: "Dir Recent"})
      mate = create_user!(%{name: "Dir Space Mate"})
      priya = create_user!(%{name: "Dir Priya"})
      plain_member!(priya, org)
      stranger = create_user!(%{name: "Dir Stranger"})
      bot = agent!("Dir Bot #{token()}")

      {group, gp} = group!([me, recent])
      message!(group.id, gp[me.id])
      channel = channel!()
      add_user!(channel.id, me.id)
      add_user!(channel.id, mate.id)

      rows = AppPeople.list_people(me, scope: "directory")
      row_ids = ids(rows)

      # Priya shares NO space with the caller: only the org puts her here.
      assert priya.id in row_ids
      assert recent.id in row_ids
      assert mate.id in row_ids
      assert bot.id in row_ids
      refute stranger.id in row_ids
      refute me.id in row_ids
      assert hd(row_ids) == recent.id, "recent collaborators lead"
      assert Enum.find(rows, &(&1.id == priya.id)).org_names == [org.name]

      # The recent-collaborator list (no scope) is unchanged: no Priya.
      refute priya.id in ids(AppPeople.list_people(me))
    end

    test "an archived space contributes nobody" do
      me = create_user!()
      gone = create_user!()
      {:ok, space} = Chat.create_space(%{kind: "group"})
      add_user!(space.id, me.id)
      add_user!(space.id, gone.id)
      Repo.update!(Ecto.Changeset.change(space, archived_at: DateTime.utc_now()))

      refute gone.id in ids(AppPeople.list_people(me, scope: "directory"))
    end

    test "external scoping holds: Ext never gets a non-allow-listed person, even one sharing a space" do
      world = external_world()
      bot = agent!("Ext Dir Bot #{token()}")

      # Riley (world.n, org B only) shares a group AND a channel with Ext.
      {group, gp} = group!([world.ext, world.m, world.n, {:agent, bot}])
      message!(group.id, gp[world.ext.id])
      add_user!(world.a.id, world.n.id)

      row_ids = ids(AppPeople.list_people(world.ext, scope: "directory"))

      # Positive control: the allow-listed org mate IS listed.
      assert world.m.id in row_ids
      refute world.n.id in row_ids
      refute bot.id in row_ids
      refute world.ext.id in row_ids
    end
  end

  describe "open_dm/2" do
    test "finds or creates the DM and answers its id as the path segment" do
      me = create_user!()
      other = create_user!()

      assert {:ok, %{space_id: id, path_segment: id}} = AppPeople.open_dm(me, other.id)
      assert {:ok, %{space_id: ^id}} = AppPeople.open_dm(me, other.id)
      assert Chat.participant?(id, other.id)
    end

    test "external: allow-listed is opened, the other is :dm_not_allowed" do
      world = external_world()
      assert {:ok, _} = AppPeople.open_dm(world.ext, world.m.id)
      assert {:error, :dm_not_allowed} = AppPeople.open_dm(world.ext, world.n.id)
    end

    test "unknown, malformed and self are :not_found" do
      me = create_user!()
      assert {:error, :not_found} = AppPeople.open_dm(me, Ecto.UUID.generate())
      assert {:error, :not_found} = AppPeople.open_dm(me, "not-a-uuid")
      assert {:error, :not_found} = AppPeople.open_dm(me, me.id)
    end
  end
end
