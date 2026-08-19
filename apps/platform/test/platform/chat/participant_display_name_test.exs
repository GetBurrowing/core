defmodule Platform.Chat.ParticipantDisplayNameTest do
  @moduledoc """
  Write-side guard for the NULL `display_name` defect.

  `chat_participants.display_name` is nullable and absent from
  `Participant.changeset/2`'s `validate_required`, so any caller reaching
  `Chat.add_participant/2` directly — RPC channel creation is the common one —
  could silently write NULL. A NULL agent name broke the roster render, the
  @-mention autocomplete and mention ROUTING all at once, the last of those with
  no error and no dead-letter row.

  `Chat.do_add_participant/2` now resolves the name from the principal, so a
  NULL is unreachable through the public API.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Test",
        slug: "test-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_agent(attrs \\ %{}) do
    defaults = %{
      slug: "agent-#{System.unique_integer([:positive])}",
      name: "Dalton",
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

  describe "add_participant/2 resolves display_name for agents" do
    test "omitting display_name entirely resolves from agents.name" do
      space = create_space()
      agent = create_agent(%{name: "Dalton"})

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          joined_at: DateTime.utc_now()
        })

      assert participant.display_name == "Dalton"
      refute is_nil(Repo.reload!(participant).display_name)
    end

    # The `Keyword.get(opts, :display_name, agent.name)` trap: a default does
    # NOT apply when the key is present holding nil. Every caller that threads
    # an unresolved name through hit this.
    test "an explicit nil display_name still resolves" do
      space = create_space()
      agent = create_agent(%{name: "Dalton"})

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: nil,
          joined_at: DateTime.utc_now()
        })

      assert participant.display_name == "Dalton"
    end

    test "a blank display_name still resolves" do
      space = create_space()
      agent = create_agent(%{name: "Dalton"})

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: "   ",
          joined_at: DateTime.utc_now()
        })

      assert participant.display_name == "Dalton"
    end

    test "an explicitly supplied name is never overwritten" do
      space = create_space()
      agent = create_agent(%{name: "Dalton"})

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: "Custom Label",
          joined_at: DateTime.utc_now()
        })

      assert participant.display_name == "Custom Label"
    end

    # `agents.name` is NOT NULL at the database level, so the slug branch in
    # `principal_display_name/2` is unreachable defence for an existing agent
    # row, not a live path. Asserting the constraint here is what keeps that
    # claim honest: if the column is ever relaxed, this test goes red and the
    # slug fallback becomes load-bearing rather than decorative.
    test "agents.name is NOT NULL, so agent resolution cannot come up empty" do
      agent = create_agent()

      assert_raise Postgrex.Error, fn ->
        Repo.query!("UPDATE agents SET name = NULL WHERE id = $1", [
          Ecto.UUID.dump!(agent.id)
        ])
      end
    end

    test "add_agent_participant/3 with an explicit nil opt still resolves" do
      space = create_space()
      agent = create_agent(%{name: "Dalton"})

      {:ok, participant} =
        Chat.add_agent_participant(space.id, agent, display_name: nil)

      assert participant.display_name == "Dalton"
    end
  end

  describe "add_participant/2 resolves display_name for users" do
    test "omitting display_name resolves from the user record" do
      space = create_space()
      n = System.unique_integer([:positive])

      user =
        Repo.insert!(%Platform.Accounts.User{
          name: "Ada Lovelace",
          email: "user-#{n}@example.com",
          oidc_sub: "sub-#{n}"
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: user.id,
          joined_at: DateTime.utc_now()
        })

      assert participant.display_name == "Ada Lovelace"
    end
  end

  describe "agent_principal_name/1" do
    test "resolves name, falls back to slug, nil for unknown" do
      agent = create_agent(%{name: "Dalton"})
      assert Chat.agent_principal_name(agent.id) == "Dalton"
      assert is_nil(Chat.agent_principal_name(Ecto.UUID.generate()))
      assert is_nil(Chat.agent_principal_name(nil))
    end
  end
end
