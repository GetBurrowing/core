defmodule Platform.Chat.DismissalRegressionTest do
  @moduledoc """
  Regression coverage for ADR 0038. These tests nail the product
  contract end-to-end so the specific bug classes we fixed can't quietly
  come back:

    1. Dismissal is durable — no code path silently re-adds a dismissed
       agent. Read paths that used to call `ensure_agent_participant`
       (LV mount, MCP tool call, runtime channel resolve) no longer
       resurrect the participant row.
    2. @-mentioning a dismissed agent DOES bring them back, and it does
       so by inserting a fresh participant row — not by clearing a
       `left_at` flag on an old one. The rejoined row has a different
       `id` than the one that was removed.
    3. Messages authored by a dismissed participant keep rendering with
       the author_* snapshot identity after the participant row is hard-
       deleted. The live `participants_map` lookup returns nil and the
       fallback path reads `author_display_name` from the message.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Repo
  alias PlatformWeb.ChatLive.PresenceHooks

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: "test-#{System.unique_integer([:positive])}", kind: "channel"}
    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_user_participant(space_id) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Alice",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp create_agent(attrs \\ %{}) do
    Repo.insert!(%Agent{
      slug: Map.get(attrs, :slug, "agent-#{System.unique_integer([:positive])}"),
      name: Map.get(attrs, :name, "Agent"),
      status: "active"
    })
  end

  describe "1. dismissal is durable" do
    test "hard-delete via remove_participant leaves no row and no resurrection path" do
      space = create_space()
      agent = create_agent(%{name: "Higgins"})
      {:ok, participant} = Chat.add_agent_participant(space.id, agent)

      assert :ok = Chat.remove_space_agent(space.id, agent.id)
      refute Repo.get(Participant, participant.id)

      # Reading the participant back through every public lookup helper
      # returns nil. None of them resurrect.
      assert Chat.get_agent_participant(space.id, agent.id) == nil
      assert Chat.get_space_agent(space.id, agent.id) == nil
      assert Chat.list_participants(space.id) |> Enum.all?(&(&1.participant_id != agent.id))
    end

    test "list_participants no longer carries a :left_at field or include_left option" do
      # left_at is gone from the schema; passing include_left is silently
      # ignored. This test exists as a breadcrumb for anyone reintroducing
      # the soft-delete pattern — the field simply isn't there.
      participants = Chat.list_participants(Ecto.UUID.generate())
      assert participants == []

      # Participant struct has no :left_at key.
      fields = %Participant{} |> Map.from_struct() |> Map.keys()
      refute :left_at in fields
    end
  end

  describe "2. @-mention reinvites a dismissed agent with a fresh participant row" do
    test "post_message with @[Name] re-adds the agent and creates a new participant.id" do
      space = create_space()
      author = create_user_participant(space.id)
      agent = create_agent(%{name: "Higgins"})

      {:ok, %Participant{id: original_participant_id}} =
        Chat.add_agent_participant(space.id, agent)

      # Put the agent on the roster so the reinvite eligibility check passes.
      {:ok, _} = Chat.add_space_agent(space.id, agent.id)

      :ok = Chat.remove_space_agent(space.id, agent.id)
      assert Chat.get_agent_participant(space.id, agent.id) == nil

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "hey @[Higgins] welcome back"
        })

      rejoined = Chat.get_agent_participant(space.id, agent.id)
      assert %Participant{} = rejoined
      # Fresh row — NOT the old id.
      refute rejoined.id == original_participant_id
    end

    test "a non-mentioning message does NOT re-add a dismissed agent" do
      space = create_space()
      author = create_user_participant(space.id)
      agent = create_agent(%{name: "Higgins"})

      {:ok, _p} = Chat.add_agent_participant(space.id, agent)
      {:ok, _} = Chat.add_space_agent(space.id, agent.id)
      :ok = Chat.remove_space_agent(space.id, agent.id)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "just chatting, no mention here"
        })

      assert Chat.get_agent_participant(space.id, agent.id) == nil
    end
  end

  describe "3. historical attribution survives hard-delete" do
    test "messages authored by a dismissed agent render their snapshot identity" do
      space = create_space()
      user = create_user_participant(space.id)
      agent = create_agent(%{name: "Higgins"})
      {:ok, agent_participant} = Chat.add_agent_participant(space.id, agent)

      {:ok, agent_message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: agent_participant.id,
          content_type: "text",
          content: "I have completed the task."
        })

      # Sanity: the snapshot was populated at post time.
      assert agent_message.author_display_name == "Higgins"
      assert agent_message.author_participant_type == "agent"

      # Dismiss.
      :ok = Chat.remove_space_agent(space.id, agent.id)

      # The participant is gone, but the message row survives. FK set null
      # on delete keeps referential integrity; snapshot columns keep the
      # rendering correct.
      reloaded = Repo.reload!(agent_message)
      assert reloaded.participant_id == nil
      assert reloaded.author_display_name == "Higgins"
      assert reloaded.author_participant_type == "agent"
      assert reloaded.author_agent_id == agent.id

      # Render helpers fall back to the snapshot when the participant map
      # lookup misses.
      participants_map = %{user.id => %{name: "Alice"}}
      assert PresenceHooks.sender_name(participants_map, reloaded) == "Higgins"
    end
  end

  describe "4. DMs are exempt from mention-reinvite (privacy)" do
    test "post_message with @[Name] in a DM does NOT add the agent as a participant" do
      # DMs must never auto-add on mention. Contrast with describe 2 above,
      # which exercises the channel-kind mention-reinvite contract.
      dm = create_space(%{kind: "dm"})
      author = create_user_participant(dm.id)
      agent = create_agent(%{name: "Higgins"})

      assert Chat.get_agent_participant(dm.id, agent.id) == nil

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: dm.id,
          participant_id: author.id,
          content_type: "text",
          content: "hey @[Higgins] pls join"
        })

      assert Chat.get_agent_participant(dm.id, agent.id) == nil
    end

    test "in a DM, @-mentioning a current agent participant is a no-op" do
      dm = create_space(%{kind: "dm"})
      author = create_user_participant(dm.id)
      agent = create_agent(%{name: "Saru"})

      {:ok, %Participant{id: original_id}} = Chat.add_agent_participant(dm.id, agent)

      {:ok, _msg} =
        Chat.post_message(%{
          space_id: dm.id,
          participant_id: author.id,
          content_type: "text",
          content: "ping @[Saru]"
        })

      still_there = Chat.get_agent_participant(dm.id, agent.id)
      assert %Participant{id: ^original_id} = still_there
    end
  end

  # Routing-after-reinvite is covered end-to-end in
  # `Platform.Chat.SpaceAgentTest` (which starts AttentionRouter) and in
  # the lane smoke verified during the ADR 0038 rollout. Not repeated
  # here to keep this module data-layer-only.
end
