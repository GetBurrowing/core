defmodule PlatformWeb.ChatLiveMainReplyTest do
  @moduledoc """
  Starting a MAIN-LOG reply to an agent's message (task 01a174f5 stage 2):
  the tap pill's Reply on an agent's top-level message, the actions sheet's
  'Reply' row above 'Reply in thread', the composer's 'Replying to <author>'
  chip (`ReplyHooks`, `Partials.Composer.reply_chip/1`), and the send path
  carrying stage 1's `:reply_to_message_id`.

  Named mutations this file is meant to kill:

    * M10 the agent-message pill reverted to `open_inline_thread`;
    * M11 `send_message` drops `reply_to_message_id`;
    * M12 Reply offered on human or thread messages (markup or server);
    * M13 the target kept across a space switch.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "main_reply_#{n}@example.com",
        name: "Member",
        oidc_sub: "oidc-main-reply-#{n}",
        avatar_url: nil
      })

    space = channel("Reply #{n}", "reply-#{n}")
    viewer = add_user(space, user)
    agent = add_agent(space, "Agent A #{n}")

    {:ok,
     conn: init_test_session(conn, current_user_id: user.id),
     user: user,
     space: space,
     viewer: viewer,
     agent: agent}
  end

  defp channel(name, slug) do
    {:ok, space} = Chat.create_space(%{name: name, slug: slug, kind: "channel"})
    space
  end

  defp add_user(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp add_agent(space, name) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "main-reply-agent-#{n}",
        name: name,
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp post_msg(space, participant, content, extra \\ %{}) do
    {:ok, msg} =
      Chat.post_message(
        Map.merge(
          %{
            space_id: space.id,
            participant_id: participant.id,
            content_type: "text",
            content: content
          },
          extra
        )
      )

    msg
  end

  defp open_chat(conn, space) do
    {:ok, view, _html} = live(conn, "/chat/#{space.slug}")
    view
  end

  defp pill_reply(msg), do: ~s([data-message-id="#{msg.id}"] [data-role="message-pill-reply"])
  defp pill_thread(msg), do: ~s([data-message-id="#{msg.id}"] [data-role="message-pill-thread"])

  defp open_sheet(view, msg) do
    view
    |> element(
      ~s([data-message-id="#{msg.id}"] [data-role="message-pill"] button[aria-label="More actions"])
    )
    |> render_click()
  end

  defp chip_text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#compose-reply-chip " <> selector)
    |> LazyHTML.text()
  end

  defp reply_target(view), do: :sys.get_state(view.pid).socket.assigns.reply_target

  describe "the tap pill" do
    test "tapping Reply on an agent message sets the composer chip and creates no thread", %{
      conn: conn,
      space: space,
      agent: agent
    } do
      a = post_msg(space, agent, "The viewer fix is in review.")
      view = open_chat(conn, space)

      refute has_element?(view, "#compose-reply-chip")
      assert has_element?(view, pill_reply(a) <> ~s([aria-label="Reply"][title="Reply"]))
      refute has_element?(view, pill_thread(a))

      view |> element(pill_reply(a)) |> render_click()

      assert has_element?(view, ~s(#compose-reply-chip[data-reply-to="#{a.id}"]))
      assert chip_text(view, ~s([data-role="compose-reply-author"])) =~ "Agent A"

      assert chip_text(view, ~s([data-role="compose-reply-preview"])) =~
               "The viewer fix is in review."

      assert has_element?(
               view,
               ~s(#compose-reply-chip button[data-role="compose-reply-cancel"][aria-label="Cancel reply"])
             )

      # No thread: no row, and no inline thread opened.
      assert Chat.get_thread_for_message(a.id) == nil
      refute MapSet.member?(:sys.get_state(view.pid).socket.assigns.expanded_threads, a.id)
    end

    test "a human message keeps Reply in thread on the pill and offers no Reply", %{
      conn: conn,
      space: space,
      viewer: viewer
    } do
      h = post_msg(space, viewer, "Is it going out this week?")
      view = open_chat(conn, space)

      assert has_element?(view, pill_thread(h) <> ~s([aria-label="Reply in thread"]))
      refute has_element?(view, pill_reply(h))
    end
  end

  describe "the actions sheet" do
    test "an agent message gets a Reply row above Reply in thread, and it sets the chip", %{
      conn: conn,
      space: space,
      agent: agent
    } do
      a = post_msg(space, agent, "Agent text.")
      view = open_chat(conn, space)
      html = open_sheet(view, a)

      roles =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s(#message-actions-sheet [data-role="message-actions-rows"] > button))
        |> LazyHTML.attribute("data-role")

      assert Enum.take(roles, 2) == ["message-actions-main-reply", "message-actions-reply"]

      view
      |> element(~s(#message-actions-sheet [data-role="message-actions-main-reply"]))
      |> render_click()

      assert has_element?(view, ~s(#compose-reply-chip[data-reply-to="#{a.id}"]))
      assert Chat.get_thread_for_message(a.id) == nil
    end

    test "a human message's sheet has no Reply row", %{
      conn: conn,
      space: space,
      viewer: viewer
    } do
      h = post_msg(space, viewer, "Human text.")
      view = open_chat(conn, space)
      open_sheet(view, h)

      assert has_element?(view, ~s(#message-actions-sheet [data-role="message-actions-reply"]))

      refute has_element?(
               view,
               ~s(#message-actions-sheet [data-role="message-actions-main-reply"])
             )
    end

    test "Reply in thread from the sheet still opens the inline thread", %{
      conn: conn,
      space: space,
      agent: agent
    } do
      a = post_msg(space, agent, "Agent text.")
      view = open_chat(conn, space)
      open_sheet(view, a)

      view
      |> element(~s(#message-actions-sheet [data-role="message-actions-reply"]))
      |> render_click()

      assert %{} = Chat.get_thread_for_message(a.id)
      assert MapSet.member?(:sys.get_state(view.pid).socket.assigns.expanded_threads, a.id)
      refute has_element?(view, "#compose-reply-chip")
    end
  end

  describe "sending" do
    test "the sent message is top-level with metadata reply_to_message_id = the agent message",
         %{conn: conn, space: space, agent: agent, viewer: viewer} do
      a = post_msg(space, agent, "The viewer fix is in review.")
      view = open_chat(conn, space)
      view |> element(pill_reply(a)) |> render_click()

      view |> form("#compose-form", compose: %{text: "When does it ship?"}) |> render_submit()

      [sent] =
        space.id
        |> Chat.list_messages(top_level_only: true)
        |> Enum.filter(&(&1.participant_id == viewer.id))

      assert sent.content == "When does it ship?"
      assert sent.thread_id == nil
      assert sent.metadata["reply_to_message_id"] == a.id
      assert Chat.get_thread_for_message(a.id) == nil

      # A successful send clears the chip, and the next send is plain.
      refute has_element?(view, "#compose-reply-chip")
      assert reply_target(view) == nil
    end

    test "with no reply target the send carries no reply_to_message_id", %{
      conn: conn,
      space: space,
      agent: agent,
      viewer: viewer
    } do
      _a = post_msg(space, agent, "Agent text.")
      view = open_chat(conn, space)
      view |> form("#compose-form", compose: %{text: "plain"}) |> render_submit()

      [sent] =
        space.id
        |> Chat.list_messages(top_level_only: true)
        |> Enum.filter(&(&1.participant_id == viewer.id))

      refute Map.has_key?(sent.metadata || %{}, "reply_to_message_id")
    end
  end

  describe "refusals" do
    test "start_reply on a human message is refused", %{conn: conn, space: space, viewer: viewer} do
      h = post_msg(space, viewer, "Human text.")
      view = open_chat(conn, space)

      render_click(view, "start_reply", %{"message-id" => h.id})

      refute has_element?(view, "#compose-reply-chip")
      assert reply_target(view) == nil
    end

    test "start_reply on a thread message is refused, and a thread reply has no Reply row", %{
      conn: conn,
      space: space,
      agent: agent,
      viewer: viewer
    } do
      parent = post_msg(space, viewer, "Parent.")
      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: parent.id})
      in_thread = post_msg(space, agent, "Agent in thread.", %{thread_id: thread.id})

      view = open_chat(conn, space)
      render_click(view, "start_reply", %{"message-id" => in_thread.id})

      refute has_element?(view, "#compose-reply-chip")
      assert reply_target(view) == nil

      open_sheet_html = render_click(view, "open_message_actions", %{"id" => in_thread.id})

      assert open_sheet_html
             |> LazyHTML.from_document()
             |> LazyHTML.query(~s([data-role="message-actions-main-reply"]))
             |> Enum.empty?()
    end

    test "a forged start_reply for another space's agent message is refused", %{
      conn: conn,
      space: space
    } do
      other =
        channel(
          "Other #{System.unique_integer([:positive])}",
          "other-#{System.unique_integer([:positive])}"
        )

      other_agent = add_agent(other, "Agent B")
      foreign = post_msg(other, other_agent, "Elsewhere.")

      view = open_chat(conn, space)
      render_click(view, "start_reply", %{"message-id" => foreign.id})

      refute has_element?(view, "#compose-reply-chip")
      assert reply_target(view) == nil
    end

    test "a deleted agent message and a malformed id are refused", %{
      conn: conn,
      space: space,
      agent: agent
    } do
      a = post_msg(space, agent, "Soon gone.")
      view = open_chat(conn, space)
      {:ok, _} = Chat.delete_message(a)

      render_click(view, "start_reply", %{"message-id" => a.id})
      render_click(view, "start_reply", %{"message-id" => "not-a-uuid"})
      render_click(view, "start_reply", %{})

      assert reply_target(view) == nil
    end
  end

  describe "clearing" do
    test "the x cancels the reply", %{conn: conn, space: space, agent: agent} do
      a = post_msg(space, agent, "Agent text.")
      view = open_chat(conn, space)
      view |> element(pill_reply(a)) |> render_click()
      assert has_element?(view, "#compose-reply-chip")

      view |> element(~s([data-role="compose-reply-cancel"])) |> render_click()

      refute has_element?(view, "#compose-reply-chip")
      assert reply_target(view) == nil
    end

    test "Escape cancels the reply", %{conn: conn, space: space, agent: agent} do
      a = post_msg(space, agent, "Agent text.")
      view = open_chat(conn, space)
      view |> element(pill_reply(a)) |> render_click()

      assert has_element?(
               view,
               ~s(#compose-reply-chip[phx-window-keydown="cancel_reply"][phx-key="Escape"])
             )

      view |> element("#compose-reply-chip") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#compose-reply-chip")
    end

    test "switching space drops the target; coming back shows no chip", %{
      conn: conn,
      space: space,
      agent: agent,
      user: user
    } do
      other =
        channel(
          "Second #{System.unique_integer([:positive])}",
          "second-#{System.unique_integer([:positive])}"
        )

      add_user(other, user)

      a = post_msg(space, agent, "Agent text.")
      view = open_chat(conn, space)
      view |> element(pill_reply(a)) |> render_click()
      assert has_element?(view, "#compose-reply-chip")

      render_patch(view, "/chat/#{other.slug}")
      refute has_element?(view, "#compose-reply-chip")
      assert reply_target(view) == nil

      render_patch(view, "/chat/#{space.slug}")
      refute has_element?(view, "#compose-reply-chip")
      assert reply_target(view) == nil
    end
  end
end
