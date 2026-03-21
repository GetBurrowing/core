defmodule Platform.Chat.SpaceAgentTest do
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, SpaceAgent, SpaceAgentPresence}
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
      display_name: "Rowan",
      joined_at: DateTime.utc_now()
    }

    {:ok, participant} = Chat.add_participant(space_id, Map.merge(default, attrs))
    participant
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "TestAgent",
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

  defp create_user do
    Repo.insert!(%User{
      email: "test_#{System.unique_integer([:positive])}@example.com",
      name: "Test User",
      oidc_sub: "oidc-test-#{System.unique_integer([:positive])}"
    })
  end

  defp unique_slug, do: "test-#{System.unique_integer([:positive])}"

  defp drain do
    :ok = GenServer.call(AttentionRouter, :__drain__)
  end

  # ── Schema changeset tests ──────────────────────────────────────────────────

  describe "SpaceAgent changeset" do
    test "valid changeset with required fields" do
      space = create_space()
      agent = create_agent()

      changeset =
        SpaceAgent.changeset(%SpaceAgent{}, %{
          space_id: space.id,
          agent_id: agent.id,
          role: "member"
        })

      assert changeset.valid?
    end

    test "validates role inclusion" do
      changeset =
        SpaceAgent.changeset(%SpaceAgent{}, %{
          space_id: Ecto.UUID.generate(),
          agent_id: Ecto.UUID.generate(),
          role: "invalid_role"
        })

      refute changeset.valid?
      assert {"is invalid", _} = changeset.errors[:role]
    end

    test "requires space_id, agent_id, role" do
      changeset = SpaceAgent.changeset(%SpaceAgent{}, %{})
      refute changeset.valid?
      assert changeset.errors[:space_id]
      assert changeset.errors[:agent_id]
    end

    test "enforces unique (space_id, agent_id) constraint" do
      space = create_space()
      agent = create_agent()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      assert {:error, changeset} = Chat.add_space_agent(space.id, agent.id)
      assert changeset.errors[:space_id] || changeset.errors[:agent_id]
    end
  end

  # ── set_principal_agent ────────────────────────────────────────────────────

  describe "set_principal_agent/2" do
    test "sets an agent as principal" do
      space = create_space()
      agent = create_agent()

      assert {:ok, sa} = Chat.set_principal_agent(space.id, agent.id)
      assert sa.role == "principal"
      assert sa.space_id == space.id
      assert sa.agent_id == agent.id
    end

    test "replaces existing principal atomically" do
      space = create_space()
      agent_a = create_agent(%{name: "AgentA"})
      agent_b = create_agent(%{name: "AgentB"})

      {:ok, _} = Chat.set_principal_agent(space.id, agent_a.id)
      {:ok, sa_b} = Chat.set_principal_agent(space.id, agent_b.id)

      assert sa_b.role == "principal"

      # Old principal should now be member
      old = Chat.get_space_agent(space.id, agent_a.id)
      assert old.role == "member"

      # Only one principal
      principal = Chat.get_principal_agent(space.id)
      assert principal.agent_id == agent_b.id
    end

    test "setting same agent as principal is a no-op" do
      space = create_space()
      agent = create_agent()

      {:ok, sa1} = Chat.set_principal_agent(space.id, agent.id)
      {:ok, sa2} = Chat.set_principal_agent(space.id, agent.id)
      assert sa1.id == sa2.id
      assert sa2.role == "principal"
    end

    test "promotes existing member to principal" do
      space = create_space()
      agent = create_agent()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id, role: "member")
      {:ok, sa} = Chat.set_principal_agent(space.id, agent.id)

      assert sa.role == "principal"
      # Should still be one entry, not two
      roster = Chat.list_space_agents(space.id)
      assert length(roster) == 1
    end
  end

  # ── add_space_agent / remove_space_agent ───────────────────────────────────

  describe "add_space_agent/3" do
    test "adds agent as member by default" do
      space = create_space()
      agent = create_agent()

      {:ok, sa} = Chat.add_space_agent(space.id, agent.id)
      assert sa.role == "member"
    end

    test "adds agent with specified role" do
      space = create_space()
      agent = create_agent()

      {:ok, sa} = Chat.add_space_agent(space.id, agent.id, role: "member")
      assert sa.role == "member"
    end
  end

  describe "remove_space_agent/2" do
    test "removes agent from roster" do
      space = create_space()
      agent = create_agent()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      assert :ok = Chat.remove_space_agent(space.id, agent.id)
      assert Chat.get_space_agent(space.id, agent.id) == nil
    end

    test "returns error when agent not in roster" do
      space = create_space()
      assert {:error, :not_found} = Chat.remove_space_agent(space.id, Ecto.UUID.generate())
    end
  end

  # ── dismiss / reinvite ─────────────────────────────────────────────────────

  describe "dismiss_space_agent/3" do
    test "sets role to dismissed with metadata" do
      space = create_space()
      agent = create_agent()
      user = create_user()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      {:ok, sa} = Chat.dismiss_space_agent(space.id, agent.id, dismissed_by: user.id)

      assert sa.role == "dismissed"
      assert sa.dismissed_by == user.id
      assert sa.dismissed_at != nil
    end

    test "dismissing already dismissed agent is a no-op" do
      space = create_space()
      agent = create_agent()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      {:ok, _} = Chat.dismiss_space_agent(space.id, agent.id)
      {:ok, sa} = Chat.dismiss_space_agent(space.id, agent.id)
      assert sa.role == "dismissed"
    end

    test "returns error for unknown agent" do
      space = create_space()
      assert {:error, :not_found} = Chat.dismiss_space_agent(space.id, Ecto.UUID.generate())
    end
  end

  describe "reinvite_space_agent/2" do
    test "restores dismissed agent to member" do
      space = create_space()
      agent = create_agent()
      user = create_user()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      {:ok, _} = Chat.dismiss_space_agent(space.id, agent.id, dismissed_by: user.id)
      {:ok, sa} = Chat.reinvite_space_agent(space.id, agent.id)

      assert sa.role == "member"
      assert sa.dismissed_by == nil
      assert sa.dismissed_at == nil
    end

    test "reinviting active agent is a no-op" do
      space = create_space()
      agent = create_agent()

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      {:ok, sa} = Chat.reinvite_space_agent(space.id, agent.id)
      assert sa.role == "member"
    end

    test "returns error for unknown agent" do
      space = create_space()
      assert {:error, :not_found} = Chat.reinvite_space_agent(space.id, Ecto.UUID.generate())
    end
  end

  # ── list / get functions ───────────────────────────────────────────────────

  describe "list_space_agents/1" do
    test "returns all roster entries with preloaded agents" do
      space = create_space()
      agent_a = create_agent(%{name: "Alpha"})
      agent_b = create_agent(%{name: "Beta"})

      {:ok, _} = Chat.set_principal_agent(space.id, agent_a.id)
      {:ok, _} = Chat.add_space_agent(space.id, agent_b.id)

      roster = Chat.list_space_agents(space.id)
      assert length(roster) == 2
      assert Enum.all?(roster, fn sa -> sa.agent != nil end)
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
    test "excludes dismissed agents" do
      space = create_space()
      agent_a = create_agent(%{name: "Alpha"})
      agent_b = create_agent(%{name: "Beta"})

      {:ok, _} = Chat.add_space_agent(space.id, agent_a.id)
      {:ok, _} = Chat.add_space_agent(space.id, agent_b.id)
      {:ok, _} = Chat.dismiss_space_agent(space.id, agent_b.id)

      active = Chat.list_active_space_agents(space.id)
      assert length(active) == 1
      assert hd(active).agent_id == agent_a.id
    end
  end

  # ── Principal uniqueness constraint ────────────────────────────────────────

  describe "principal uniqueness" do
    test "cannot insert two principals for the same space directly" do
      space = create_space()
      agent_a = create_agent(%{name: "A"})
      agent_b = create_agent(%{name: "B"})

      {:ok, _} =
        %SpaceAgent{}
        |> SpaceAgent.changeset(%{space_id: space.id, agent_id: agent_a.id, role: "principal"})
        |> Repo.insert()

      assert {:error, _} =
               %SpaceAgent{}
               |> SpaceAgent.changeset(%{
                 space_id: space.id,
                 agent_id: agent_b.id,
                 role: "principal"
               })
               |> Repo.insert()
    end
  end

  # ── Composite status ───────────────────────────────────────────────────────

  describe "composite_status/1" do
    test "returns :none for empty list" do
      assert SpaceAgentPresence.composite_status([]) == :none
    end

    test "single active returns :active" do
      assert SpaceAgentPresence.composite_status([:active]) == :active
    end

    test "single idle returns :idle" do
      assert SpaceAgentPresence.composite_status([:idle]) == :idle
    end

    test "error always wins" do
      assert SpaceAgentPresence.composite_status([:active, :error]) == :error
      assert SpaceAgentPresence.composite_status([:error, :busy, :active]) == :error
    end

    test "busy wins over active/idle" do
      assert SpaceAgentPresence.composite_status([:active, :busy]) == :busy
      assert SpaceAgentPresence.composite_status([:idle, :busy]) == :busy
    end

    test "active wins over idle" do
      assert SpaceAgentPresence.composite_status([:idle, :active]) == :active
    end

    test "all healthy returns :active" do
      assert SpaceAgentPresence.composite_status([:active, :active, :idle]) == :active
    end

    test "mix of error and busy returns :error" do
      assert SpaceAgentPresence.composite_status([:busy, :error]) == :error
    end
  end

  # ── Attention routing with roster ──────────────────────────────────────────

  describe "attention routing with roster" do
    test "@-mention routes to mentioned agent in roster" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "CodeBot"})

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "CodeBot")

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
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      {:ok, _} = Chat.set_principal_agent(space.id, agent.id)

      message = create_message(space.id, user.id, %{content: "hey what's up"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "hey what's up", _opts}, 500
      drain()
    end

    test "dismissed agent @-mention triggers reinvite" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Linter"})

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Linter")

      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      {:ok, _} = Chat.dismiss_space_agent(space.id, agent.id)

      # Verify dismissed
      sa = Chat.get_space_agent(space.id, agent.id)
      assert sa.role == "dismissed"

      message = create_message(space.id, user.id, %{content: "@Linter check this"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :mention}]} =
               AttentionRouter.route(message)

      # Verify reinvited
      sa = Chat.get_space_agent(space.id, agent.id)
      assert sa.role == "member"

      assert_receive {:agent_chat_called, "@Linter check this", _opts}, 500
      drain()
    end

    test "agent not in roster does not receive messages" do
      space = create_space(%{kind: "channel"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Ghost"})
      other_agent = create_agent(%{name: "Visible"})

      {:ok, _} = Chat.ensure_agent_participant(space.id, agent, display_name: "Ghost")
      {:ok, _} = Chat.ensure_agent_participant(space.id, other_agent, display_name: "Visible")

      # Only add other_agent to roster, not agent
      {:ok, _} = Chat.add_space_agent(space.id, other_agent.id)

      message = create_message(space.id, user.id, %{content: "@Ghost help me"})

      # Ghost is not in roster, so no delivery
      assert {:ok, []} = AttentionRouter.route(message)
      refute_receive {:agent_chat_called, _, _}, 200
      drain()
    end

    test "spaces without roster fall back to legacy routing" do
      space = create_space(%{kind: "dm"})
      user = create_participant(space.id)
      agent = create_agent(%{name: "Zip"})

      {:ok, agent_participant} =
        Chat.ensure_agent_participant(space.id, agent, display_name: "Zip")

      # No roster entries — should use legacy participant-based routing
      message = create_message(space.id, user.id, %{content: "hey"})
      agent_participant_id = agent_participant.id

      assert {:ok, [%{participant_id: ^agent_participant_id, reason: :directed}]} =
               AttentionRouter.route(message)

      assert_receive {:agent_chat_called, "hey", _opts}, 500
      drain()
    end
  end
end
