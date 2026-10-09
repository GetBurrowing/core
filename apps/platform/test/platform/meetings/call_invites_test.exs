defmodule Platform.Meetings.CallInvitesTest do
  @moduledoc """
  Task 01a111bb stage 1: who a call started from the native app rings
  (`Platform.Meetings.CallInvites`).

  `authorize/3` writes nothing; `invite/2` writes draft invites (no
  inviter) on a meeting that already exists. `invite_space_id` resolves to at
  most 25 people, a deliberate product cap.
  """
  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.CallInvites
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Ring
  alias Platform.Repo
  alias Platform.Tasks

  defp agent! do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "call-agent-#{n}", name: "Call Agent #{n}", status: "active"})
  end

  defp meeting! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Calls #{n}"})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Call #{n}"})
    meeting
  end

  defp counts do
    {Repo.aggregate(Meeting, :count, :id), Repo.aggregate(Invite, :count, :id)}
  end

  describe "authorize/3 with explicit invitees" do
    test "returns the ids, deduplicated and without the caller, and writes nothing" do
      me = create_user!()
      a = create_user!()
      b = create_user!()
      before = counts()

      assert {:ok, ids} = CallInvites.authorize(me, [a.id, b.id, a.id, me.id], nil)
      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      assert counts() == before
    end

    test "more than 10 is :too_many_invitees" do
      me = create_user!()
      ids = for _ <- 1..11, do: create_user!().id
      assert {:error, :too_many_invitees} = CallInvites.authorize(me, ids, nil)
      assert {:ok, _} = CallInvites.authorize(me, Enum.take(ids, 10), nil)
    end

    test "an agent id is :agent_not_callable" do
      me = create_user!()
      assert {:error, :agent_not_callable} = CallInvites.authorize(me, [agent!().id], nil)
    end

    test "a malformed or unknown id is :forbidden" do
      me = create_user!()
      assert {:error, :forbidden} = CallInvites.authorize(me, ["nope"], nil)
      assert {:error, :forbidden} = CallInvites.authorize(me, [Ecto.UUID.generate()], nil)
      assert {:error, :forbidden} = CallInvites.authorize(me, "not-a-list", nil)
    end

    test "external: the allow-listed person passes, the other is :forbidden" do
      world = external_world()
      # Positive control.
      assert {:ok, [m]} = CallInvites.authorize(world.ext, [world.m.id], nil)
      assert m == world.m.id
      assert {:error, :forbidden} = CallInvites.authorize(world.ext, [world.n.id], nil)

      assert {:error, :forbidden} =
               CallInvites.authorize(world.ext, [world.m.id, world.n.id], nil)
    end
  end

  describe "authorize/3 with invite_space_id" do
    test "resolves to the space's other humans, never agents or the caller" do
      me = create_user!()
      a = create_user!()
      space = channel!()
      add_user!(space.id, me.id)
      add_user!(space.id, a.id)
      add_agent!(space.id, agent!().id)

      assert {:ok, [id]} = CallInvites.authorize(me, nil, space.id)
      assert id == a.id
    end

    test "a space the caller is not in, an archived one, or a malformed id is :forbidden" do
      me = create_user!()
      other = channel!()
      add_user!(other.id, create_user!().id)

      archived = channel!()
      add_user!(archived.id, me.id)
      {:ok, _} = Chat.archive_space(archived)

      assert {:error, :forbidden} = CallInvites.authorize(me, nil, other.id)
      assert {:error, :forbidden} = CallInvites.authorize(me, nil, archived.id)
      assert {:error, :forbidden} = CallInvites.authorize(me, nil, "general")
    end

    test "external: a member they may not DM is dropped, the allow-listed one kept" do
      world = external_world()
      add_user!(world.a.id, world.m.id)
      add_user!(world.a.id, world.n.id)

      assert {:ok, ids} = CallInvites.authorize(world.ext, nil, world.a.id)
      # Positive control.
      assert world.m.id in ids
      refute world.n.id in ids
    end

    test "the cap: a space with 30 other humans resolves to exactly 25, and invites 25" do
      me = create_user!()
      space = channel!()
      add_user!(space.id, me.id)
      for _ <- 1..30, do: add_user!(space.id, create_user!().id)

      assert {:ok, ids} = CallInvites.authorize(me, nil, space.id)
      assert length(ids) == 25
      refute me.id in ids

      meeting = meeting!()
      assert {:ok, invites} = CallInvites.invite(meeting, ids)
      assert length(invites) == 25

      assert Repo.aggregate(from(i in Invite, where: i.meeting_id == ^meeting.id), :count, :id) ==
               25
    end
  end

  describe "invite/2" do
    test "writes draft invites with no live ring" do
      meeting = meeting!()
      a = create_user!()
      b = create_user!()

      assert {:ok, invites} = CallInvites.invite(meeting, [a.id, b.id])
      assert Enum.map(invites, & &1.user_id) |> Enum.sort() == Enum.sort([a.id, b.id])
      assert Enum.all?(invites, &is_nil(&1.revoked_at))

      # Draft: nothing rings until the meeting starts.
      assert Repo.aggregate(from(r in Ring, where: r.meeting_id == ^meeting.id), :count, :id) ==
               0
    end
  end
end
