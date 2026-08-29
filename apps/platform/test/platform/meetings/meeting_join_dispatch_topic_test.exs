defmodule Platform.Meetings.MeetingJoinDispatchTopicTest do
  @moduledoc """
  Task 01a04f31 — `meeting_join` was broadcast on a topic no client can join.

  ## What was broken

  `Platform.Meetings.dispatch_meeting_join/3` broadcast on
  `"runtime:agent:\#{agent.id}"`. `PlatformWeb.RuntimeChannel.join/3` matches
  `"runtime:" <> runtime_id` and requires it to equal
  `socket.assigns.runtime_id`, which `PlatformWeb.RuntimeSocket.connect/3`
  assigns from `AgentRuntime.runtime_id` — the external STRING, never an agent
  UUID. `Phoenix.Endpoint.broadcast/3` returns `:ok` with zero subscribers, so
  `invite_agent/3` succeeded, wrote a `meeting_participants` row and logged
  "dispatched" while delivering to nobody.

  ## Why the test that shipped with the feature could not catch it

  `PlatformWeb.MeetingLiveAgentInviteTest` asserted the dispatch with

      PlatformWeb.Endpoint.subscribe("runtime:agent:\#{agent.id}")

  an in-VM `Phoenix.PubSub` subscribe. That call bypasses `join/3` entirely:
  the test process becomes a subscriber on a topic that no websocket client
  could ever have become a subscriber on, so it can confirm a broadcast
  happened and can never discover that the broadcast was unreachable.

  ## What this file refuses to be satisfied by

  Nothing here calls `Endpoint.subscribe/1`. The load-bearing test drives a
  REAL runtime through `PlatformWeb.RuntimeSocket.connect/3` and
  `subscribe_and_join/3`, so `join/3`'s authorization sits in the delivery
  path, and then asserts the `meeting_join` frame is pushed to that client.
  Reverting the topic to `"runtime:agent:\#{agent.id}"` turns it red, because
  the channel process is not subscribed to that topic — which is the whole
  defect, restated as an assertion.

  Its companion asserts the converse directly: a correctly authenticated
  socket is REFUSED when it tries to join the old topic. That is the in-VM
  equivalent of the live production probe (the orchestrator reports a valid
  token joining `runtime:agent:<uuid>` returned
  `{"status":"error","response":{"reason":"unauthorized"}}` while
  `runtime:<runtime_id>` returned `{"status":"ok"}`).

  `async: false` — LiveKit lives in app env, and `RuntimeChannel.join/3`
  writes through the shared sandbox from a separate process.
  """
  use PlatformWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.IntentRuntimeAdapter
  alias Platform.Meetings.Participant, as: MeetingParticipant
  alias Platform.Repo

  @room_name "meeting-dispatch-topic-test"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "meeting-join-topic-#{n}@example.com",
      name: "Meeting Join Topic #{n}",
      oidc_sub: "oidc-meeting-join-topic-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "join-topic-agent-#{n}",
      name: "Join Topic Agent #{n}",
      status: "active"
    })
  end

  # An agent with a live, activated, LINKED runtime — i.e. an agent that a
  # real websocket client can be connected for. `raw_token` is returned
  # because it is the only moment the plaintext exists; the row stores a hash.
  defp agent_with_runtime! do
    owner = user!()
    agent = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "join-topic-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  defp connected_runtime_client!(%{runtime: runtime, raw_token: raw_token}) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    socket
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Join Topic Space #{n}",
        slug: "join-topic-space-#{n}",
        kind: "channel"
      })

    space
  end

  # A room plus a member who `SpaceAccess.authorize_writer/2` will admit, so
  # every `invite_agent/3` refusal below is about the runtime and not about
  # the actor.
  defp room_with_writer! do
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    inviter = user!()

    {:ok, _row} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: inviter.id,
        display_name: inviter.name,
        joined_at: DateTime.utc_now()
      })

    %{space: space, room: room, inviter: inviter}
  end

  defp agent_participant_rows(space_id, agent_id) do
    Repo.all(
      from(p in MeetingParticipant,
        join: r in Meetings.Room,
        on: r.id == p.room_id,
        where: r.space_id == ^space_id and p.agent_id == ^agent_id
      )
    )
  end

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    :ok
  end

  # ── The topic a real client can join ─────────────────────────────────────

  describe "the topic dispatch_meeting_join/3 publishes on" do
    test "reaches a runtime that authenticated and joined through RuntimeChannel" do
      %{agent: agent} = ctx = agent_with_runtime!()

      {:ok, _reply, _channel} =
        ctx
        |> connected_runtime_client!()
        |> subscribe_and_join("runtime:#{ctx.runtime.runtime_id}", %{})

      assert :ok = Meetings.dispatch_meeting_join(agent, @room_name, %{})

      # `assert_push`, not `assert_broadcast`: this asserts the frame reached
      # the CLIENT through the joined channel process. `assert_broadcast`
      # would only prove the test process's own topic subscription fired,
      # which is the weaker thing the #856 test did.
      assert_push "meeting_join", payload, 1_000

      assert payload.agent_identity == "agent:" <> agent.slug
      assert payload.room_name == @room_name
      assert is_binary(payload.token) and payload.token != ""
      assert [_header, _claims, _sig] = String.split(payload.token, ".")
    end

    test "is the runtime_id topic, derived through the resolver rather than rebuilt" do
      %{agent: agent, runtime: runtime} = agent_with_runtime!()

      assert {:ok, topic} = Meetings.meeting_join_topic(agent)
      assert topic == IntentRuntimeAdapter.runtime_topic(runtime.runtime_id)

      # The mutant this file exists to kill, named explicitly.
      refute topic == "runtime:agent:#{agent.id}"
    end

    test "the old agent-UUID topic is REFUSED by RuntimeChannel.join/3" do
      %{agent: agent} = ctx = agent_with_runtime!()

      socket = connected_runtime_client!(ctx)

      # Positive control on the very same socket: the runtime_id topic is
      # accepted, so the refusal below is about the TOPIC and not about the
      # credentials, the runtime row, or the sandbox.
      assert {:ok, _reply, _channel} =
               subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "runtime:agent:#{agent.id}", %{})

      # And the runtime's own primary key is not it either — only the
      # external string is.
      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, "runtime:#{ctx.runtime.id}", %{})
    end
  end

  # ── An agent with no runtime ─────────────────────────────────────────────

  describe "an agent with no linked AgentRuntime" do
    test "dispatch_meeting_join/3 returns {:error, :no_runtime} instead of a green no-op" do
      agent = agent!()
      assert agent.runtime_id == nil

      assert {:error, :no_runtime} = Meetings.dispatch_meeting_join(agent, @room_name, %{})
      assert {:error, :no_runtime} = Meetings.meeting_join_topic(agent)

      # Positive control: the identical call with a runtime attached is `:ok`,
      # so the error above is about the missing runtime and not about LiveKit
      # config or the room name.
      %{agent: runnable} = agent_with_runtime!()
      assert :ok = Meetings.dispatch_meeting_join(runnable, @room_name, %{})
    end

    test "invite_agent/3 refuses and writes no participant row" do
      %{space: space, room: room, inviter: inviter} = room_with_writer!()
      agent = agent!()

      assert {:error, :no_runtime} = Meetings.invite_agent(room, agent, inviter)
      assert agent_participant_rows(space.id, agent.id) == []

      # Positive control on the identical call: same room, same authorized
      # inviter, an agent that differs only in having a runtime.
      %{agent: runnable} = agent_with_runtime!()
      assert {:ok, %MeetingParticipant{}} = Meetings.invite_agent(room, runnable, inviter)
      assert [%MeetingParticipant{}] = agent_participant_rows(space.id, runnable.id)
    end
  end

  # ── The whole path, from invite_agent/3 to a websocket client ────────────

  describe "invite_agent/3" do
    test "delivers the join to the invited agent's connected runtime client" do
      %{room: room, inviter: inviter} = room_with_writer!()
      %{agent: agent} = ctx = agent_with_runtime!()

      {:ok, _reply, _channel} =
        ctx
        |> connected_runtime_client!()
        |> subscribe_and_join("runtime:#{ctx.runtime.runtime_id}", %{})

      assert {:ok, %MeetingParticipant{}} = Meetings.invite_agent(room, agent, inviter)

      assert_push "meeting_join", payload, 1_000
      assert payload.room_name == room.livekit_room_name
      assert payload.space_id == room.space_id
    end
  end
end
