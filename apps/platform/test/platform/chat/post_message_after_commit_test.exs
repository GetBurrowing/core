defmodule Platform.Chat.PostMessageAfterCommitTest do
  @moduledoc """
  `Chat.post_message/2` publishes (message_posted telemetry, the
  `{:new_message, _}` broadcast, link unfurls) through
  `Platform.Tasks.PostCommit.run_after_commit/2` (task 01a1eab6 stage 1).

  Inside a `PostCommit.scope/1` the publish waits for the outermost commit
  and is dropped on rollback. With no scope open it runs at once, as before.

  This module runs INSIDE the SQL sandbox, so it can only check ordering
  against the scope. Whether another connection can see the row when the
  telemetry fires is invisible here: the sandbox shares one connection.
  `Platform.Chat.PostMessageAfterCommitUnboxedTest` below covers that.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Tasks.PostCommit

  setup do
    {:ok, space} =
      Chat.create_space(%{
        name: "After commit",
        slug: "after-commit-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Avery",
        joined_at: DateTime.utc_now()
      })

    :ok = ChatPubSub.subscribe(space.id)

    test_pid = self()
    space_id = space.id
    handler_id = "post-message-after-commit-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :chat, :message_posted],
        fn _event, _measurements, %{space_id: ^space_id} = meta, _ ->
          send(test_pid, {:message_posted_telemetry, meta.message_id})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    %{space: space, participant: participant}
  end

  defp post!(space, participant, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    message
  end

  test "inside a scope the publish waits for the commit; a rollback publishes nothing; no scope publishes at once",
       %{space: space, participant: participant} do
    # 1. Scoped and committed: nothing while the transaction is open,
    #    exactly one broadcast and one telemetry event after it commits.
    assert {:ok, %{id: committed_id}} =
             PostCommit.scope(fn ->
               Repo.transaction(fn ->
                 message = post!(space, participant, "scoped and committed")
                 refute_received {:new_message, _}
                 refute_received {:message_posted_telemetry, _}
                 message
               end)
             end)

    assert_received {:new_message, %{id: ^committed_id}}
    assert_received {:message_posted_telemetry, ^committed_id}
    refute_received {:new_message, _}
    refute_received {:message_posted_telemetry, _}

    # 2. Scoped and rolled back: the message never existed, so nothing is
    #    published.
    assert {:error, :rolled_back} =
             PostCommit.scope(fn ->
               Repo.transaction(fn ->
                 _message = post!(space, participant, "scoped and rolled back")
                 Repo.rollback(:rolled_back)
               end)
             end)

    refute_received {:new_message, _}
    refute_received {:message_posted_telemetry, _}

    # 3. No scope (regression guard): published before post_message returns.
    %{id: plain_id} = post!(space, participant, "no scope")
    assert_received {:new_message, %{id: ^plain_id}}
    assert_received {:message_posted_telemetry, ^plain_id}
  end
end

defmodule Platform.Chat.PostMessageAfterCommitUnboxedTest do
  @moduledoc """
  The race task 01a1eab6 stage 1 fixes, OUT OF THE SANDBOX with the REAL
  `Platform.Chat.AttentionRouter`.

  The router reacts to `[:platform, :chat, :message_posted]` by sending
  itself a message, then reads the row with `Repo.get/2` on ITS OWN
  connection. If the telemetry fires before the poster's transaction
  commits, that read misses and the router logs
  `[AttentionRouter] message not found: <id>`, so the message is never
  routed. The shared SQL sandbox hides this, so this module puts the pool in
  `:auto` mode (the `Platform.Calendar.BookingConcurrencyTest` pattern):
  every process gets its own real connection and really commits, and every
  committed row is deleted in `on_exit`.

  The race is made deterministic, not timing-dependent: INSIDE the
  transaction the test makes a synchronous `:__drain__` call to the router.
  The router handles its mailbox in order, so the drain returns only after
  it has processed any telemetry message sent before it, while the row is
  still uncommitted.

  Observable for "the router routed it": the router's own
  `[:platform, :chat, :attention_routed]` telemetry, which it emits per
  decision in `do_route/2`, with `reason: :directed` for the DM's agent.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{AttentionRouter, Message, Participant, Space}
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo
  alias Platform.Tasks.PostCommit

  setup do
    Sandbox.mode(Repo, :auto)

    previous_mode = Application.get_env(:platform, :chat_agent_dispatch_mode)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "after-commit-user-#{n}@example.com",
        name: "After Commit User",
        oidc_sub: "oidc-after-commit-user-#{n}"
      })

    owner =
      Repo.insert!(%User{
        email: "after-commit-owner-#{n}@example.com",
        name: "After Commit Owner",
        oidc_sub: "oidc-after-commit-owner-#{n}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "rt-after-commit-#{n}",
        display_name: "after-commit-rt"
      })

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "after-commit-agent-#{n}",
        name: "After Commit Agent",
        status: "active",
        max_concurrent: 1,
        sandbox_mode: "off",
        runtime_type: "external",
        runtime_id: runtime.id,
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })
      |> Repo.insert!()

    {:ok, dm} = Chat.find_or_create_dm(user.id, "agent", agent.id)

    on_exit(fn ->
      # Runs after start_supervised children (the router) have stopped, and
      # still in :auto mode, so these deletes commit on a real connection.
      Repo.delete_all(from(m in Message, where: m.space_id == ^dm.id))
      Repo.delete_all(from(p in Participant, where: p.space_id == ^dm.id))
      Repo.delete_all(from(s in Space, where: s.id == ^dm.id))
      Repo.delete_all(from(a in Agent, where: a.id == ^agent.id))
      Repo.delete_all(from(r in AgentRuntime, where: r.id == ^runtime.id))
      Repo.delete_all(from(u in User, where: u.id in ^[user.id, owner.id]))

      if previous_mode,
        do: Application.put_env(:platform, :chat_agent_dispatch_mode, previous_mode),
        else: Application.delete_env(:platform, :chat_agent_dispatch_mode)

      Sandbox.mode(Repo, :manual)
    end)

    # An ONLINE runtime, so the router's synchronous dispatch is a broadcast
    # to the runtime topic rather than a failure notice posted into the DM.
    _presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
    RuntimePresence.track(runtime.runtime_id)
    on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)

    refute Process.whereis(AttentionRouter),
           "expected no AttentionRouter running in test (config :start_attention_router)"

    router = start_supervised!({AttentionRouter, []})

    test_pid = self()
    handler_id = "after-commit-unboxed-#{n}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:platform, :chat, :attention_routed],
        fn _event, _measurements, meta, _ -> send(test_pid, {:attention_routed, meta}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    user_p =
      Repo.get_by!(Participant, space_id: dm.id, participant_type: "user", participant_id: user.id)

    agent_p =
      Repo.get_by!(Participant,
        space_id: dm.id,
        participant_type: "agent",
        participant_id: agent.id
      )

    %{dm: dm, user_p: user_p, agent_p: agent_p, router: router}
  end

  defp drain(router), do: :ok = GenServer.call(router, :__drain__, 10_000)

  # Posts as the user inside an outer transaction, then drains the router
  # BEFORE the transaction commits. Returns the committed message.
  defp post_in_transaction(dm, user_p, router, content) do
    {:ok, message} =
      Repo.transaction(fn ->
        {:ok, message} =
          Chat.post_message(%{
            space_id: dm.id,
            participant_id: user_p.id,
            content_type: "text",
            content: content
          })

        drain(router)
        message
      end)

    drain(router)
    message
  end

  test "a post inside PostCommit.scope is routed after the commit and never 'not found'",
       %{dm: dm, user_p: user_p, agent_p: agent_p, router: router} do
    {message_id, log} =
      with_log(fn ->
        {:ok, message} =
          PostCommit.scope(fn ->
            {:ok, post_in_transaction(dm, user_p, router, "scoped goal message")}
          end)

        # The scope flushes after its function returns; drain once more so
        # the router has handled the deferred telemetry.
        drain(router)
        message.id
      end)

    agent_p_id = agent_p.id

    assert_received {:attention_routed,
                     %{message_id: ^message_id, recipient_id: ^agent_p_id, reason: :directed}}

    refute log =~ "message not found: #{message_id}"
  end

  test "POSITIVE CONTROL: the same post WITHOUT a scope races the commit and is 'not found'",
       %{dm: dm, user_p: user_p, router: router} do
    {message_id, log} =
      with_log(fn ->
        post_in_transaction(dm, user_p, router, "unscoped goal message").id
      end)

    # The row did commit, so the miss is the race, not a lost write.
    assert Repo.get(Message, message_id)
    assert log =~ "[AttentionRouter] message not found: #{message_id}"
    refute_received {:attention_routed, %{message_id: ^message_id}}
  end
end
