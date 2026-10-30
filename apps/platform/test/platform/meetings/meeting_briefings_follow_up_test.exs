defmodule Platform.Meetings.MeetingBriefingsFollowUpTest do
  @moduledoc """
  Task 01a18d37 stage 2: a meeting-filed task card names the agent to follow
  up with, and `MeetingBriefings.follow_up/4` posts the attendee's message
  into their 1:1 DM with that agent. The recipient is resolved on the server
  only (the stamped filer if active, else the active triage officer), no
  receipt is written, and every error path posts nothing.

  `async: false`: the triage officer is a global role assignment, and the
  wake test talks to the shared `Platform.Chat.AttentionRouter`.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, Participant}
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.MeetingBriefing
  alias Platform.Meetings.MeetingBriefings
  alias Platform.Meetings.Participant, as: MeetingParticipant
  alias Platform.Meetings.Room
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tenancy.OrgMembership

  setup do
    :ok = Roles.unassign_role("triage_officer")
    :ok
  end

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp n, do: System.unique_integer([:positive])

  defp user! do
    i = n()

    user =
      %User{}
      |> User.changeset(%{
        email: "follow-up-#{i}@example.com",
        name: "Follower #{i}",
        oidc_sub: "oidc-follow-up-#{i}"
      })
      |> Repo.insert!()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
    |> Repo.insert!()

    user
  end

  defp agent!(status \\ "active") do
    i = n()
    Repo.insert!(%Agent{slug: "follow-up-agent-#{i}", name: "Filer #{i}", status: status})
  end

  defp scope(%User{} = user), do: Scope.for_user(Repo.get!(User, user.id))

  defp graduate!(meeting, title) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: meeting.project_id,
        title: title,
        metadata: %{
          "source" => "meetings.candidate",
          "meeting_id" => meeting.id,
          "candidate_id" => Ecto.UUID.generate()
        }
      })

    task
  end

  # A concluded meeting attended by A and B, two backlog tasks, and the
  # briefing delivered by the bounded fallback.
  defp concluded! do
    {:ok, project} =
      Tasks.create_project(%{name: "Follow-up Project #{n()}", org_id: acme_org_id()})

    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Follow-up #{n()}"})

    {:ok, live} =
      meeting
      |> Meeting.status_changeset("live", %{
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })
      |> Repo.update()

    room =
      %Room{}
      |> Room.changeset(%{
        space_id: live.chat_space_id,
        livekit_room_name: "space-#{live.chat_space_id}"
      })
      |> Repo.insert!()

    a = user!()
    b = user!()

    for user <- [a, b] do
      %MeetingParticipant{}
      |> MeetingParticipant.changeset(%{
        room_id: room.id,
        user_id: user.id,
        display_name: user.name,
        joined_at: DateTime.add(DateTime.utc_now(), -3000, :second)
      })
      |> Repo.insert!()
    end

    t1 = graduate!(live, "somebody should rotate the S3 keys")
    t2 = graduate!(live, "somebody should renew the TLS certs")
    {:ok, ended} = Meetings.end_meeting(live)

    ended =
      ended
      |> Ecto.Changeset.change(ended_at: DateTime.add(DateTime.utc_now(), -1201))
      |> Repo.update!()

    assert {:ok, %{created: _}} = MeetingBriefings.deliver(ended)
    briefing = MeetingBriefings.get_for_attendee(ended.id, a.id)
    assert %MeetingBriefing{} = briefing

    %{project: project, meeting: ended, briefing: briefing, a: a, b: b, t1: t1, t2: t2}
  end

  defp stamp!(%TaskRecord{} = task, %Agent{} = agent) do
    task = Repo.get!(TaskRecord, task.id)

    task
    |> Ecto.Changeset.change(
      metadata: Map.put(task.metadata || %{}, "filed_by_agent_id", agent.id)
    )
    |> Repo.update!()
  end

  defp key(%TaskRecord{id: id}), do: MeetingBriefings.node_key("task:" <> id)

  defp item(view, key), do: Enum.find(view.open ++ view.resolved, &(&1.key == key))

  defp message_count, do: Repo.aggregate(Message, :count)

  defp agent_ref(%Agent{id: id, name: name}), do: %{id: id, name: name}

  # ── The happy path ────────────────────────────────────────────────────────

  describe "follow_up/4 to the stamped filer" do
    test "posts exactly one message in the user<->agent DM, as the user, and writes no receipt" do
      ctx = concluded!()
      filer = agent!()
      stamp!(ctx.t1, filer)
      k = key(ctx.t1)

      before = message_count()

      assert {:ok, result} =
               MeetingBriefings.follow_up(ctx.briefing, k, scope(ctx.a), %{
                 "text" => "Please re-file this into the platform project"
               })

      assert message_count() == before + 1
      assert result.agent == agent_ref(filer)

      {:ok, dm} = Chat.find_or_create_dm(ctx.a.id, "agent", filer.id)
      assert result.space_id == dm.id

      assert result.url ==
               "/chat/" <> Chat.space_path_segment(dm) <> "?message=" <> result.message_id

      assert [message] = Repo.all(from(m in Message, where: m.space_id == ^dm.id))
      assert message.id == result.message_id

      poster = Repo.get!(Participant, message.participant_id)
      assert {poster.participant_type, poster.participant_id} == {"user", ctx.a.id}

      assert message.content =~ "@[" <> filer.name <> "]"
      assert message.content =~ ctx.t1.id
      assert message.content =~ "/tasks/" <> ctx.t1.id
      assert message.content =~ ctx.project.name
      assert message.content =~ "/inbox/meeting/" <> ctx.meeting.id
      assert message.content =~ "Please re-file this into the platform project"

      # No receipt: the item stays open, Revert stays, and B sees the same.
      assert Repo.get!(MeetingBriefing, ctx.briefing.id).receipts == %{}
      view = MeetingBriefings.view(ctx.briefing, scope(ctx.b))
      entry = item(view, k)
      assert entry in view.open
      assert entry.actions == [:revert, :follow_up]
      assert entry.filed_by == agent_ref(filer)
      assert entry.follow_up_agent == agent_ref(filer)
      assert entry.project == %{id: ctx.project.id, name: ctx.project.name}
      assert entry.availability == "backlog"

      # A second follow-up on the same item is allowed and lands in the same DM.
      assert {:ok, again} =
               MeetingBriefings.follow_up(ctx.briefing, k, scope(ctx.a), %{"text" => "Ping"})

      assert again.space_id == dm.id
      assert message_count() == before + 2
    end

    test "the DM wakes the agent: the router routes the message to the agent participant" do
      router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
      Sandbox.allow(Repo, self(), router)
      store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
      Sandbox.allow(Repo, self(), store)

      ctx = concluded!()
      filer = agent!()
      stamp!(ctx.t1, filer)

      assert {:ok, result} =
               MeetingBriefings.follow_up(ctx.briefing, key(ctx.t1), scope(ctx.a), %{
                 "text" => "Can you look again?"
               })

      message = Repo.get!(Message, result.message_id)
      agent_p = Repo.get_by!(Participant, space_id: result.space_id, participant_type: "agent")
      assert agent_p.participant_id == filer.id

      {:ok, decisions} = AttentionRouter.route(message)
      :ok = GenServer.call(AttentionRouter, :__drain__)

      assert Enum.any?(decisions, &(&1.participant_id == agent_p.id))
    end

    test "a mention token in the task title or meeting name is inert" do
      ctx = concluded!()
      filer = agent!()
      victim = agent!()

      ctx.t1
      |> stamp!(filer)
      |> Ecto.Changeset.change(title: "summon @[" <> victim.name <> "] please")
      |> Repo.update!()

      ctx.meeting
      |> Ecto.Changeset.change(name: "Sync with @[" <> victim.name <> "]")
      |> Repo.update!()

      assert {:ok, result} =
               MeetingBriefings.follow_up(ctx.briefing, key(ctx.t1), scope(ctx.a), %{
                 "text" => "hello"
               })

      content = Repo.get!(Message, result.message_id).content
      refute content =~ "@[" <> victim.name <> "]"
      assert content =~ "@[" <> filer.name <> "]"
    end
  end

  # ── Recipient resolution ──────────────────────────────────────────────────

  describe "the recipient" do
    test "a stamped filer wins over the triage officer" do
      ctx = concluded!()
      filer = agent!()
      officer = agent!()
      {:ok, _} = Roles.assign_role("triage_officer", officer.id)
      stamp!(ctx.t1, filer)

      view = MeetingBriefings.view(ctx.briefing, scope(ctx.a))
      assert item(view, key(ctx.t1)).follow_up_agent == agent_ref(filer)
      # The unstamped sibling falls back to the officer.
      assert item(view, key(ctx.t2)).follow_up_agent == agent_ref(officer)
      assert item(view, key(ctx.t2)).actions == [:revert, :follow_up]

      assert {:ok, %{agent: agent}} =
               MeetingBriefings.follow_up(ctx.briefing, key(ctx.t1), scope(ctx.a), %{
                 "text" => "x"
               })

      assert agent == agent_ref(filer)
    end

    test "an unstamped task falls back to the triage officer" do
      ctx = concluded!()
      officer = agent!()
      {:ok, _} = Roles.assign_role("triage_officer", officer.id)

      assert {:ok, %{agent: agent, space_id: space_id}} =
               MeetingBriefings.follow_up(ctx.briefing, key(ctx.t2), scope(ctx.a), %{
                 "text" => "x"
               })

      assert agent == agent_ref(officer)
      {:ok, dm} = Chat.find_or_create_dm(ctx.a.id, "agent", officer.id)
      assert space_id == dm.id
    end

    test "an inactive stamped filer falls back to the officer" do
      ctx = concluded!()
      officer = agent!()
      {:ok, _} = Roles.assign_role("triage_officer", officer.id)
      stamp!(ctx.t1, agent!("paused"))

      view = MeetingBriefings.view(ctx.briefing, scope(ctx.a))
      assert item(view, key(ctx.t1)).follow_up_agent == agent_ref(officer)
    end

    test "no stamp and no officer: no agent, no follow_up action, and nothing posts" do
      ctx = concluded!()

      view = MeetingBriefings.view(ctx.briefing, scope(ctx.a))
      entry = item(view, key(ctx.t1))
      assert entry.follow_up_agent == nil
      assert entry.filed_by == nil
      assert entry.actions == [:revert]

      before = message_count()

      assert {:error, :no_recipient} =
               MeetingBriefings.follow_up(ctx.briefing, key(ctx.t1), scope(ctx.a), %{
                 "text" => "anyone?"
               })

      assert message_count() == before
    end
  end

  # ── Refusals post nothing ─────────────────────────────────────────────────

  describe "refusals" do
    setup do
      ctx = concluded!()
      filer = agent!()
      stamp!(ctx.t1, filer)
      Map.put(ctx, :filer, filer)
    end

    test "blank text", ctx do
      before = message_count()

      for text <- ["", "   ", "\n\t"] do
        assert {:error, :blank} =
                 MeetingBriefings.follow_up(ctx.briefing, key(ctx.t1), scope(ctx.a), %{
                   "text" => text
                 })
      end

      assert {:error, :blank} =
               MeetingBriefings.follow_up(ctx.briefing, key(ctx.t1), scope(ctx.a), %{})

      assert message_count() == before
    end

    test "a forged key and the reserved content key", ctx do
      before = message_count()

      for k <- ["m" <> String.duplicate("0", 16), MeetingBriefings.content_key(), ""] do
        assert {:error, :not_found} =
                 MeetingBriefings.follow_up(ctx.briefing, k, scope(ctx.a), %{"text" => "hi"})
      end

      assert message_count() == before
    end

    test "a non-attendee", ctx do
      before = message_count()
      outsider = user!()

      assert {:error, :not_found} =
               MeetingBriefings.follow_up(ctx.briefing, key(ctx.t1), scope(outsider), %{
                 "text" => "hi"
               })

      assert message_count() == before
    end

    test "a resolved item and a removed task", ctx do
      assert {:ok, _} =
               MeetingBriefings.act(ctx.briefing, key(ctx.t1), :revert, scope(ctx.a), %{})

      stamp!(ctx.t2, ctx.filer)

      Repo.get!(TaskRecord, ctx.t2.id)
      |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
      |> Repo.update!()

      before = message_count()

      for task <- [ctx.t1, ctx.t2] do
        assert {:error, :not_found} =
                 MeetingBriefings.follow_up(ctx.briefing, key(task), scope(ctx.a), %{
                   "text" => "hi"
                 })
      end

      assert message_count() == before

      view = MeetingBriefings.view(ctx.briefing, scope(ctx.a))
      assert item(view, key(ctx.t2)).follow_up_agent == nil
      assert item(view, key(ctx.t2)).actions == []
    end
  end
end
