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

  defp user!(org_id \\ acme_org_id()) do
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
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
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
  defp concluded!(opts \\ []) do
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
    extra_attendees = Keyword.get(opts, :extra_attendees, [])

    for user <- [a, b | extra_attendees] do
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

    extra_tasks =
      for i <- 1..Keyword.get(opts, :extra_tasks, 0)//1,
          do: graduate!(live, "somebody should do extra chore #{i}")

    {:ok, ended} = Meetings.end_meeting(live)

    ended =
      ended
      |> Ecto.Changeset.change(ended_at: DateTime.add(DateTime.utc_now(), -1201))
      |> Repo.update!()

    assert {:ok, %{created: _}} = MeetingBriefings.deliver(ended)
    briefing = MeetingBriefings.get_for_attendee(ended.id, a.id)
    assert %MeetingBriefing{} = briefing

    %{
      project: project,
      meeting: ended,
      briefing: briefing,
      a: a,
      b: b,
      t1: t1,
      t2: t2,
      tasks: [t1, t2 | extra_tasks]
    }
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

  # ── Assignee and sponsor (Ryan, 2026-10-30) ───────────────────────────────

  describe "assignee and sponsor" do
    defp assign!(%TaskRecord{} = task, assignee_id, type, sponsor_id) do
      Repo.get!(TaskRecord, task.id)
      |> Ecto.Changeset.change(
        assignee_id: assignee_id,
        assignee_type: type,
        sponsor_user_id: sponsor_id
      )
      |> Repo.update!()
    end

    test "are the current-phase assignee and the human sponsor, read live" do
      ctx = concluded!()
      worker = agent!()
      sponsor = user!()
      human = user!()
      assign!(ctx.t1, worker.id, "agent", sponsor.id)
      assign!(ctx.t2, human.id, "user", nil)

      view = MeetingBriefings.view(ctx.briefing, scope(ctx.a))

      assert item(view, key(ctx.t1)).assignee == %{
               id: worker.id,
               name: worker.name,
               type: "agent"
             }

      assert item(view, key(ctx.t1)).sponsor == %{id: sponsor.id, name: sponsor.name}
      assert item(view, key(ctx.t2)).assignee == %{id: human.id, name: human.name, type: "user"}
      assert item(view, key(ctx.t2)).sponsor == nil

      # A per-phase slot for the task's current phase wins over the flat pointer,
      # exactly as on the board.
      other = agent!()
      phase = Tasks.current_phase(Repo.get!(TaskRecord, ctx.t1.id))

      Repo.get!(TaskRecord, ctx.t1.id)
      |> Ecto.Changeset.change(
        phase_assignees: %{phase => %{"assignee_id" => other.id, "assignee_type" => "agent"}}
      )
      |> Repo.update!()

      view = MeetingBriefings.view(ctx.briefing, scope(ctx.a))
      assert item(view, key(ctx.t1)).assignee == %{id: other.id, name: other.name, type: "agent"}
    end

    test "are nil when unset" do
      ctx = concluded!()
      view = MeetingBriefings.view(ctx.briefing, scope(ctx.a))

      for task <- [ctx.t1, ctx.t2] do
        assert item(view, key(task)).assignee == nil
        assert item(view, key(task)).sponsor == nil
      end
    end

    test "are nil for a viewer who cannot read the task's project, like the project itself" do
      outsider = user!(tenant_org_id("follow_up_fenced_#{n()}"))
      ctx = concluded!(extra_attendees: [outsider])
      assert outsider.id in ctx.briefing.attendee_user_ids
      assign!(ctx.t1, agent!().id, "agent", user!().id)

      fenced = item(MeetingBriefings.view(ctx.briefing, scope(outsider)), key(ctx.t1))
      assert fenced.project == %{id: nil, name: nil}
      assert fenced.assignee == nil
      assert fenced.sponsor == nil

      # Positive control: an org member sees all three.
      member = item(MeetingBriefings.view(ctx.briefing, scope(ctx.a)), key(ctx.t1))
      assert member.project.id == ctx.project.id
      assert %{type: "agent"} = member.assignee
      assert %{id: _} = member.sponsor
    end

    # The view already spends some queries per task (Revert's per-task
    # tasks.write check), so the pin is on what assignee + sponsor ADD: the
    # same small constant whatever the briefing's size.
    test "add a fixed number of queries, not one per task" do
      small = concluded!()
      large = concluded!(extra_tasks: 4)
      assert length(large.tasks) == length(small.tasks) + 4

      view_queries = fn ctx ->
        count_queries(fn -> MeetingBriefings.view(ctx.briefing, scope(ctx.a)) end)
      end

      [small_bare, large_bare] = Enum.map([small, large], view_queries)

      for ctx <- [small, large],
          task <- ctx.tasks,
          do: assign!(task, agent!().id, "agent", user!().id)

      [small_full, large_full] = Enum.map([small, large], view_queries)

      # Positive control: the counter sees the view's queries at all.
      assert small_bare > 0
      added = small_full - small_bare
      assert large_full - large_bare == added
      assert added in 0..2

      view = MeetingBriefings.view(large.briefing, scope(large.a))

      for task <- large.tasks do
        assert %{type: "agent"} = item(view, key(task)).assignee
        assert %{id: _} = item(view, key(task)).sponsor
      end
    end
  end

  @query_event [:platform, :repo, :query]

  defp count_queries(fun) do
    assert Repo.config()[:telemetry_prefix] ++ [:query] == @query_event
    test_pid = self()
    handler = "follow-up-query-count-#{n()}"

    :telemetry.attach(
      handler,
      @query_event,
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:counted_query, handler})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler)
    end

    drain_queries(handler, 0)
  end

  defp drain_queries(handler, count) do
    receive do
      {:counted_query, ^handler} -> drain_queries(handler, count + 1)
    after
      0 -> count
    end
  end
end
