defmodule Platform.Federation.ToolSurfaceMeetingSayTest do
  @moduledoc """
  Coverage for the `meeting_say` MCP tool (task 01a06672 stage 2).

  Executes the tool through `ToolArguments.dispatch/3` — the entry point
  both federation transports use — and asserts on the envelope AND on what
  reached the agent's runtime topic. The pairing is the point: a refusal
  that still broadcast would be a green envelope over an uninvited voice
  in the room, so every refusal here is followed by a `refute_receive` on
  the runtime topic.

  The mutation this file exists to kill is a handler that broadcasts on its
  own instead of going through `Meetings.say/4`: the non-participant case
  then still receives a `meeting_say` frame.

  async: false — LiveKit and the ack-timeout seam live in app env, and
  `SayRegistry` is one named ETS table.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Federation
  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Meetings
  alias Platform.Repo

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "tool-say-#{n}@example.com",
      name: "Tool Say #{n}",
      oidc_sub: "oidc-tool-say-#{n}"
    })
  end

  defp agent_with_runtime! do
    n = System.unique_integer([:positive])
    owner = user!()

    agent =
      Repo.insert!(%Agent{
        slug: "tool-say-agent-#{n}",
        name: "Tool Say Agent #{n}",
        status: "active"
      })

    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "tool-say-rt-#{n}"})
    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    runtime = Federation.get_runtime(activated.id)
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

    %{agent: agent, runtime: runtime}
  end

  defp room! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Tool Say Space #{n}",
        slug: "tool-say-space-#{n}",
        kind: "channel"
      })

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)
    %{space: space, room: room}
  end

  # `link_agent/2` auto-rosters the agent into every channel space, so the
  # chat membership `authorize_writer/2` needs is already there; this adds
  # the ROSTER row, which is the thing the tool guards on.
  defp seat!(room, agent) do
    {:ok, _} = Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})
    :ok
  end

  defp say_messages(space_id) do
    Repo.all(
      from(m in Message,
        where:
          m.space_id == ^space_id and fragment("?->>'source' = ?", m.metadata, "meetings.say")
      )
    )
  end

  defp dispatch(args, agent), do: ToolArguments.dispatch("meeting_say", args, %{agent: agent})

  setup do
    original_livekit = Application.get_env(:platform, :livekit, [])
    original_timeout = Application.get_env(:platform, :meeting_say_ack_timeout_ms)

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    # The tool calls `Meetings.say/4` with no options; without this seam
    # every `no_ack` case below would be a real 15-second wait.
    Application.put_env(:platform, :meeting_say_ack_timeout_ms, 200)

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original_livekit)

      case original_timeout do
        nil -> Application.delete_env(:platform, :meeting_say_ack_timeout_ms)
        v -> Application.put_env(:platform, :meeting_say_ack_timeout_ms, v)
      end
    end)

    :ok
  end

  # ── Exposure ─────────────────────────────────────────────────────────────

  describe "the tool definition" do
    test "sits in the task bundle beside meeting_create, with both parameters required" do
      names = ToolSurface.list_tools(["task"]) |> Enum.map(& &1.name)
      assert "meeting_say" in names
      assert "meeting_create" in names

      tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == "meeting_say"))
      assert tool.parameters.room_name.required
      assert tool.parameters.text.required
      assert tool.description =~ "no_ack"
      assert tool.description =~ "spoken"
      assert tool.description =~ "failed"
    end
  end

  # ── The happy path, both endings ─────────────────────────────────────────

  describe "a seated agent" do
    test "gets one meeting_say on its runtime topic and no_ack when nothing answers" do
      %{space: space, room: room} = room!()
      %{agent: agent} = agent_with_runtime!()
      seat!(room, agent)

      assert {:ok, %{status: "no_ack", utterance_id: id, room_name: room_name}} =
               dispatch(%{"room_name" => room.livekit_room_name, "text" => "hello room"}, agent)

      assert room_name == room.livekit_room_name

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: ^id, text: "hello room"}
                     },
                     1_000

      # Exactly one.
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
      assert say_messages(space.id) == []
    end

    test "returns spoken when the runtime acks, and the text lands in chat" do
      %{space: space, room: room} = room!()
      %{agent: agent} = agent_with_runtime!()
      seat!(room, agent)
      room_name = room.livekit_room_name

      # A longer window for this one case: the ack has to be sent by hand.
      Application.put_env(:platform, :meeting_say_ack_timeout_ms, 2_000)

      task = Task.async(fn -> dispatch(%{"room_name" => room_name, "text" => "on it"}, agent) end)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "meeting_say",
                       payload: %{utterance_id: id}
                     },
                     1_000

      Meetings.record_agent_say_ack(agent.id, %{
        "utterance_id" => id,
        "room_name" => room_name,
        "status" => "spoken",
        "duration_s" => 0.8
      })

      assert {:ok, %{status: "spoken", utterance_id: ^id, duration_s: 0.8}} = Task.await(task)
      assert [%Message{content: "on it"}] = say_messages(space.id)
    end
  end

  # ── Refusals, each with an empty runtime topic ───────────────────────────

  describe "refusals" do
    test "an agent that was not invited gets a not-a-participant envelope and NO broadcast" do
      %{room: room} = room!()
      %{agent: agent} = agent_with_runtime!()

      assert {:error, env} =
               dispatch(%{"room_name" => room.livekit_room_name, "text" => "let me in"}, agent)

      assert env.code == :not_in_room
      assert env.recoverable
      assert env.suggestion =~ "not a participant"
      assert env.suggestion =~ "invite you from the meeting page"

      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 200
    end

    # Task 01a06686 stage 2: `Meetings.say/4` resolves through
    # `resolve_voice_target/1`, so a declared-but-disconnected voice row is
    # its own refusal, with its own code, rather than the catch-all.
    test "a voice row that declared voice but is not connected is refused as offline" do
      %{room: room} = room!()
      %{agent: agent} = agent_with_runtime!()
      seat!(room, agent)

      owner = user!()
      {:ok, voice, _token} = Federation.register_voice_runtime(owner.id, agent)

      {:ok, _} =
        Federation.update_metadata(voice, %{
          "client_info" => %{"product" => "openclaw", "features" => ["meeting_voice"]}
        })

      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{voice.runtime_id}")

      assert {:error, env} =
               dispatch(%{"room_name" => room.livekit_room_name, "text" => "hello?"}, agent)

      assert env.code == :voice_runtime_offline
      assert env.recoverable
      assert env.error =~ "voice worker is offline"
      assert env.suggestion =~ "not connected"

      # Neither the brain nor the voice topic got the utterance.
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 200
    end

    test "text over the cap names the cap" do
      %{room: room} = room!()
      %{agent: agent} = agent_with_runtime!()
      seat!(room, agent)

      assert {:error, env} =
               dispatch(
                 %{"room_name" => room.livekit_room_name, "text" => String.duplicate("x", 2_001)},
                 agent
               )

      assert env.code == :text_too_long
      assert env.error =~ "2000"
      assert env.suggestion =~ "2000"
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end

    test "a missing room_name is refused by the argument gate" do
      %{agent: agent} = agent_with_runtime!()

      assert {:error, env} = dispatch(%{"text" => "where am I"}, agent)
      assert env.code == :missing_room_name
      assert env.recoverable
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end

    test "an unknown room is refused" do
      %{agent: agent} = agent_with_runtime!()

      assert {:error, env} = dispatch(%{"room_name" => "space-nope", "text" => "hi"}, agent)
      assert env.code == :room_not_found
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end

    # Task 01a06672 stage 2: the reply budget lives in `Meetings.say/4`;
    # the tool only has to give each refusal its own code. Seeded straight
    # into the ledger, so no runtime and no ack wait is involved.
    test "a budget refusal is an envelope with code :reply_budget_exhausted" do
      %{room: room} = room!()
      %{agent: agent} = agent_with_runtime!()
      seat!(room, agent)

      for _ <- 1..6 do
        Meetings.SayRegistry.ledger_put(Platform.Types.UUIDv7.generate(), %{
          room_id: room.id,
          room_name: room.livekit_room_name,
          agent_id: agent.id,
          at_ms: System.monotonic_time(:millisecond)
        })
      end

      assert {:error, env} =
               dispatch(%{"room_name" => room.livekit_room_name, "text" => "one more"}, agent)

      assert env.code == :reply_budget_exhausted
      assert env.recoverable
      assert env.suggestion =~ "6 times"
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end

    test "a chain refusal is an envelope with code :agent_chain_too_deep" do
      %{room: room} = room!()
      %{agent: agent} = agent_with_runtime!()
      %{agent: other} = agent_with_runtime!()
      seat!(room, agent)
      seat!(room, other)

      # Three accepted says in the room, by two agents, and no human since.
      for speaker <- [agent, other, agent] do
        Meetings.SayRegistry.ledger_put(Platform.Types.UUIDv7.generate(), %{
          room_id: room.id,
          room_name: room.livekit_room_name,
          agent_id: speaker.id,
          at_ms: System.monotonic_time(:millisecond)
        })
      end

      assert {:error, env} =
               dispatch(%{"room_name" => room.livekit_room_name, "text" => "me again"}, agent)

      assert env.code == :agent_chain_too_deep
      assert env.recoverable
      assert env.suggestion =~ "Wait for a human"
      refute_receive %Phoenix.Socket.Broadcast{event: "meeting_say"}, 100
    end

    test "no calling agent in context is refused" do
      assert {:error, env} =
               ToolArguments.dispatch(
                 "meeting_say",
                 %{"room_name" => "space-x", "text" => "hi"},
                 %{}
               )

      assert env.error =~ "no calling agent"
    end
  end
end
