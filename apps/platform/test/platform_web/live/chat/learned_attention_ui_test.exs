defmodule PlatformWeb.ChatLive.LearnedAttentionUITest do
  @moduledoc """
  Task 01a1b6a1 stage 4: the learned-defaults UI on the attention picker and
  under the message. Rung 1 (the ✦ mark and the reason line), rung 2 (the
  pre-filled card, its confirm and "Not <name>"), the "Why this?" line, and
  the rung 3 acted-for-you notice (shown, undone, stopped): persistent,
  never a flash, never a success colour, never a percentage.
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
        slug: "helper-agent-ui-#{n}",
        name: "Helper Agent #{n}",
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    rooms =
      for name <- ["room-x", "room-y"], into: %{} do
        {:ok, space} =
          Chat.create_space(%{name: "#{name} #{n}", slug: "#{name}-ui-#{n}", kind: "channel"})

        ps =
          for u <- [one, two, three],
              into: %{},
              do: {u.id, participant!(space, "user", u.id, u.name)}

        agent_p = participant!(space, "agent", agent.id, agent.name)
        {name, %{space: space, agent_p: agent_p, ps: ps}}
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
      one_p_x: rooms["room-x"].ps[one.id],
      one_p_y: rooms["room-y"].ps[one.id]
    }
  end

  defp user!(name, n) do
    slug = name |> String.downcase() |> String.replace(" ", "-")

    Repo.insert!(%User{
      email: "#{slug}-ui-#{n}@example.com",
      name: "#{name} #{n}",
      oidc_sub: "oidc-#{slug}-ui-#{n}",
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

  defp record!(actor, space, type, target_id, outcome, rung, n) do
    for _ <- 1..n do
      {:ok, %Signal{}} =
        Habits.record(%{
          actor_user_id: actor.id,
          space_id: space.id,
          action: @action,
          target_type: type,
          target_id: target_id,
          outcome: outcome,
          rung: rung
        })
    end
  end

  defp live_as(conn, user, space) do
    {:ok, view, _html} =
      live(init_test_session(conn, current_user_id: user.id), "/chat/#{space.slug}")

    view
  end

  defp open_picker(conn, user, space, msg) do
    view = live_as(conn, user, space)
    render_click(view, "open_message_attention", %{"message-id" => msg.id})
    view
  end

  defp drain, do: :ok = GenServer.call(AttentionRouter, :__drain__)

  defp attention_rows(msg_id),
    do: Repo.all(from(a in MessageAttention, where: a.message_id == ^msg_id))

  # The visible text of `selector`, so a class such as `calc(100%+4px)`
  # never reads as a shown percentage.
  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash

  @sheet "#message-attention-sheet"
  @notice_sel "[data-role=learned-notice]"

  defp sheet_rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@sheet} [data-role=mention-list] [role=option]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("data-mention-name") |> List.first()))
  end

  # ── Rung 1 ────────────────────────────────────────────────────────────────

  describe "rung 1, ranked" do
    test "learned rows come first with the ✦ mark and a reason line naming the display name",
         %{conn: conn, one: one, two: two, three: three} = ctx do
      record!(one, ctx.room_x, "user", two.id, "chosen", "none", 4)
      record!(one, ctx.room_x, "user", three.id, "chosen", "none", 3)
      msg = post!(ctx.room_x, ctx.one_p_x, "own message")
      view = open_picker(conn, one, ctx.room_x, msg)

      assert has_element?(
               view,
               "#{@sheet} [data-role=message-attention-title]",
               "Get someone's attention"
             )

      assert has_element?(view, "#{@sheet} [data-role=message-attention-picker][data-rung=rank]")
      refute has_element?(view, "#{@sheet} [data-role=learned-prefill]")

      assert has_element?(
               view,
               "#{@sheet} [data-role=message-attention-search][placeholder='Search agents and people']"
             )

      # Learned rows lead, ahead of the agent the kind sort would put first.
      assert [first, second | _] = sheet_rows(view)
      assert first == two.name and second == three.name

      assert has_element?(
               view,
               "#{@sheet} [data-role=learned-reason]",
               "You usually ask #{two.name} here"
             )

      assert has_element?(
               view,
               "#{@sheet} [data-role=learned-reason]",
               "You usually ask #{three.name} here"
             )

      assert has_element?(
               view,
               "#{@sheet} [data-role=learned-reason] [data-role=learned-reason-name].font-semibold",
               two.name
             )

      assert has_element?(view, "#{@sheet} [data-role=learned-reason].text-info.text-\\[13px\\]")
      assert has_element?(view, "#{@sheet} [data-role=learned-mark]", "✦")

      # The agent row is unlearned: no mark on it.
      refute has_element?(
               view,
               "#{@sheet} [role=option][data-kind=agent] [data-role=learned-mark]"
             )

      shown = text(view, @sheet)
      refute shown =~ ~r/\d+\s*%/
      refute shown =~ ~r/\b(AI|model)\b/
      refute shown =~ ~r/dismiss suggestion/i
    end

    test "Member Three and room-y see no learned mark",
         %{conn: conn, one: one, two: two, three: three} = ctx do
      record!(one, ctx.room_x, "user", two.id, "chosen", "none", 4)
      msg_x = post!(ctx.room_x, ctx.agent_p_x, "look here")

      {:ok, msg_y} =
        Chat.post_message(%{
          space_id: ctx.room_y.id,
          participant_id: ctx.one_p_y.id,
          content_type: "text",
          content: "look"
        })

      view3 = open_picker(build_conn(), three, ctx.room_x, msg_x)
      assert has_element?(view3, "#{@sheet} [data-role=mention-list]")
      refute has_element?(view3, "#{@sheet} [data-role=learned-mark]")

      view_y = open_picker(conn, one, ctx.room_y, msg_y)
      assert has_element?(view_y, "#{@sheet} [data-role=mention-list]")
      refute has_element?(view_y, "#{@sheet} [data-role=learned-mark]")
    end

    test "tapping the reason line opens 'Why this?' linking to Settings → Learned defaults",
         %{conn: conn, one: one, two: two, three: three} = ctx do
      record!(one, ctx.room_x, "user", two.id, "chosen", "none", 4)
      record!(one, ctx.room_x, "user", three.id, "chosen", "none", 3)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)

      refute has_element?(view, "#{@sheet} [data-role=learned-why]")

      view
      |> element(
        "#{@sheet} [role=option][data-principal-id='#{two.id}'] [data-role=learned-reason]"
      )
      |> render_click()

      assert has_element?(view, "#{@sheet} [data-role=learned-why]", "Why this?")

      assert has_element?(
               view,
               "#{@sheet} [data-role=learned-why] a[data-role=learned-why-link][href='/settings?sheet=learned_defaults']"
             )

      # It is not a pick.
      assert attention_rows(msg.id) == []
      # One plain sentence: no count and no percentage.
      why = view |> text("#{@sheet} [data-role=learned-why]") |> String.replace(two.name, "")
      refute why =~ ~r/\d/

      view
      |> element(
        "#{@sheet} [role=option][data-principal-id='#{two.id}'] [data-role=learned-reason]"
      )
      |> render_click()

      refute has_element?(view, "#{@sheet} [data-role=learned-why]")
    end
  end

  # ── Rung 2 ────────────────────────────────────────────────────────────────

  describe "rung 2, pre-filled" do
    test "the pre-selected card, the confirm in primary, 'Not <name>' and the search below",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, "user", two.id, "chosen", "none", 4)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)

      assert has_element?(
               view,
               "#{@sheet} [data-role=message-attention-picker][data-rung=prefill]"
             )

      assert has_element?(view, "#{@sheet} [data-role=learned-prefill-row]", two.name)

      assert has_element?(
               view,
               "#{@sheet} [data-role=learned-prefill-row] [data-role=learned-reason]",
               "You usually ask #{two.name} here"
             )

      assert has_element?(
               view,
               "#{@sheet} [data-role=learned-prefill-confirm].bg-primary.text-primary-content",
               "Get #{two.name}'s attention"
             )

      assert has_element?(
               view,
               "#{@sheet} [data-role=learned-prefill-decline]",
               "Not #{two.name}"
             )

      assert has_element?(
               view,
               "#{@sheet} [data-role=message-attention-search][placeholder='Search for someone else…']"
             )

      # The pre-filled person is in the card, not again in the list below.
      refute two.name in sheet_rows(view)
      refute text(view, @sheet) =~ ~r/\d+\s*%/
    end

    test "confirm asks the pre-filled person and records an accepted pre-fill",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, "user", two.id, "chosen", "none", 4)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)

      view |> element("#{@sheet} [data-role=learned-prefill-confirm]") |> render_click()
      drain()

      assert [_] = attention_rows(msg.id)
      refute has_element?(view, @sheet)

      assert Repo.exists?(
               from(s in Signal,
                 where:
                   s.actor_user_id == ^one.id and s.target_id == ^two.id and
                     s.outcome == "accepted" and s.rung == "prefill"
               )
             )
    end

    test "'Not <name>' clears the pre-fill, writes one override and goes back to rung 1",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, "user", two.id, "chosen", "none", 4)
      msg = post!(ctx.room_x, ctx.agent_p_x, "look here")
      view = open_picker(conn, one, ctx.room_x, msg)

      view |> element("#{@sheet} [data-role=learned-prefill-decline]") |> render_click()

      refute has_element?(view, "#{@sheet} [data-role=learned-prefill]")
      assert has_element?(view, "#{@sheet} [data-role=message-attention-picker][data-rung=rank]")

      assert has_element?(
               view,
               "#{@sheet} [data-role=message-attention-search][placeholder='Search agents and people']"
             )

      assert hd(sheet_rows(view)) == two.name

      assert Repo.aggregate(
               from(s in Signal,
                 where: s.actor_user_id == ^one.id and s.outcome == "overridden"
               ),
               :count
             ) == 1
    end
  end

  # ── Rung 3 ────────────────────────────────────────────────────────────────

  describe "rung 3, the acted-for-you notice" do
    test "shown under the message with Undo and the ··· menu; persistent, no flash, no success colour",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, "user", two.id, "accepted", "prefill", 5)
      view = live_as(conn, one, ctx.room_x)

      msg = post!(ctx.room_x, ctx.one_p_x, "status update")
      drain()

      sel = "#messages-#{msg.id} #{@notice_sel}[data-state=shown]"
      assert has_element?(view, sel, "Asked #{two.name} for attention, as you usually do here.")
      assert has_element?(view, "#{sel} [data-role=learned-mark].text-info", "✦")
      assert has_element?(view, "#{sel} [data-role=learned-notice-undo].bg-primary", "Undo")
      assert has_element?(view, "#{sel} [data-role=learned-notice-menu-toggle]", "···")

      assert has_element?(
               view,
               "#{sel} [data-role=learned-notice-menu] [data-role=learned-notice-stop]",
               "Stop doing this automatically"
             )

      assert has_element?(
               view,
               "#{sel} [data-role=learned-notice-menu] a[data-role=learned-notice-menu-settings][href='/settings?sheet=learned_defaults']"
             )

      # Never a toast.
      refute Enum.any?(Map.values(flash(view)), &(is_binary(&1) and &1 =~ "Asked"))

      notice = view |> element(sel) |> render()
      refute notice =~ ~r/\b(bg|text|border|ring)-success\b/
      refute text(view, sel) =~ ~r/\d+\s*%/

      # It survives a reload: a fresh mount renders it from data.
      reloaded = live_as(build_conn(), one, ctx.room_x)
      assert has_element?(reloaded, sel)

      # Only the author's habits act, so only the author sees it.
      other = live_as(build_conn(), two, ctx.room_x)
      assert has_element?(other, "#messages-#{msg.id}")
      refute has_element?(other, "#messages-#{msg.id} #{@notice_sel}")
    end

    test "Undo withdraws the ask and the notice turns quiet; the next post does not act",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, "user", two.id, "accepted", "prefill", 5)
      msg = post!(ctx.room_x, ctx.one_p_x, "status update")
      drain()
      view = live_as(conn, one, ctx.room_x)

      view
      |> element("#messages-#{msg.id} [data-role=learned-notice-undo]")
      |> render_click()

      sel = "#messages-#{msg.id} #{@notice_sel}[data-state=undone]"
      assert has_element?(view, sel, "Undone. #{two.name} isn’t asked on this message.")
      refute has_element?(view, "#{sel} [data-role=learned-notice-undo]")
      assert has_element?(view, "#{sel} [data-role=learned-notice-ask]", "Ask someone")
      assert attention_rows(msg.id) == []
      refute has_element?(view, "#messages-#{msg.id} [data-role=message-attention]")

      next = post!(ctx.room_x, ctx.one_p_x, "another")
      drain()
      assert has_element?(view, "#messages-#{next.id}")
      refute has_element?(view, "#messages-#{next.id} #{@notice_sel}")
    end

    test "Stop confirms inline, keeps Undo, and the next post does not act",
         %{conn: conn, one: one, two: two} = ctx do
      record!(one, ctx.room_x, "user", two.id, "accepted", "prefill", 5)
      msg = post!(ctx.room_x, ctx.one_p_x, "status update")
      drain()
      view = live_as(conn, one, ctx.room_x)

      view
      |> element("#messages-#{msg.id} [data-role=learned-notice-stop]")
      |> render_click()

      sel = "#messages-#{msg.id} #{@notice_sel}[data-state=stopped]"

      assert has_element?(
               view,
               "#{sel} [data-role=learned-notice-confirm]",
               "Got it. Won’t ask #{two.name} for you here again."
             )

      assert has_element?(view, "#{sel} [data-role=learned-notice-undo]", "Undo")
      assert [_] = attention_rows(msg.id)

      next = post!(ctx.room_x, ctx.one_p_x, "another")
      drain()
      assert has_element?(view, "#messages-#{next.id}")
      refute has_element?(view, "#messages-#{next.id} #{@notice_sel}")
      assert attention_rows(next.id) == []
    end

    test "an agent target never acts, so no notice",
         %{conn: conn, one: one, agent: agent} = ctx do
      record!(one, ctx.room_x, "agent", agent.id, "accepted", "prefill", 5)
      msg = post!(ctx.room_x, ctx.one_p_x, "status update")
      view = live_as(conn, one, ctx.room_x)

      assert has_element?(view, "#messages-#{msg.id}")
      refute has_element?(view, "#messages-#{msg.id} #{@notice_sel}")
    end
  end
end
