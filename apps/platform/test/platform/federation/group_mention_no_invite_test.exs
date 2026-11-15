defmodule Platform.Federation.GroupMentionNoInviteTest do
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures, only: [channel!: 1]
  alias Platform.Chat
  alias Platform.Agents.Agent
  alias Platform.Federation.AttentionDispatch
  alias Platform.Repo

  setup do
    org_id = Platform.TenancyFixtures.acme_org_id()
    space = channel!(%{org_id: org_id})
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(
        Agent.changeset(%Agent{}, %{name: "Group receiver", slug: "group-receiver-#{n}"})
      )

    {:ok, participant} = Chat.add_agent_participant(space.id, agent)
    runtime = "group-probe-#{n}"
    PlatformWeb.Endpoint.subscribe(AttentionDispatch.topic(runtime))
    %{space: space, agent: agent, participant: participant, runtime: runtime}
  end

  test "existing-only delivery succeeds for a current eligible participant", c do
    assert :ok =
             AttentionDispatch.broadcast(c.runtime, %{signal: %{reason: "group_probe"}},
               space_id: c.space.id,
               agent_id: c.agent,
               participant_id: c.participant.id,
               membership: :existing_only,
               source: :agent_responder
             )

    assert_receive %Phoenix.Socket.Broadcast{
      event: "attention",
      payload: %{signal: %{reason: "group_probe"}}
    }

    assert Chat.get_agent_participant(c.space.id, c.agent.id).id == c.participant.id
  end

  test "removal between context construction and broadcast never restores participation", c do
    {:ok, _} = Chat.remove_participant(c.participant)
    assert is_nil(Chat.get_agent_participant(c.space.id, c.agent.id))

    assert {:error, :recipient_unavailable} =
             AttentionDispatch.broadcast(
               c.runtime,
               %{signal: %{reason: "group_probe"}},
               space_id: c.space.id,
               agent_id: c.agent,
               participant_id: c.participant.id,
               membership: :existing_only,
               source: :agent_responder
             )

    refute_receive %Phoenix.Socket.Broadcast{event: "attention"}
    assert is_nil(Chat.get_agent_participant(c.space.id, c.agent.id))
  end

  test "a replacement participant cannot receive an old snapshot", c do
    {:ok, _} = Chat.remove_participant(c.participant)
    {:ok, replacement} = Chat.add_agent_participant(c.space.id, c.agent)
    refute replacement.id == c.participant.id

    assert {:error, :recipient_unavailable} =
             AttentionDispatch.broadcast(
               c.runtime,
               %{signal: %{reason: "group_probe"}},
               space_id: c.space.id,
               agent_id: c.agent,
               participant_id: c.participant.id,
               membership: :existing_only,
               source: :agent_responder
             )

    refute_receive %Phoenix.Socket.Broadcast{event: "attention"}
    assert Chat.get_agent_participant(c.space.id, c.agent.id).id == replacement.id
  end

  test "archived space refuses existing-only delivery without changing membership", c do
    Repo.update!(Ecto.Changeset.change(c.space, archived_at: DateTime.utc_now()))

    assert {:error, :recipient_unavailable} =
             AttentionDispatch.broadcast(
               c.runtime,
               %{signal: %{reason: "group_probe"}},
               space_id: c.space.id,
               agent_id: c.agent,
               participant_id: c.participant.id,
               membership: :existing_only,
               source: :agent_responder
             )

    refute_receive %Phoenix.Socket.Broadcast{event: "attention"}
    assert Chat.get_agent_participant(c.space.id, c.agent.id).id == c.participant.id
  end
end
