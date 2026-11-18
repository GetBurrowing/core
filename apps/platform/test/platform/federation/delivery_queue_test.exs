defmodule Platform.Federation.DeliveryQueueTest do
  @moduledoc """
  A chat message to an external runtime is held until it is delivered,
  instead of failed the moment a broadcast cannot go out.

  Pinned end to end through the real runtime socket:

    * a runtime that is offline at dispatch (a deploy restart drops every
      socket for a few seconds): no notice, no dead letter, the space is told
      "waiting", and the message is pushed when the runtime joins;
    * a runtime that never comes back inside the TTL: exactly one notice;
    * a runtime that declares `attention_ack`: an unacked attention is pushed
      again, an `attention_ack` stops it, and attempts are bounded;
    * a runtime WITHOUT the feature (every plugin before it): one push, never
      a redelivery it would run as a duplicate turn;
    * a held message the agent answered meanwhile is not redelivered.
  """
  use PlatformWeb.ChannelCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{AgentResponder, ReplyFailure}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Federation
  alias Platform.Federation.{DeadLetter, DeliveryQueue, RuntimePresence}
  alias Platform.Repo

  @ack_timeout_ms 150

  setup do
    keys = [
      :delivery_queue_enabled,
      :delivery_queue_ttl_ms,
      :delivery_queue_ack_timeout_ms,
      :delivery_queue_max_attempts,
      :chat_agent_dispatch_mode
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})
    Application.put_env(:platform, :delivery_queue_enabled, true)
    Application.put_env(:platform, :delivery_queue_ttl_ms, 10_000)
    Application.put_env(:platform, :delivery_queue_ack_timeout_ms, @ack_timeout_ms)
    Application.put_env(:platform, :delivery_queue_max_attempts, 3)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), presence)

    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "dq-#{n}@example.com",
        name: "DQ #{n}",
        oidc_sub: "oidc-dq-#{n}"
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{slug: "dq-#{n}", name: "Quill#{n}", status: "active"})
      |> Repo.insert()

    {:ok, runtime} = Federation.register_runtime(owner.id, %{runtime_id: "dq-rt-#{n}"})
    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)

    {:ok, space} = Chat.create_space(%{name: "Queue", slug: "dq-#{n}", kind: "channel"})

    {:ok, user} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: owner.id,
        display_name: "Owner",
        joined_at: DateTime.utc_now()
      })

    {:ok, agent_p} = Chat.add_agent_participant(space.id, agent, display_name: agent.name)

    %{
      agent: agent,
      runtime: Federation.get_runtime(activated.id),
      raw_token: raw_token,
      space: space,
      user: user,
      agent_p: agent_p
    }
  end

  defp join!(ctx, features) do
    {:ok, socket} =
      connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => ctx.runtime.runtime_id,
        "token" => ctx.raw_token
      })

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "runtime:#{ctx.runtime.runtime_id}", %{
        "client_info" => %{
          "product" => "claude_channel",
          "version" => "0.5.0",
          "features" => features
        }
      })

    socket
  end

  defp leave!(socket) do
    Process.unlink(socket.channel_pid)
    ref = leave(socket)
    assert_reply ref, :ok
    # terminate/2 untracks presence; wait for it.
    assert_eventually(fn -> not RuntimePresence.online?(socket.assigns.runtime_id) end)
  end

  defp mention!(ctx, text) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: ctx.space.id,
        participant_id: ctx.user.id,
        content_type: "text",
        content: text
      })

    signal = %{
      reason: :mention,
      participant_id: ctx.agent_p.id,
      message_id: message.id,
      space_id: ctx.space.id
    }

    {message, signal}
  end

  defp notices(space) do
    space.id |> Chat.list_messages(limit: 100) |> Enum.filter(&ReplyFailure.notice?/1)
  end

  defp entries_for(ctx) do
    Enum.filter(DeliveryQueue.entries(), &(&1.runtime_id == ctx.runtime.runtime_id))
  end

  describe "a runtime that is offline at dispatch" do
    test "holds the message, says waiting, and pushes it when the runtime joins", ctx do
      %{space: space, agent_p: agent_p} = ctx
      :ok = ChatPubSub.subscribe(space.id)
      refute RuntimePresence.online?(ctx.runtime.runtime_id)

      {message, signal} = mention!(ctx, "@quill what's the status?")
      assert :ok = AgentResponder.respond(signal)

      # Not failed: no notice, no dead letter.
      assert notices(space) == []
      assert Repo.all(DeadLetter) == []
      assert [%{state: :held, message_id: held_id}] = entries_for(ctx)
      assert held_id == message.id

      pid = agent_p.id

      assert_receive {:agent_busy,
                      %{participant_id: ^pid, busy: %{state: "queued", since: %DateTime{}}}}

      assert %{^pid => %{state: "queued"}} = DeliveryQueue.held_in_space(space.id)

      # The runtime comes back (an old plugin: no ack feature).
      _socket = join!(ctx, [])
      message_id = message.id
      assert_push "attention", %{signal: %{message_id: ^message_id}}, 3_000

      # Waiting is over, and nothing is left to redeliver.
      assert_receive {:agent_busy, %{participant_id: ^pid, busy: nil}}, 1_000
      assert_eventually(fn -> entries_for(ctx) == [] end)
      refute_push "attention", %{signal: %{message_id: ^message_id}}, @ack_timeout_ms * 3
      assert notices(space) == []
    end

    test "a runtime that does not come back inside the TTL: exactly one notice", ctx do
      Application.put_env(:platform, :delivery_queue_ttl_ms, 200)
      {message, signal} = mention!(ctx, "@quill hello?")
      assert :ok = AgentResponder.respond(signal)
      assert notices(ctx.space) == []

      [notice] = assert_eventually(fn -> notices(ctx.space) |> then(&(&1 != [] && &1)) end)
      assert notice.metadata["message_id"] == message.id
      assert notice.metadata["agent_id"] == ctx.agent.id
      assert entries_for(ctx) == []

      Process.sleep(300)
      assert [_one] = notices(ctx.space)
    end

    test "a held message the agent answered meanwhile is not redelivered", ctx do
      {message, signal} = mention!(ctx, "@quill ping")
      assert :ok = AgentResponder.respond(signal)
      assert [%{state: :held}] = entries_for(ctx)

      {:ok, _} =
        Chat.post_message(%{
          space_id: ctx.space.id,
          participant_id: ctx.agent_p.id,
          content_type: "text",
          content: "pong (answered another way)"
        })

      _socket = join!(ctx, [])
      message_id = message.id
      refute_push "attention", %{signal: %{message_id: ^message_id}}, 1_500
      assert_eventually(fn -> entries_for(ctx) == [] end)
    end

    test "with the queue off, the old behaviour: an instant notice", ctx do
      Application.put_env(:platform, :delivery_queue_enabled, false)
      {_message, signal} = mention!(ctx, "@quill off")
      assert {:error, :runtime_offline} = AgentResponder.respond(signal)
      assert [_notice] = notices(ctx.space)
      assert entries_for(ctx) == []
    end
  end

  describe "a runtime that declares attention_ack" do
    test "an ack settles the delivery; no redelivery follows", ctx do
      socket = join!(ctx, [DeliveryQueue.ack_feature()])
      assert DeliveryQueue.acks?(Federation.get_runtime(ctx.runtime.id))

      {message, signal} = mention!(ctx, "@quill ack me")
      assert :ok = AgentResponder.respond(signal)
      message_id = message.id
      assert_push "attention", %{signal: %{message_id: ^message_id}}
      assert [%{state: :awaiting_ack}] = entries_for(ctx)

      ref = push(socket, "attention_ack", %{"message_id" => message_id})
      assert_reply ref, :ok, %{message_id: ^message_id, pending: true}
      assert entries_for(ctx) == []

      refute_push "attention", %{signal: %{message_id: ^message_id}}, @ack_timeout_ms * 3

      # The ack is evidence core observed, recorded as such.
      assert %{proven: %{"attention_ack" => %DateTime{}}} =
               RuntimePresence.status(ctx.runtime.runtime_id)

      # An ack for nothing pending is answered, not an error.
      ref = push(socket, "attention_ack", %{"message_id" => message_id})
      assert_reply ref, :ok, %{pending: false}
    end

    test "no ack: pushed again, up to the attempt cap, then dropped", ctx do
      _socket = join!(ctx, [DeliveryQueue.ack_feature()])
      {message, signal} = mention!(ctx, "@quill are you there")
      assert :ok = AgentResponder.respond(signal)
      message_id = message.id

      # Attempt 1, then 2 and 3 on ack timeouts; the cap is 3.
      for _attempt <- 1..3 do
        assert_push "attention", %{signal: %{message_id: ^message_id}}, 2_000
      end

      refute_push "attention", %{signal: %{message_id: ^message_id}}, @ack_timeout_ms * 4
      assert_eventually(fn -> entries_for(ctx) == [] end)
    end

    test "unacked when the socket drops: pushed again on rejoin", ctx do
      Application.put_env(:platform, :delivery_queue_ack_timeout_ms, 10_000)
      socket = join!(ctx, [DeliveryQueue.ack_feature()])
      {message, signal} = mention!(ctx, "@quill during a deploy")
      assert :ok = AgentResponder.respond(signal)
      message_id = message.id
      assert_push "attention", %{signal: %{message_id: ^message_id}}

      leave!(socket)
      socket = join!(ctx, [DeliveryQueue.ack_feature()])
      assert_push "attention", %{signal: %{message_id: ^message_id}}, 3_000

      ref = push(socket, "attention_ack", %{"message_id" => message_id})
      assert_reply ref, :ok, %{pending: true}
      assert entries_for(ctx) == []
    end
  end

  describe "a runtime without the feature (every plugin before it)" do
    test "one push and nothing tracked: a redelivery would be a duplicate turn", ctx do
      _socket = join!(ctx, [])
      refute DeliveryQueue.acks?(Federation.get_runtime(ctx.runtime.id))

      {message, signal} = mention!(ctx, "@quill old plugin")
      assert :ok = AgentResponder.respond(signal)
      message_id = message.id
      assert_push "attention", %{signal: %{message_id: ^message_id}}
      assert entries_for(ctx) == []
      refute_push "attention", %{signal: %{message_id: ^message_id}}, @ack_timeout_ms * 3
    end
  end
end
