defmodule Platform.Chat.ReplyFailureTest do
  @moduledoc """
  The visible reply-failure notice (task 01a10322 stage 1).

  Driven end to end: a user message mentions an agent, `AttentionRouter`
  routes it, `AgentResponder` fails, and `ReplyFailure` posts the notice. The
  notice must then route NOWHERE, which is pinned against the case that would
  otherwise catch it: the mention just armed the failed agent as the space's
  active agent, so an ordinary un-addressed system message IS routed back to
  it (the positive control below).
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, ReplyFailure}
  alias Platform.Federation.RuntimePresence
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo

  defmodule CodexAuthMissingChat do
    def chat(_message, _opts), do: {:error, {:codex_auth_missing, "no codex auth on this host"}}
  end

  setup do
    previous_module = Application.get_env(:platform, :chat_agent_module)
    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    previous_window = Application.get_env(:platform, :reply_failure_notice_dedupe_s)

    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      restore(:chat_agent_module, previous_module)
      restore(:chat_agent_dispatch_mode, previous_mode)
      restore(:reply_failure_notice_dedupe_s, previous_window)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    Sandbox.allow(Repo, self(), presence)

    test_pid = self()
    handler_id = "reply-failure-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :chat, :attention_routed],
        fn _event, _measurements, meta, _ -> send(test_pid, {:routed, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)

  defp create_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "reply-failure-#{n}@example.com",
      name: "Reply Failure #{n}",
      oidc_sub: "oidc-reply-failure-#{n}"
    })
  end

  defp channel_with_user do
    {:ok, space} =
      Chat.create_space(%{
        name: "Reply failure",
        slug: "reply-failure-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, user} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Alice",
        joined_at: DateTime.utc_now()
      })

    {space, user}
  end

  defp seat_agent(space, %Agent{} = agent) do
    {:ok, _} = Chat.ensure_space_agent(space.id, agent.id, role: "member")
    {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: agent.name)
    participant
  end

  defp say(space, user, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: user.id,
        content_type: "text",
        content: content
      })

    # Flush the router's own telemetry-driven routing of this message.
    :ok = GenServer.call(AttentionRouter, :__drain__)
    message
  end

  defp notices(space) do
    space.id
    |> Chat.list_messages(limit: 100)
    |> Enum.filter(&ReplyFailure.notice?/1)
  end

  describe "an offline native agent" do
    test "gets exactly one 'stopped' notice, and the notice routes nowhere" do
      {space, user} = channel_with_user()

      {:ok, ada, _rt} =
        NativeAgents.create(create_user().id, %{name: "Ada", harness: "claude_code"})

      ada_participant = seat_agent(space, ada)

      message = say(space, user, "@ada are you there?")

      # The explicit route repeats what the router's telemetry path already
      # did; the notice is still posted once.
      assert {:ok, [%{reason: :mention}]} = AttentionRouter.route(message)
      :ok = GenServer.call(AttentionRouter, :__drain__)

      assert [%Message{} = notice] = notices(space)
      assert notice.content_type == "system"

      assert notice.content ==
               "Ada couldn't reply to this message.\nAda is stopped."

      assert notice.metadata == %{
               "kind" => "reply_failure",
               "agent_id" => ada.id,
               "message_id" => message.id,
               "cause" => "stopped"
             }

      # Not routed: neither by the router's telemetry path nor on demand.
      notice_id = notice.id
      refute_received {:routed, %{message_id: ^notice_id}}
      assert {:ok, []} = AttentionRouter.route(notice)
      refute_received {:routed, %{message_id: ^notice_id}}

      # POSITIVE CONTROL: the mention armed Ada as the active agent, so an
      # ordinary un-addressed system message in the same space IS routed to
      # her. That is exactly what the notice would get without the exit.
      {:ok, system} = ExecutionSpace.ensure_system_participant(space.id)

      {:ok, plain} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: system.id,
          content_type: "system",
          content: "an ordinary system line"
        })

      ada_pid = ada_participant.id

      assert {:ok, [%{participant_id: ^ada_pid, reason: :active_agent}]} =
               AttentionRouter.route(plain)
    end

    test "a repeat inside the window still gives one notice" do
      {space, user} = channel_with_user()

      {:ok, ada, _rt} =
        NativeAgents.create(create_user().id, %{name: "Ada", harness: "claude_code"})

      seat_agent(space, ada)

      first = say(space, user, "@ada one")
      _second = say(space, user, "@ada two")
      # The same message dispatched again is also one notice.
      AttentionRouter.route(first)
      :ok = GenServer.call(AttentionRouter, :__drain__)

      assert [_one] = notices(space)
    end

    test "POSITIVE CONTROL: with a zero window, a second message gets its own notice" do
      Application.put_env(:platform, :reply_failure_notice_dedupe_s, 0)

      {space, user} = channel_with_user()

      {:ok, ada, _rt} =
        NativeAgents.create(create_user().id, %{name: "Ada", harness: "claude_code"})

      seat_agent(space, ada)

      first = say(space, user, "@ada one")
      _second = say(space, user, "@ada two")
      # Per (agent, message) still holds with no window.
      AttentionRouter.route(first)
      :ok = GenServer.call(AttentionRouter, :__drain__)

      assert length(notices(space)) == 2
    end

    test "an install-managed agent that should be running reads as unknown, not stopped" do
      {space, user} = channel_with_user()

      {:ok, ada, _rt} =
        NativeAgents.create(create_user().id, %{name: "Ada", harness: "claude_code"})

      {:ok, _} = NativeAgents.set_desired_state(ada, "running")
      seat_agent(space, ada)

      _ = say(space, user, "@ada hello")

      assert [%Message{metadata: %{"cause" => "unknown"}} = notice] = notices(space)
      assert notice.content =~ "Something went wrong before Ada could reply."
    end
  end

  describe "a system-event space" do
    test "gets no notice: nobody there is waiting for the reply" do
      Application.put_env(:platform, :chat_agent_module, CodexAuthMissingChat)

      {:ok, space} =
        Chat.create_space(%{
          name: "Quick — System Events",
          slug: "system-quick-#{System.unique_integer([:positive])}",
          kind: "system"
        })

      {:ok, quick} =
        %Agent{}
        |> Agent.changeset(%{
          slug: "quick-#{System.unique_integer([:positive])}",
          name: "Quick",
          status: "active"
        })
        |> Repo.insert()

      {:ok, _} = Chat.add_agent_participant(space.id, quick, display_name: "Quick")
      {:ok, system} = ExecutionSpace.ensure_system_participant(space.id)

      {:ok, dispatch} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: system.id,
          content_type: "text",
          content: "curate this"
        })

      context = %{agent: quick, message: dispatch}
      assert ReplyFailure.notify(context, {:codex_auth_missing, "x"}) == :skipped
      assert notices(space) == []
    end
  end

  describe "a built_in agent" do
    test "{:codex_auth_missing, _} gives the unknown cause and no further respond" do
      Application.put_env(:platform, :chat_agent_module, CodexAuthMissingChat)

      {space, user} = channel_with_user()

      {:ok, quick} =
        %Agent{}
        |> Agent.changeset(%{
          slug: "quick-#{System.unique_integer([:positive])}",
          name: "Quick",
          status: "active"
        })
        |> Repo.insert()

      assert quick.runtime_type == "built_in"
      seat_agent(space, quick)

      message = say(space, user, "@quick help")

      assert [notice] = notices(space)
      assert notice.metadata["cause"] == "unknown"
      assert notice.metadata["message_id"] == message.id

      assert notice.content ==
               "Quick couldn't reply to this message.\nSomething went wrong before Quick could reply."

      notice_id = notice.id
      refute_received {:routed, %{message_id: ^notice_id}}
    end
  end

  describe "copy" do
    test "line 2 matches the design canvas for every cause" do
      assert ReplyFailure.headline("Ada") == "Ada couldn't reply to this message."
      assert ReplyFailure.cause_line(:needs_login, "Ada") == "Ada's Claude login has expired."
      assert ReplyFailure.cause_line(:stopped, "Ada") == "Ada is stopped."

      assert ReplyFailure.cause_line(:crashed, "Ada") ==
               "Ada stopped unexpectedly while replying."

      assert ReplyFailure.cause_line(:unknown, "Ada") ==
               "Something went wrong before Ada could reply."
    end
  end
end
