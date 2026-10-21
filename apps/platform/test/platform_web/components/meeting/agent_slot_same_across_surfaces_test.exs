defmodule PlatformWeb.Components.Meeting.AgentSlotSameAcrossSurfacesTest do
  @moduledoc """
  One agent, one slot, three surfaces (task 01a1557a rung 3 stage 3). Saru's
  canvas 01a15b1e-d673: the 3px rail is "the element that reads the same in
  chat, the meeting tile edge and the Ask row".

  The agent's `color` is stored once, in the agents table. Each surface reads
  it through its own production path, from the DB:

    * chat: `Chat.agent_slot_map_for_participants/1` over the space's chat
      participants, into `<.chat_message agent_slots_map=...>`;
    * gallery tile: the same function over the meeting's live view model
      (`MeetingLive.meeting_participant_view_model/1`'s shape, keyed by the
      meeting participant row id), into `<.agent_tile slot=...>`;
    * Ask row: `MeetingLive.load_agents_by_id/1` into `<.participant_rail>`.

  All three must carry the same `data-agent-slot`.
  """
  use Platform.DataCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias PlatformWeb.Components.Meeting.AgentTile
  alias PlatformWeb.Components.Meetings.ParticipantRail
  alias PlatformWeb.MeetingLive

  defp agent!(color) do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "same-slot-#{n}",
        name: "Same Slot #{n}",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        color: color,
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert()

    agent
  end

  defp space! do
    n = System.unique_integer([:positive, :monotonic])

    {:ok, space} =
      Chat.create_space(%{name: "Same Slot #{n}", slug: "same-slot-#{n}", kind: "channel"})

    space
  end

  defp chat_slot(participant) do
    space_slots =
      Chat.agent_slot_map_for_participants(Chat.list_participants(participant.space_id))

    assigns = %{
      msg: %{
        id: "msg-a",
        space_id: participant.space_id,
        participant_id: participant.id,
        content: "hello",
        content_type: "text",
        canvas_id: nil,
        inserted_at: ~U[2026-10-20 10:00:00.000000Z],
        day_label: nil,
        reactions: [],
        versions_count: 1,
        corrects_message_id: nil,
        metadata: nil
      },
      pid: participant.id,
      slots: space_slots
    }

    ~H"""
    <PlatformWeb.Components.ChatMessage.chat_message
      dom_id="row-a"
      msg={@msg}
      current_participant={nil}
      agent_participant_ids={MapSet.new([@pid])}
      agent_slots_map={@slots}
      highlighted_message_id={nil}
      participants_map={%{@pid => %{name: "Agent", avatar_url: nil, avatar_seed: nil}}}
      quick_emojis={[]}
      pinned_message_ids={MapSet.new()}
      canvases_by_id={%{}}
      attachments_map={%{}}
      thread_previews={%{}}
      expanded_threads={MapSet.new()}
      inline_thread_messages={%{}}
      read_only={false}
    />
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
    |> Floki.find("#row-a")
    |> Floki.attribute("data-agent-slot")
  end

  # The live meeting view model for an agent: `:id` is the meeting participant
  # row, `:participant_id` the agent (see `meeting_participant_view_model/1`).
  defp meeting_vm(agent) do
    %{
      id: Ecto.UUID.generate(),
      participant_id: agent.id,
      participant_type: "agent",
      display_name: agent.name,
      avatar_url: nil,
      identity: "agent:" <> agent.slug,
      attention_config: %{}
    }
  end

  defp tile_slot(vm) do
    slots = Chat.agent_slot_map_for_participants([vm])
    assigns = %{vm: vm, slot: Map.get(slots, vm.id)}

    ~H"""
    <AgentTile.agent_tile
      id_prefix="gallery-agent-tile"
      agent_participant={%{identity: @vm.identity, id: @vm.id, name: @vm.display_name}}
      slot={@slot}
      speaking?={true}
    />
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
    |> Floki.find("[data-agent-tile]")
    |> Floki.attribute("data-agent-slot")
  end

  defp ask_row_slot(vm) do
    render_component(&ParticipantRail.participant_rail/1,
      participants: [vm],
      agents_by_id: MeetingLive.load_agents_by_id([vm]),
      meeting: %{id: "m-1", host_participant_id: nil}
    )
    |> Floki.parse_fragment!()
    |> Floki.find(~s(li.row[data-participant-type="agent"]))
    |> Floki.attribute("data-agent-slot")
  end

  test "the chat message, the gallery tile and the Ask row carry the same slot" do
    for color <- ["rose", "lime", "amber", nil, "magenta"] do
      agent = agent!(color)
      {:ok, chat_participant} = Chat.add_agent_participant(space!().id, agent)
      vm = meeting_vm(agent)
      want = Platform.Agents.ColorPalette.slot_for(color)

      assert {chat_slot(chat_participant), tile_slot(vm), ask_row_slot(vm)} ==
               {[want], [want], [want]},
             "stored colour #{inspect(color)}"
    end
  end
end
