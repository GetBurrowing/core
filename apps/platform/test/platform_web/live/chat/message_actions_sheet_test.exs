defmodule PlatformWeb.ChatLive.MessageActionsSheetTest do
  @moduledoc """
  The per-message actions surface (redesign rung 9 stage 2, task
  01a1557a-9406): the phone 'Message' sheet and the desktop ⋯ popover, both
  rendered from `:open_message_actions_id` by
  `PlatformWeb.ChatLive.Partials.Overlays.message_actions_sheet/1`, with
  their events in `PlatformWeb.ChatLive.MessageActionsHooks`.

  Masters canvas 01a1382f node `proto` (MM `stubMessageActions`, MD
  `messageActions`): the preview, the quick strip (👍 🔥 ❤️ 😂 👀 ✅ + ＋),
  Reply in thread, What this is answering (agent only), Pin message, Copy
  text, Copy link, Edit and Delete (own only).
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Emoji
  alias Platform.Chat.Message
  alias Platform.Repo

  @own_rows [
    "Reply in thread",
    "Get someone's attention",
    "Pin message",
    "Copy text",
    "Copy link",
    "Edit",
    "Delete"
  ]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "actions_#{n}@example.com",
        name: "Actions Viewer",
        oidc_sub: "oidc-actions-#{n}",
        avatar_url: nil
      })

    {:ok, space} =
      Chat.create_space(%{name: "Actions #{n}", slug: "actions-#{n}", kind: "channel"})

    {:ok, viewer} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, other} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Other Person #{n}",
        joined_at: DateTime.utc_now()
      })

    agent_row =
      Repo.insert!(%Agent{
        slug: "actions-agent-#{n}",
        name: "Actions Agent #{n}",
        status: "active",
        model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
      })

    {:ok, agent} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_row.id,
        display_name: agent_row.name,
        joined_at: DateTime.utc_now()
      })

    {:ok,
     conn: init_test_session(conn, current_user_id: user.id),
     space: space,
     viewer: viewer,
     other: other,
     agent: agent}
  end

  defp post_msg(space, participant, content, metadata \\ %{}) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content,
        metadata: metadata
      })

    msg
  end

  defp open_chat(conn, space) do
    {:ok, view, _html} = live(conn, "/chat/#{space.slug}")
    view
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_document()

  defp labels(view, frame) do
    view
    |> doc()
    |> LazyHTML.query(~s(#{frame} [data-role="message-actions-label"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp strip(view, frame) do
    view
    |> doc()
    |> LazyHTML.query(
      ~s(#{frame} [role="group"][aria-label="Quick reactions"] button[phx-value-emoji])
    )
    |> Enum.map(&(&1 |> LazyHTML.attribute("phx-value-emoji") |> hd()))
  end

  describe "rows" do
    test "an own human text message: the sheet and the popover, rows in the masters' order",
         %{conn: conn, space: space, viewer: viewer} do
      msg = post_msg(space, viewer, "my own line")
      view = open_chat(conn, space)

      refute has_element?(view, "#message-actions-sheet")
      render_click(view, "open_message_actions", %{"id" => msg.id})

      assert has_element?(view, ~s(#message-actions-sheet[data-swipe-dismiss="true"]))
      assert has_element?(view, "#message-actions-sheet .sheet-handle-button")
      assert has_element?(view, "#message-actions-sheet.lg\\:hidden")
      assert has_element?(view, ~s(#message-actions-sheet p[aria-hidden="true"]), "Message")
      assert has_element?(view, "#message-actions-popover.hidden.lg\\:block")

      assert has_element?(
               view,
               ~s(#message-actions-popover[phx-click-away="close_message_actions"])
             )

      refute has_element?(view, ~s(#message-actions-sheet[phx-click-away]))

      assert labels(view, "#message-actions-sheet") == @own_rows
      assert labels(view, "#message-actions-popover") == @own_rows

      refute render(view) =~ "What this is answering"

      assert has_element?(
               view,
               ~s(#message-actions-sheet [data-role="message-actions-preview"]),
               "my own line"
             )
    end

    test "an agent message offers What this is answering and no Edit or Delete",
         %{conn: conn, space: space, agent: agent} do
      msg = post_msg(space, agent, "agent reply", %{"reply_context" => "the ask"})
      view = open_chat(conn, space)
      render_click(view, "open_message_actions", %{"id" => msg.id})

      rows = labels(view, "#message-actions-sheet")

      # 'Reply' (a main-log reply, task 01a174f5 stage 2) heads an agent's
      # top-level message, above Reply in thread.
      assert rows == [
               "Reply",
               "Reply in thread",
               "Get someone's attention",
               "What this is answering",
               "Pin message",
               "Copy text",
               "Copy link"
             ]

      assert has_element?(
               view,
               ~s(#message-actions-sheet [data-role="message-actions-context"]),
               "context · summarise what led here"
             )

      refute has_element?(view, ~s([data-role="message-actions-edit"]))
      refute has_element?(view, ~s([data-role="message-actions-delete"]))
    end

    test "another human's message offers no Edit or Delete",
         %{conn: conn, space: space, other: other} do
      msg = post_msg(space, other, "their line")
      view = open_chat(conn, space)
      render_click(view, "open_message_actions", %{"id" => msg.id})

      assert labels(view, "#message-actions-sheet") ==
               [
                 "Reply in thread",
                 "Get someone's attention",
                 "Pin message",
                 "Copy text",
                 "Copy link"
               ]

      refute has_element?(view, ~s([data-role="message-actions-edit"]))
      refute has_element?(view, ~s([data-role="message-actions-delete"]))
    end
  end

  describe "the quick strip" do
    test "its order is Emoji.quick_defaults/0 in both frames, then the picker control",
         %{conn: conn, space: space, other: other} do
      msg = post_msg(space, other, "react to me")
      view = open_chat(conn, space)
      render_click(view, "open_message_actions", %{"id" => msg.id})

      assert strip(view, "#message-actions-sheet") == Emoji.quick_defaults()
      assert strip(view, "#message-actions-popover") == Emoji.quick_defaults()

      for emoji <- Emoji.quick_defaults() do
        assert has_element?(
                 view,
                 ~s(#message-actions-sheet button[aria-label="React with #{Emoji.quick_name(emoji)}"])
               )
      end

      assert has_element?(
               view,
               ~s(#message-actions-quick-reactions #message-actions-more-reactions[aria-label="More reactions"])
             )
    end

    test "the viewer's own reaction shows as 'mine': neutral, never primary",
         %{conn: conn, space: space, other: other} do
      msg = post_msg(space, other, "react to me")
      view = open_chat(conn, space)
      render_click(view, "react", %{"message-id" => msg.id, "emoji" => "\u{1F525}"})
      render_click(view, "open_message_actions", %{"id" => msg.id})

      fire = ~s(#message-actions-sheet button[phx-value-emoji="\u{1F525}"])
      assert has_element?(view, fire <> ~s([data-mine="true"][aria-pressed="true"]))
      assert has_element?(view, fire <> ".bg-base-300.ring-1.ring-base-content")

      thumbs = ~s(#message-actions-sheet button[phx-value-emoji="\u{1F44D}"])
      assert has_element?(view, thumbs <> ~s([aria-pressed="false"]))
      assert has_element?(view, thumbs <> ".bg-base-200")

      classes =
        view
        |> doc()
        |> LazyHTML.query("#message-actions-sheet #message-actions-quick-reactions button")
        |> Enum.flat_map(&LazyHTML.attribute(&1, "class"))

      assert length(classes) == 7
      refute Enum.any?(classes, &(&1 =~ "primary"))
    end
  end

  describe "Copy link" do
    test "carries the absolute deep link, and that link anchors the message",
         %{conn: conn, space: space, other: other} do
      msg = post_msg(space, other, "link to me")
      view = open_chat(conn, space)
      render_click(view, "open_message_actions", %{"id" => msg.id})

      [link] =
        view
        |> doc()
        |> LazyHTML.query(~s(#message-actions-sheet [data-role="message-actions-copy-link"]))
        |> LazyHTML.attribute("data-clipboard-text")

      path = "/chat/#{Chat.space_path_segment(space)}?message=#{msg.id}"
      assert String.ends_with?(link, path)
      assert link == PlatformWeb.Endpoint.url() <> path
      assert %URI{scheme: scheme, host: host} = URI.parse(link)
      assert scheme in ["http", "https"] and is_binary(host)

      assert has_element?(
               view,
               ~s(#message-actions-sheet [data-role="message-actions-copy-link"][data-copy-toast="Link copied"])
             )

      assert has_element?(
               view,
               ~s(#message-actions-sheet [data-role="message-actions-copy-text"][data-copy-toast="Copied"][data-clipboard-text="link to me"])
             )

      {:ok, linked, _html} = live(conn, path)
      assert :sys.get_state(linked.pid).socket.assigns.anchor_message_id == msg.id
    end
  end

  describe "Pin message" do
    test "the row persists a pin, and then reads Unpin message",
         %{conn: conn, space: space, other: other} do
      msg = post_msg(space, other, "pin me")
      view = open_chat(conn, space)
      render_click(view, "open_message_actions", %{"id" => msg.id})

      view |> element("#message-actions-pin") |> render_click()

      assert msg.id in Enum.map(Chat.list_pins(space.id), & &1.message_id)
      refute has_element?(view, "#message-actions-sheet")

      render_click(view, "open_message_actions", %{"id" => msg.id})
      assert has_element?(view, "#message-actions-pin", "Unpin message")
    end
  end

  describe "Delete" do
    test "deletes an own message: deleted_at is set and the row leaves the stream",
         %{conn: conn, space: space, viewer: viewer} do
      msg = post_msg(space, viewer, "delete me")
      view = open_chat(conn, space)
      assert has_element?(view, ~s([data-message-id="#{msg.id}"][phx-hook="MessageGestures"]))

      render_click(view, "open_message_actions", %{"id" => msg.id})

      assert has_element?(
               view,
               ~s(#message-actions-sheet [data-role="message-actions-delete"][data-confirm="Delete this message?"])
             )

      view
      |> element(~s(#message-actions-sheet [data-role="message-actions-delete"]))
      |> render_click()

      assert %Message{deleted_at: %DateTime{}} = Repo.get(Message, msg.id)
      refute has_element?(view, ~s([data-message-id="#{msg.id}"][phx-hook="MessageGestures"]))
      refute has_element?(view, "#message-actions-sheet")
    end

    test "a forged delete of someone else's message is refused by the server",
         %{conn: conn, space: space, other: other, agent: agent} do
      theirs = post_msg(space, other, "not yours")
      agents = post_msg(space, agent, "not yours either")
      view = open_chat(conn, space)

      render_hook(view, "delete_message", %{"message-id" => theirs.id})
      render_hook(view, "delete_message", %{"message-id" => agents.id})
      render_hook(view, "delete_message", %{"message-id" => Ecto.UUID.generate()})
      render_hook(view, "delete_message", %{})

      assert %Message{deleted_at: nil} = Repo.get(Message, theirs.id)
      assert %Message{deleted_at: nil} = Repo.get(Message, agents.id)
      assert has_element?(view, ~s([data-message-id="#{theirs.id}"][phx-hook="MessageGestures"]))
    end

    test "an own message in a space the viewer is not looking at is refused",
         %{conn: conn, space: space, viewer: viewer} do
      {:ok, elsewhere} =
        Chat.create_space(%{name: "Elsewhere", slug: "elsewhere-#{viewer.id}", kind: "channel"})

      {:ok, me_there} =
        Chat.add_participant(elsewhere.id, %{
          participant_type: "user",
          participant_id: viewer.participant_id,
          display_name: viewer.display_name,
          joined_at: DateTime.utc_now()
        })

      mine_elsewhere = post_msg(elsewhere, me_there, "mine, elsewhere")
      view = open_chat(conn, space)

      render_hook(view, "delete_message", %{"message-id" => mine_elsewhere.id})

      assert %Message{deleted_at: nil} = Repo.get(Message, mine_elsewhere.id)
    end
  end

  describe "palette" do
    test "no hover: outside lg:hover:, no text-error, and red only as the Delete icon's fill",
         %{conn: conn, space: space, viewer: viewer, agent: agent} do
      own = post_msg(space, viewer, "own")
      theirs = post_msg(space, agent, "agent")
      view = open_chat(conn, space)

      for msg <- [own, theirs] do
        render_click(view, "open_message_actions", %{"id" => msg.id})
        page = doc(view)

        for frame <- ["#message-actions-sheet", "#message-actions-popover"] do
          nodes = LazyHTML.query(page, "#{frame}, #{frame} *")
          assert Enum.count(nodes) > 20, "the scan saw almost nothing in #{frame}"

          classes = Enum.flat_map(nodes, &LazyHTML.attribute(&1, "class"))

          bare_hover =
            for class <- classes,
                token <- String.split(class),
                token =~ "hover:" and not String.starts_with?(token, "lg:hover:"),
                do: token

          assert bare_hover == [],
                 "#{frame} carries phone hover utilities: #{inspect(bare_hover)}"

          assert LazyHTML.query(page, ~s(#{frame} [class*="text-error"])) |> Enum.count() == 0,
                 "text-error in #{frame}"

          refute Enum.any?(classes, &(&1 =~ ~r/(?<![\w-])(bg|text|ring|border)-primary/)),
                 "#{frame} uses primary"
        end

        render_click(view, "close_message_actions", %{})
      end

      # Positive control: the Delete icon really is the one red element.
      render_click(view, "open_message_actions", %{"id" => own.id})

      assert has_element?(
               view,
               ~s(#message-actions-sheet [data-role="message-actions-delete"] .hero-trash.bg-error)
             )
    end
  end
end
