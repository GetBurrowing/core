defmodule Platform.Chat.MessageAttentionTest do
  @moduledoc """
  Task 01a1557a-a30a stage 1 (Burrow redesign rung 12): "Get someone's
  attention" on an already-sent message, server side.

  `Chat.add_message_attention/4` writes `chat_message_attentions` rows and
  never touches the message row or its versions; `AttentionRouter.route_attention/3`
  routes the newly added through the same machinery as a posted mention.

  Every refusal has a positive control on the same space and message, so a
  writer that refused everything could not pass.
  """
  use Platform.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, MessageAttention}
  alias Platform.Chat.{MessageVersions, Participant}
  alias Platform.Federation.RuntimePresence
  alias Platform.Inbox.Item
  alias Platform.Repo

  defmodule StubAgentChat do
    def chat(message, opts) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "on it", model: "stub", usage: %{}}}
    end
  end

  setup do
    previous =
      for key <- [:chat_agent_module, :chat_agent_dispatch_mode, :chat_agent_test_pid],
          do: {key, Application.get_env(:platform, key)}

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:platform, key, value) end)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)

    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  defp user!(name) do
    n = System.unique_integer([:positive])

    %User{}
    |> User.changeset(%{
      email: "attn-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-attn-#{n}"
    })
    |> Repo.insert!()
  end

  defp channel!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "General #{n}", slug: "attn-#{n}", kind: "channel"}, attrs)
      )

    space
  end

  defp member!(space, %User{} = user, attrs \\ %{}) do
    {:ok, p} =
      Chat.add_participant(
        space.id,
        Map.merge(
          %{
            participant_type: "user",
            participant_id: user.id,
            display_name: user.name,
            joined_at: DateTime.utc_now()
          },
          attrs
        )
      )

    p
  end

  defp agent_record!(name, attrs \\ %{}) do
    %Agent{}
    |> Agent.changeset(
      Map.merge(
        %{
          slug: "attn-agent-#{System.unique_integer([:positive])}",
          name: name,
          status: "active",
          max_concurrent: 1,
          sandbox_mode: "off",
          model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp agent!(space, name) do
    agent = agent_record!(name)
    {:ok, participant} = Chat.add_agent_participant(space.id, agent, display_name: name)
    {agent, participant}
  end

  defp post!(space, %Participant{} = author, content) do
    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: author.id,
        content_type: "text",
        content: content
      })

    drain()
    flush_mailbox()
    message
  end

  defp drain, do: :ok = GenServer.call(AttentionRouter, :__drain__)

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp actor(%Participant{participant_id: user_id}), do: {:user, user_id}

  defp rows(message_id),
    do: Repo.all(from(a in MessageAttention, where: a.message_id == ^message_id))

  defp inbox_rows(user_id),
    do: Repo.all(from(i in Item, where: i.user_id == ^user_id and i.kind == "chat_mention"))

  defp raw_message(id) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT content, edited_at, metadata::text FROM chat_messages WHERE id = $1",
        [Ecto.UUID.dump!(id)]
      )

    row
  end

  defp with_info_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :info)

    try do
      ExUnit.CaptureLog.capture_log([level: :info], fun)
    after
      Logger.configure(level: previous)
    end
  end

  defp with_debug_log(fun) do
    previous = Logger.level()
    Logger.configure(level: :debug)

    try do
      ExUnit.CaptureLog.capture_log([level: :debug], fun)
    after
      Logger.configure(level: previous)
    end
  end

  # Existing synchronous assertions must wait for this test's unlinked worker.
  defp add_attention_and_settle(actor, space_id, message_id, ids) do
    result = Chat.add_message_attention(actor, space_id, message_id, ids)
    assert :ok = Platform.SandboxHelpers.await_own_supervised_writes(self())
    result
  end

  describe "post-commit routing isolation" do
    test "slow routing does not block persistence, human inbox or broadcast and dispatches once" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      bob_user = user!("Bob")
      bob = member!(space, bob_user)
      {_agent, zip} = agent!(space, "Zip")
      message = post!(space, alice, "slow router")
      :ok = Chat.PubSub.subscribe(space.id)
      router = Process.whereis(AttentionRouter)
      :ok = :sys.suspend(router)

      try do
        started = System.monotonic_time(:millisecond)

        assert {:ok, %{added: [_, _]}} =
                 Chat.add_message_attention(actor(alice), space.id, message.id, [
                   zip.participant_id,
                   bob.participant_id
                 ])

        assert System.monotonic_time(:millisecond) - started < 1_000
        assert length(rows(message.id)) == 2
        assert length(inbox_rows(bob_user.id)) == 1
        assert_receive {:message_attention_changed, %Message{id: id}}
        assert id == message.id
        refute_receive {:attention_needed, _}, 5_100
        :ok = :sys.resume(router)
        assert :ok = Platform.SandboxHelpers.await_own_supervised_writes(self())
        zip_id = zip.id
        message_id = message.id
        assert_receive {:attention_needed, %{participant_id: ^zip_id, message_id: ^message_id}}

        refute_receive {:attention_needed, %{participant_id: ^zip_id, message_id: ^message_id}},
                       100
      after
        :sys.resume(router)
      end
    end

    test "router exit is logged without killing the caller or losing independent side effects" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {_agent, zip} = agent!(space, "Zip")
      message = post!(space, alice, "router exit")
      :ok = Chat.PubSub.subscribe(space.id)
      router = Process.whereis(AttentionRouter)
      :ok = :sys.suspend(router)

      log =
        with_info_log(fn ->
          try do
            assert {:ok, %{added: [_]}} =
                     Chat.add_message_attention(actor(alice), space.id, message.id, [
                       zip.participant_id
                     ])

            assert_eventually(fn ->
              {:messages, messages} = Process.info(router, :messages)
              Enum.any?(messages, &match?({:"$gen_call", _, {:route_attention, _, _}}, &1))
            end)

            :ok = :sys.terminate(router, :normal)
            assert :ok = Platform.SandboxHelpers.await_own_supervised_writes(self())
            assert [%MessageAttention{}] = rows(message.id)
            assert_receive {:message_attention_changed, _}
          after
            if Process.alive?(router), do: :sys.resume(router)
          end
        end)

      assert log =~ "add_message_attention routing worker failed"
      assert log =~ "message=#{message.id} space=#{space.id} recipients=#{zip.id}"
      assert log =~ "phase=failure"
      assert log =~ "kind=exit category=:exit cause=normal"
      assert log =~ "phase=handoff message=#{message.id}"
      assert log =~ "outcome=accepted"
      refute log =~ "router exit"
    end
  end

  # ── Own message ────────────────────────────────────────────────────────────

  describe "adding attention to your own message" do
    test "routes :mention to the added agent and never touches the message row" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {_agent, zip} = agent!(space, "Zip")
      message = post!(space, alice, "can someone look at the tab bar spacing?")
      before = raw_message(message.id)
      assert MessageVersions.count_versions(message.id) == 1

      :ok = Chat.PubSub.subscribe(space.id)
      message_id = message.id
      zip_id = zip.id

      log =
        with_debug_log(fn ->
          assert {:ok, %{added: [row], unchanged: [], refused: []}} =
                   add_attention_and_settle(actor(alice), space.id, message.id, [
                     zip.participant_id
                   ])

          assert row.participant_id == zip.id
          assert row.added_by_participant_id == alice.id
        end)

      assert_receive {:attention_needed,
                      %{participant_id: ^zip_id, reason: :mention, message_id: ^message_id}}

      assert_receive {:message_attention_changed,
                      %Message{id: ^message_id, attention: [%{participant_id: ^zip_id}]}}

      refute_received {:message_updated, _}

      assert log =~
               "[AttentionRouter] agent_route space=#{space.id} message=#{message.id} " <>
                 "policy=on_mention awake=true decisions=#{zip.id}:mention silenced_skipped= reply_target=\n"

      # R6: content, edited_at and metadata byte-identical; still one version.
      assert raw_message(message.id) == before
      assert MessageVersions.count_versions(message.id) == 1
      assert [%{edited_at: nil}] = Repo.all(from(m in Message, where: m.id == ^message.id))

      # Awake and not silenced: the single added agent arms the mutex.
      assert ActiveAgentStore.get_active(space.id) == zip.id

      # D3: the built-in agent is told who asked it to look.
      assert_receive {:agent_chat_called, body, _opts}
      assert body == "(Alice asked you to look at this message.)\n\n" <> message.content

      assert [%{participant_id: ^zip_id, added_by_display_name: "Alice"}] =
               Chat.list_message_attention(message.id)
    end

    test "several added agents are :multi_mention and clear the mutex" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {_a, zip} = agent!(space, "Zip")
      {_b, nova} = agent!(space, "Nova")
      {_c, holder} = agent!(space, "Holder")
      message = post!(space, alice, "two opinions please")
      ActiveAgentStore.set_active(space.id, holder.id)
      :ok = Chat.PubSub.subscribe(space.id)

      assert {:ok, %{added: [_, _]}} =
               add_attention_and_settle(actor(alice), space.id, message.id, [
                 zip.participant_id,
                 nova.participant_id
               ])

      zip_id = zip.id
      nova_id = nova.id
      assert_receive {:attention_needed, %{participant_id: ^zip_id, reason: :multi_mention}}
      assert_receive {:attention_needed, %{participant_id: ^nova_id, reason: :multi_mention}}
      assert ActiveAgentStore.get_active(space.id) == nil
    end
  end

  describe "adding attention to another member's message (D1)" do
    test "is allowed and records the actor as the adder" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      bob = member!(space, user!("Bob"))
      {_agent, zip} = agent!(space, "Zip")
      message = post!(space, alice, "the build is red")

      assert {:ok, %{added: [_]}} =
               add_attention_and_settle(actor(bob), space.id, message.id, [zip.participant_id])

      assert [row] = rows(message.id)
      assert row.added_by_participant_id == bob.id
      assert row.added_by_display_name == "Bob"
      assert row.display_name == "Zip"
      assert row.participant_type == "agent"
    end
  end

  # ── Refusals ───────────────────────────────────────────────────────────────

  describe "refusals" do
    setup do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {agent, zip} = agent!(space, "Zip")
      message = post!(space, alice, "please look")
      %{space: space, alice: alice, agent: agent, zip: zip, message: message}
    end

    test "a non-member, a nil actor and an agent actor are :forbidden", ctx do
      ids = [ctx.zip.participant_id]

      assert {:error, :forbidden} =
               add_attention_and_settle(
                 {:user, Ecto.UUID.generate()},
                 ctx.space.id,
                 ctx.message.id,
                 ids
               )

      assert {:error, :forbidden} =
               add_attention_and_settle(nil, ctx.space.id, ctx.message.id, ids)

      assert {:error, :forbidden} =
               add_attention_and_settle(
                 {:agent, ctx.agent.id},
                 ctx.space.id,
                 ctx.message.id,
                 ids
               )

      assert rows(ctx.message.id) == []

      # POSITIVE CONTROL: same space, message and principal, a member.
      assert {:ok, %{added: [_]}} =
               add_attention_and_settle(actor(ctx.alice), ctx.space.id, ctx.message.id, ids)
    end

    test "a member of ANOTHER space cannot add attention to this one's message", ctx do
      other = channel!()
      mallory = member!(other, user!("Mallory"))

      assert {:error, :forbidden} =
               add_attention_and_settle(actor(mallory), ctx.space.id, ctx.message.id, [
                 ctx.zip.participant_id
               ])

      assert rows(ctx.message.id) == []
    end

    test "a message from another space is :not_found (forged event)", ctx do
      other = channel!()
      alice_there = member!(other, Repo.get!(User, ctx.alice.participant_id))
      foreign = post!(other, alice_there, "elsewhere")

      # The actor IS a member of both spaces; only the space/message pairing is forged.
      assert {:error, :not_found} =
               add_attention_and_settle(actor(ctx.alice), ctx.space.id, foreign.id, [
                 ctx.zip.participant_id
               ])

      assert rows(foreign.id) == []

      assert {:ok, _} =
               add_attention_and_settle(actor(ctx.alice), ctx.space.id, ctx.message.id, [
                 ctx.zip.participant_id
               ])
    end

    test "a deleted or unknown message is :not_found", ctx do
      {:ok, _} = Chat.delete_message(ctx.message)

      assert {:error, :not_found} =
               add_attention_and_settle(actor(ctx.alice), ctx.space.id, ctx.message.id, [
                 ctx.zip.participant_id
               ])

      assert {:error, :not_found} =
               add_attention_and_settle(actor(ctx.alice), ctx.space.id, Ecto.UUID.generate(), [
                 ctx.zip.participant_id
               ])

      assert {:error, :not_found} =
               add_attention_and_settle(actor(ctx.alice), ctx.space.id, "not-a-uuid", [
                 ctx.zip.participant_id
               ])

      assert rows(ctx.message.id) == []
    end

    test "an archived space is :space_archived", ctx do
      {:ok, _} = Chat.archive_space(ctx.space)

      assert {:error, :space_archived} =
               add_attention_and_settle(actor(ctx.alice), ctx.space.id, ctx.message.id, [
                 ctx.zip.participant_id
               ])

      assert rows(ctx.message.id) == []
    end

    test "the author, the actor, @here and a stranger are dropped; nothing left is :invalid",
         ctx do
      bob = member!(ctx.space, user!("Bob"))
      stranger = Ecto.UUID.generate()

      # Alice is author AND actor.
      assert {:error, :invalid} =
               add_attention_and_settle(actor(ctx.alice), ctx.space.id, ctx.message.id, [
                 ctx.alice.participant_id,
                 "here",
                 stranger
               ])

      # Bob is actor; Alice is author.
      assert {:error, :invalid} =
               add_attention_and_settle(actor(bob), ctx.space.id, ctx.message.id, [
                 bob.participant_id,
                 ctx.alice.participant_id
               ])

      assert {:error, :invalid} =
               add_attention_and_settle(actor(bob), ctx.space.id, ctx.message.id, [])

      assert rows(ctx.message.id) == []

      # POSITIVE CONTROL: the dropped ids ride along with a real one.
      assert {:ok, %{added: [row]}} =
               add_attention_and_settle(actor(bob), ctx.space.id, ctx.message.id, [
                 bob.participant_id,
                 ctx.alice.participant_id,
                 "here",
                 ctx.zip.participant_id
               ])

      assert row.participant_id == ctx.zip.id
    end
  end

  # ── Idempotency ────────────────────────────────────────────────────────────

  describe "idempotency" do
    test "adding twice writes one row, routes once and notifies once" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      bob_user = user!("Bob")
      bob = member!(space, bob_user)
      {_agent, zip} = agent!(space, "Zip")
      message = post!(space, alice, "look here")
      :ok = Chat.PubSub.subscribe(space.id)
      ids = [zip.participant_id, bob.participant_id]

      assert {:ok, %{added: [_, _], unchanged: []}} =
               add_attention_and_settle(actor(alice), space.id, message.id, ids)

      zip_id = zip.id
      bob_id = bob.id
      assert_receive {:attention_needed, %{participant_id: ^zip_id, reason: :mention}}
      assert_receive {:attention_needed, %{participant_id: ^bob_id, reason: :mention}}
      assert_receive {:message_attention_changed, _}
      flush_mailbox()

      assert {:ok, %{added: [], unchanged: [_, _]}} =
               add_attention_and_settle(actor(alice), space.id, message.id, ids)

      refute_receive {:attention_needed, _}, 200
      refute_received {:message_attention_changed, _}
      refute_received {:agent_chat_called, _, _}

      assert length(rows(message.id)) == 2
      assert length(inbox_rows(bob_user.id)) == 1
    end
  end

  # ── Agent attention controls ───────────────────────────────────────────────

  describe "silenced agents and the master switch" do
    test "a silenced agent gets :mention, the mutex is not armed, and a follow-up reaches nobody" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {_agent, zip} = agent!(space, "Zip")
      {:ok, _} = Chat.set_agent_silenced(actor(alice), space.id, zip.id, true)
      message = post!(space, alice, "anyone?")
      :ok = Chat.PubSub.subscribe(space.id)

      assert {:ok, %{added: [_]}} =
               add_attention_and_settle(actor(alice), space.id, message.id, [zip.participant_id])

      zip_id = zip.id
      assert_receive {:attention_needed, %{participant_id: ^zip_id, reason: :mention}}
      assert ActiveAgentStore.get_active(space.id) == nil

      followup = post!(space, alice, "and a follow-up with no mention")
      assert {:ok, []} = AttentionRouter.route(followup)
    end

    test "agents_awake false: added attention still routes :mention and arms nobody" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {_agent, zip} = agent!(space, "Zip")
      {:ok, _} = Chat.set_agents_awake(actor(alice), space.id, false)
      message = post!(space, alice, "switch is off")
      :ok = Chat.PubSub.subscribe(space.id)

      assert {:ok, %{added: [_]}} =
               add_attention_and_settle(actor(alice), space.id, message.id, [zip.participant_id])

      zip_id = zip.id
      assert_receive {:attention_needed, %{participant_id: ^zip_id, reason: :mention}}
      assert ActiveAgentStore.get_active(space.id) == nil
    end
  end

  # ── Humans (D4) ────────────────────────────────────────────────────────────

  describe "adding a human" do
    test "one chat_mention Inbox row, a :mention decision whatever the mode, no agent dispatch" do
      space = channel!(%{name: "Design Crit"})
      alice = member!(space, user!("Alice"))
      bob_user = user!("Bob")
      bob = member!(space, bob_user, %{attention_mode: "heartbeat"})
      {_agent, _zip} = agent!(space, "Zip")
      message = post!(space, alice, "can someone look at the tab bar spacing?")
      :ok = Chat.PubSub.subscribe(space.id)

      assert {:ok, %{added: [row]}} =
               add_attention_and_settle(actor(alice), space.id, message.id, [bob_user.id])

      assert row.participant_type == "user"
      bob_id = bob.id
      assert_receive {:attention_needed, %{participant_id: ^bob_id, reason: :mention}}
      refute_receive {:agent_chat_called, _, _}, 200

      message_id = message.id

      assert [
               %Item{
                 kind: "chat_mention",
                 source_type: "chat_message",
                 source_id: ^message_id,
                 title: "@Mention from Alice in #Design Crit",
                 body: "can someone look at the tab bar spacing?",
                 url: url
               }
             ] = inbox_rows(bob_user.id)

      assert url == "/chat/#{Chat.space_path_segment(space)}?message=#{message.id}"
      assert raw_message(message.id) |> hd() == message.content
    end
  end

  # ── Summons (D5) ───────────────────────────────────────────────────────────

  describe "agents not in the space" do
    test "an ordinary member's summon is refused with no row; an admin's summons and routes" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      bob = member!(space, user!("Bob"), %{role: "member"})
      admin = member!(space, user!("Ada"), %{role: "admin"})
      outsider = agent_record!("Scout")
      message = post!(space, alice, "needs an outside view")
      :ok = Chat.PubSub.subscribe(space.id)

      assert {:ok, %{added: [], unchanged: [], refused: [%Agent{id: refused_id}]}} =
               add_attention_and_settle(actor(bob), space.id, message.id, [outsider.id])

      assert refused_id == outsider.id
      assert Chat.get_agent_participant(space.id, outsider.id) == nil
      assert rows(message.id) == []
      refute_receive {:attention_needed, _}, 100

      # POSITIVE CONTROL: the same agent, an admin actor.
      assert {:ok, %{added: [row], refused: []}} =
               add_attention_and_settle(actor(admin), space.id, message.id, [outsider.id])

      seated = Chat.get_agent_participant(space.id, outsider.id)
      assert row.participant_id == seated.id
      seated_id = seated.id
      assert_receive {:attention_needed, %{participant_id: ^seated_id, reason: :mention}}
    end

    test "nobody is summoned into a DM" do
      alice_user = user!("Alice")
      bob_user = user!("Bob")
      {:ok, dm} = Chat.find_or_create_dm(alice_user.id, "user", bob_user.id)

      alice =
        Repo.get_by!(Participant,
          space_id: dm.id,
          participant_type: "user",
          participant_id: alice_user.id
        )

      outsider = agent_record!("Scout")
      message = post!(dm, alice, "just us")

      assert {:error, :invalid} =
               add_attention_and_settle(actor(alice), dm.id, message.id, [outsider.id])

      assert Chat.get_agent_participant(dm.id, outsider.id) == nil
    end
  end

  # ── Nobody else is re-routed ───────────────────────────────────────────────

  describe "the original message's recipients" do
    test "the mutex holder, a mode-all human and a content mention get nothing new" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      carol = member!(space, user!("Carol"), %{attention_mode: "all"})
      {_h, holder} = agent!(space, "Holder")
      {_n, nova} = agent!(space, "Nova")
      {_z, zip} = agent!(space, "Zip")
      ActiveAgentStore.set_active(space.id, holder.id)
      message = post!(space, alice, "@[Nova] what do you think")
      :ok = Chat.PubSub.subscribe(space.id)

      assert {:ok, %{added: [_]}} =
               add_attention_and_settle(actor(alice), space.id, message.id, [zip.participant_id])

      zip_id = zip.id
      assert_receive {:attention_needed, %{participant_id: ^zip_id, reason: :mention}}

      # Zip's stub reply is a NEW message that routes on its own; only signals
      # for THIS message id are about the added attention.
      # The supervised routing worker has settled: all signals for M are in the mailbox.
      message_id = message.id

      for p <- [holder, nova, carol] do
        pid = p.id
        refute_received {:attention_needed, %{participant_id: ^pid, message_id: ^message_id}}
      end

      refute_received {:attention_needed, %{message_id: ^message_id}}
    end
  end

  # ── Router entry (D3) ──────────────────────────────────────────────────────

  describe "AttentionRouter.route_attention/3" do
    test "execution log-only attention persists but logs no decision, with a dispatch positive control" do
      previous_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      space = channel!(%{kind: "execution", agent_attention_policy: "on_mention"})
      alice = member!(space, user!("Alice"))
      {_agent, zip} = agent!(space, "Zip")
      message = post!(space, alice, "execution log")
      message |> Ecto.Changeset.change(log_only: true) |> Repo.update!()
      :ok = Chat.PubSub.subscribe(space.id)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          assert {:ok, %{added: [_]}} =
                   add_attention_and_settle(actor(alice), space.id, message.id, [
                     zip.participant_id
                   ])
        end)

      assert length(rows(message.id)) == 1
      assert log =~ "message=#{message.id} requested=#{zip.id}"
      assert log =~ "outcome=empty"
      assert log =~ "skipped_reason=execution_log_only"
      refute_receive {:attention_needed, _}, 100
      refute_received {:agent_chat_called, _, _}

      positive = post!(space, alice, "explicit request")

      assert {:ok, %{added: [_]}} =
               add_attention_and_settle(actor(alice), space.id, positive.id, [zip.participant_id])

      zip_id = zip.id
      assert_receive {:attention_needed, %{participant_id: ^zip_id, reason: :mention}}
    end

    test "added attention decisions are visible at info without message content" do
      space = channel!(%{agent_attention_policy: "on_mention", agents_awake: true})
      alice = member!(space, user!("Alice"))
      {_agent, zip} = agent!(space, "Zip")
      message = post!(space, alice, "private-content-sentinel")
      previous = Logger.level()
      Logger.configure(level: :info)

      try do
        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            assert {:ok, [%{participant_id: id, reason: :mention}]} =
                     AttentionRouter.route_attention(message, [zip.id], alice)

            assert id == zip.id
          end)

        assert log =~ "added_attention phase=decision"
        assert log =~ "space=#{space.id} message=#{message.id} requested=#{zip.id}"
        assert log =~ "policy=on_mention awake=true outcome=selected"
        assert log =~ "decisions=#{zip.id}:mention"
        refute log =~ "private-content-sentinel"

        ghost = %{message | space_id: Ecto.UUID.generate()}

        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            assert {:ok, []} = AttentionRouter.route_attention(ghost, [zip.id], alice)
          end)

        assert log =~ "space=#{ghost.space_id} message=#{message.id} requested=#{zip.id}"
        assert log =~ "outcome=empty"
        assert log =~ "skipped_reason=space_not_found"

        missing = Ecto.UUID.generate()

        log =
          ExUnit.CaptureLog.capture_log([level: :info], fn ->
            assert {:ok, []} = AttentionRouter.route_attention(message, [missing], alice)
          end)

        assert log =~ "requested=#{missing}"
        assert log =~ "outcome=empty"
        assert log =~ "not_selected=#{missing}"
        assert log =~ "skipped_reason=no_eligible_recipients"
      after
        Logger.configure(level: previous)
      end
    end

    test "takes the same early exits as route/1: a message whose space is gone routes nobody" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {_z, zip} = agent!(space, "Zip")
      message = post!(space, alice, "plain")

      assert {:ok, [%{participant_id: _, reason: :mention}]} =
               AttentionRouter.route_attention(message, [zip.id], alice)

      ghost = %{message | space_id: Ecto.UUID.generate()}
      assert {:ok, []} = AttentionRouter.route_attention(ghost, [zip.id], alice)
    end

    test "an added participant id the space does not hold routes nobody" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {_z, zip} = agent!(space, "Zip")
      ActiveAgentStore.set_active(space.id, zip.id)
      message = post!(space, alice, "plain")

      # Not the un-mentioned fallback: the armed holder is NOT routed.
      assert {:ok, []} = AttentionRouter.route_attention(message, [Ecto.UUID.generate()], alice)
    end

    test "the external dispatch payload carries attention_added_by" do
      runtime_presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), runtime_presence)

      n = System.unique_integer([:positive])
      owner = user!("Owner #{n}")

      runtime =
        Repo.insert!(%AgentRuntime{
          owner_user_id: owner.id,
          status: "active",
          runtime_id: "rt-attn-#{n}",
          display_name: "attn-runtime-#{n}"
        })

      agent = agent_record!("Remote", %{runtime_type: "external", runtime_id: runtime.id})
      runtime |> Ecto.Changeset.change(%{agent_id: agent.id}) |> Repo.update!()
      RuntimePresence.track(runtime.runtime_id)
      on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)
      PlatformWeb.Endpoint.subscribe("runtime:#{runtime.runtime_id}")

      space = channel!()
      alice = member!(space, user!("Alice"))
      {:ok, _remote} = Chat.add_agent_participant(space.id, agent, display_name: "Remote")
      message = post!(space, alice, "a message that does not name the agent")

      assert {:ok, %{added: [_]}} =
               add_attention_and_settle(actor(alice), space.id, message.id, [agent.id])

      assert_receive %Phoenix.Socket.Broadcast{event: "attention", payload: payload}, 1_000
      signal = payload[:signal] || payload["signal"]
      assert (signal[:attention_added_by] || signal["attention_added_by"]) == "Alice"
      assert (signal[:message_id] || signal["message_id"]) == message.id
      assert (signal[:reason] || signal["reason"]) in [:mention, "mention"]
    end
  end

  # ── Render reads ───────────────────────────────────────────────────────────

  describe "attention_by_message_ids/1" do
    test "batches by message id and omits messages with none" do
      space = channel!()
      alice = member!(space, user!("Alice"))
      {_z, zip} = agent!(space, "Zip")
      one = post!(space, alice, "one")
      two = post!(space, alice, "two")
      {:ok, _} = add_attention_and_settle(actor(alice), space.id, one.id, [zip.participant_id])

      assert %{} = map = Chat.attention_by_message_ids([one.id, two.id, "junk"])
      assert Map.keys(map) == [one.id]
      assert [%{display_name: "Zip", added_by_display_name: "Alice"}] = map[one.id]
      assert Chat.attention_by_message_ids([]) == %{}
    end
  end

  # ── Migration ──────────────────────────────────────────────────────────────

  # Runs the shipped migration's `down/0` then `up/0` inside the sandbox
  # transaction (Postgres DDL is transactional; the test's rollback restores
  # the schema). Same technique as agent_attention_controls_test.exs.
  describe "migration" do
    @migration Platform.Repo.Migrations.CreateChatMessageAttentions
    @migration_path Path.expand(
                      "../../../priv/repo/migrations/20261024213417_create_chat_message_attentions.exs",
                      __DIR__
                    )

    defp run_migration!(operation) do
      unless Code.ensure_loaded?(@migration), do: Code.require_file(@migration_path)

      {:ok, runner} =
        Ecto.Migration.Runner.start_link(
          {self(), Repo, Repo.config(), @migration, :forward, operation,
           %{level: false, sql: false}}
        )

      Ecto.Migration.Runner.metadata(runner, [])
      apply(@migration, operation, [])
      Ecto.Migration.Runner.flush()
      Ecto.Migration.Runner.stop()
      :ok
    end

    defp table_exists? do
      %{rows: [[exists]]} =
        Repo.query!("SELECT to_regclass('chat_message_attentions') IS NOT NULL")

      exists
    end

    test "down drops the table and up recreates it with the unique index" do
      assert table_exists?()
      :ok = run_migration!(:down)
      refute table_exists?()
      :ok = run_migration!(:up)
      assert table_exists?()

      %{rows: indexes} =
        Repo.query!(
          "SELECT indexname FROM pg_indexes WHERE tablename = 'chat_message_attentions'"
        )

      assert ["chat_message_attentions_message_participant_index"] in indexes
    end
  end
end
