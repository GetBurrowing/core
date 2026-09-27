defmodule Platform.Chat.AttentionRouterTest do
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message}
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "Zip reply: #{message}", model: "stub", usage: %{}}}
    end
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_pid = Application.get_env(:platform, :chat_agent_test_pid)

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn ->
      Application.put_env(:platform, :chat_agent_module, previous_module)
      Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode)
      Application.put_env(:platform, :chat_agent_test_pid, previous_pid)
    end)

    router =
      Process.whereis(AttentionRouter) ||
        start_supervised!({AttentionRouter, []})

    Sandbox.allow(Repo, self(), router)

    # Ensure ActiveAgentStore is running and sandbox-allowed
    store =
      Process.whereis(ActiveAgentStore) ||
        start_supervised!({ActiveAgentStore, []})

    Sandbox.allow(Repo, self(), store)

    :ok
  end

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      display_name: "Rowan",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Zip",
      status: "active",
      max_concurrent: 1,
      sandbox_mode: "off",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    }

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    agent
  end

  defp create_message(space_id, participant_id, attrs \\ %{}) do
    defaults = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: "hello"
    }

    {:ok, message} =
      %Message{}
      |> Message.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    message
  end

  defp unique_slug do
    "test-#{System.unique_integer([:positive])}"
  end

  # Insert a real Platform.Accounts.User for tests that exercise archived-user
  # filtering (Stage 3). Most other tests in this file use bogus participant_ids
  # because chat_participants has no FK to users; the archival helper's LEFT
  # JOIN keeps those bogus rows visible while still dropping known-archived
  # users. Tests here need REAL user rows so `Accounts.archive_user/1` has
  # something to flip.
  defp insert_test_user(opts \\ []) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: Keyword.get(opts, :name, "User #{n}"),
      email: Keyword.get(opts, :email, "user-#{n}@example.com"),
      oidc_sub: "sub-#{n}"
    })
  end

  defp participant_count(space_id) do
    Repo.aggregate(
      from(p in Platform.Chat.Participant, where: p.space_id == ^space_id),
      :count
    )
  end

  defp drain do
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  describe "DM spaces" do
    test "always routes to agent participant without mention" do
      space = create_space(%{kind: "dm"})
      user = create_participant(space.id)
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "hey, what's up?"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "hey, what's up?", _opts}, 500
      drain()
    end
  end

  describe "execution spaces" do
    test "log_only messages return empty" do
      space = create_space(%{kind: "execution"})
      user = create_participant(space.id)
      agent = create_agent()
      Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "log entry", log_only: true})
      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 100
      drain()
    end

    # Task 01a0e266 remediation. The two lines above ("log_only messages
    # return empty") pass whether or not the log_only exit works: that space
    # has no task, so there is no assignee to route to and no mutex, and the
    # router returns [] by falling silent. This test seeds the case that
    # discriminates: an execution space whose task HAS an agent assignee who
    # is NOT yet a participant, which is exactly the space the rule-6
    # fallback (`execution_assignee_participant/1`) would join and wake.
    #
    # Before the fix the exit was a bare `if` whose value Elixir discarded, so
    # every `ExecutionSpace.post_log/3` added the assignee (attention "all")
    # and woke it. Paired with the positive control below it in the SAME
    # space, so a vacuous pass (the router never processing the post at all)
    # is ruled out: the same path demonstrably joins and dispatches for a
    # non-log message.
    test "post_log leaves an absent assignee out and dispatches nothing; a non-log post still routes to it" do
      agent = create_agent(%{name: "Beacon"})
      {:ok, project} = Tasks.create_project(%{name: "Execution log_only project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Execution log_only task",
          status: "in_progress",
          assignee_id: agent.id,
          assignee_type: "agent"
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      # post_log inserts the TaskRouter system participant on a space's first
      # log line; create it first so the count below measures routing only.
      {:ok, _system} = ExecutionSpace.ensure_system_participant(space.id)
      :ok = Platform.Chat.PubSub.subscribe(space.id)

      before = participant_count(space.id)
      assert Chat.get_agent_participant(space.id, agent.id) == nil

      # Through the production path: post_message -> telemetry -> router.
      {:ok, log} = ExecutionSpace.post_log(space.id, "Dispatch withheld: control log line")
      assert log.log_only == true
      drain()

      assert participant_count(space.id) == before
      assert Chat.get_agent_participant(space.id, agent.id) == nil
      assert ActiveAgentStore.get_active(space.id) == nil
      refute_received {:attention_needed, _}
      refute_received {:agent_chat_called, _, _}

      # And directly: the router's own decision for that message is empty.
      assert {:ok, []} = AttentionRouter.route(log)
      assert participant_count(space.id) == before
      assert Chat.get_agent_participant(space.id, agent.id) == nil
      refute_receive {:attention_needed, _}, 100

      # POSITIVE CONTROL, same space, same production path: a non-log post
      # joins the assignee and dispatches to it, as before this fix.
      user = create_participant(space.id)
      before_control = participant_count(space.id)

      {:ok, _steer} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: user.id,
          content_type: "text",
          content: "are you still working?"
        })

      drain()

      assert %{id: assignee_participant_id} = Chat.get_agent_participant(space.id, agent.id)
      assert participant_count(space.id) == before_control + 1
      assert ActiveAgentStore.get_active(space.id) == assignee_participant_id

      assert_receive {:attention_needed,
                      %{participant_id: ^assignee_participant_id, reason: :watch}},
                     500

      assert_receive {:agent_chat_called, "are you still working?", _opts}, 500
      drain()
    end

    # Task 01a0e266 remediation, the sibling exit. Before the fix
    # `unless space do ... end` discarded its value too, so a message whose
    # space row does not exist fell through to `route_agents/3`, whose
    # `%Space{}` head raised FunctionClauseError inside the GenServer call.
    test "a message whose space does not exist routes to nobody and does not crash the router" do
      router = Process.whereis(AttentionRouter)

      message = %Message{
        id: Ecto.UUID.generate(),
        space_id: Ecto.UUID.generate(),
        participant_id: Ecto.UUID.generate(),
        content_type: "text",
        content: "orphan",
        log_only: false
      }

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, []} = AttentionRouter.route(message)
      end)

      assert Process.whereis(AttentionRouter) == router
    end

    test "non-log steering routes to the assigned task agent even without an active mutex" do
      agent = create_agent(%{name: "Beacon"})
      {:ok, project} = Tasks.create_project(%{name: "Execution routing project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Execution routing task",
          status: "in_progress",
          assignee_id: agent.id,
          assignee_type: "agent"
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      user = create_participant(space.id)

      message = create_message(space.id, user.id, %{content: "are you still working?"})

      assert {:ok, [%{participant_id: agent_participant_id, reason: :watch}]} =
               AttentionRouter.route(message)

      assert is_binary(agent_participant_id)
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "are you still working?", _opts}, 500
      drain()
    end

    test "execution steering follows the current assignee when the mutex is stale after reassignment" do
      agent_one = create_agent(%{name: "Beacon"})
      agent_two = create_agent(%{name: "Nova"})
      {:ok, project} = Tasks.create_project(%{name: "Execution reassignment project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Execution reassignment task",
          status: "in_progress",
          assignee_id: agent_one.id,
          assignee_type: "agent"
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      user = create_participant(space.id)

      {:ok, participant_one} =
        Chat.add_agent_participant(space.id, agent_one, display_name: "Beacon")

      {:ok, participant_two} =
        Chat.add_agent_participant(space.id, agent_two, display_name: "Nova")

      participant_two_id = participant_two.id
      ActiveAgentStore.set_active(space.id, participant_one.id)

      {:ok, _task} =
        Tasks.update_task(task, %{assignee_id: agent_two.id, assignee_type: "agent"})

      message = create_message(space.id, user.id, %{content: "please pick up the new direction"})

      assert {:ok, [%{participant_id: ^participant_two_id, reason: :watch}]} =
               AttentionRouter.route(message)

      assert ActiveAgentStore.get_active(space.id) == participant_two_id

      assert_receive {:agent_chat_called, "please pick up the new direction", _opts}, 500
      drain()
    end

    test "execution steering rejoins a departed assignee participant instead of dropping feedback" do
      agent = create_agent(%{name: "Beacon"})
      {:ok, project} = Tasks.create_project(%{name: "Execution departed participant project"})

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Execution departed participant task",
          status: "in_progress",
          assignee_id: agent.id,
          assignee_type: "agent"
        })

      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      user = create_participant(space.id)
      {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: "Beacon")

      participant_id = participant.id
      ActiveAgentStore.set_active(space.id, participant_id)

      # Hard-delete the participant to simulate dismissal (ADR 0038).
      {:ok, _} = Chat.remove_participant(participant)

      message = create_message(space.id, user.id, %{content: "are you still on this?"})

      # With the mutex holder gone, execution-space routing falls through to
      # the watch path, which re-activates the assignee.
      assert {:ok, [%{reason: reason}]} = AttentionRouter.route(message)
      assert reason in [:watch, :mention, :active_agent]
      # A fresh participant row was created by the execution-space add path.
      assert Chat.get_agent_participant(space.id, agent.id) != nil

      assert_receive {:agent_chat_called, "are you still on this?", _opts}, 500
      drain()
    end
  end

  describe "single @mention" do
    test "sets active agent and routes to mentioned agent" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      # Add to roster as member
      Chat.add_space_agent(space.id, agent.id, role: "member")

      message = create_message(space.id, user.id, %{content: "hey @zip help me"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      # Verify active agent was set
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "hey @zip help me", _opts}, 500
      drain()
    end
  end

  describe "multi @mention" do
    test "routes to all mentioned agents and clears active" do
      space = create_space(%{kind: "group"})
      user = create_participant(space.id)

      agent1 = create_agent(%{name: "Zip"})
      agent2 = create_agent(%{name: "Nova"})

      {:ok, p1} = Chat.add_agent_participant(space.id, agent1, display_name: "Zip")
      {:ok, p2} = Chat.add_agent_participant(space.id, agent2, display_name: "Nova")

      Chat.add_space_agent(space.id, agent1.id, role: "principal")
      Chat.add_space_agent(space.id, agent2.id, role: "member")

      # Set one as active first to verify it gets cleared
      ActiveAgentStore.set_active(space.id, p1.id)

      message = create_message(space.id, user.id, %{content: "hey @zip and @nova help"})

      {:ok, decisions} = AttentionRouter.route(message)

      participant_ids = Enum.map(decisions, & &1.participant_id) |> Enum.sort()
      expected_ids = Enum.sort([p1.id, p2.id])
      assert participant_ids == expected_ids

      assert Enum.all?(decisions, fn d -> d.reason == :multi_mention end)

      # Active agent should be cleared
      assert ActiveAgentStore.get_active(space.id) == nil

      drain()
    end
  end

  describe "skip_mention_scan metadata flag" do
    test "silences named-agent mention decisions on messages that opt out" do
      # System-event pipelines that embed raw chat activity (Historian digest
      # posts, meeting-summary rebroadcasts) can stamp
      # `metadata["skip_mention_scan"] = true` on the outgoing message so the
      # `@[Name]` tokens quoted inside the embedded activity don't get
      # tokenised as live mentions and fan out to every quoted agent.
      #
      # Repro of the 2026-07-10 bug that prompted the flag: Rowan noticed
      # Dalton was receiving Historian dispatches meant for Higgins. Cause
      # was the Historian post embedding a 24h digest full of real Rowan→
      # Dalton `@[Dalton]` mentions from other spaces; AttentionRouter's
      # regex tokenised each one and produced a `:multi_mention` decision.
      space = create_space(%{kind: "group"})
      user = create_participant(space.id)

      agent1 = create_agent(%{name: "Zip"})
      agent2 = create_agent(%{name: "Nova"})
      {:ok, _p1} = Chat.add_agent_participant(space.id, agent1, display_name: "Zip")
      {:ok, _p2} = Chat.add_agent_participant(space.id, agent2, display_name: "Nova")
      Chat.add_space_agent(space.id, agent1.id, role: "principal")
      Chat.add_space_agent(space.id, agent2.id, role: "member")

      message =
        create_message(space.id, user.id, %{
          content: "digest quotes @[Zip] and @[Nova]",
          metadata: %{"skip_mention_scan" => true}
        })

      {:ok, decisions} = AttentionRouter.route(message)

      refute Enum.any?(decisions, fn d -> d.reason in [:mention, :multi_mention] end)

      drain()
    end

    test "silences @[here] broadcast fan-out on messages that opt out" do
      # Even if the embedded digest contains a literal `@[here]` string
      # somewhere (e.g. quoting a real broadcast someone else sent), the
      # opt-out message must not broadcast to every human recipient of
      # the system space.
      space = create_space(%{kind: "channel"})
      sender = create_participant(space.id)
      _recipient = create_participant(space.id)

      message =
        create_message(space.id, sender.id, %{
          content: "digest: @[here] please read",
          metadata: %{"skip_mention_scan" => true}
        })

      {:ok, decisions} = AttentionRouter.route(message)

      refute Enum.any?(decisions, fn d -> d.reason == :here end)

      drain()
    end

    test "leaves messages WITHOUT the flag fully mention-routed (regression guard)" do
      # Sanity: the flag must not change routing for the vast majority of
      # messages that don't set it.
      space = create_space(%{kind: "group"})
      user = create_participant(space.id)

      agent1 = create_agent(%{name: "Zip"})
      {:ok, p1} = Chat.add_agent_participant(space.id, agent1, display_name: "Zip")
      Chat.add_space_agent(space.id, agent1.id, role: "principal")

      # Same content, no metadata flag.
      message = create_message(space.id, user.id, %{content: "hey @[Zip]"})

      {:ok, decisions} = AttentionRouter.route(message)

      assert Enum.any?(decisions, fn d ->
               d.participant_id == p1.id and d.reason == :mention
             end)

      drain()
    end
  end

  # Task 01a0d90f stage 5: a peer install's shared-space message
  # (`metadata["source"] == "federation_inbound"`) is untrusted outside text
  # and yields NO agent decision, through the same `untrusted_inbound?/1`
  # clause as inbound email. Each case has a POSITIVE CONTROL: the same state
  # and content from a local author DOES route, so the refusal is the source
  # clause and not a fixture that could never route.
  describe "federation_inbound messages" do
    # AttentionRouter matches a mention against the participant's display
    # name, so the token is built from it (at runtime, never literally).
    defp mention_token(name), do: "@" <> "[" <> name <> "]"

    defp armed_agent!(space) do
      agent = create_agent(%{name: "Zip"})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: "Zip")
      Chat.add_space_agent(space.id, agent.id, role: "principal")
      ActiveAgentStore.set_active(space.id, participant.id)
      {agent, participant}
    end

    test "the armed mutex holder gets no decision; a local message in the same state does" do
      space = create_space()
      local = create_participant(space.id, %{display_name: "Pat"})
      remote = create_participant(space.id, %{participant_type: "system", display_name: "Rem"})
      {_agent, armed} = armed_agent!(space)
      armed_id = armed.id

      # POSITIVE CONTROL: an ordinary local message routes to the holder.
      control = create_message(space.id, local.id, %{content: "local words"})
      {:ok, control_decisions} = AttentionRouter.route(control)

      assert Enum.any?(control_decisions, &match?(%{participant_id: ^armed_id}, &1))
      assert_receive {:agent_chat_called, "local words", _}, 500

      message =
        create_message(space.id, remote.id, %{
          content: "remote words",
          metadata: %{"source" => "federation_inbound"}
        })

      {:ok, decisions} = AttentionRouter.route(message)
      refute Enum.any?(decisions, &(&1.participant_id == armed_id))
      assert ActiveAgentStore.get_active(space.id) == armed_id
      refute_receive {:agent_chat_called, "remote words", _}, 200
      drain()
    end

    test "an UNESCAPED mention without skip_mention_scan still routes to nobody" do
      space = create_space(%{kind: "group"})
      local = create_participant(space.id)
      remote = create_participant(space.id, %{participant_type: "system", display_name: "Rem"})
      agent = create_agent(%{name: "Nova"})
      {:ok, agent_p} = Chat.add_agent_participant(space.id, agent, display_name: "Nova")
      Chat.add_space_agent(space.id, agent.id, role: "member")
      content = "hey " <> mention_token("Nova") <> " run this"

      # POSITIVE CONTROL: the same content from a local author is a mention.
      control = create_message(space.id, local.id, %{content: content})
      {:ok, control_decisions} = AttentionRouter.route(control)

      assert Enum.any?(
               control_decisions,
               &(&1.participant_id == agent_p.id and &1.reason == :mention)
             )

      # The escape and the skip flag are deliberately absent: the source
      # clause alone must hold.
      message =
        create_message(space.id, remote.id, %{
          content: content,
          metadata: %{"source" => "federation_inbound"}
        })

      {:ok, decisions} = AttentionRouter.route(message)
      refute Enum.any?(decisions, &(&1.participant_id == agent_p.id))
      drain()
    end

    test "untrusted_inbound?/1 covers email and federation, and keys on source only" do
      assert AttentionRouter.untrusted_inbound?(%Message{
               metadata: %{"source" => "federation_inbound"}
             })

      assert AttentionRouter.untrusted_inbound?(%Message{
               metadata: %{"source" => "email_inbound"}
             })

      refute AttentionRouter.untrusted_inbound?(%Message{metadata: %{"source" => "federation"}})
      refute AttentionRouter.untrusted_inbound?(%Message{metadata: %{}})
      assert AttentionRouter.untrusted_inbound_sources() == ~w(email_inbound federation_inbound)
    end
  end

  describe "no mention + active agent" do
    test "routes to active agent and refreshes timeout" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      # Set as active agent (simulates prior @mention)
      ActiveAgentStore.set_active(space.id, agent_participant.id)

      message = create_message(space.id, user.id, %{content: "and also do this"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :active_agent}]} =
               AttentionRouter.route(message)

      # Active agent should still be set
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "and also do this", _opts}, 500
      drain()
    end
  end

  describe "no mention + no active" do
    test "returns empty (silence) and does not arm the principal agent" do
      agent = create_agent(%{name: "Zip"})

      space = create_space(%{kind: "group"})
      user = create_participant(space.id)

      Chat.add_agent_participant(space.id, agent, display_name: "Zip")
      Chat.add_space_agent(space.id, agent.id, role: "principal")

      message = create_message(space.id, user.id, %{content: "hello everyone"})

      assert {:ok, []} = AttentionRouter.route(message)

      # Nothing may arm the mutex behind the user's back — only an @mention
      # (or the execution task-assignee path) opens the eye.
      assert ActiveAgentStore.get_active(space.id) == nil

      refute_receive {:agent_chat_called, _, _}, 200
      drain()
    end

    test "returns empty (silence) in a channel" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      Chat.add_agent_participant(space.id, agent, display_name: "Zip")
      Chat.add_space_agent(space.id, agent.id, role: "principal")

      message = create_message(space.id, user.id, %{content: "just chatting"})
      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 200
      drain()
    end
  end

  describe "agent self-message filtering" do
    test "agent doesn't respond to its own messages in DM" do
      space = create_space(%{kind: "dm"})
      agent = create_agent()

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      agent_message =
        create_message(space.id, agent_participant.id, %{content: "I'm the agent speaking"})

      assert {:ok, []} = AttentionRouter.route(agent_message)
      refute_receive {:agent_chat_called, _, _}, 200
      drain()
    end
  end

  describe "resolve_attention_mode/2" do
    test "returns kind-based default for each space kind" do
      participant = %Platform.Chat.Participant{}

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "channel"},
               participant
             ) == "on_mention"

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "dm"},
               participant
             ) == "directed"

      assert AttentionRouter.resolve_attention_mode(
               %Platform.Chat.Space{kind: "group"},
               participant
             ) == "collaborative"
    end
  end

  describe "mention → active agent → no mention flow" do
    test "mention sets active, followup routes via active_agent, clearing falls silent" do
      agent = create_agent(%{name: "Zip"})

      space = create_space(%{kind: "channel"})

      user = create_participant(space.id)

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")
      agent_participant_id = agent_participant.id

      # Step 1: @mention sets active agent
      mention = create_message(space.id, user.id, %{content: "@zip help me"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(mention)

      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      # Step 2: followup without mention → routes via active_agent
      followup = create_message(space.id, user.id, %{content: "and also this"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :active_agent}]} =
               AttentionRouter.route(followup)

      # Step 3: closing the eye is final — the next un-addressed message
      # routes to nobody and does not re-arm the agent.
      ActiveAgentStore.clear_active(space.id)
      after_close = create_message(space.id, user.id, %{content: "new topic"})

      assert {:ok, []} = AttentionRouter.route(after_close)
      assert ActiveAgentStore.get_active(space.id) == nil

      drain()
    end
  end

  describe "stale active agent cleanup" do
    test "clears the mutex when the active agent has left" do
      agent = create_agent(%{name: "Zip"})
      agent2 = create_agent(%{name: "Zip2"})

      # Two agents so the stale-vs-present distinction is still exercised:
      # agent is dismissed, agent2 stays in the roster and must NOT inherit
      # the eye.
      space = create_space(%{kind: "group"})

      user = create_participant(space.id)

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      {:ok, _agent2_participant} =
        Chat.add_agent_participant(space.id, agent2, display_name: "Zip2")

      Chat.add_space_agent(space.id, agent2.id, role: "member")

      # Set the first agent as active
      ActiveAgentStore.set_active(space.id, agent_participant.id)

      # Dismiss the first agent (hard-delete post-ADR-0038)
      {:ok, _} = Chat.remove_participant(agent_participant)

      message = create_message(space.id, user.id, %{content: "feedback for agent"})
      {:ok, decisions} = AttentionRouter.route(message)

      # The stale mutex is cleared outright — not handed to the remaining agent
      assert ActiveAgentStore.get_active(space.id) == nil

      # Eye closed, so nobody hears the message
      assert decisions == []
      refute_receive {:agent_chat_called, _, _}, 200

      drain()
    end

    test "keeps mutex when active agent is still present but authored the message" do
      space = create_space(%{kind: "channel"})
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      # Set agent as active
      ActiveAgentStore.set_active(space.id, agent_participant.id)

      # Agent sends its own message — should NOT clear the mutex
      message =
        create_message(space.id, agent_participant.id, %{content: "I'm responding"})

      {:ok, decisions} = AttentionRouter.route(message)

      # No routing needed for self-message
      assert decisions == []

      # Mutex should still be set (agent is still an active participant)
      assert ActiveAgentStore.get_active(space.id) == agent_participant.id

      drain()
    end
  end

  # The header eye IS the mutex (task 019f9790). Before this task three
  # header controls disagreed with one another and none of them was the
  # thing that actually routed messages; `watch_enabled` + `primary_agent_id`
  # could re-arm an agent behind the user's back. These tests pin the
  # lifecycle the eye now promises, end to end through the router.
  describe "eye-as-mutex lifecycle" do
    setup do
      agent = create_agent(%{name: "Zip"})
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      %{space: space, user: user, agent: agent, agent_participant: agent_participant}
    end

    test "an @mention opens the eye and is remembered as the last agent", %{
      space: space,
      user: user,
      agent_participant: agent_participant
    } do
      message = create_message(space.id, user.id, %{content: "hey @zip help me"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      # Stage 2's widened ETS row: arming by mention populates both fields, so
      # a later close still knows who to offer on re-open.
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id
      assert ActiveAgentStore.get_last_agent(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "hey @zip help me", _opts}, 500
      drain()
    end

    test "an open eye routes unaddressed messages and preserves last-agent memory", %{
      space: space,
      user: user,
      agent_participant: agent_participant
    } do
      ActiveAgentStore.set_active(space.id, agent_participant.id)
      agent_participant_id = agent_participant.id

      message = create_message(space.id, user.id, %{content: "and also do this"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :active_agent}]} =
               AttentionRouter.route(message)

      # The router refreshes the TTL via `set_active/2` on every routed
      # message; `last` must survive that refresh unchanged.
      assert ActiveAgentStore.get_active(space.id) == agent_participant_id
      assert ActiveAgentStore.get_last_agent(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "and also do this", _opts}, 500
      drain()
    end

    test "a closed eye means silence — the agent is not called at all", %{
      space: space,
      user: user,
      agent_participant: agent_participant
    } do
      # Open the eye the way a user would, then close it.
      mention = create_message(space.id, user.id, %{content: "@zip you there?"})
      assert {:ok, [%{reason: :mention}]} = AttentionRouter.route(mention)
      assert_receive {:agent_chat_called, "@zip you there?", _opts}, 500

      ActiveAgentStore.clear_active(space.id)
      assert ActiveAgentStore.get_active(space.id) == nil

      after_close = create_message(space.id, user.id, %{content: "ok humans only now"})

      assert {:ok, []} = AttentionRouter.route(after_close)

      # The whole point of stage 5: no `route_watch/2` fallback may survive to
      # re-arm the agent behind the user's back.
      refute_receive {:agent_chat_called, _, _}, 200
      assert ActiveAgentStore.get_active(space.id) == nil
      assert ActiveAgentStore.get_last_agent(space.id) == agent_participant.id

      drain()
    end

    test "closing the eye does not poison the @mention path", %{
      space: space,
      user: user,
      agent_participant: agent_participant
    } do
      ActiveAgentStore.set_active(space.id, agent_participant.id)
      ActiveAgentStore.clear_active(space.id)
      assert ActiveAgentStore.get_active(space.id) == nil

      agent_participant_id = agent_participant.id
      mention = create_message(space.id, user.id, %{content: "@zip back to you"})

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(mention)

      assert ActiveAgentStore.get_active(space.id) == agent_participant_id

      assert_receive {:agent_chat_called, "@zip back to you", _opts}, 500
      drain()
    end

    test "an agent DM stays :directed even after the mutex is cleared for that space" do
      # DMs have no eye control at all — `route_agents/3` answers `:directed`
      # unconditionally, so mutex state must not reach them.
      space = create_space(%{kind: "dm"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Nova"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Nova")

      ActiveAgentStore.set_active(space.id, agent_participant.id)
      ActiveAgentStore.clear_active(space.id)
      assert ActiveAgentStore.get_active(space.id) == nil

      message = create_message(space.id, user.id, %{content: "just us two"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "just us two", _opts}, 500
      drain()
    end

    test "the eye falls closed on TTL expiry but the space still remembers the agent", %{
      space: space,
      user: user,
      agent_participant: agent_participant
    } do
      mention = create_message(space.id, user.id, %{content: "@zip quick one"})
      assert {:ok, [%{reason: :mention}]} = AttentionRouter.route(mention)
      assert_receive {:agent_chat_called, "@zip quick one", _opts}, 500
      assert ActiveAgentStore.get_active(space.id) == agent_participant.id

      # The assertion above used to race a deliberately-shortened 50ms timeout:
      # under load the timer fired before the test got here and the eye was
      # already closed. The timeout is no longer overridden, so at the 900_000ms
      # default it cannot fire during this test at all. Arming is asserted
      # directly instead: `set_active/2` keeps the timer ref in the ETS row's
      # 4th element (row shape is documented on the store), and the table handle
      # comes from the store's own state rather than a hardcoded table name.
      # `Process.read_timer/1` is the same instrument `task_router_test.exs`
      # uses to prove an armed deadline.
      table = :sys.get_state(ActiveAgentStore).table
      [{_space_id, _active, _last, timer_ref}] = :ets.lookup(table, space.id)

      assert is_reference(timer_ref), "set_active/2 armed no inactivity timer"
      remaining = Process.read_timer(timer_ref)

      assert is_integer(remaining) and remaining > 0 and remaining <= 900_000,
             "inactivity timer is not pending within the default window: #{inspect(remaining)}"

      # Drive expiry through the store's own timer message rather than a wall
      # clock, then synchronise on its mailbox: `get_active/1` reads ETS
      # directly, so without this call we would race the `handle_info` we just
      # triggered — the same class of race this change removes.
      send(ActiveAgentStore, {:timeout, space.id, agent_participant.id})
      _ = :sys.get_state(ActiveAgentStore)
      assert ActiveAgentStore.get_active(space.id) == nil

      after_expiry = create_message(space.id, user.id, %{content: "much later"})

      assert {:ok, []} = AttentionRouter.route(after_expiry)
      refute_receive {:agent_chat_called, _, _}, 200

      # Expiry closes the eye but keeps the memory, so click-to-resume still
      # offers the agent the user was last talking to.
      assert ActiveAgentStore.get_last_agent(space.id) == agent_participant.id

      drain()
    end
  end

  describe "bracketed @[Name] mentions (ADR 0037)" do
    test "routes on exact bracketed match with multi-word display name" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Rowan Ellis"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Rowan Ellis")

      Chat.add_space_agent(space.id, agent.id, role: "member")

      message =
        create_message(space.id, user.id, %{content: "hey @[Rowan Ellis] can you look"})

      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      drain()
    end

    test "bracketed @[Rowan] does not leak to @[Rowan Ellis] (no prefix ambiguity)" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)

      rowan_agent = create_agent(%{name: "Rowan"})
      rowan_m_agent = create_agent(%{name: "Rowan Ellis"})

      {:ok, rowan_participant} =
        Chat.add_agent_participant(space.id, rowan_agent, display_name: "Rowan")

      {:ok, _rowan_m_participant} =
        Chat.add_agent_participant(space.id, rowan_m_agent, display_name: "Rowan Ellis")

      Chat.add_space_agent(space.id, rowan_agent.id, role: "member")
      Chat.add_space_agent(space.id, rowan_m_agent.id, role: "member")

      message = create_message(space.id, user.id, %{content: "hey @[Rowan] look here"})

      rowan_participant_id = rowan_participant.id

      # Only Rowan is routed — Rowan Ellis's participant must not appear.
      assert {:ok, [%{participant_id: ^rowan_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      drain()
    end

    test "legacy @name still routes in a pre-migration message" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "member")

      message = create_message(space.id, user.id, %{content: "hey @zip help me"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      drain()
    end

    test "hybrid message: bracketed + legacy both route" do
      space = create_space(%{kind: "group"})
      user = create_participant(space.id)

      zip = create_agent(%{name: "Zip"})
      nova = create_agent(%{name: "Nova"})

      {:ok, zip_p} = Chat.add_agent_participant(space.id, zip, display_name: "Zip")
      {:ok, nova_p} = Chat.add_agent_participant(space.id, nova, display_name: "Nova")

      Chat.add_space_agent(space.id, zip.id, role: "member")
      Chat.add_space_agent(space.id, nova.id, role: "member")

      # User autocompletes Zip → bracketed; types @nova manually → legacy.
      message =
        create_message(space.id, user.id, %{content: "ping @[Zip] and also @nova please"})

      {:ok, decisions} = AttentionRouter.route(message)

      participant_ids = decisions |> Enum.map(& &1.participant_id) |> Enum.sort()
      assert participant_ids == Enum.sort([zip_p.id, nova_p.id])
      assert Enum.all?(decisions, fn d -> d.reason == :multi_mention end)

      drain()
    end

    test "@[Rowan Ellis] does not route to a legacy Rowan substring-match" do
      # Regression guard: ensure `@Rowan` substring inside `@[Rowan Ellis]`
      # does not leak into the legacy zone. Without stripping brackets first,
      # a plain-Rowan participant would be falsely routed.
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)

      rowan_agent = create_agent(%{name: "Rowan"})
      rowan_m_agent = create_agent(%{name: "Rowan Ellis"})

      {:ok, _rowan_p} = Chat.add_agent_participant(space.id, rowan_agent, display_name: "Rowan")

      {:ok, rowan_m_p} =
        Chat.add_agent_participant(space.id, rowan_m_agent, display_name: "Rowan Ellis")

      Chat.add_space_agent(space.id, rowan_agent.id, role: "member")
      Chat.add_space_agent(space.id, rowan_m_agent.id, role: "member")

      message = create_message(space.id, user.id, %{content: "hello @[Rowan Ellis]"})

      rowan_m_p_id = rowan_m_p.id

      assert {:ok, [%{participant_id: ^rowan_m_p_id, reason: :mention}]} =
               AttentionRouter.route(message)

      drain()
    end
  end

  # ── Parser-level unit tests (Stage 1 of @here notifications) ───────────────
  #
  # These exercise `extract_mention_tokens/1` and the back-compat shape of
  # `extract_bracketed_tokens/1`. No DB, no router pipeline — just the
  # tokenizer that the later fan-out / push / UI stages build on.

  describe "extract_mention_tokens/1 — @[here] broadcast sentinel" do
    test "recognizes @[here] at the start of a message" do
      assert AttentionRouter.extract_mention_tokens("@[here] heads up") ==
               [%{kind: :broadcast, target: :here}]
    end

    test "recognizes @[here] in the middle of a message" do
      assert AttentionRouter.extract_mention_tokens("hey folks @[here] check this") ==
               [%{kind: :broadcast, target: :here}]
    end

    test "recognizes @[here] immediately after punctuation" do
      assert AttentionRouter.extract_mention_tokens("status:@[here] update?") ==
               [%{kind: :broadcast, target: :here}]
    end

    test "returns two tokens when @[here] appears twice (dedup is fan-out's job)" do
      tokens = AttentionRouter.extract_mention_tokens("@[here] and again @[here]")

      assert tokens == [
               %{kind: :broadcast, target: :here},
               %{kind: :broadcast, target: :here}
             ]
    end

    test "distinguishes @[here] from an adjacent @[Name] mention" do
      tokens =
        AttentionRouter.extract_mention_tokens("ping @[Rowan Ellis] also @[here] please")

      assert tokens == [
               %{kind: :name, value: "Rowan Ellis"},
               %{kind: :broadcast, target: :here}
             ]
    end

    test "trailing space inside brackets is a name token, not a broadcast" do
      # `@[here ]` keeps whitespace significant — treat as a name token so
      # the broadcast classifier stays strict.
      assert AttentionRouter.extract_mention_tokens("@[here ] hello") ==
               [%{kind: :name, value: "here "}]
    end

    test "@[HERE] (uppercase) is a name token, not a broadcast" do
      # Case-insensitivity is a deferred follow-up. For now only the literal
      # lowercase form is special.
      assert AttentionRouter.extract_mention_tokens("@[HERE] hello") ==
               [%{kind: :name, value: "HERE"}]
    end

    test "@[Here] (title case) is a name token, not a broadcast" do
      assert AttentionRouter.extract_mention_tokens("@[Here] hello") ==
               [%{kind: :name, value: "Here"}]
    end

    test "@[hereish] (substring) is a name token, not a broadcast" do
      assert AttentionRouter.extract_mention_tokens("@[hereish] hello") ==
               [%{kind: :name, value: "hereish"}]
    end

    test "returns an empty list when no bracketed tokens are present" do
      assert AttentionRouter.extract_mention_tokens("plain message with no mentions") == []
    end

    test "preserves source order across mixed token kinds" do
      tokens =
        AttentionRouter.extract_mention_tokens(
          "@[here] first then @[Zip] then @[here] then @[Nova]"
        )

      assert tokens == [
               %{kind: :broadcast, target: :here},
               %{kind: :name, value: "Zip"},
               %{kind: :broadcast, target: :here},
               %{kind: :name, value: "Nova"}
             ]
    end

    test "non-binary input returns an empty list" do
      assert AttentionRouter.extract_mention_tokens(nil) == []
      assert AttentionRouter.extract_mention_tokens(123) == []
    end
  end

  # ── Fan-out tests (Stage 2 of @here notifications) ─────────────────────────
  #
  # These exercise the routing pipeline end-to-end: a message containing
  # `@[here]` must produce one `:here` decision per human recipient,
  # excluding the sender, regardless of per-participant attention_mode.
  # Agent routing remains under the mutex pipeline and is unaffected.

  describe "do_route/1 — @[here] fan-out" do
    test "5-human-1-agent channel fans out :here to all humans except sender" do
      space = create_space(%{kind: "channel"})

      sender = create_participant(space.id, %{display_name: "Sender"})

      _h2 =
        create_participant(space.id, %{
          display_name: "Alice",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      _h3 =
        create_participant(space.id, %{
          display_name: "Bob",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "all"
        })

      _h4 =
        create_participant(space.id, %{
          display_name: "Carol",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "active"
        })

      _h5 =
        create_participant(space.id, %{
          display_name: "Dan",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "heartbeat"
        })

      agent = create_agent(%{name: "Zip"})
      {:ok, _agent_p} = Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, sender.id, %{content: "team check-in @[here]"})

      {:ok, decisions} = AttentionRouter.route(message)

      here_decisions = Enum.filter(decisions, &(&1.reason == :here))

      assert length(here_decisions) == 4,
             "expected 4 :here decisions for the 4 non-sender humans, got #{inspect(decisions)}"

      here_pids = here_decisions |> Enum.map(& &1.participant_id) |> Enum.sort()

      participants =
        Platform.Repo.all(
          from(p in Platform.Chat.Participant,
            where: p.space_id == ^space.id and p.participant_type == "user"
          )
        )

      expected_pids =
        participants
        |> Enum.reject(&(&1.id == sender.id))
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert here_pids == expected_pids
      refute Enum.any?(here_decisions, &(&1.participant_id == sender.id))

      # Agent decisions are independent of @[here] — no :here for the agent.
      agent_decisions = Enum.reject(decisions, &(&1.reason == :here))
      refute Enum.any?(agent_decisions, &(&1.reason == :here))

      drain()
    end

    test "agent-only channel (no humans) emits zero :here decisions" do
      space = create_space(%{kind: "group"})

      agent1 = create_agent(%{name: "Zip"})
      agent2 = create_agent(%{name: "Nova"})
      {:ok, sender} = Chat.add_agent_participant(space.id, agent1, display_name: "Zip")
      {:ok, _other_agent} = Chat.add_agent_participant(space.id, agent2, display_name: "Nova")

      message = create_message(space.id, sender.id, %{content: "broadcast @[here]"})

      {:ok, decisions} = AttentionRouter.route(message)

      assert Enum.filter(decisions, &(&1.reason == :here)) == [],
             "expected no :here decisions when there are no human recipients"

      drain()
    end

    test "heartbeat-mode human still gets a :here decision (override), not ETS-queued" do
      space = create_space(%{kind: "channel"})
      sender = create_participant(space.id, %{display_name: "Sender"})

      heartbeat_user =
        create_participant(space.id, %{
          display_name: "Heartbeat User",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "heartbeat"
        })

      message = create_message(space.id, sender.id, %{content: "ping @[here]"})

      heartbeat_pid = heartbeat_user.id

      {:ok, decisions} = AttentionRouter.route(message)

      assert Enum.any?(decisions, fn d ->
               d.participant_id == heartbeat_pid and d.reason == :here
             end),
             "heartbeat-mode user must receive :here decision, got #{inspect(decisions)}"

      # ETS heartbeat queue should NOT have been populated for this signal —
      # the dispatch loop only queues `:heartbeat`, never `:here`.
      assert AttentionRouter.pending(heartbeat_pid) == []

      drain()
    end

    test "mention-mode human gets :here decision without self-name match" do
      space = create_space(%{kind: "channel"})
      sender = create_participant(space.id, %{display_name: "Sender"})

      # Their display name does NOT appear in the message — under the
      # ordinary "mention" path they'd be silenced. @[here] overrides that.
      mention_user =
        create_participant(space.id, %{
          display_name: "Quiet Person",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      message =
        create_message(space.id, sender.id, %{content: "no name here, just @[here] please"})

      mention_pid = mention_user.id

      {:ok, decisions} = AttentionRouter.route(message)

      assert Enum.any?(decisions, fn d ->
               d.participant_id == mention_pid and d.reason == :here
             end),
             "mention-mode user must receive :here override decision, got #{inspect(decisions)}"

      drain()
    end

    test "duplicate @[here] @[here] still produces exactly one decision per human" do
      space = create_space(%{kind: "channel"})
      sender = create_participant(space.id, %{display_name: "Sender"})

      _h2 =
        create_participant(space.id, %{
          display_name: "Alice",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      _h3 =
        create_participant(space.id, %{
          display_name: "Bob",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "all"
        })

      message =
        create_message(space.id, sender.id, %{content: "@[here] and again @[here] please"})

      {:ok, decisions} = AttentionRouter.route(message)

      here_decisions = Enum.filter(decisions, &(&1.reason == :here))

      here_pids = Enum.map(here_decisions, & &1.participant_id)

      assert length(here_pids) == length(Enum.uniq(here_pids)),
             "expected dedup per participant_id"

      assert length(here_decisions) == 2, "expected one decision per non-sender human"

      drain()
    end

    # V2 (e2e_behavior task 019edbbf, validation 019edbc2-991d-7a9c-8a7e-5a295744e32d):
    # When `@[here]` and a named `@[Name]` co-occur in one message, the named
    # recipient must receive BOTH a `:here` broadcast AND a `:mention`
    # decision. Other non-sender humans receive only `:here`. Agents are
    # untouched by the broadcast. Duplicate `@[here]` tokens dedupe to one
    # `:here` per participant. Sender is never in any decision.
    test "mixed @[here] + @[Name] produces :here per human plus a :mention for the named recipient" do
      space = create_space(%{kind: "channel"})

      rowan =
        create_participant(space.id, %{
          display_name: "Rowan",
          attention_mode: "mention"
        })

      alex =
        create_participant(space.id, %{
          display_name: "Alex",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      sam =
        create_participant(space.id, %{
          display_name: "Sam",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      harper =
        create_participant(space.id, %{
          display_name: "Harper",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      taylor =
        create_participant(space.id, %{
          display_name: "Taylor",
          participant_id: Ecto.UUID.generate(),
          attention_mode: "mention"
        })

      higgins_agent = create_agent(%{name: "Higgins"})
      geordi_agent = create_agent(%{name: "Geordi"})

      {:ok, _higgins_p} =
        Chat.add_agent_participant(space.id, higgins_agent, display_name: "Higgins")

      {:ok, _geordi_p} =
        Chat.add_agent_participant(space.id, geordi_agent, display_name: "Geordi")

      message =
        create_message(space.id, rowan.id, %{
          content:
            "@[here] kickoff in 10! Reminder: @[here], grab coffee. Also @[Alex] sync after. @[here]"
        })

      {:ok, decisions} = AttentionRouter.route(message)

      here_decisions = Enum.filter(decisions, &(&1.reason == :here))
      mention_decisions = Enum.filter(decisions, &(&1.reason == :mention))

      # 4 :here decisions — one per non-sender human (alex, sam, harper, taylor),
      # despite the message containing three `@[here]` tokens.
      assert length(here_decisions) == 4,
             "expected 4 :here decisions (one per non-sender human), got #{inspect(decisions)}"

      here_pids = here_decisions |> Enum.map(& &1.participant_id) |> Enum.sort()

      expected_here_pids =
        [alex.id, sam.id, harper.id, taylor.id] |> Enum.sort()

      assert here_pids == expected_here_pids,
             "here_pids should be alex/sam/harper/taylor, got #{inspect(here_pids)}"

      # 1 :mention decision — for Alex only (the only named human).
      assert length(mention_decisions) == 1,
             "expected exactly one :mention decision (for Alex), got #{inspect(mention_decisions)}"

      assert hd(mention_decisions).participant_id == alex.id,
             ":mention must target Alex, got #{inspect(mention_decisions)}"

      # Alex appears in BOTH lists — the planner expected duplication, not dedup.
      alex_decisions = Enum.filter(decisions, &(&1.participant_id == alex.id))

      assert length(alex_decisions) == 2,
             "Alex must appear in both :here and :mention, got #{inspect(alex_decisions)}"

      assert Enum.any?(alex_decisions, &(&1.reason == :here))
      assert Enum.any?(alex_decisions, &(&1.reason == :mention))

      # Sender (rowan) is never in any decision.
      refute Enum.any?(decisions, &(&1.participant_id == rowan.id)),
             "sender rowan must not appear in decisions"

      # Agents receive zero :here (broadcast is humans-only).
      higgins_participant = Chat.get_agent_participant(space.id, higgins_agent.id)
      geordi_participant = Chat.get_agent_participant(space.id, geordi_agent.id)

      refute Enum.any?(decisions, fn d ->
               d.reason == :here and
                 d.participant_id in [higgins_participant.id, geordi_participant.id]
             end),
             "agents must receive zero :here decisions"

      # Total decision count = 4 :here + 1 :mention (+ agent routing, which
      # may add up to 0–2 entries depending on watch/mutex state but never
      # :here or :mention since the message has no agent @[Name] tokens
      # and no roster is configured).
      human_decision_count = length(here_decisions) + length(mention_decisions)

      assert human_decision_count == 5,
             "expected 5 human decisions (4 :here + 1 :mention), got #{human_decision_count}"

      drain()
    end
  end

  # ── Push title tests (Stage 3 of @here notifications) ─────────────────────
  #
  # Pure-helper coverage. The actual `Platform.Push.send_notification/2`
  # call short-circuits under `:test` (see maybe_send_push/4) to avoid
  # racing against Ecto sandbox teardown, so we test the title-builder
  # in isolation. That's enough — `maybe_send_push/4` does nothing more
  # than pass the helper output through.

  describe "notification_title/2" do
    test "for :here, surfaces the @here broadcast context in the title" do
      assert AttentionRouter.notification_title("Rowan", :here) == "Rowan @here in Suite"
    end

    test "for :mention, uses the default sender-only title" do
      assert AttentionRouter.notification_title("Rowan", :mention) == "Rowan in Suite"
    end

    test "for :all, uses the default sender-only title" do
      assert AttentionRouter.notification_title("Rowan", :all) == "Rowan in Suite"
    end

    test "for any other reason atom, uses the default sender-only title" do
      # Defensive: future reasons (e.g. :directed, :watch, :active_agent)
      # should fall through to the default rather than crash.
      for reason <- [:directed, :watch, :active_agent, :active, :multi_mention] do
        assert AttentionRouter.notification_title("Rowan", reason) == "Rowan in Suite",
               "expected default title for reason #{inspect(reason)}"
      end
    end
  end

  # ── Push suppression predicate (task 019ffb7b Stage 1) ────────────────────
  #
  # `maybe_send_push/4` short-circuits under `:test` and the send runs inside
  # `Task.start`, so ExUnit cannot observe delivery. Asserting "a push was
  # sent" would mean re-deriving the router's own condition in the test, which
  # can never fail. These assert the decision itself.

  describe "send_push?/2" do
    test "a direct mention pushes even when the recipient is present in the space" do
      assert AttentionRouter.send_push?(:mention, true)
    end

    test "a direct mention pushes when the recipient is absent" do
      assert AttentionRouter.send_push?(:mention, false)
    end

    test "ambient activity does not push to a present recipient" do
      refute AttentionRouter.send_push?(:active, true)
    end

    test "ambient activity pushes to an absent recipient" do
      assert AttentionRouter.send_push?(:active, false)
    end

    test "every non-mention reason stays presence-gated" do
      for reason <- [:active, :all, :watch, :directed, :here, :heartbeat] do
        refute AttentionRouter.send_push?(reason, true),
               "expected #{inspect(reason)} to stay suppressed for a present recipient"

        assert AttentionRouter.send_push?(reason, false),
               "expected #{inspect(reason)} to push to an absent recipient"
      end
    end
  end

  # ── Archived-user filtering (task 019f671f Stage 3) ──────────────────────
  #
  # Archiving a user flips `users.archived_at` but does NOT hard-delete the
  # `chat_participants` row — that stays behind so past-message author
  # snapshots remain attributable via presence_hooks. To silence attention
  # routing for archived users, `AttentionRouter.route/1` filters human
  # recipients through `Chat.list_active_user_participant_ids/1`. Agent
  # participants are NOT affected (archival is a user-only lifecycle).

  describe "archived-user participants (Stage 3)" do
    test "route/1 emits no decision for an archived-user participant; agent + active-user decisions unchanged" do
      space = create_space(%{kind: "group"})

      # Sender (an active user with a real user row).
      sender_user = insert_test_user(name: "Rowan Sender")

      sender =
        create_participant(space.id, %{
          participant_id: sender_user.id,
          display_name: "Rowan Sender",
          attention_mode: "all"
        })

      # Active recipient — real, unarchived user row.
      active_user = insert_test_user(name: "Alice Active")

      active_recipient =
        create_participant(space.id, %{
          participant_id: active_user.id,
          display_name: "Alice Active",
          attention_mode: "all"
        })

      # Archived recipient — real user, then archived.
      archived_user = insert_test_user(name: "Bob Archived")

      archived_recipient =
        create_participant(space.id, %{
          participant_id: archived_user.id,
          display_name: "Bob Archived",
          attention_mode: "all"
        })

      {:ok, _archived_user} = Platform.Accounts.archive_user(archived_user)

      # Agent participant — should stay in routing (archival is user-only).
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      Chat.add_space_agent(space.id, agent.id, role: "principal")

      # Message @-mentions the archived user by display name; agent gets
      # `:mention` via bracketed form. Under Stage 3 the archived recipient
      # is dropped BEFORE decide_human/2 runs.
      message =
        create_message(space.id, sender.id, %{
          content: "hey @[Bob Archived] and @[Zip] and @[Alice Active]"
        })

      {:ok, decisions} = AttentionRouter.route(message)

      participant_ids = Enum.map(decisions, & &1.participant_id)

      refute archived_recipient.id in participant_ids,
             "archived-user participant must not receive any routing decision, got: #{inspect(decisions)}"

      assert active_recipient.id in participant_ids,
             "active user must still receive a routing decision, got: #{inspect(decisions)}"

      assert agent_participant.id in participant_ids,
             "agent participant must still be routed (archival is user-only), got: #{inspect(decisions)}"

      # Sender is never in decisions.
      refute sender.id in participant_ids

      drain()
    end

    test "route/1 with @[here] fan-out skips archived-user participants" do
      # Defense: @[here] bypasses per-participant attention_mode and fans
      # out to every human recipient. Archived users must still be excluded.
      space = create_space(%{kind: "channel"})

      sender_user = insert_test_user(name: "Sender")

      sender =
        create_participant(space.id, %{participant_id: sender_user.id, display_name: "Sender"})

      active_user = insert_test_user(name: "Alice")

      active_recipient =
        create_participant(space.id, %{
          participant_id: active_user.id,
          display_name: "Alice",
          attention_mode: "all"
        })

      archived_user = insert_test_user(name: "Bob")

      archived_recipient =
        create_participant(space.id, %{
          participant_id: archived_user.id,
          display_name: "Bob",
          attention_mode: "all"
        })

      {:ok, _archived_user} = Platform.Accounts.archive_user(archived_user)

      message = create_message(space.id, sender.id, %{content: "@[here] all hands"})

      {:ok, decisions} = AttentionRouter.route(message)

      here_pids =
        decisions
        |> Enum.filter(&(&1.reason == :here))
        |> Enum.map(& &1.participant_id)

      refute archived_recipient.id in here_pids,
             "archived user must be excluded from @[here] fan-out, got: #{inspect(decisions)}"

      assert active_recipient.id in here_pids,
             "active user must still receive :here, got: #{inspect(decisions)}"

      drain()
    end
  end

  describe "extract_bracketed_tokens/1 back-compat with @[here]" do
    test "filters out the @[here] sentinel from the name token list" do
      # Existing callers (e.g. `Chat.reinvite_and_pin_mentioned`) consume the
      # token list to look up agents by display name. If `here` leaked
      # through, an agent literally named "here" could be mistakenly
      # resurrected on every broadcast.
      {tokens, _legacy_zone} =
        AttentionRouter.extract_bracketed_tokens("@[here] please @[Rowan Ellis]")

      assert tokens == ["Rowan Ellis"]
    end

    test "still strips the @[here] form from the legacy_zone" do
      # The legacy zone is fed to the substring-match path; we don't want
      # `@here` to fall through and accidentally match a legacy `@here`.
      {_tokens, legacy_zone} =
        AttentionRouter.extract_bracketed_tokens("hi @[here] then keep going")

      refute String.contains?(legacy_zone, "@[")
      refute String.contains?(legacy_zone, "@here")
    end

    test "name-only message round-trips unchanged" do
      {tokens, legacy_zone} =
        AttentionRouter.extract_bracketed_tokens("hey @[Zip] take a look")

      assert tokens == ["Zip"]
      refute String.contains?(legacy_zone, "@[")
    end
  end

  describe "agent mentions when participant display_name is NULL" do
    # Regression: agent participant rows written through the raw
    # `Chat.add_participant/2` path (RPC channel creation) carried a NULL
    # `display_name`. `mentioned?/2` consulted ONLY that column, so `@[Dalton]`
    # produced no `:mention` decision, no dispatch, no dead-letter row and no
    # error — the message silently vanished. Mention identity now keys on the
    # principal, with the participant column as a cache.
    #
    # These rows are inserted with `Repo.insert!` on purpose: the write side now
    # resolves the name, so a legacy NULL row is no longer reachable through the
    # public API and has to be forged to be tested.
    defp legacy_null_name_participant(space_id, agent_id) do
      {:ok, participant} = Chat.add_agent_participant(space_id, agent_id)

      {1, _} =
        Repo.update_all(
          from(p in Platform.Chat.Participant, where: p.id == ^participant.id),
          set: [display_name: nil]
        )

      Repo.get!(Platform.Chat.Participant, participant.id)
    end

    test "mention by agent NAME still routes when display_name is NULL" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent(%{name: "Dalton"})
      Chat.add_space_agent(space.id, agent.id, role: "member")

      participant = legacy_null_name_participant(space.id, agent.id)
      assert is_nil(participant.display_name)

      message = create_message(space.id, user.id, %{content: "hey @[Dalton] look at this"})

      {:ok, decisions} = AttentionRouter.route(message)

      assert %{participant_id: participant.id, reason: :mention} in decisions
    end

    test "mention by agent SLUG still routes when display_name is NULL" do
      space = create_space()
      user = create_participant(space.id)

      agent =
        create_agent(%{name: "Dalton", slug: "dalton-#{System.unique_integer([:positive])}"})

      Chat.add_space_agent(space.id, agent.id, role: "member")

      participant = legacy_null_name_participant(space.id, agent.id)
      message = create_message(space.id, user.id, %{content: "ping @[#{agent.slug}] please"})

      {:ok, decisions} = AttentionRouter.route(message)

      assert %{participant_id: participant.id, reason: :mention} in decisions
    end

    test "mentioned?/2 is true for a NULL-named agent participant" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent(%{name: "Dalton"})
      participant = legacy_null_name_participant(space.id, agent.id)

      message = create_message(space.id, user.id, %{content: "@[dalton] hi"})

      assert AttentionRouter.mentioned?(participant, message)
    end

    test "a NULL-named agent is NOT mentioned by an unrelated name" do
      space = create_space()
      user = create_participant(space.id)
      agent = create_agent(%{name: "Dalton"})
      participant = legacy_null_name_participant(space.id, agent.id)

      message = create_message(space.id, user.id, %{content: "@[Higgins] hi"})

      refute AttentionRouter.mentioned?(participant, message)
    end
  end
end
