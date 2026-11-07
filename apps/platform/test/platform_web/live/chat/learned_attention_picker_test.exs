defmodule PlatformWeb.ChatLive.LearnedAttentionPickerTest do
  @moduledoc """
  Task 01a1b6a1 stage 3 (`0061-learned-defaults.md` § 4): the attention
  picker's backend learns. Ranking and the pre-fill land on
  `@open_message_attention`; every pick, the "Not X" decline and a close
  after a pre-fill write a signal. The UI is stage 4, so these read assigns.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, MessageAttention}
  alias Platform.Habits
  alias Platform.Habits.Signal
  alias Platform.Repo

  @action "chat.message_attention"

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
    one = user!("Member One", n)
    two = user!("Member Two", n)
    three = user!("Member Three", n)

    agent =
      Repo.insert!(%Agent{
        slug: "helper-agent-lp-#{n}",
        name: "Helper Agent #{n}",
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    rooms =
      for name <- ["room-x", "room-y"], into: %{} do
        {:ok, space} =
          Chat.create_space(%{name: "#{name} #{n}", slug: "#{name}-lp-#{n}", kind: "channel"})

        for u <- [one, two, three], do: participant!(space, "user", u.id, u.name)
        agent_p = participant!(space, "agent", agent.id, agent.name)
        {name, %{space: space, agent_p: agent_p}}
      end

    %{
      conn: conn,
      one: one,
      two: two,
      three: three,
      agent: agent,
      room_x: rooms["room-x"].space,
      room_y: rooms["room-y"].space,
      agent_p_x: rooms["room-x"].agent_p,
      agent_p_y: rooms["room-y"].agent_p
    }
  end

  defp user!(name, n) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%User{
      email: "#{slug}-lp-#{n}@example.com",
      name: "#{name} #{n}",
      oidc_sub: "oidc-#{slug}-lp-#{n}",
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

  # Messages are authored by the agent, so both people stay pickable.
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

  defp record!(actor, space, target_user, outcome, rung, n) do
    for _ <- 1..n do
      {:ok, %Signal{}} =
        Habits.record(%{
          actor_user_id: actor.id,
          space_id: space.id,
          action: @action,
          target_type: "user",
          target_id: target_user.id,
          outcome: outcome,
          rung: rung
        })
    end
  end

  defp open_picker(conn, user, space, msg) do
    {:ok, view, _html} =
      live(init_test_session(conn, current_user_id: user.id), "/chat/#{space.slug}")

    render_click(view, "open_message_attention", %{"message-id" => msg.id})
    view
  end

  defp picker(view), do: :sys.get_state(view.pid).socket.assigns.open_message_attention

  defp signals(user) do
    Repo.all(
      from(s in Signal,
        where: s.actor_user_id == ^user.id and s.action == @action,
        order_by: [asc: s.inserted_at, asc: s.id],
        select: {s.target_id, s.outcome, s.rung}
      )
    )
  end

  defp drain, do: :ok = GenServer.call(AttentionRouter, :__drain__)

  describe "ranking" do
    test "after 4 asks for Member Two in room-x, Member One sees them first, learned; " <>
           "Member Three and room-y see nothing learned",
         %{conn: conn, one: one, two: two, three: three} = ctx do
      record!(one, ctx.room_x, two, "chosen", "none", 4)

      msg_x = post!(ctx.room_x, ctx.agent_p_x, "look here")
      msg_y = post!(ctx.room_y, ctx.agent_p_y, "look here too")

      [first | rest] = picker(open_picker(conn, one, ctx.room_x, msg_x)).suggestions
      assert first.principal_id == two.id
      assert first.learned == true
      assert first.reason == {:usually, first.display_name}
      refute Enum.any?(rest, &(&1[:learned] == true))

      refute Enum.any?(
               picker(open_picker(build_conn(), three, ctx.room_x, msg_x)).suggestions,
               &(&1[:learned] == true)
             )

      refute Enum.any?(
               picker(open_picker(build_conn(), one, ctx.room_y, msg_y)).suggestions,
               &(&1[:learned] == true)
             )
    end

    test "with a query, the ranking applies within the matches",
         %{conn: conn, one: one, three: three} = ctx do
      record!(one, ctx.room_x, three, "chosen", "none", 4)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)

      render_change(view, "attention_query", %{"query" => "Member"})
      assert [%{principal_id: id, learned: true} | _] = picker(view).suggestions
      assert id == three.id

      render_change(view, "attention_query", %{"query" => "Two"})
      assert [row] = picker(view).suggestions
      refute row[:learned]
    end
  end

  describe "the pre-fill" do
    test "is present above threshold and absent below",
         %{conn: conn, one: one, two: two, three: three} = ctx do
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")

      # 2 signals: below min_signals (3).
      record!(one, ctx.room_x, two, "chosen", "none", 2)
      assert picker(open_picker(conn, one, ctx.room_x, msg)).prefill == nil

      record!(one, ctx.room_x, two, "chosen", "none", 2)
      state = picker(open_picker(build_conn(), one, ctx.room_x, msg))
      assert state.prefill.principal_id == two.id
      assert state.rung == "prefill"

      # Confidence below 0.6: Member Three is chosen as often.
      record!(one, ctx.room_x, three, "chosen", "none", 4)
      assert picker(open_picker(build_conn(), one, ctx.room_x, msg)).prefill == nil
    end

    test "'Not X' writes an overridden signal and clears the pre-fill",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, two, "chosen", "none", 4)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)
      assert picker(view).prefill.principal_id == two.id

      render_click(view, "decline_attention_prefill", %{})

      assert picker(view).prefill == nil
      assert List.last(signals(one)) == {two.id, "overridden", "prefill"}

      # Closing after the decline is not also an ignore.
      render_click(view, "close_message_attention", %{})
      refute Enum.any?(signals(one), &match?({_, "ignored", _}, &1))
    end

    test "picking the pre-filled person is accepted at prefill",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, two, "chosen", "none", 4)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)

      render_click(view, "add_message_attention", %{"message-id" => msg.id, "ids" => [two.id]})
      drain()

      assert List.last(signals(one)) == {two.id, "accepted", "prefill"}

      assert Repo.aggregate(from(a in MessageAttention, where: a.message_id == ^msg.id), :count) ==
               1
    end

    test "picking someone else is overridden for the pre-fill plus chosen for the pick",
         %{conn: conn, one: one, two: two, three: three} = ctx do
      record!(one, ctx.room_x, two, "chosen", "none", 4)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)
      before = length(signals(one))

      render_click(view, "add_message_attention", %{"message-id" => msg.id, "ids" => [three.id]})
      drain()

      assert Enum.sort(Enum.drop(signals(one), before)) ==
               Enum.sort([{three.id, "chosen", "prefill"}, {two.id, "overridden", "prefill"}])
    end

    test "at rung 1 (rank), picking someone else is chosen for the pick and overrides nothing",
         %{conn: conn, one: one, two: two, three: three} = ctx do
      # Two learned but under the pre-fill threshold: rung 1, rank only.
      record!(one, ctx.room_x, two, "chosen", "none", 2)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)
      assert picker(view).rung == "rank"
      assert picker(view).prefill == nil
      before = length(signals(one))

      render_click(view, "add_message_attention", %{"message-id" => msg.id, "ids" => [three.id]})
      drain()

      assert Enum.drop(signals(one), before) == [{three.id, "chosen", "rank"}]
      refute Enum.any?(signals(one), &match?({_, "overridden", _}, &1))
    end

    test "closing with no pick after a pre-fill is ignored",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, two, "chosen", "none", 4)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)

      render_click(view, "close_message_attention", %{})
      assert List.last(signals(one)) == {two.id, "ignored", "prefill"}
    end

    test "a pick with nothing learned is chosen at none",
         %{conn: conn, one: one, three: three} = ctx do
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)
      assert picker(view).prefill == nil

      render_click(view, "add_message_attention", %{"message-id" => msg.id, "ids" => [three.id]})
      drain()

      assert signals(one) == [{three.id, "chosen", "none"}]
    end
  end

  describe "the notice's controls" do
    test "undo_learned_action removes the automatic ask and demotes the pattern",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, two, "accepted", "prefill", 5)

      one_p =
        Repo.one!(
          from(p in Chat.Participant,
            where: p.space_id == ^ctx.room_x.id and p.participant_id == ^one.id
          )
        )

      msg = post!(ctx.room_x, one_p, "status update")
      drain()

      assert Repo.aggregate(from(a in MessageAttention, where: a.message_id == ^msg.id), :count) ==
               1

      {:ok, view, _html} =
        live(init_test_session(conn, current_user_id: one.id), "/chat/#{ctx.room_x.slug}")

      render_click(view, "undo_learned_action", %{"message-id" => msg.id})

      assert Repo.aggregate(from(a in MessageAttention, where: a.message_id == ^msg.id), :count) ==
               0

      assert %{act: nil, prefill: %{target_id: two_id}} =
               Habits.suggest(one.id, ctx.room_x.id, @action)

      assert two_id == two.id

      render_click(view, "stop_learned_action", %{"message-id" => msg.id})
      assert %{prefill: nil} = Habits.suggest(one.id, ctx.room_x.id, @action)
    end
  end
end
