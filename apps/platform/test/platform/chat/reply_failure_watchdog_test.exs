defmodule Platform.Chat.ReplyFailureWatchdogTest do
  @moduledoc """
  No message to a native agent ends silently (task 01a10322 stage 7, round 2).

  The behavioural gate found two mentions with no reply, no notice and a
  "thinking…" indicator that never cleared, because nothing failed that
  anyone observed:

    * case 7008, an agent that answered in its own terminal;
    * case 7009, an agent whose key went bad after it worked: the pane read
      ready and the dev channel dropped the message.

  `Platform.Chat.ReplyFailure.Watchdog` is the one mechanism for both. Pinned
  here, each with its positive control:

    * a delivered message with no reply and no turn activity gets EXACTLY ONE
      notice inside the window, and the indicator clears;
    * the host is asked whether the key works; a rejected key reads
      needs_login (row tagged, action Log in), anything else unknown (action
      Restart <Name> for a native agent);
    * a reply in time, or turn activity, holds the notice off;
    * a federated agent, or the watchdog switched off, arms nothing.
  """
  use PlatformWeb.ChannelCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.AgentHost
  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, ReplyFailure}
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.ReplyFailure.{Dedupe, Watchdog}
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias PlatformWeb.Components.ReplyFailureRow

  @token "agent-host-token-01a10322-s7r2-watchdog"
  @window_ms 150

  setup do
    keys = [
      :agent_host_token,
      :chat_agent_dispatch_mode,
      :reply_failure_notice_dedupe_s,
      :native_reply_watchdog_ms,
      :native_reply_watchdog_max_ms
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})
    Application.put_env(:platform, :agent_host_token, @token)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    # A zero window: only the per-MESSAGE dedupe can keep a second notice out,
    # which is the one the host's report and the watchdog race on.
    Application.put_env(:platform, :reply_failure_notice_dedupe_s, 0)
    Application.put_env(:platform, :native_reply_watchdog_ms, @window_ms)
    Application.put_env(:platform, :native_reply_watchdog_max_ms, 10_000)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)
    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)
    assert is_pid(Process.whereis(Watchdog))

    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "watchdog-#{n}@example.com",
        name: "Watchdog #{n}",
        oidc_sub: "oidc-watchdog-#{n}"
      })

    {:ok, agent, _runtime} =
      NativeAgents.create(owner.id, %{name: "Bea#{n}", harness: "claude_code"})

    {:ok, _} = NativeAgents.set_desired_state(agent, "running")

    {:ok, space} =
      Chat.create_space(%{name: "Watchdog", slug: "watchdog-#{n}", kind: "channel"})

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

  # A user message delivered to the agent's runtime: what AgentResponder
  # records after a successful broadcast.
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

  # The host's side of `agent.check_auth`: answer `result` under the ref core
  # sent, as services/agent-host/src/host.ts does.
  defp answer_auth!(channel, agent, result) do
    agent_id = agent.id
    assert_push "agent.check_auth", %{"agent_id" => ^agent_id, "ref" => ref}, 3_000
    ref = push(channel, "agent.auth", %{"ref" => ref, "agent_id" => agent_id, "result" => result})
    assert_reply ref, :ok
  end

  describe "a delivered message that gets no reply and no turn activity" do
    test "exactly one notice inside the window, cause unknown, and thinking clears", ctx do
      %{channel: channel, agent: agent, space: space, agent_p: agent_p} = ctx
      :ok = ChatPubSub.subscribe(space.id)
      message = delivered!(ctx, "what is your marker?")
      assert [%{message_id: message_id}] = Watchdog.watches()
      assert message_id == message.id

      answer_auth!(channel, agent, "unknown")

      [notice] = assert_eventually(fn -> notices(space) |> then(&(&1 != [] && &1)) end)
      assert notice.metadata["cause"] == "unknown"
      assert notice.metadata["detail"] == "no_response"
      assert notice.metadata["message_id"] == message.id

      assert notice.content ==
               "#{agent.name} couldn't reply to this message.\nSomething went wrong before #{agent.name} could reply."

      pid = agent_p.id
      assert_receive {:agent_typing, %{participant_id: ^pid, typing: false}}, 1_000

      # A native agent's unknown cause offers Restart; a federated agent's
      # keeps "Open" (positive control for the branch).
      assert ReplyFailureRow.action_label("unknown", agent.name, true) == "Restart #{agent.name}"
      assert ReplyFailureRow.action_label("unknown", agent.name, false) == "Open #{agent.name}"

      # Exactly one: several windows later there is still one, the watch is
      # gone, and the notice was not routed back to the agent as a turn.
      Process.sleep(@window_ms * 4)
      assert [_one] = notices(space)
      assert Watchdog.watches() == []
      assert {:ok, []} = AttentionRouter.route(notice)
      assert Repo.aggregate(from_agent(agent, space), :count) == 0
    end

    test "a key the host finds rejected reads needs_login: row tagged, action Log in, one notice",
         ctx do
      %{channel: channel, agent: agent, space: space} = ctx
      _ = delivered!(ctx, "reply with the word OK3")

      answer_auth!(channel, agent, "rejected")

      # The host then reports the agent needs_login (host.ts handleCheckAuth),
      # which posts through notify_pending too. Both race for ONE message.
      ref =
        push(channel, "agent.state", %{
          "agent_id" => agent.id,
          "state" => "needs_login",
          "detail" => "auth_error",
          "login" => %{"step" => "auth_error"}
        })

      assert_reply ref, :ok

      [notice] = assert_eventually(fn -> notices(space) |> then(&(&1 != [] && &1)) end)
      assert notice.metadata["cause"] == "needs_login"
      assert notice.content =~ "#{agent.name}'s Claude login has expired."
      assert ReplyFailureRow.action_label("needs_login", agent.name, true) == "Log in"
      assert %{state: :needs_login} = AgentHost.status(agent)

      Process.sleep(@window_ms * 4)
      assert [_one] = notices(space)

      # The next mention is refused at dispatch with the same cause: the row
      # stays tagged until a start gives the agent a new key.
      assert ReplyFailure.refuse_dispatch_cause(agent) == :needs_login
    end
  end

  describe "POSITIVE CONTROLS: what holds the notice off" do
    test "a reply inside the window: no notice, and the host is never asked", ctx do
      %{agent: agent, space: space, agent_p: agent_p} = ctx
      _ = delivered!(ctx, "reply with the word PONG")

      {:ok, _reply} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: agent_p.id,
          content_type: "text",
          content: "PONG"
        })

      agent_id = agent.id
      refute_push "agent.check_auth", %{"agent_id" => ^agent_id}, @window_ms * 4
      assert notices(space) == []
      assert Watchdog.watches() == []
    end

    test "turn activity holds it off; when the activity stops, the notice comes", ctx do
      %{channel: channel, agent: agent, space: space} = ctx
      _ = delivered!(ctx, "a long job")
      agent_id = agent.id

      # Activity every third of a window for four windows.
      for _ <- 1..12 do
        :ok = Watchdog.activity(agent.id)
        Process.sleep(div(@window_ms, 3))
      end

      refute_push "agent.check_auth", %{"agent_id" => ^agent_id}, 0
      assert notices(space) == []
      assert [_watch] = Watchdog.watches()

      answer_auth!(channel, agent, "ok")
      [notice] = assert_eventually(fn -> notices(space) |> then(&(&1 != [] && &1)) end)
      assert notice.metadata["cause"] == "unknown"
    end

    test "turn activity never holds it off past the cap", ctx do
      Application.put_env(:platform, :native_reply_watchdog_max_ms, @window_ms * 2)
      %{channel: channel, agent: agent, space: space} = ctx
      _ = delivered!(ctx, "busy forever")

      task =
        Task.async(fn ->
          for _ <- 1..30 do
            Watchdog.activity(agent.id)
            Process.sleep(div(@window_ms, 3))
          end
        end)

      answer_auth!(channel, agent, "unknown")
      [_notice] = assert_eventually(fn -> notices(space) |> then(&(&1 != [] && &1)) end)
      Task.shutdown(task, :brutal_kill)
    end
  end

  describe "what is never watched" do
    test "a federated agent", ctx do
      %{space: space, user: user} = ctx
      agent = %Agent{id: Ecto.UUID.generate(), runtime_id: nil, name: "Fed"}

      {:ok, message} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: user.id,
          content_type: "text",
          content: "hi"
        })

      assert Watchdog.arm(%{agent: agent, message: message}) == :ignored
      assert Watchdog.watches() == []
      # Positive control for the discriminator, without arming a watch that
      # would fire after this test: the native agent is managed, this one not.
      assert NativeAgents.managed?(ctx.agent)
      refute NativeAgents.managed?(agent)
    end

    test "anything, while the watchdog is off", ctx do
      Application.put_env(:platform, :native_reply_watchdog_ms, false)
      _ = delivered!(ctx, "hello")
      assert Watchdog.watches() == []
      # The delivery is still remembered for the host-observed path.
      assert %{message_id: _} = Dedupe.take_pending(ctx.agent.id)
    end
  end

  describe "decide/4" do
    test "no activity is a verdict; activity waits a window from it, never past the cap" do
      entry = %{armed_at: 0, activity_at: nil}
      assert Watchdog.decide(entry, 100, 100, 1_000) == :verdict
      assert Watchdog.decide(%{entry | activity_at: 80}, 100, 100, 1_000) == {:wait, 80}
      assert Watchdog.decide(%{entry | activity_at: 950}, 1_000, 100, 1_000) == :verdict
      assert Watchdog.decide(%{entry | activity_at: 950}, 990, 100, 1_000) == {:wait, 10}
    end
  end

  describe "Dedupe.claim/4: one notice per message, atomically" do
    test "with a zero agent window, a second claim for the same message is a duplicate" do
      agent_id = Ecto.UUID.generate()
      assert Dedupe.claim(agent_id, "m1", 0, 10) == :ok
      assert Dedupe.claim(agent_id, "m1", 0, 11) == :duplicate
      # Positive control: another message of the same agent is not.
      assert Dedupe.claim(agent_id, "m2", 0, 12) == :ok
    end
  end

  defp from_agent(%Agent{id: agent_id}, space) do
    import Ecto.Query, only: [from: 2]
    from(m in Message, where: m.space_id == ^space.id and m.author_agent_id == ^agent_id)
  end
end
