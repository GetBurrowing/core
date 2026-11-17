defmodule Platform.Goals.ProposalsTest do
  @moduledoc """
  Goals 5/8 stage 1 (task 01a1dfc1-7625): the New goal conversation, the
  proposal and the person's confirmation.
  """
  use Platform.DataCase, async: false

  import Platform.GoalsFixtures

  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.{Goal, Grant, Limits, Proposal, Proposals, Signals, Stop}

  @now ~U[2026-11-16 09:00:00.000000Z]
  @opening "ZEBRA-QUARTZ: I want to run a half marathon by spring"

  setup do
    enable_goals!()

    old =
      Map.new([:clock_now, :wake_up_dispatcher], &{&1, Application.fetch_env(:goals, &1)})

    parent = self()
    Application.put_env(:goals, :clock_now, fn -> @now end)

    Application.put_env(:goals, :wake_up_dispatcher, fn signal ->
      send(parent, {:signal, signal})
      :ok
    end)

    on_exit(fn ->
      for {key, previous} <- old do
        case previous do
          {:ok, value} -> Application.put_env(:goals, key, value)
          :error -> Application.delete_env(:goals, key)
        end
      end
    end)

    org = org_id!()
    %{org: org, person: member!(org)}
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp external_agent!(owner) do
    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: owner.id,
        runtime_id: "goal-proposal-#{unique()}",
        display_name: "Goals proposal test",
        status: "active"
      })

    agent!()
    |> Ecto.Changeset.change(runtime_type: "external", runtime_id: runtime.id)
    |> Repo.update!()
  end

  defp lead!(c) do
    agent = c.person |> external_agent!() |> grant_goals_tools!()
    {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), agent.id)
    agent
  end

  defp start!(user, text \\ @opening) do
    {:ok, proposal} = Goals.start_goal_conversation(user, text)
    assert_received {:signal, _}
    proposal
  end

  defp set_now(now), do: Application.put_env(:goals, :clock_now, fn -> now end)

  @full %{
    title: "VIOLET-ANVIL half marathon",
    why: "To feel strong",
    unit: "km",
    target_value: "21.1",
    source_key: "self_reported",
    agent_mode: "coach",
    rhythm: "weekly",
    rhythm_weekday: 3,
    outreach: "gentle",
    kind: "shared",
    stops: [
      %{label: "First 5k", target_value: "5", due_on: "2026-12-01", theme: "habit"},
      %{label: "10k", target_value: "10"},
      %{label: "Race day", caption: "the big one"}
    ]
  }

  defp ready!(agent, proposal, extra \\ %{}) do
    {:ok, proposal} =
      Goals.propose_goal(agent, proposal.id, Map.merge(@full, Map.put(extra, :ready, true)))

    proposal
  end

  defp counts do
    Enum.map(
      [Proposal, Goal, Stop, Grant, Chat.Message, Chat.Space, Chat.Participant],
      &Repo.aggregate(&1, :count)
    )
  end

  defp row(proposal), do: Repo.one!(from(p in Proposal, where: p.id == ^proposal.id))
  defp goal_count, do: Repo.aggregate(Goal, :count)

  # ── limits and the signal sender ─────────────────────────────────────────

  test "the new limits have their defaults and the install override" do
    previous = Application.fetch_env(:goals, :limits)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:goals, :limits, value)
        :error -> Application.delete_env(:goals, :limits)
      end
    end)

    Application.delete_env(:goals, :limits)

    for {key, expected} <- [
          proposal_expiry_days: 7,
          max_quick_replies: 4,
          max_reply_chars: 40,
          max_stops: 12,
          max_opening_chars: 2000,
          max_sources: 8,
          max_takeaways: 20
        ],
        do: assert(apply(Limits, key, []) == expected)

    Application.put_env(:goals, :limits, %{max_stops: 3})
    assert Limits.max_stops() == 3
    assert Limits.max_quick_replies() == 4
  end

  test "Signals.deliver sends only to an external runtime and maps the result", c do
    assert Signals.deliver(agent!(), "goals.new_goal", "p") == "no_runtime"
    refute_received {:signal, _}

    agent = external_agent!(c.person)
    assert Signals.deliver(agent, "goals.new_goal", "p", trigger_kind: "event_topic") == "sent"
    assert_received {:signal, %{metadata: %{responsibility_key: "goals.new_goal"}}}

    Application.put_env(:goals, :wake_up_dispatcher, fn _ -> {:error, :runtime_offline} end)
    assert Signals.deliver(agent, "k", "p") == "offline"
    Application.put_env(:goals, :wake_up_dispatcher, fn _ -> raise "boom" end)
    assert Signals.deliver(agent, "k", "p") == "failed"
  end

  test "the clock sends through the one signal sender" do
    source = File.read!(Path.expand("../../../lib/platform/goals/clock.ex", __DIR__))
    assert source =~ "Signals.deliver("
    refute source =~ "wake_up_dispatcher"
    refute source =~ ":system_event"
  end

  # ── lead agent and start ─────────────────────────────────────────────────

  test "lead_agent resolves the agents_leader role", c do
    assert Goals.lead_agent(c.person) == {:error, :no_lead_agent}
    lead = lead!(c)
    assert {:ok, %{id: id}} = Goals.lead_agent(c.person)
    assert id == lead.id
  end

  test "start opens the proposal's own space with the lead agent, posts as the person and signals ids only",
       c do
    lead = lead!(c)
    assert {:ok, proposal} = Goals.start_goal_conversation(c.person, "  #{@opening}  ")

    assert proposal.status == "open"
    assert proposal.user_id == c.person.id
    assert proposal.agent_id == lead.id
    assert proposal.org_id == c.org
    assert proposal.revision == 0
    assert proposal.delivery == "sent"
    assert DateTime.compare(proposal.expires_at, DateTime.add(@now, 7 * 86_400)) == :eq

    space = Repo.one!(from(s in Chat.Space, where: s.id == ^proposal.space_id))
    assert space.kind == "dm"
    assert space.is_direct == false
    assert space.metadata == %{"surface" => "goals"}
    assert space.org_id == c.org
    assert space.created_by == c.person.id

    participants =
      Repo.all(
        from(p in Chat.Participant,
          where: p.space_id == ^space.id,
          select: {p.participant_type, p.participant_id}
        )
      )

    assert Enum.sort(participants) == Enum.sort([{"user", c.person.id}, {"agent", lead.id}])

    msg = Chat.get_message(proposal.first_message_id)
    assert msg.space_id == space.id
    assert msg.content == @opening
    assert msg.author_participant_type == "user"
    assert msg.author_user_id == c.person.id

    assert Repo.aggregate(from(p in Proposal, where: p.status == "open"), :count) == 1

    assert_received {:signal, signal}
    refute_received {:signal, _}

    assert signal.metadata.prompt ==
             "A person started a New goal conversation with you. Conversation id: #{proposal.id}. " <>
               "Read it with goal_proposal_get, talk with them in this goal's conversation " <>
               "(space #{proposal.space_id}), and record what you settle with goal_propose. " <>
               "Nothing is created until they press Create goal."

    assert signal.metadata.responsibility_key == "goals.new_goal"
    assert signal.metadata.agent_id == lead.id
    refute inspect(signal) =~ "ZEBRA-QUARTZ"

    # Control: the same search over the conversation finds the words.
    assert {:ok, [first]} = Goals.conversation(c.person, proposal.id)
    assert inspect(first) =~ "ZEBRA-QUARTZ"
    assert first.from == :person
  end

  test "no lead agent, blank text, a second start and an external-only user write nothing",
       c do
    before = counts()
    assert Goals.start_goal_conversation(c.person, @opening) == {:error, :no_lead_agent}
    assert counts() == before

    lead!(c)
    before = counts()
    assert Goals.start_goal_conversation(c.person, "   ") == {:error, :text_required}
    assert Goals.start_goal_conversation(c.person, nil) == {:error, :text_required}

    too_long = String.duplicate("a", Limits.max_opening_chars() + 1)
    assert Goals.start_goal_conversation(c.person, too_long) == {:error, :text_required}
    assert counts() == before

    start!(c.person)
    before = counts()
    assert Goals.start_goal_conversation(c.person, "again") == {:error, :conversation_open}
    assert counts() == before

    outsider = external_member!(c.org)
    before = counts()
    assert Goals.start_goal_conversation(outsider, @opening) == {:error, :no_org}
    assert counts() == before

    refute_received {:signal, _}
  end

  # ── the lead's Goals tools (task 01a1eab6 stage 3) ───────────────────────

  describe "a lead whose runtime lacks the Goals tools" do
    defp intake_counts,
      do: Enum.map([Chat.Space, Chat.Message, Proposal], &Repo.aggregate(&1, :count))

    defp toolless_lead!(owner, modules) do
      agent = external_agent!(owner)
      if modules, do: grant_goals_tools!(agent, modules)
      {:ok, _} = Platform.Roles.assign_role(Chat.Sidebar.agents_leader_role(), agent.id)
      agent
    end

    test "a profile without the goals bundle is refused and writes no row", c do
      lead = toolless_lead!(c.person, ["messaging"])
      before = intake_counts()

      assert Goals.start_goal_conversation(c.person, @opening) ==
               {:error, :lead_missing_goals_tools}

      assert intake_counts() == before
      refute_received {:signal, _}
      assert Goals.current_proposal(c.person) == {:ok, nil}
      assert Proposals.check_lead_tools(lead) == {:error, :lead_missing_goals_tools}
    end

    test "a runtime with no profile row is refused (fail closed)", c do
      toolless_lead!(c.person, nil)
      before = intake_counts()

      assert Goals.start_goal_conversation(c.person, @opening) ==
               {:error, :lead_missing_goals_tools}

      assert intake_counts() == before
    end

    test "the goals bundle with an owner who lacks goals.use is refused: effective_tools decides",
         c do
      owner = member!(c.org)
      lead = toolless_lead!(owner, ["goals"])
      revoke_goals_use!(owner)
      runtime = Repo.get!(Platform.Agents.AgentRuntime, lead.runtime_id)

      # The profile alone would say yes, and core reports the owner cap.
      assert "goals" in Platform.Access.RuntimeProfiles.tool_profile(runtime)
      assert Map.has_key?(Platform.Access.Caps.for_runtime(runtime), "goals")

      before = intake_counts()

      assert Goals.start_goal_conversation(c.person, @opening) ==
               {:error, :lead_missing_goals_tools}

      assert intake_counts() == before
      refute_received {:signal, _}

      # Lifting the cap is all it takes.
      grant_goals_use!(owner)
      assert Proposals.check_lead_tools(lead) == :ok
    end

    test "after the grant the same start succeeds", c do
      lead = toolless_lead!(c.person, ["messaging"])

      assert Goals.start_goal_conversation(c.person, @opening) ==
               {:error, :lead_missing_goals_tools}

      grant_goals_tools!(lead)

      assert {:ok, %Proposal{status: "open"} = proposal} =
               Goals.start_goal_conversation(c.person, @opening)

      assert proposal.agent_id == lead.id
      assert_received {:signal, %{metadata: %{responsibility_key: "goals.new_goal"}}}
    end

    test "check_lead_tools/1 is public: agent in, result out", c do
      lead = toolless_lead!(c.person, ["messaging"])
      assert Proposals.check_lead_tools(lead) == {:error, :lead_missing_goals_tools}
      assert Proposals.check_lead_tools(grant_goals_tools!(lead)) == :ok

      # No external runtime: nothing to hold tools, so today's no_runtime path.
      assert Proposals.check_lead_tools(agent!()) == :ok

      # An external agent whose runtime row is gone is refused.
      dangling = %{lead | runtime_id: Ecto.UUID.generate()}
      assert Proposals.check_lead_tools(dangling) == {:error, :lead_missing_goals_tools}
    end
  end

  test "an agent cannot start a conversation", c do
    lead = lead!(c)
    before = counts()
    assert Goals.start_goal_conversation(lead, @opening) == {:error, :not_found}
    assert Goals.start_goal_conversation(nil, @opening) == {:error, :not_found}
    assert counts() == before
  end

  test "a tenant org is picked before the root org", c do
    lead!(c)
    person = root_admin!() |> join_org!(c.org)
    proposal = start!(person)
    assert proposal.org_id == c.org
  end

  test "a stale open row is expired and a new conversation starts in a space of its own", c do
    lead!(c)
    first = start!(c.person)
    set_now(DateTime.add(@now, 8 * 86_400))
    assert Goals.current_proposal(c.person) == {:ok, nil}

    second = start!(c.person, "Something new")
    assert row(first).status == "expired"
    assert second.space_id != first.space_id
    assert {:ok, %{id: id}} = Goals.current_proposal(c.person)
    assert id == second.id
  end

  # ── its own space (task 01a1eab6 stage 2) ────────────────────────────────

  defp dm_user_participant!(dm, user) do
    Repo.get_by!(Chat.Participant,
      space_id: dm.id,
      participant_type: "user",
      participant_id: user.id
    )
  end

  defp post_in!(space_id, participant, text) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "text",
        content: text
      })

    msg
  end

  test "the goal conversation and the person's DM never see each other's messages", c do
    lead = lead!(c)
    {:ok, dm} = Chat.find_or_create_dm(c.person.id, "agent", lead.id)
    dm_me = dm_user_participant!(dm, c.person)
    post_in!(dm.id, dm_me, "DM-ONLY before")

    proposal = start!(c.person)
    post_in!(dm.id, dm_me, "DM-ONLY after")
    agent_p = Chat.get_agent_participant(proposal.space_id, lead.id)
    post_in!(proposal.space_id, agent_p, "GOAL-ONLY agent")
    {:ok, _} = Goals.say_in_conversation(c.person, proposal.id, "GOAL-ONLY person")

    assert proposal.space_id != dm.id

    space = Repo.one!(from(s in Chat.Space, where: s.id == ^proposal.space_id))
    assert space.metadata["surface"] == "goals"
    assert space.is_direct == false

    # The DM is still the person's DM with the agent.
    assert {:ok, %{id: dm_id}} = Chat.find_or_create_dm(c.person.id, "agent", lead.id)
    assert dm_id == dm.id

    assert {:ok, conversation} = Goals.conversation(c.person, proposal.id)

    assert Enum.map(conversation, & &1.content) ==
             [@opening, "GOAL-ONLY agent", "GOAL-ONLY person"]

    dm_contents = dm.id |> Chat.list_messages(limit: 200) |> Enum.map(& &1.content)
    assert Enum.sort(dm_contents) == Enum.sort(["DM-ONLY before", "DM-ONLY after"])
    refute Enum.any?(dm_contents, &(&1 =~ "GOAL-ONLY" or &1 == @opening))
  end

  test "the new_goal and research signals carry the space id in metadata only", c do
    lead = lead!(c)
    {:ok, proposal} = Goals.start_goal_conversation(c.person, @opening)

    assert_received {:signal, new_goal}
    assert new_goal.metadata.responsibility_key == "goals.new_goal"
    assert new_goal.metadata.space_id == proposal.space_id
    refute Map.has_key?(new_goal, :space_id)

    proposal = ready!(lead, proposal)
    {:ok, _} = Goals.confirm_proposal(c.person, proposal.id, proposal.revision)

    assert_received {:signal, research}
    assert research.metadata.responsibility_key == "goals.research"
    assert research.metadata.space_id == proposal.space_id
    refute Map.has_key?(research, :space_id)
    refute_received {:signal, _}
  end

  test "Signals.deliver puts :space_id in metadata only, and not at all without it", c do
    agent = external_agent!(c.person)
    space_id = Ecto.UUID.generate()

    assert Signals.deliver(agent, "k", "p", space_id: space_id) == "sent"
    assert_received {:signal, %{metadata: %{space_id: ^space_id}} = with_space}
    refute Map.has_key?(with_space, :space_id)

    assert Signals.deliver(agent, "k", "p") == "sent"
    assert_received {:signal, without}
    refute Map.has_key?(without.metadata, :space_id)
  end

  describe "routing (the real AttentionRouter in the sandbox)" do
    alias Ecto.Adapters.SQL.Sandbox
    alias Platform.Chat.{AttentionRouter, Message}
    alias Platform.Federation.RuntimePresence

    setup c do
      previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
      Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

      on_exit(fn ->
        if previous_mode,
          do: Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode),
          else: Application.delete_env(:platform, :chat_agent_dispatch_mode)
      end)

      router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
      Sandbox.allow(Repo, self(), router)
      presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), presence)

      test_pid = self()
      handler_id = "goals-routing-#{unique()}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          [[:platform, :chat, :attention_routed], [:platform, :chat, :attention_skipped]],
          fn event, _measurements, meta, _ -> send(test_pid, {List.last(event), meta}) end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      lead = lead!(c)
      runtime = Repo.get!(Platform.Agents.AgentRuntime, lead.runtime_id)
      RuntimePresence.track(runtime.runtime_id)
      on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

      %{lead: lead, router: router}
    end

    defp drain(router), do: :ok = GenServer.call(router, :__drain__, 10_000)

    test "the opening message is :caller_suppressed and a later message routes :directed",
         c do
      proposal = start!(c.person)
      drain(c.router)
      opening_id = proposal.first_message_id

      assert Repo.get!(Message, opening_id).metadata["attention"] == "none"

      assert_received {:attention_skipped, %{message_id: ^opening_id, reason: :caller_suppressed}}

      refute_received {:attention_routed, %{message_id: ^opening_id}}

      {:ok, second} = Goals.say_in_conversation(c.person, proposal.id, "Second turn")
      drain(c.router)
      second_id = second.id
      agent_p = Chat.get_agent_participant(proposal.space_id, c.lead.id)
      agent_p_id = agent_p.id

      refute Map.has_key?(Repo.get!(Message, second_id).metadata, "attention")

      assert_received {:attention_routed,
                       %{message_id: ^second_id, recipient_id: ^agent_p_id, reason: :directed}}

      refute_received {:attention_routed, %{message_id: ^second_id}}
      refute_received {:attention_skipped, %{message_id: ^second_id}}
    end
  end

  # ── reads ─────────────────────────────────────────────────────────────────

  test "current, get, list and conversation for the person and the agent", c do
    lead = lead!(c)
    proposal = start!(c.person)

    assert {:ok, %{id: id}} = Goals.current_proposal(c.person)
    assert id == proposal.id
    assert {:ok, %{id: ^id}} = Goals.get_proposal(c.person, proposal.id)
    assert {:ok, %{id: ^id}} = Goals.get_proposal(lead, proposal.id)
    assert {:ok, [%{id: ^id}]} = Goals.list_proposals(c.person)
    assert {:ok, [%{id: ^id}]} = Goals.list_proposals(lead)

    participant = Chat.get_agent_participant(proposal.space_id, lead.id)

    {:ok, _} =
      Chat.post_message(%{
        space_id: proposal.space_id,
        participant_id: participant.id,
        content_type: "text",
        content: "How far is far?"
      })

    assert {:ok, %{content: "21k"}} = Goals.say_in_conversation(c.person, proposal.id, " 21k ")

    assert {:ok, messages} = Goals.conversation(c.person, proposal.id)

    assert Enum.map(messages, &{&1.from, &1.content}) ==
             [{:person, @opening}, {:agent, "How far is far?"}, {:person, "21k"}]

    assert Enum.all?(messages, &match?(%{id: _, at: %DateTime{}}, &1))

    # The agent sees the row but the conversation read and the writes are the person's.
    assert Goals.conversation(lead, proposal.id) == {:error, :forbidden}
    assert Goals.say_in_conversation(lead, proposal.id, "x") == {:error, :forbidden}
    assert Goals.cancel_proposal(lead, proposal.id) == {:error, :forbidden}
    assert Goals.say_in_conversation(c.person, proposal.id, "  ") == {:error, :text_required}
  end

  test "every proposal write broadcasts the id only", c do
    lead = lead!(c)
    proposal = start!(c.person)
    assert :ok = Goals.subscribe_proposal(c.person, proposal.id)
    {:ok, _} = Goals.propose_goal(lead, proposal.id, %{title: "VIOLET-ANVIL"})
    assert_receive {:goal_proposal_changed, id}
    assert id == proposal.id
    {:ok, _} = Goals.say_in_conversation(c.person, proposal.id, "ok")
    assert_receive {:goal_proposal_changed, ^id}
    {:ok, _} = Goals.cancel_proposal(c.person, proposal.id)
    assert_receive {:goal_proposal_changed, ^id}
  end

  # ── propose_goal ─────────────────────────────────────────────────────────

  test "propose_goal merges, stamps settled once and raises the revision", c do
    lead = lead!(c)
    proposal = start!(c.person)

    {:ok, p1} =
      Goals.propose_goal(lead, proposal.id, %{
        title: "Half marathon",
        replies: ["21k", "Not sure"]
      })

    assert p1.revision == 1
    assert p1.draft == %{"title" => "Half marathon"}
    assert p1.replies == ["21k", "Not sure"]
    assert p1.settled == %{}

    set_now(DateTime.add(@now, 60))

    {:ok, p2} =
      Goals.propose_goal(lead, proposal.id, %{
        "source_key" => nil,
        "stops" => [%{"label" => "5k", "target_value" => "5", "due_on" => "2026-12-01"}],
        "unit" => "km"
      })

    assert p2.revision == 2
    assert p2.draft["title"] == "Half marathon"
    assert p2.draft["source_key"] == nil
    assert p2.draft["unit"] == "km"

    assert [%{"label" => "5k", "target_value" => "5", "due_on" => "2026-12-01"}] =
             p2.draft["stops"]

    # Replies are left alone when absent.
    assert p2.replies == ["21k", "Not sure"]
    stamp = DateTime.to_iso8601(DateTime.add(@now, 60))
    assert p2.settled == %{"source" => stamp, "stops" => stamp}

    set_now(DateTime.add(@now, 120))
    {:ok, p3} = Goals.propose_goal(lead, proposal.id, %{source_key: "self_reported", replies: []})
    assert p3.settled["source"] == stamp
    assert p3.draft["source_key"] == "self_reported"
    assert p3.replies == []
    assert p3.revision == 3
    refute p3.ready
  end

  test "each bad value is refused and the revision does not move", c do
    lead = lead!(c)
    proposal = start!(c.person)
    {:ok, _} = Goals.propose_goal(lead, proposal.id, %{title: "Fine"})

    stops = for n <- 1..13, do: %{label: "Stop #{n}"}

    for {attrs, expected} <- [
          {%{agent_mode: "boss"}, :changeset},
          {%{rhythm: "hourly"}, :changeset},
          {%{outreach: "loud"}, :changeset},
          {%{rhythm_weekday: 9}, :changeset},
          {%{title: ""}, :changeset},
          {%{stops: stops}, :changeset},
          {%{stops: [%{label: ""}]}, :changeset},
          {%{replies: ["a", "b", "c", "d", "e"]}, :changeset},
          {%{replies: [String.duplicate("x", 41)]}, :changeset},
          {%{replies: [""]}, :changeset},
          {%{ready: "yes"}, :changeset},
          {%{source_key: "youtube"}, :unknown_source}
        ] do
      result = Goals.propose_goal(lead, proposal.id, attrs)

      case expected do
        :changeset -> assert {:error, %Ecto.Changeset{}} = result, inspect(attrs)
        atom -> assert result == {:error, atom}, inspect(attrs)
      end

      assert row(proposal).revision == 1, inspect(attrs)
      assert row(proposal).draft == %{"title" => "Fine"}
    end

    # Exactly the limits pass.
    four = for n <- 1..4, do: String.duplicate("#{n}", 40)
    assert {:ok, %{revision: 2}} = Goals.propose_goal(lead, proposal.id, %{replies: four})
    twelve = for n <- 1..12, do: %{label: "Stop #{n}"}
    assert {:ok, %{revision: 3}} = Goals.propose_goal(lead, proposal.id, %{stops: twelve})
  end

  test "ready needs the four settings and a weekday for weekly rhythms", c do
    lead = lead!(c)
    proposal = start!(c.person)

    for missing <- [:title, :agent_mode, :rhythm, :outreach, :rhythm_weekday] do
      attrs = @full |> Map.delete(missing) |> Map.put(:ready, true)
      fresh = start_fresh!(c, lead)
      assert Goals.propose_goal(lead, fresh.id, attrs) == {:error, :proposal_incomplete}
      assert row(fresh).revision == 0
    end

    daily = @full |> Map.delete(:rhythm_weekday) |> Map.merge(%{rhythm: "daily", ready: true})
    assert {:ok, %{ready: true}} = Goals.propose_goal(lead, proposal.id, daily)
  end

  defp start_fresh!(c, _lead) do
    user = member!(c.org)
    start!(user)
  end

  test "identity attrs change nothing", c do
    lead = lead!(c)
    proposal = start!(c.person)
    other = member!(c.org)
    other_agent = agent!()
    goal = goal!(c.person, c.org)

    {:ok, updated} =
      Goals.propose_goal(lead, proposal.id, %{
        "user_id" => other.id,
        "agent_id" => other_agent.id,
        "org_id" => org_id!(),
        "space_id" => Ecto.UUID.generate(),
        "status" => "confirmed",
        "goal_id" => goal.id,
        "revision" => 99,
        "settled" => %{"x" => "y"},
        "title" => "Ok"
      })

    stored = row(proposal)

    for p <- [updated, stored] do
      assert p.user_id == c.person.id
      assert p.agent_id == lead.id
      assert p.org_id == c.org
      assert p.space_id == proposal.space_id
      assert p.status == "open"
      assert p.goal_id == nil
      assert p.revision == 1
      assert p.settled == %{}
      assert p.draft == %{"title" => "Ok"}
    end
  end

  test "only the conversation's agent proposes; a closed row is refused", c do
    lead = lead!(c)
    proposal = start!(c.person)
    assert Goals.propose_goal(c.person, proposal.id, %{title: "x"}) == {:error, :forbidden}
    assert Goals.propose_goal(agent!(), proposal.id, %{title: "x"}) == {:error, :not_found}
    {:ok, _} = Goals.cancel_proposal(c.person, proposal.id)
    assert Goals.propose_goal(lead, proposal.id, %{title: "x"}) == {:error, :proposal_closed}
    assert Goals.cancel_proposal(c.person, proposal.id) == {:error, :proposal_closed}
    assert row(proposal).revision == 0
    assert row(proposal).status == "cancelled"
  end

  test "an expired row is closed to the agent and to the person", c do
    lead = lead!(c)
    proposal = start!(c.person)
    proposal = ready!(lead, proposal)
    set_now(DateTime.add(@now, 7 * 86_400))
    assert Goals.propose_goal(lead, proposal.id, %{title: "x"}) == {:error, :proposal_closed}

    assert Goals.confirm_proposal(c.person, proposal.id, proposal.revision) ==
             {:error, :proposal_closed}

    assert Goals.say_in_conversation(c.person, proposal.id, "hi") == {:error, :proposal_closed}
    assert Goals.list_proposals(c.person) == {:ok, []}
    assert goal_count() == 0
  end

  # ── confirm ───────────────────────────────────────────────────────────────

  test "confirm creates one goal as the person with the agent as coach", c do
    lead = lead!(c)
    proposal = c.person |> start!() |> then(&ready!(lead, &1))
    assert goal_count() == 0

    assert {:ok, %{goal: goal, proposal: confirmed}} =
             Goals.confirm_proposal(c.person, proposal.id, proposal.revision)

    assert goal.owner_user_id == c.person.id
    assert goal.coach_agent_id == lead.id
    assert goal.org_id == c.org
    assert goal.kind == "personal"
    assert goal.title == "VIOLET-ANVIL half marathon"
    assert goal.why == "To feel strong"
    assert goal.unit == "km"
    assert Decimal.equal?(goal.target_value, "21.1")
    assert goal.source_key == "self_reported"
    assert goal.agent_mode == "coach"
    assert goal.rhythm == "weekly"
    assert goal.rhythm_weekday == 3
    assert goal.outreach == "gentle"
    assert Repo.aggregate(from(g in Grant, where: g.goal_id == ^goal.id), :count) == 0

    {:ok, stops} = Goals.list_stops(c.person, goal.id)

    assert Enum.map(stops, &{&1.position, &1.label}) == [
             {1, "First 5k"},
             {2, "10k"},
             {3, "Race day"}
           ]

    assert Enum.at(stops, 0).due_on == ~D[2026-12-01]
    assert Enum.at(stops, 2).caption == "the big one"

    assert confirmed.status == "confirmed"
    assert confirmed.goal_id == goal.id
    assert confirmed.confirmed_at
    assert row(proposal).goal_id == goal.id

    assert_received {:signal, signal}

    assert signal.metadata.prompt ==
             "The person confirmed the goal from conversation #{proposal.id}. Goal id: #{goal.id}. " <>
               "You are its coach. Tell them in this goal's conversation (space #{proposal.space_id}) " <>
               "that you are researching, then record each finding with goal_takeaway_add. " <>
               "A finding needs at least one source."

    assert signal.metadata.responsibility_key == "goals.research"
    refute inspect(signal) =~ "VIOLET-ANVIL"
    refute inspect(signal) =~ "ZEBRA-QUARTZ"

    # One proposal makes at most one goal.
    assert Goals.confirm_proposal(c.person, proposal.id, proposal.revision) ==
             {:error, :proposal_closed}

    assert goal_count() == 1
    refute_received {:signal, _}

    # The conversation stays open for talk after confirmation.
    assert {:ok, _} = Goals.say_in_conversation(c.person, proposal.id, "Thanks")
    assert Goals.current_proposal(c.person) == {:ok, nil}
  end

  test "a stale revision, a row not ready and a non-integer revision write nothing", c do
    lead = lead!(c)
    proposal = start!(c.person)
    {:ok, partial} = Goals.propose_goal(lead, proposal.id, %{title: "x"})

    assert Goals.confirm_proposal(c.person, proposal.id, partial.revision) ==
             {:error, :proposal_not_ready}

    shown = ready!(lead, proposal)
    {:ok, rewritten} = Goals.propose_goal(lead, proposal.id, %{title: "Something else"})
    before = counts()

    assert Goals.confirm_proposal(c.person, proposal.id, shown.revision) ==
             {:error, :proposal_changed}

    assert Goals.confirm_proposal(c.person, proposal.id, "#{rewritten.revision}") ==
             {:error, :proposal_changed}

    assert counts() == before
    assert row(proposal).status == "open"
    refute_received {:signal, _}

    assert {:ok, %{goal: %{title: "Something else"}}} =
             Goals.confirm_proposal(c.person, proposal.id, rewritten.revision)
  end

  test "a failing goal write rolls everything back and leaves the row open", c do
    lead = lead!(c)
    proposal = c.person |> start!() |> then(&ready!(lead, &1))
    # The person can no longer read the org the proposal names.
    Repo.delete_all(from(m in Platform.Tenancy.OrgMembership, where: m.user_id == ^c.person.id))

    before = counts()

    assert Goals.confirm_proposal(c.person, proposal.id, proposal.revision) ==
             {:error, :org_not_visible}

    assert counts() == before
    assert row(proposal).status == "open"
    assert row(proposal).confirmed_at == nil
  end

  test "forgery: the row's agent, another agent and nil make no goal", c do
    lead = lead!(c)
    proposal = c.person |> start!() |> then(&ready!(lead, &1))
    other = agent!()

    assert Goals.confirm_proposal(lead, proposal.id, proposal.revision) == {:error, :forbidden}
    assert Goals.confirm_proposal(other, proposal.id, proposal.revision) == {:error, :not_found}
    assert Goals.confirm_proposal(nil, proposal.id, proposal.revision) == {:error, :not_found}

    for actor <- [lead, other, nil] do
      assert Goals.create_goal(actor, %{org_id: c.org, title: "Forged"}) == {:error, :not_found}
    end

    assert goal_count() == 0
    assert row(proposal).status == "open"
  end

  # ── privacy ───────────────────────────────────────────────────────────────

  test "others get exactly the value of a missing id from every proposal function", c do
    lead = lead!(c)
    proposal = c.person |> start!() |> then(&ready!(lead, &1))
    before = counts()
    stored = row(proposal)

    calls = fn actor, id ->
      [
        Goals.get_proposal(actor, id),
        Goals.conversation(actor, id),
        Goals.say_in_conversation(actor, id, "hello"),
        Goals.propose_goal(actor, id, %{title: "Hijack"}),
        Goals.confirm_proposal(actor, id, proposal.revision),
        Goals.cancel_proposal(actor, id),
        Goals.subscribe_proposal(actor, id)
      ]
    end

    missing = calls.(c.person, Ecto.UUID.generate())
    assert Enum.all?(missing, &(&1 == {:error, :not_found}))
    assert calls.(c.person, "not-a-uuid") == missing

    for actor <- [member!(c.org), root_admin!(), agent!(), nil] do
      assert calls.(actor, proposal.id) == missing, inspect(actor)
      assert calls.(actor, Ecto.UUID.generate()) == missing
      assert Goals.list_proposals(actor) == {:ok, []}
      assert Goals.current_proposal(actor) == {:ok, nil}
    end

    refute_received {:goal_proposal_changed, _}
    assert counts() == before
    assert row(proposal) == stored
  end
end
