defmodule PlatformWeb.ChatLive.MessageAttentionUITest do
  @moduledoc """
  "Get someone's attention", the UI (Burrow redesign rung 12, task
  01a1557a-a30a stage 2): the sheet row, the tap pill's +@, the
  "+@ add someone" button, the picker (rung 10's `MentionList` in pick mode)
  and the added line under the message. Server side: stage 1's
  `Chat.add_message_attention/4`.

  Masters canvas 01a1382f node `proto` (mobile `stubAttention`/`attnHTML`,
  desktop `attention`/`attnHTML`).
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, MessageAttention, MessageVersions}
  alias Platform.Repo
  alias PlatformWeb.ChatLive.MessageAttentionHooks

  import Ecto.Query

  defmodule StubAgentChat do
    def chat(_message, _opts), do: {:ok, %{content: "on it", model: "stub", usage: %{}}}
  end

  setup %{conn: conn} do
    previous =
      for key <- [:chat_agent_module, :chat_agent_dispatch_mode],
          do: {key, Application.get_env(:platform, key)}

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:platform, key, value) end)
    end)

    router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    Sandbox.allow(Repo, self(), router)
    store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    Sandbox.allow(Repo, self(), store)

    n = System.unique_integer([:positive])
    alice = user!("Alice Viewer #{n}")
    bob = user!("Bob Member #{n}")

    {:ok, space} =
      Chat.create_space(%{name: "Attention #{n}", slug: "attention-#{n}", kind: "channel"})

    alice_p = participant!(space, "user", alice.id, alice.name)
    bob_p = participant!(space, "user", bob.id, bob.name)

    agent_row =
      Repo.insert!(%Agent{
        slug: "attn-ui-agent-#{n}",
        name: "Zip #{n}",
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    agent_p = participant!(space, "agent", agent_row.id, agent_row.name)

    {:ok,
     conn: conn,
     alice_conn: init_test_session(conn, current_user_id: alice.id),
     bob_conn: init_test_session(build_conn(), current_user_id: bob.id),
     space: space,
     alice: alice,
     bob: bob,
     alice_p: alice_p,
     bob_p: bob_p,
     agent_row: agent_row,
     agent_p: agent_p}
  end

  defp user!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "attn-ui-#{n}@example.com",
      name: name,
      oidc_sub: "oidc-attn-ui-#{n}",
      avatar_url: nil
    })
  end

  defp participant!(space, type, id, name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: type,
        participant_id: id,
        display_name: name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post!(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp open_chat(conn, space) do
    {:ok, view, _html} = live(conn, "/chat/#{space.slug}")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp texts(view, selector) do
    view
    |> doc()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()))
  end

  defp attention_rows(msg_id) do
    Repo.all(from(a in MessageAttention, where: a.message_id == ^msg_id))
  end

  defp drain, do: :ok = GenServer.call(AttentionRouter, :__drain__)

  describe "the sheet row" do
    test "is second on own, others' and agent messages, with the meta for whose it is",
         %{alice_conn: conn, space: space, alice_p: alice_p, bob_p: bob_p, agent_p: agent_p} do
      own = post!(space, alice_p, "my line")
      others = post!(space, bob_p, "bob's line")
      agent = post!(space, agent_p, "agent line")
      view = open_chat(conn, space)

      for {msg, meta} <- [
            {own, "notify an agent or person about this — no edit"},
            {others, "ask someone to look at this"},
            {agent, "ask someone to look at this"}
          ] do
        render_click(view, "open_message_actions", %{"id" => msg.id})

        for frame <- ["#message-actions-sheet", "#message-actions-popover"] do
          labels = texts(view, ~s(#{frame} [data-role="message-actions-label"]))

          # Second, right after Reply in thread. An agent's top-level message
          # is headed by 'Reply' (task 01a174f5 stage 2), so there it is third.
          lead =
            if msg.id == agent.id, do: ["Reply", "Reply in thread"], else: ["Reply in thread"]

          assert Enum.take(labels, length(lead)) == lead, inspect(labels)
          assert Enum.at(labels, length(lead)) == "Get someone's attention", inspect(labels)

          assert texts(view, ~s(#{frame} [data-role="message-actions-attention-meta"])) == [meta]
        end

        render_click(view, "close_message_actions", %{})
      end
    end

    test "opens the picker, titled per whose message it is",
         %{alice_conn: conn, space: space, alice_p: alice_p, bob_p: bob_p} do
      own = post!(space, alice_p, "can someone look at the tab bar spacing?")
      others = post!(space, bob_p, "their line")
      view = open_chat(conn, space)

      render_click(view, "open_message_actions", %{"id" => own.id})

      view
      |> element(~s(#message-actions-sheet [data-role="message-actions-attention"]))
      |> render_click()

      refute has_element?(view, "#message-actions-sheet")

      assert has_element?(
               view,
               ~s(#message-attention-sheet p[aria-hidden="true"]),
               "Get someone's attention"
             )

      assert has_element?(view, "#message-attention-popover.hidden.lg\\:block")

      assert texts(view, ~s(#message-attention-sheet [data-role="message-attention-preview"])) ==
               ["can someone look at the tab bar spacing?"]

      assert has_element?(
               view,
               ~s(#message-attention-sheet input[placeholder="Search agents and people"])
             )

      render_click(view, "close_message_attention", %{})
      render_click(view, "open_message_attention", %{"message-id" => others.id})

      assert has_element?(
               view,
               ~s(#message-attention-sheet p[aria-hidden="true"]),
               "Ask someone to look"
             )
    end
  end

  describe "the tap pill" do
    test "reads 👍 ↩ +@ ⧉ ⋯, and +@ opens the picker",
         %{alice_conn: conn, space: space, bob_p: bob_p} do
      msg = post!(space, bob_p, "pill me")
      view = open_chat(conn, space)

      glyphs = texts(view, ~s(#messages-#{msg.id} [data-role="message-pill"] button))
      assert glyphs == ["👍", "↩", "+@", "⧉", "⋯"]

      view
      |> element(~s(#messages-#{msg.id} [data-role="message-pill-attention"]))
      |> render_click()

      assert has_element?(view, "#message-attention-sheet")
    end
  end

  describe "the add-someone button" do
    test "renders on own messages only; the latest-row rule shows it under the last one",
         %{alice_conn: conn, space: space, alice_p: alice_p, bob_p: bob_p, agent_p: agent_p} do
      first = post!(space, alice_p, "first own")
      view = open_chat(conn, space)

      assert last_row_has_button?(view)
      assert has_element?(view, ~s(#messages-#{first.id} [data-role="message-add-attention"]))

      # A newer message from someone else: the last row is theirs and has
      # no button, so the CSS rule shows none.
      bob_msg = post!(space, bob_p, "bob after")
      assert last_row_id(view) == "messages-#{bob_msg.id}"
      refute last_row_has_button?(view)

      agent_msg = post!(space, agent_p, "agent after")
      assert last_row_id(view) == "messages-#{agent_msg.id}"
      refute has_element?(view, ~s(#messages-#{agent_msg.id} [data-role="message-add-attention"]))

      # The viewer's own newer message: the button moves to it.
      second = post!(space, alice_p, "second own")
      assert last_row_id(view) == "messages-#{second.id}"
      assert last_row_has_button?(view)

      [button] =
        view
        |> doc()
        |> LazyHTML.query(~s(#messages-#{second.id} [data-role="message-add-attention"]))
        |> Enum.to_list()

      assert LazyHTML.attribute(button, "aria-label") ==
               ["Get someone's attention on this message"]

      assert LazyHTML.attribute(button, "title") == ["Add someone to this message"]

      assert button |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim() ==
               "+@ add someone"

      classes = button |> LazyHTML.attribute("class") |> hd() |> String.split()
      assert "border-dashed" in classes and "text-subtle" in classes
      refute Enum.any?(classes, &String.starts_with?(&1, "hover:")), inspect(classes)
    end

    test "app.css shows it only on the last row, own, while the newest are on screen" do
      css =
        Path.expand("../../../../assets/css/app.css", __DIR__)
        |> File.read!()
        |> String.replace(~r{/\*.*?\*/}s, "")

      assert css =~ ~r/\.message-add-attention\s*\{\s*display:\s*none;\s*\}/

      assert css =~
               ~r/#message-list:not\(\[data-newest-evicted="true"\]\)\s*>\s*\[data-is-own-message="true"\]:last-child\s*\.message-add-attention\s*\{\s*display:\s*inline-flex;\s*\}/
    end
  end

  defp last_row_id(view) do
    view
    |> doc()
    |> LazyHTML.query("#message-list > [data-message-id]")
    |> Enum.to_list()
    |> List.last()
    |> LazyHTML.attribute("id")
    |> hd()
  end

  defp last_row_has_button?(view) do
    id = last_row_id(view)
    has_element?(view, ~s(##{id} [data-role="message-add-attention"]))
  end

  describe "picking someone" do
    test "an agent on another member's message: every viewer's own copy, no (edited)",
         ctx do
      %{space: space, bob_p: bob_p, agent_p: agent_p, agent_row: agent_row, alice: alice} = ctx
      msg = post!(space, bob_p, "can someone look at the tab bar spacing?")
      alice_view = open_chat(ctx.alice_conn, space)
      bob_view = open_chat(ctx.bob_conn, space)

      render_click(alice_view, "open_message_attention", %{"message-id" => msg.id})

      row = ~s(#message-attention-sheet [data-principal-id="#{agent_row.id}"])
      assert has_element?(alice_view, row)
      alice_view |> element(row) |> render_click()
      drain()

      refute has_element?(alice_view, "#message-attention-sheet")
      assert render(alice_view) =~ "@#{agent_p.display_name} notified"

      assert [%MessageAttention{participant_id: pid}] = attention_rows(msg.id)
      assert pid == agent_p.id

      assert texts(alice_view, ~s(#messages-#{msg.id} [data-role="message-attention"])) ==
               ["you asked @#{agent_p.display_name} to look"]

      assert texts(bob_view, ~s(#messages-#{msg.id} [data-role="message-attention"])) ==
               ["#{alice.name} asked @#{agent_p.display_name} to look"]

      for view <- [alice_view, bob_view] do
        refute has_element?(view, ~s(#messages-#{msg.id} [data-role="message-edited"]))

        assert has_element?(
                 view,
                 ~s(#messages-#{msg.id}),
                 "can someone look at the tab bar spacing?"
               )
      end

      assert MessageVersions.count_versions(msg.id) <= 1
      reloaded = Chat.get_message(msg.id)
      assert reloaded.edited_at == nil
      assert reloaded.content == msg.content

      # The picker now marks the agent "added", and picking it is a no-op.
      render_click(alice_view, "open_message_attention", %{"message-id" => msg.id})

      [added] =
        alice_view
        |> doc()
        |> LazyHTML.query(row)
        |> Enum.to_list()

      assert LazyHTML.attribute(added, "data-added") == ["true"]
      assert LazyHTML.attribute(added, "phx-click") == []
      assert texts(alice_view, row <> ~s( [data-role="mention-list-added"])) == ["added"]
    end

    test "on the viewer's own message: '→ @A, @B added · notified', after a reload too",
         ctx do
      %{space: space, alice_p: alice_p, bob_p: bob_p, agent_p: agent_p} = ctx
      msg = post!(space, alice_p, "own ask")
      view = open_chat(ctx.alice_conn, space)

      render_click(view, "add_message_attention", %{
        "message-id" => msg.id,
        "ids" => [agent_p.participant_id, bob_p.participant_id]
      })

      drain()

      expected = ["→ @#{agent_p.display_name}, @#{bob_p.display_name} added · notified"]
      assert texts(view, ~s(#messages-#{msg.id} [data-role="message-attention"])) == expected

      reloaded = open_chat(ctx.alice_conn, space)
      assert texts(reloaded, ~s(#messages-#{msg.id} [data-role="message-attention"])) == expected
      refute has_element?(reloaded, ~s(#messages-#{msg.id} [data-role="message-edited"]))

      chips = texts(reloaded, ~s(#messages-#{msg.id} [data-role="message-attention-chip"]))
      assert chips == ["@#{agent_p.display_name}", "@#{bob_p.display_name}"]
    end

    test "the picker leaves out @here, the author and the viewer", ctx do
      %{space: space, bob_p: bob_p, agent_row: agent_row, alice: alice, bob: bob} = ctx
      msg = post!(space, bob_p, "bob's")
      view = open_chat(ctx.alice_conn, space)
      render_click(view, "open_message_attention", %{"message-id" => msg.id})

      ids =
        view
        |> doc()
        |> LazyHTML.query(~s(#message-attention-sheet [data-principal-id]))
        |> Enum.flat_map(&LazyHTML.attribute(&1, "data-principal-id"))

      assert agent_row.id in ids
      refute bob.id in ids
      refute alice.id in ids

      refute has_element?(view, ~s(#message-attention-sheet [data-kind="broadcast"]))

      # The search re-runs rung 10's builder.
      view
      |> element("#message-attention-search")
      |> render_change(%{"query" => "zzz-nobody"})

      assert has_element?(view, ~s(#message-attention-sheet [data-role="mention-list-empty"]))
    end
  end

  # Runtime broadcasts, rather than a chip or an attention row, are the delivery oracle.
  describe "picker runtime delivery and isolation" do
    setup ctx do
      alias Platform.Agents.AgentRuntime
      alias Platform.Federation.RuntimePresence
      presence = Process.whereis(RuntimePresence) || start_supervised!(RuntimePresence)
      Sandbox.allow(Repo, self(), presence)
      n = System.unique_integer([:positive])

      runtime =
        Repo.insert!(%AgentRuntime{
          owner_user_id: ctx.alice.id,
          status: "active",
          runtime_id: "attn-ui-runtime-#{n}",
          display_name: "Attention UI runtime #{n}"
        })

      agent =
        ctx.agent_row
        |> Ecto.Changeset.change(%{runtime_type: "external", runtime_id: runtime.id})
        |> Repo.update!()

      runtime |> Ecto.Changeset.change(%{agent_id: agent.id}) |> Repo.update!()
      RuntimePresence.track(runtime.runtime_id)
      on_exit(fn -> RuntimePresence.untrack(runtime.runtime_id) end)
      topic = "runtime:#{runtime.runtime_id}"
      :ok = PlatformWeb.Endpoint.subscribe(topic)

      space =
        ctx.space
        |> Ecto.Changeset.change(%{agent_attention_policy: "on_mention", agents_awake: true})
        |> Repo.update!()

      message = post!(space, ctx.alice_p, "Plain request without a mention")
      drain()
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention"}, 100
      view = open_chat(ctx.alice_conn, space)

      {:ok,
       runtime_topic: topic,
       delivery_message: message,
       delivery_view: view,
       original_version_count: MessageVersions.count_versions(message.id)}
    end

    test "real picker dispatches the original message once and duplicate clicks do not resend",
         ctx do
      monitor = Process.monitor(ctx.delivery_view.pid)
      pick_agent(ctx)
      assert_runtime_attention(ctx)
      assert_original_message(ctx)

      render_click(ctx.delivery_view, "open_message_attention", %{
        "message-id" => ctx.delivery_message.id
      })

      assert has_element?(
               ctx.delivery_view,
               ~s(#message-attention-sheet [data-principal-id="#{ctx.agent_row.id}"][data-added="true"])
             )

      # A stale client can still send the original click after the row becomes disabled.
      render_click(ctx.delivery_view, "add_message_attention", %{
        "message-id" => ctx.delivery_message.id,
        "ids" => [ctx.agent_row.id]
      })

      drain()
      topic = ctx.runtime_topic
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention"}, 200
      assert_original_message(ctx)
      assert Process.alive?(ctx.delivery_view.pid)
      refute_received {:DOWN, ^monitor, _, _, _}
    end

    @tag timeout: 20_000
    test "picker stays interactive beyond the old five-second timeout and dispatches after release",
         ctx do
      router = Process.whereis(AttentionRouter)
      monitor = Process.monitor(ctx.delivery_view.pid)
      :ok = :sys.suspend(router)

      try do
        pick_agent(ctx)
        worker = queued_attention_worker(router)
        worker_monitor = Process.monitor(worker)
        assert Process.alive?(ctx.delivery_view.pid)
        assert_original_message(ctx)
        refute has_element?(ctx.delivery_view, "#message-attention-sheet")
        topic = ctx.runtime_topic
        refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention"}, 5_100
        # A server round trip on the same pid proves the socket did not merely remount.
        render_click(ctx.delivery_view, "open_message_attention", %{
          "message-id" => ctx.delivery_message.id
        })

        assert has_element?(ctx.delivery_view, "#message-attention-sheet")
        assert Process.alive?(ctx.delivery_view.pid)
        refute_received {:DOWN, ^monitor, _, _, _}
        :ok = :sys.resume(router)
        assert_runtime_attention(ctx)
        assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 2_000
        refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention"}, 100
      after
        if Process.alive?(router), do: :sys.resume(router)
      end
    end

    test "router exit preserves the LiveView, viewer update and human inbox with a correlated failure",
         ctx do
      alias Platform.Inbox.Item
      router = Process.whereis(AttentionRouter)
      monitor = Process.monitor(ctx.delivery_view.pid)
      viewer = open_chat(ctx.bob_conn, ctx.space)
      :ok = Chat.PubSub.subscribe(ctx.space.id)
      :ok = :sys.suspend(router)

      log =
        ExUnit.CaptureLog.capture_log([level: :info], fn ->
          try do
            render_click(ctx.delivery_view, "open_message_attention", %{
              "message-id" => ctx.delivery_message.id
            })

            # Select the agent through the actual picker; add a person in a second request
            # while the router is parked to prove inbox is independent of it.
            pick_agent(ctx)
            worker = queued_attention_worker(router)
            worker_monitor = Process.monitor(worker)

            render_click(ctx.delivery_view, "add_message_attention", %{
              "message-id" => ctx.delivery_message.id,
              "ids" => [ctx.bob.id]
            })

            assert_receive {:message_attention_changed, _}
            assert render(viewer) =~ "asked @#{ctx.agent_p.display_name} to look"
            assert Repo.exists?(from(i in Item, where: i.user_id == ^ctx.bob.id))
            :ok = :sys.terminate(router, :normal)
            assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :normal}, 2_000

            render_click(ctx.delivery_view, "open_message_attention", %{
              "message-id" => ctx.delivery_message.id
            })

            assert has_element?(ctx.delivery_view, "#message-attention-sheet")
            assert Process.alive?(ctx.delivery_view.pid)
            refute_received {:DOWN, ^monitor, _, _, _}
          after
            if Process.alive?(router), do: :sys.resume(router)
          end
        end)

      assert log =~ "add_message_attention routing worker failed phase=failure"

      assert log =~
               "message=#{ctx.delivery_message.id} space=#{ctx.space.id} recipients=#{ctx.agent_p.id}"

      assert log =~ "kind=exit"
      topic = ctx.runtime_topic
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention"}, 100
    end
  end

  defp pick_agent(ctx) do
    render_click(ctx.delivery_view, "open_message_attention", %{
      "message-id" => ctx.delivery_message.id
    })

    ctx.delivery_view
    |> element(~s(#message-attention-sheet [data-principal-id="#{ctx.agent_row.id}"]))
    |> render_click()
  end

  defp assert_runtime_attention(ctx) do
    topic = ctx.runtime_topic

    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "attention", payload: payload},
                   2_000

    signal = payload[:signal] || payload["signal"]
    assert (signal[:message_id] || signal["message_id"]) == ctx.delivery_message.id
    assert (signal[:reason] || signal["reason"]) in [:mention, "mention"]
    assert (signal[:agent_id] || signal["agent_id"]) == ctx.agent_row.id
    assert (signal[:attention_added_by] || signal["attention_added_by"]) == ctx.alice.name
  end

  defp assert_original_message(ctx) do
    assert [%MessageAttention{participant_id: participant_id}] =
             attention_rows(ctx.delivery_message.id)

    assert participant_id == ctx.agent_p.id
    message = Chat.get_message(ctx.delivery_message.id)
    assert message.content == ctx.delivery_message.content
    assert message.edited_at == ctx.delivery_message.edited_at
    assert MessageVersions.count_versions(message.id) == ctx.original_version_count
  end

  defp queued_attention_worker(router, attempts \\ 200)

  defp queued_attention_worker(_router, 0),
    do: flunk("routing worker never queued its GenServer call")

  defp queued_attention_worker(router, attempts) do
    {:messages, messages} = Process.info(router, :messages)

    case Enum.find(messages, &match?({:"$gen_call", _, {:route_attention, _, _}}, &1)) do
      {:"$gen_call", {worker, _}, _} ->
        worker

      nil ->
        Process.sleep(5)
        queued_attention_worker(router, attempts - 1)
    end
  end

  describe "refusals" do
    test "a forged message id from another space is refused and renders nothing", ctx do
      %{space: space, alice: alice, agent_p: agent_p} = ctx
      n = System.unique_integer([:positive])

      {:ok, other_space} =
        Chat.create_space(%{name: "Elsewhere #{n}", slug: "elsewhere-#{n}", kind: "channel"})

      alice_there = participant!(other_space, "user", alice.id, alice.name)
      _bob_there = participant!(other_space, "user", ctx.bob.id, ctx.bob.name)
      foreign = post!(other_space, alice_there, "not here")
      local = post!(space, ctx.bob_p, "here")

      view = open_chat(ctx.alice_conn, space)

      render_click(view, "add_message_attention", %{
        "message-id" => foreign.id,
        "ids" => [ctx.bob.id, agent_p.participant_id]
      })

      assert attention_rows(foreign.id) == []
      refute has_element?(view, ~s([data-role="message-attention"]))

      # Positive control: the same socket and agent on a message in its space.
      render_click(view, "add_message_attention", %{
        "message-id" => local.id,
        "ids" => [agent_p.participant_id]
      })

      drain()
      assert [_] = attention_rows(local.id)
    end

    test "a socket whose viewer is no longer a member writes nothing", ctx do
      %{space: space, agent_p: agent_p} = ctx
      outsider = user!("Outsider")
      msg = post!(space, ctx.bob_p, "members only")

      # Opening a channel seats an internal user, so the socket is mounted
      # first and its participant row removed after: the case a forged event
      # from a stale or removed session is.
      conn = init_test_session(build_conn(), current_user_id: outsider.id)
      {:ok, view, _html} = live(conn, "/chat/#{space.slug}")

      Repo.delete_all(
        from(p in Platform.Chat.Participant,
          where: p.space_id == ^space.id and p.participant_id == ^outsider.id
        )
      )

      render_click(view, "add_message_attention", %{
        "message-id" => msg.id,
        "ids" => [agent_p.participant_id]
      })

      assert attention_rows(msg.id) == []
      refute has_element?(view, ~s([data-role="message-attention"]))

      # Positive control: a member's socket on the same message and agent.
      member_view = open_chat(ctx.alice_conn, space)

      render_click(member_view, "add_message_attention", %{
        "message-id" => msg.id,
        "ids" => [agent_p.participant_id]
      })

      drain()
      assert [_] = attention_rows(msg.id)
    end
  end

  describe "external sessions" do
    test "are offered no agents, present or addable", ctx do
      %{agent_p: agent_p, bob_p: bob_p} = ctx
      msg = post!(ctx.space, bob_p, "x")

      participants = %{
        agent_p.id => %{
          display_name: agent_p.display_name,
          participant_type: "agent",
          principal_id: agent_p.participant_id
        },
        bob_p.id => %{
          display_name: bob_p.display_name,
          participant_type: "user",
          principal_id: bob_p.participant_id
        }
      }

      addable = [
        %{id: Ecto.UUID.generate(), name: "Addable Agent", display_name: "Addable Agent"}
      ]

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          participants_map: participants,
          external?: true,
          user_id: Ecto.UUID.generate(),
          mention_addable_agents: addable
        }
      }

      suggestions = MessageAttentionHooks.suggestions(socket, msg, "")
      refute Enum.any?(suggestions, &(&1[:participant_type] == "agent")), inspect(suggestions)

      internal = put_in(socket.assigns.external?, false)

      kinds =
        internal |> MessageAttentionHooks.suggestions(msg, "") |> Enum.map(& &1.display_name)

      assert agent_p.display_name in kinds and "Addable Agent" in kinds
    end
  end
end
