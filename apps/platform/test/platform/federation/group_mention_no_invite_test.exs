defmodule Platform.Federation.GroupMentionNoInviteTest do
  use Platform.DataCase, async: false

  import Platform.ExternalUserFixtures, only: [channel!: 1]
  alias Platform.Chat
  alias Platform.Agents.Agent
  alias Platform.Federation.AttentionDispatch
  alias Platform.Repo

  test "the real responder uses existing-only transport for a persisted group audience", c do
    presence =
      Process.whereis(Platform.Federation.RuntimePresence) ||
        start_supervised!({Platform.Federation.RuntimePresence, []})

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), presence)
    admin = Platform.TenancyFixtures.root_admin!()

    runtime =
      Repo.insert!(%Platform.Agents.AgentRuntime{
        owner_user_id: admin.id,
        status: "active",
        runtime_id: c.runtime,
        display_name: "Group runtime"
      })

    agent =
      Repo.update!(
        Ecto.Changeset.change(c.agent, runtime_type: "external", runtime_id: runtime.id)
      )

    Platform.Federation.RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> Platform.Federation.RuntimePresence.untrack(runtime.runtime_id) end)

    {:ok, author} =
      Chat.add_participant(c.space.id, %{
        participant_type: "user",
        participant_id: admin.id,
        joined_at: DateTime.utc_now()
      })

    {:ok, group} =
      Platform.Chat.MentionGroups.create_group(admin, c.space.org_id, %{
        name: "Transport team",
        members: [%{type: "agent", id: agent.id}]
      })

    {:ok, message} =
      Chat.post_message(%{
        space_id: c.space.id,
        participant_id: author.id,
        content_type: "text",
        content: Platform.Chat.GroupMentionToken.encode(group.id, group.name)
      })

    handler = {__MODULE__, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :chat, :dispatch_auto_invite],
        fn _, _, metadata, _ -> send(parent, {:group_auto_invite, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Platform.Chat.AgentResponder.respond(%{
               reason: :mention,
               space_id: c.space.id,
               participant_id: c.participant.id,
               message_id: message.id,
               group_mention_only: true,
               group_mentions: [%{id: group.id, name: group.name}]
             })

    assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: payload}, 1_000
    assert payload.signal.group_mentions == [%{id: group.id, name: group.name}]
    refute_receive {:group_auto_invite, _}
    assert Chat.get_agent_participant(c.space.id, agent.id).id == c.participant.id
  end

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
