defmodule Platform.Chat.SpaceAgentTest do
  @moduledoc """
  Roster behaviour tests. ADR 0038 collapsed `chat_space_agents` into
  `chat_participants.role`, so what we exercise here is:

    * `set_principal_agent` promotes + demotes the old principal atomically
    * `add_space_agent` / `remove_space_agent` / `ensure_space_agent` are
      thin wrappers over agent-participant membership
    * Attention routing gates mentions on the agent being a participant
      (the old roster is just membership now)

  Schema-level tests for the deleted `Platform.Chat.SpaceAgent` are gone.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, SpaceAgentPresence}
  alias Platform.Repo

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "Reply: #{message}", model: "stub", usage: %{}}}
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
      display_name: "Alice",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Agent"
    }

    Repo.insert!(%Agent{
      slug: Map.get(attrs, :slug, defaults.slug),
      name: Map.get(attrs, :name, defaults.name),
      status: "active"
    })
  end

  defp create_message(space_id, participant_id, attrs \\ %{}) do
    defaults = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: "hello"
    }

    {:ok, message} = Chat.post_message(Map.merge(defaults, attrs))
    message
  end

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  defp drain do
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  describe "set_principal_agent/2" do
    test "sets an agent as principal" do
      space = create_space()
      agent = create_agent()

      assert {:ok, entry} = Chat.set_principal_agent(space.id, agent.id)
      assert entry.role == "principal"
      assert entry.agent_id == agent.id
    end

    test "replaces existing principal atomically" do
      space = create_space()
      agent_a = create_agent(%{name: "AgentA"})
      agent_b = create_agent(%{name: "AgentB"})

      {:ok, _} = Chat.set_principal_agent(space.id, agent_a.id)
      {:ok, entry_b} = Chat.set_principal_agent(space.id, agent_b.id)

      assert entry_b.role == "principal"

      old = Chat.get_space_agent(space.id, agent_a.id)
      assert old.role == "member"

      principal = Chat.get_principal_agent(space.id)
      assert principal.agent_id == agent_b.id
    end

    test "setting same agent as principal is a no-op" do
      space = create_space()
      agent = create_agent()

      {:ok, entry1} = Chat.set_principal_agent(space.id, agent.id)
      {:ok, entry2} = Chat.set_principal_agent(space.id, agent.id)
      assert entry1.agent_id == entry2.agent_id
      assert entry2.role == "principal"
    end

    test "promotes existing member to principal" do
      space = create_space()
      agent = create_agent()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id, role: "member")
      {:ok, entry} = Chat.set_principal_agent(space.id, agent.id)

      assert entry.role == "principal"
      roster = Chat.list_space_agents(space.id)
      assert length(roster) == 1
    end
  end

  describe "add_space_agent/3" do
    test "adds agent as member by default" do
      space = create_space()
      agent = create_agent()

      {:ok, entry} = Chat.add_space_agent(space.id, agent.id)
      assert entry.role == "member"
      assert entry.agent_id == agent.id
    end

    test "adds agent with specified role" do
      space = create_space()
      agent = create_agent()

      {:ok, entry} = Chat.add_space_agent(space.id, agent.id, role: "member")
      assert entry.role == "member"
    end
  end

  # The dismisser must be a participant of the space it is dismissing from —
  # that is the whole point of `remove_space_agent/3`'s actor argument
  # (task 01a01ce0).
  defp dismisser!(space_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now()
      })

    {:user, p.participant_id}
  end

  describe "remove_space_agent/3" do
    test "removes agent from roster (hard-delete, ADR 0038)" do
      space = create_space()
      agent = create_agent()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      assert :ok = Chat.remove_space_agent(dismisser!(space.id), space.id, agent.id)
      assert Chat.get_space_agent(space.id, agent.id) == nil
    end

    test "returns error when agent not in roster" do
      space = create_space()

      assert {:error, :not_found} =
               Chat.remove_space_agent(dismisser!(space.id), space.id, Ecto.UUID.generate())
    end

    test "a non-participant of the space is refused and the agent stays" do
      space = create_space()
      agent = create_agent()
      {:ok, _} = Chat.add_space_agent(space.id, agent.id)

      assert {:error, :forbidden} =
               Chat.remove_space_agent({:user, Ecto.UUID.generate()}, space.id, agent.id)

      assert Chat.get_space_agent(space.id, agent.id)
    end
  end

  describe "list_space_agents/1" do
    test "returns all roster entries with preloaded agents" do
      space = create_space()
      agent_a = create_agent(%{name: "Alpha"})
      agent_b = create_agent(%{name: "Beta"})

      {:ok, _} = Chat.set_principal_agent(space.id, agent_a.id)
      {:ok, _} = Chat.add_space_agent(space.id, agent_b.id)

      roster = Chat.list_space_agents(space.id)
      assert length(roster) == 2
      assert Enum.all?(roster, fn entry -> entry.agent != nil end)
    end
  end

  describe "get_principal_agent/1" do
    test "returns principal with preloaded agent" do
      space = create_space()
      agent = create_agent(%{name: "Zip"})

      {:ok, _} = Chat.set_principal_agent(space.id, agent.id)

      principal = Chat.get_principal_agent(space.id)
      assert principal.role == "principal"
      assert principal.agent.name == "Zip"
    end

    test "returns nil when no principal" do
      space = create_space()
      assert Chat.get_principal_agent(space.id) == nil
    end
  end

  describe "list_active_space_agents/1" do
    test "returns all agents in roster" do
      space = create_space()
      agent_a = create_agent(%{name: "Alpha"})
      agent_b = create_agent(%{name: "Beta"})

      {:ok, _} = Chat.add_space_agent(space.id, agent_a.id)
      {:ok, _} = Chat.add_space_agent(space.id, agent_b.id)

      active = Chat.list_active_space_agents(space.id)
      assert length(active) == 2
    end
  end

  describe "composite/1 — healthy-over-total ratio" do
    test "empty roster is :none with a zero ratio" do
      assert SpaceAgentPresence.composite([]) == %{healthy: 0, total: 0, state: :none}
      assert SpaceAgentPresence.composite_status([]) == :none
    end

    # REWRITTEN (was "error always wins", asserting :error absorbed the whole
    # roster). The absorbing fold was documented behaviour and was reversed on
    # purpose: worst-wins made the meter stop varying. The old assertions were
    #   composite_status([:active, :error]) == :error
    #   composite_status([:error, :busy, :active]) == :error
    # Erroring agents still push the state to :error, but the ratio now carries
    # how much of the roster is actually fine.
    test "one error among healthy agents is :error but the ratio still reports the healthy ones" do
      assert SpaceAgentPresence.composite([:active, :error]) ==
               %{healthy: 1, total: 2, state: :error}

      assert SpaceAgentPresence.composite([:error, :busy, :active]) ==
               %{healthy: 2, total: 3, state: :error}
    end

    # ANTI-VACUITY: asserting a state in isolation passes against a function
    # that returns one constant. Compute both sides of the transition in one
    # body and assert they DIFFER, so a refactor that collapses them fails
    # even if both individual expectations get updated to the same value.
    test "the erroring roster and the all-healthy roster do not produce the same state" do
      with_error = SpaceAgentPresence.composite([:active, :active, :active, :error])
      all_healthy = SpaceAgentPresence.composite([:active, :active, :active, :active])

      assert with_error == %{healthy: 3, total: 4, state: :error}
      assert all_healthy == %{healthy: 4, total: 4, state: :healthy}

      refute with_error.state == all_healthy.state,
             "composite state must vary between an erroring and a fully healthy roster; " <>
               "identical states mean the indicator is decorative"
    end

    test "dot_color varies across the same transition" do
      with_error = SpaceAgentPresence.dot_color(:error)
      all_healthy = SpaceAgentPresence.dot_color(:healthy)

      assert with_error == "bg-error"
      assert all_healthy == "bg-success"

      refute with_error == all_healthy,
             "dot_color must differ between :error and :healthy; identical classes mean " <>
               "the dot is hardcoded"
    end

    # The regression Rowan reported: never-linked agents used to be :error, and
    # :error absorbed the fold, so the meter was permanently red.
    test "absent agents are counted in the denominator and are NOT an error" do
      result = SpaceAgentPresence.composite([:active, :absent, :absent])

      assert result == %{healthy: 1, total: 3, state: :degraded}
      refute result.state == :error
    end

    test ":idle and :busy count as healthy" do
      assert SpaceAgentPresence.composite([:active, :busy, :idle]) ==
               %{healthy: 3, total: 3, state: :healthy}
    end

    test "offline agents degrade without erroring" do
      result = SpaceAgentPresence.composite([:active, :offline])

      assert result == %{healthy: 1, total: 2, state: :degraded}
      refute result.state == :error
    end

    test "composite_status/1 delegates to composite/1's state" do
      for statuses <- [[], [:active], [:active, :absent], [:active, :error]] do
        assert SpaceAgentPresence.composite_status(statuses) ==
                 SpaceAgentPresence.composite(statuses).state
      end
    end
  end

  describe "agent_status/1 — external agents" do
    test "never linked to any runtime is :absent, not :error" do
      external = %{create_agent() | runtime_type: "external", runtime_id: nil}

      status = SpaceAgentPresence.agent_status(external)

      assert status == :absent
      refute status == :error
    end

    test "linked and online is :active; linked and not present is :offline" do
      agent = create_agent()
      runtime_id = "rt-#{System.unique_integer([:positive])}"

      runtime =
        Repo.insert!(%Platform.Agents.AgentRuntime{
          agent_id: agent.id,
          owner_user_id: Platform.ExternalUserFixtures.create_user!().id,
          status: "active",
          runtime_id: runtime_id
        })

      external = %{agent | runtime_type: "external", runtime_id: runtime.id}

      Platform.Federation.RuntimePresence.untrack(runtime_id)
      offline = SpaceAgentPresence.agent_status(external)

      Platform.Federation.RuntimePresence.track(runtime_id)
      on_exit(fn -> Platform.Federation.RuntimePresence.untrack(runtime_id) end)
      online = SpaceAgentPresence.agent_status(external)

      assert offline == :offline
      assert online == :active
      refute offline == online
    end
  end

  describe "attention routing with roster" do
    test "@-mention routes to mentioned agent on the roster" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "CodeBot"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "CodeBot")

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)

      message = create_message(space.id, user.id, %{content: "@CodeBot review this"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "@CodeBot review this", _opts}, 500
      drain()
    end

    test "no @-mention routes to principal agent" do
      space = create_space(%{kind: "dm"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      {:ok, _} = Chat.set_principal_agent(space.id, agent.id)

      message = create_message(space.id, user.id, %{content: "hey what's up"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "hey what's up", _opts}, 500
      drain()
    end

    # Under ADR 0038 there's no "participant but not on the roster" state —
    # membership == roster. The previous test asserting that distinction no
    # longer has a behavior to check; the product contract is "if the agent
    # is in the space, mentioning them routes to them." Tests for that live
    # in attention_router_test.exs.

    test "spaces without roster fall back to legacy routing" do
      space = create_space(%{kind: "dm"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.add_agent_participant(space.id, agent, display_name: "Zip")

      message = create_message(space.id, user.id, %{content: "hey"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "hey", _opts}, 500
      drain()
    end
  end

  # Drop any unused aliases defensively.
  _ = Message
end
