defmodule Platform.Chat.ReplyFailureOfflineBroadcastTest do
  @moduledoc """
  The incident path, end to end (task 01a215fb stage 3).

  A person posts in a channel naming several external agents whose runtimes
  are offline. `AttentionRouter` routes each as `:multi_mention`,
  `AgentResponder` (sync dispatch) finds the runtime offline and
  `DeliveryQueue.hold/3` holds the message; the queue's TTL runs out and
  `ReplyFailure.undelivered/1` posts the notice. Two such posts used to give
  one notice per agent per post, each reading "Something went wrong before
  <Name> could reply."

  Pinned here:

    * the first post gives one notice per agent, "<Name> is offline." for an
      external agent and "<Name> is stopped." for an install-managed one;
    * a second post naming the same agents gives no new notice;
    * a lone mention of one of them is still told;
    * no notice routes anywhere.

  The 300 s per-agent window is set to 0 (the incident's posts were nine
  minutes apart, past it), so only the once-a-day standing rule can hold the
  second batch back.
  """
  use Platform.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents}
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, ReplyFailure}
  alias Platform.Federation
  alias Platform.Federation.{DeliveryQueue, RuntimePresence}
  alias Platform.Repo

  setup do
    keys = [
      :chat_agent_dispatch_mode,
      :delivery_queue_enabled,
      :delivery_queue_ttl_ms,
      :reply_failure_notice_dedupe_s,
      :reply_failure_standing_notice_s
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:platform, &1)})

    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :delivery_queue_enabled, true)
    Application.put_env(:platform, :delivery_queue_ttl_ms, 200)
    Application.put_env(:platform, :reply_failure_notice_dedupe_s, 0)
    Application.delete_env(:platform, :reply_failure_standing_notice_s)

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

    :ok
  end

  defp create_user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "rf-broadcast-#{n}@example.com",
      name: "RF Broadcast #{n}",
      oidc_sub: "oidc-rf-broadcast-#{n}"
    })
  end

  defp channel_with_user do
    {:ok, space} =
      Chat.create_space(%{
        name: "Offline broadcast",
        slug: "rf-broadcast-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, user} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Poster",
        joined_at: DateTime.utc_now()
      })

    {space, user}
  end

  # An external agent: a federated runtime (managed_by nil, the schema's
  # default desired_state "stopped") that is not connected.
  defp external_agent(name) do
    n = System.unique_integer([:positive])

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: create_user().id,
        status: "active",
        runtime_id: "rf-broadcast-#{n}",
        display_name: "#{name} runtime"
      })

    {:ok, agent} =
      Federation.link_agent(runtime, %{
        slug: "#{String.downcase(name)}-#{n}",
        name: name,
        status: "active"
      })

    runtime = Repo.get!(AgentRuntime, runtime.id)
    assert runtime.managed_by == nil
    assert runtime.desired_state == "stopped"
    refute RuntimePresence.online?(runtime.runtime_id)
    {agent, runtime}
  end

  defp seat(space, %Agent{} = agent) do
    {:ok, _} = Chat.ensure_space_agent(space.id, agent.id, role: "member")
    {:ok, _} = Chat.add_agent_participant(space.id, agent, display_name: agent.name)
    :ok
  end

  defp post!(space, user, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: user.id,
        content_type: "text",
        content: content
      })

    :ok = GenServer.call(AttentionRouter, :__drain__)
    message
  end

  defp notices(space) do
    space.id
    |> Chat.list_messages(limit: 100)
    |> Enum.filter(&ReplyFailure.notice?/1)
  end

  # Every held entry for these runtimes has expired, and the notice tasks
  # the expiry started have had time to post.
  defp settle!(runtime_ids) do
    assert_eventually(fn ->
      not Enum.any?(DeliveryQueue.entries(), &(&1.runtime_id in runtime_ids))
    end)

    Process.sleep(500)
  end

  test "a broadcast to parked agents: one notice each, once; a lone mention still told" do
    {space, user} = channel_with_user()

    externals = for name <- ["Bea", "Cyd", "Dov"], do: external_agent(name)

    {:ok, ada, ada_runtime} =
      NativeAgents.create(create_user().id, %{name: "Ada", harness: "claude_code"})

    assert ada_runtime.managed_by == "install"
    assert ada_runtime.desired_state == "stopped"

    agents = Enum.map(externals, &elem(&1, 0)) ++ [ada]
    runtime_ids = Enum.map(externals, &elem(&1, 1).runtime_id) ++ [ada_runtime.runtime_id]
    Enum.each(agents, &seat(space, &1))

    # (1) The first post: one notice per agent.
    first = post!(space, user, "@Bea @Cyd @Dov @Ada standup in five?")
    settle!(runtime_ids)

    batch = notices(space)
    assert length(batch) == 4
    assert Enum.all?(batch, &(&1.metadata["message_id"] == first.id))
    by_agent = Map.new(batch, &{&1.metadata["agent_id"], &1})

    for {agent, _runtime} <- externals do
      notice = Map.fetch!(by_agent, agent.id)
      assert notice.metadata["cause"] == "offline"

      assert notice.content ==
               "#{agent.name} couldn't reply to this message.\n#{agent.name} is offline."
    end

    # (5) The install-managed agent told to stop reads as stopped.
    ada_notice = Map.fetch!(by_agent, ada.id)
    assert ada_notice.metadata["cause"] == "stopped"
    assert ada_notice.content == "Ada couldn't reply to this message.\nAda is stopped."

    refute Enum.any?(batch, &(&1.content =~ "Something went wrong"))

    # (2) A second post naming the same agents: nothing new (8 would be the bug).
    _second = post!(space, user, "@Bea @Cyd @Dov @Ada standup, anyone?")
    settle!(runtime_ids)
    assert length(notices(space)) == 4

    # (3) A lone mention of one of them is still told.
    [{bea, bea_runtime} | _] = externals
    lone = post!(space, user, "@Bea just you, please")
    settle!([bea_runtime.runtime_id])

    all = notices(space)
    assert length(all) == 5
    assert [%Message{} = told] = Enum.filter(all, &(&1.metadata["message_id"] == lone.id))
    assert told.metadata["agent_id"] == bea.id
    assert told.metadata["cause"] == "offline"

    # (4) No notice routes anywhere.
    for notice <- all do
      assert {:ok, []} = AttentionRouter.route(notice)
    end
  end
end
