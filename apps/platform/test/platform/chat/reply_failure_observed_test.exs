defmodule Platform.Chat.ReplyFailureObservedTest do
  @moduledoc """
  Reply-failure notices for failures the AGENT HOST observes (task 01a10322
  stage 7).

  The behavioural gate found a native agent whose runtime could be connected
  while Claude Code could not run a turn (a well-formed but invalid API key),
  and one stuck before Claude's input box. Neither failed the dispatch, so
  neither produced a notice with the right action. Pinned here:

    * a delivered message gets its notice when the host then reports
      `needs_login` (action Log in) or `crashed` (action Restart <Name>), once;
    * a message the agent already answered gets none;
    * an agent already observed `needs_login` is not dispatched to at all,
      and the person gets the notice at once;
    * every notice clears the agent's "is thinking…" indicator.
  """
  use PlatformWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.AgentHost
  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, ReplyFailure}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.ReplyFailure.Dedupe
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias PlatformWeb.Components.ReplyFailureRow

  @token "agent-host-token-01a10322-s7-observed"

  setup do
    previous_token = Application.get_env(:platform, :agent_host_token)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_window = Application.get_env(:platform, :reply_failure_notice_dedupe_s)
    Application.put_env(:platform, :agent_host_token, @token)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    # Each test posts several notices for one agent on purpose.
    Application.put_env(:platform, :reply_failure_notice_dedupe_s, 0)

    on_exit(fn ->
      restore(:agent_host_token, previous_token)
      restore(:chat_agent_dispatch_mode, previous_mode)
      restore(:reply_failure_notice_dedupe_s, previous_window)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)
    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)

    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "observed-#{n}@example.com",
        name: "Observed #{n}",
        oidc_sub: "oidc-observed-#{n}"
      })

    {:ok, agent, _runtime} =
      NativeAgents.create(owner.id, %{name: "Bea#{n}", harness: "claude_code"})

    {:ok, _} = NativeAgents.set_desired_state(agent, "running")

    {:ok, space} =
      Chat.create_space(%{name: "Observed", slug: "observed-#{n}", kind: "channel"})

    {:ok, user} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: owner.id,
        display_name: "Owner",
        joined_at: DateTime.utc_now()
      })

    {:ok, _} = Chat.ensure_space_agent(space.id, agent.id, role: "member")
    {:ok, agent_p} = Chat.add_agent_participant(space.id, agent, display_name: agent.name)

    channel = join_host!()
    inventory!(channel, [%{"agent_id" => agent.id, "state" => "running"}])

    %{owner: owner, agent: agent, space: space, user: user, agent_p: agent_p, channel: channel}
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  defp join_host! do
    {:ok, socket} =
      connect(PlatformWeb.AgentHostSocket, %{},
        connect_info: %{x_headers: [{"x-agent-host-token", @token}]}
      )

    {:ok, _reply, channel} = subscribe_and_join(socket, "agent_host:control", %{})
    channel
  end

  defp inventory!(channel, agents) do
    ref = push(channel, "host.inventory", %{"profile" => "contained", "agents" => agents})
    assert_reply ref, :ok
  end

  defp report!(channel, agent, state, extra \\ %{}) do
    ref =
      push(channel, "agent.state", Map.merge(%{"agent_id" => agent.id, "state" => state}, extra))

    assert_reply ref, :ok
  end

  # A user message the agent's runtime received: what AgentResponder records
  # after a successful broadcast.
  defp delivered!(%{space: space, user: user, agent: agent, agent_p: agent_p}, text) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: user.id,
        content_type: "text",
        content: text
      })

    :ok =
      ReplyFailure.remember_delivery(%{
        agent: agent,
        message: message,
        agent_participant: agent_p
      })

    message
  end

  defp notices(space) do
    space.id |> Chat.list_messages(limit: 100) |> Enum.filter(&ReplyFailure.notice?/1)
  end

  describe "a delivered message, then the host observes a failure" do
    test "needs_login: exactly one notice, cause needs_login, action Log in", ctx do
      %{channel: channel, agent: agent, space: space} = ctx
      message = delivered!(ctx, "reply with the word PONG")

      report!(channel, agent, "needs_login", %{
        "detail" => "auth_error",
        "login" => %{"step" => "auth_error"}
      })

      assert [%Message{} = notice] = notices(space)
      assert notice.metadata["cause"] == "needs_login"
      assert notice.metadata["message_id"] == message.id

      assert notice.content ==
               "#{agent.name} couldn't reply to this message.\n#{agent.name}'s Claude login has expired."

      assert ReplyFailureRow.action_label(notice.metadata["cause"], agent.name) == "Log in"

      # The same state reported again is not a new failure.
      report!(channel, agent, "needs_login", %{"detail" => "auth_error"})
      assert [_one] = notices(space)
    end

    test "crashed (stuck before Claude's input box): cause crashed, action Restart", ctx do
      %{channel: channel, agent: agent, space: space} = ctx
      _ = delivered!(ctx, "hello?")

      report!(channel, agent, "crashed", %{"detail" => "stuck: Claude's input box did not appear"})

      assert [%Message{metadata: %{"cause" => "crashed"}} = notice] = notices(space)
      assert notice.content =~ "#{agent.name} stopped unexpectedly while replying."
      assert ReplyFailureRow.action_label("crashed", agent.name) == "Restart #{agent.name}"
    end

    test "POSITIVE CONTROL: without a delivery, the same transition posts nothing", ctx do
      %{channel: channel, agent: agent, space: space} = ctx
      report!(channel, agent, "needs_login")
      assert notices(space) == []
    end

    test "a message the agent already answered gets no notice", ctx do
      %{channel: channel, agent: agent, space: space, agent_p: agent_p} = ctx
      _ = delivered!(ctx, "first")

      {:ok, _reply} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: agent_p.id,
          content_type: "text",
          content: "PONG"
        })

      report!(channel, agent, "crashed")
      assert notices(space) == []
    end

    test "a running report consumes nothing: the later failure still finds the delivery", ctx do
      %{channel: channel, agent: agent, space: space} = ctx
      _ = delivered!(ctx, "first")
      report!(channel, agent, "starting")
      report!(channel, agent, "needs_login")
      assert [%Message{metadata: %{"cause" => "needs_login"}}] = notices(space)
    end

    test "the notice clears the agent's typing indicator", ctx do
      %{channel: channel, agent: agent, space: space, agent_p: agent_p} = ctx
      :ok = ChatPubSub.subscribe(space.id)
      _ = delivered!(ctx, "are you there")

      report!(channel, agent, "needs_login")

      pid = agent_p.id
      assert_receive {:agent_typing, %{participant_id: ^pid, typing: false}}
    end
  end

  describe "an agent already observed needs_login" do
    test "is not dispatched to; the mention gets the Log in notice at once", ctx do
      %{channel: channel, agent: agent, space: space, user: user, agent_p: agent_p} = ctx
      report!(channel, agent, "needs_login")
      assert %{state: :needs_login} = AgentHost.status(agent)
      assert ReplyFailure.refuse_dispatch_cause(agent) == :needs_login

      :ok = ChatPubSub.subscribe(space.id)

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: user.id,
          content_type: "text",
          content: "@#{agent.slug} reply with the word PONG"
        })

      :ok = GenServer.call(AttentionRouter, :__drain__)

      assert [%Message{} = notice] = notices(space)
      assert notice.metadata["cause"] == "needs_login"
      assert notice.metadata["message_id"] == message.id
      # Nothing was remembered as delivered: it was never sent.
      assert Dedupe.take_pending(agent.id) == nil

      pid = agent_p.id
      assert_receive {:agent_typing, %{participant_id: ^pid, typing: false}}
    end

    test "POSITIVE CONTROL: an agent observed running is not refused", ctx do
      assert ReplyFailure.refuse_dispatch_cause(ctx.agent) == nil
      assert ReplyFailure.refuse_dispatch_cause(%Agent{id: Ecto.UUID.generate()}) == nil
    end
  end

  describe "Dedupe pending" do
    test "an expired delivery is not taken" do
      id = Ecto.UUID.generate()
      :ok = Dedupe.put_pending(id, %{message_id: "m"}, 0)
      assert Dedupe.take_pending(id, Dedupe.pending_ttl_ms() + 1) == nil

      :ok = Dedupe.put_pending(id, %{message_id: "m"}, 0)
      assert Dedupe.take_pending(id, 1) == %{message_id: "m"}
      assert Dedupe.take_pending(id, 1) == nil
    end

    test "sweep removes expired pending rows too" do
      id = Ecto.UUID.generate()
      :ok = Dedupe.put_pending(id, %{message_id: "m"}, 0)
      assert Dedupe.sweep(Dedupe.pending_ttl_ms() + 1) >= 1
      assert Dedupe.take_pending(id, 0) == nil
    end
  end
end
