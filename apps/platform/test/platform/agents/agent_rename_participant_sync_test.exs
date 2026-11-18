defmodule Platform.Agents.AgentRenameParticipantSyncTest do
  # Task 01a1f0d1: renaming an agent must carry onto its chat participant rows,
  # because `display_name` there is the copy the mention router and the members
  # sheet read.
  use Platform.DataCase, async: true

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, Participant}
  alias Platform.Repo

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Rename sync",
        slug: "rename-sync-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp create_agent(attrs) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(
        Map.merge(
          %{
            slug: "ux-agent-#{System.unique_integer([:positive])}",
            name: "UX",
            status: "active",
            max_concurrent: 1,
            sandbox_mode: "off",
            model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
          },
          attrs
        )
      )
      |> Repo.insert()

    agent
  end

  defp user_participant(space_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Avery",
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp message(space_id, participant_id, content) do
    {:ok, message} =
      %Message{}
      |> Message.changeset(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: content
      })
      |> Repo.insert()

    message
  end

  defp rename(agent, name) do
    agent |> Agent.changeset(%{name: name}) |> Repo.update()
  end

  defp agent_rows(agent_id) do
    from(p in Participant,
      where: p.participant_type == "agent" and p.participant_id == ^agent_id,
      order_by: p.space_id
    )
    |> Repo.all()
  end

  setup do
    agent = create_agent(%{})
    space_a = create_space()
    space_b = create_space()
    {:ok, _} = Chat.add_agent_participant(space_a.id, agent)
    {:ok, _} = Chat.add_agent_participant(space_b.id, agent)

    %{agent: agent, space_a: space_a, space_b: space_b}
  end

  test "(a) a rename rewrites the display_name on every participant row", %{agent: agent} do
    assert Enum.map(agent_rows(agent.id), & &1.display_name) == ["UX", "UX"]

    {:ok, _} = rename(agent, "Loki")

    assert Enum.map(agent_rows(agent.id), & &1.display_name) == ["Loki", "Loki"]
  end

  test "(b) the new name mentions the agent, bracketed and legacy", %{
    agent: agent,
    space_a: space
  } do
    {:ok, _} = rename(agent, "Loki")
    user = user_participant(space.id)
    participant = Repo.get_by!(Participant, space_id: space.id, participant_id: agent.id)

    assert AttentionRouter.mentioned?(participant, message(space.id, user.id, "@[Loki] hi"))
    assert AttentionRouter.mentioned?(participant, message(space.id, user.id, "@Loki hi"))
  end

  test "(c) the old name stops mentioning the agent; the bracketed slug still does", %{
    agent: agent,
    space_a: space
  } do
    {:ok, _} = rename(agent, "Loki")
    user = user_participant(space.id)
    participant = Repo.get_by!(Participant, space_id: space.id, participant_id: agent.id)

    refute AttentionRouter.mentioned?(participant, message(space.id, user.id, "@UX hi"))

    assert AttentionRouter.mentioned?(
             participant,
             message(space.id, user.id, "@[#{agent.slug}] hi")
           )
  end

  test "(d) the members sheet's agent rows carry the new name", %{
    agent: agent,
    space_a: space
  } do
    {:ok, _} = rename(agent, "Loki")

    assert [%{agent_id: agent_id, name: "Loki"}] = Chat.agent_attention_state(space.id).agents
    assert agent_id == agent.id
  end

  test "(e) a row named something else on purpose keeps its name", %{agent: agent} do
    space = create_space()
    {:ok, _} = Chat.add_agent_participant(space.id, agent, display_name: "Zip")

    {:ok, _} = rename(agent, "Loki")

    assert Repo.get_by!(Participant, space_id: space.id, participant_id: agent.id).display_name ==
             "Zip"
  end

  test "(e2) a NULL display_name row picks up the new name", %{agent: agent} do
    space = create_space()
    {:ok, p} = Chat.add_agent_participant(space.id, agent)
    from(x in Participant, where: x.id == ^p.id) |> Repo.update_all(set: [display_name: nil])

    {:ok, _} = rename(agent, "Loki")

    assert Repo.get!(Participant, p.id).display_name == "Loki"
  end

  test "(f) a failed rename leaves participant rows unchanged", %{agent: agent} do
    assert {:error, %Ecto.Changeset{}} = rename(agent, "")

    assert Enum.map(agent_rows(agent.id), & &1.display_name) == ["UX", "UX"]
  end

  test "a non-name update does not touch participant rows", %{agent: agent} do
    {:ok, _} = agent |> Agent.changeset(%{color: "#123456"}) |> Repo.update()

    assert Enum.map(agent_rows(agent.id), & &1.display_name) == ["UX", "UX"]
  end
end
