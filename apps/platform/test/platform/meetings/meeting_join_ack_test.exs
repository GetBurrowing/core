defmodule Platform.Meetings.MeetingJoinAckTest do
  @moduledoc """
  Task 01a0554f — the `meeting_join_ack` that core received and never read.

  ## What was broken

  `PlatformWeb.RuntimeChannel.handle_in("meeting_join_ack", ...)` logged the
  ack, emitted telemetry, and returned `{:noreply, socket}`. So a runtime
  answering `status: "error"` — which is what a text-only agent with no voice
  worker answers — told core the join had failed, and the meeting screen went
  on displaying its optimistic invite flash for the rest of the call. The
  founder sat through five test meetings waiting for an agent that had already
  said no.

  This is NOT the silent-failure shape the rest of the meeting suite guards.
  The disproof arrived, on the wire, and was dropped on the floor.

  ## What these tests refuse to be satisfied by

  The obvious test — "a failing ack broadcasts `:agent_join_failed`" — is
  green against a function that broadcasts unconditionally, which would turn
  every successful join into an error banner. So the success direction is
  asserted with `refute_receive` in the same describe block, and both are
  driven through the same helper. Pinning one direction here is worth nothing.

  A `"joined"` ack is deliberately NOT broadcast as arrival either: it means
  the worker accepted the dispatch, not that it published into the room. That
  distinction is the whole of task 01a04e0f, so it gets its own assertion
  rather than being left implied by the absence of a message.

  The channel-level test exists because `Meetings.record_agent_join_ack/3`
  being correct proves nothing about whether anything calls it — the original
  defect was a correct signal with no consumer, and a context-only test would
  reproduce exactly that.
  """
  use Platform.DataCase, async: false

  import Phoenix.ChannelTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo

  @endpoint PlatformWeb.Endpoint

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "join-ack-#{n}@example.com",
      name: "Join Ack #{n}",
      oidc_sub: "oidc-join-ack-#{n}"
    })
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "join-ack-agent-#{n}",
      name: "Join Ack Agent #{n}",
      status: "active"
    })
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Join Ack Space #{n}",
        slug: "join-ack-space-#{n}",
        kind: "channel"
      })

    space
  end

  # An active room, subscribed, so a broadcast on its topic lands in this
  # test process's mailbox exactly as it lands in a MeetingLive process.
  defp subscribed_room! do
    space = space!()
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)
    :ok = MeetingsPubSub.subscribe_room(room.id)
    %{space: space, room: room}
  end

  defp agent_with_runtime! do
    owner = user!()
    agent = agent!()

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "join-ack-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  # ── The context function ─────────────────────────────────────────────────

  describe "record_agent_join_ack/3" do
    test "a failing ack reaches the room topic, naming the agent" do
      %{room: room} = subscribed_room!()
      agent = agent!()

      :ok = Meetings.record_agent_join_ack(agent.id, room.livekit_room_name, "error")

      assert_receive {:agent_join_failed, info}, 1_000
      assert info.agent_id == agent.id
      assert info.agent_name == agent.name
      assert info.room_name == room.livekit_room_name
      assert info.status == "error"
    end

    # The control for the test above. Without it, `record_agent_join_ack/3`
    # could broadcast on every ack and both would be green — turning a working
    # join into a red banner in front of the user.
    test "a successful ack broadcasts NOTHING" do
      %{room: room} = subscribed_room!()
      agent = agent!()

      :ok = Meetings.record_agent_join_ack(agent.id, room.livekit_room_name, "joined")

      refute_receive {:agent_join_failed, _}, 300
    end

    # `"joined"` is also the default RuntimeChannel applies when a client omits
    # `status`, so the same silence must hold for it.
    test "acceptance is not reported as arrival" do
      %{room: room} = subscribed_room!()
      agent = agent!()

      :ok = Meetings.record_agent_join_ack(agent.id, room.livekit_room_name, "JOINED")
      :ok = Meetings.record_agent_join_ack(agent.id, room.livekit_room_name, " joined ")

      refute_receive {:agent_join_failed, _}, 300
      refute_receive {:participant_joined, _}, 300
    end

    # An unrecognised token must fail LOUD, not quiet: a visible wrong answer
    # is retryable, a silent one is the defect being fixed.
    test "an unknown status token is treated as a failure" do
      %{room: room} = subscribed_room!()
      agent = agent!()

      :ok = Meetings.record_agent_join_ack(agent.id, room.livekit_room_name, "wedged")

      assert_receive {:agent_join_failed, %{status: "wedged"}}, 1_000
    end

    test "an ack for a room that no longer exists is a no-op, not a raise" do
      %{room: room} = subscribed_room!()

      assert :ok =
               Meetings.record_agent_join_ack(
                 agent!().id,
                 "space-gone-#{System.unique_integer([:positive])}",
                 "error"
               )

      refute_receive {:agent_join_failed, _}, 300

      # And the live room is untouched by the miss.
      assert Meetings.get_room_by_name(room.livekit_room_name)
    end

    test "an ack with no agent id still names the room and reports a failure" do
      %{room: room} = subscribed_room!()

      :ok = Meetings.record_agent_join_ack(nil, room.livekit_room_name, "error")

      assert_receive {:agent_join_failed, info}, 1_000
      assert info.agent_id == nil
      assert info.agent_name == "That agent"
    end
  end

  # ── The wire ─────────────────────────────────────────────────────────────

  describe "the ack a real RuntimeChannel client sends" do
    # The load-bearing test. The original defect was a correct signal with no
    # consumer, so proving the context function works while nothing calls it
    # would reproduce the bug and stay green.
    test "a client's error ack is consumed and surfaced to the room" do
      %{agent: agent, runtime: runtime, raw_token: raw_token} = agent_with_runtime!()
      %{room: room} = subscribed_room!()

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => runtime.runtime_id,
          "token" => raw_token
        })

      {:ok, _reply, channel} =
        subscribe_and_join(
          socket,
          PlatformWeb.RuntimeChannel,
          "runtime:#{runtime.runtime_id}",
          %{}
        )

      push(channel, "meeting_join_ack", %{
        "room_name" => room.livekit_room_name,
        "status" => "error"
      })

      assert_receive {:agent_join_failed, info}, 1_000
      assert info.agent_id == agent.id
      assert info.status == "error"
    end

    test "a client's successful ack produces no failure banner" do
      %{runtime: runtime, raw_token: raw_token} = agent_with_runtime!()
      %{room: room} = subscribed_room!()

      {:ok, socket} =
        connect(PlatformWeb.RuntimeSocket, %{
          "runtime_id" => runtime.runtime_id,
          "token" => raw_token
        })

      {:ok, _reply, channel} =
        subscribe_and_join(
          socket,
          PlatformWeb.RuntimeChannel,
          "runtime:#{runtime.runtime_id}",
          %{}
        )

      push(channel, "meeting_join_ack", %{
        "room_name" => room.livekit_room_name,
        "status" => "joined"
      })

      refute_receive {:agent_join_failed, _}, 500
    end
  end
end
