defmodule PlatformWeb.ChatLiveLazyCanvasTest do
  @moduledoc """
  Lazy-mounted inline canvases (task 01a13884 stage 4).

  A canvas message already in the space when the viewer enters renders as a
  placeholder (kind icon + title, height reserved) until the
  `LazyInlineCanvas` hook pushes `inline_canvas_mount`. The mount is honoured
  only for a canvas message of the ACTIVE space that the window holds; a
  canvas that arrives live renders mounted; `{:canvas_updated, _}` keeps
  re-rendering whichever of the two the row is in.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  setup %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "lazy_canvas@example.com",
        name: "Lazy Canvas User",
        oidc_sub: "oidc-lazy-canvas"
      })

    conn = init_test_session(conn, current_user_id: user.id)

    # The first mount creates #general; the canvases below then exist BEFORE
    # the LiveView each test opens, which is the entry path under test.
    {:ok, _view, _html} = live(conn, ~p"/chat/general", on_error: :warn)
    space = Repo.get_by!(Chat.Space, slug: "general")

    participant =
      Repo.get_by(Chat.Participant,
        space_id: space.id,
        participant_type: "user",
        participant_id: user.id
      ) ||
        elem(
          Chat.add_participant(space.id, %{participant_type: "user", participant_id: user.id}),
          1
        )

    %{conn: conn, user: user, space: space, participant: participant}
  end

  defp markdown_doc(token) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "children" => [
          %{"id" => "m1", "type" => "markdown", "props" => %{"content" => "#{token} body"}}
        ]
      }
    }
  end

  defp embed_doc(height) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "children" => [
          %{"id" => "h1", "type" => "heading", "props" => %{"value" => "Embed heading"}},
          %{
            "id" => "e1",
            "type" => "embed",
            "props" => %{"srcdoc" => "<p>EMBED_BODY_TOKEN</p>", "height" => height}
          }
        ]
      }
    }
  end

  defp canvas_message(space, participant, title, document) do
    {:ok, canvas, message} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        "title" => title,
        "document" => document
      })

    {canvas, message}
  end

  defp row(view, message), do: view |> element("#inline-canvas-#{message.id}") |> render()

  test "entering a space renders a titled placeholder, not the canvas document", %{
    conn: conn,
    space: space,
    participant: participant
  } do
    {canvas, message} =
      canvas_message(space, participant, "Lazy design pass", markdown_doc("LAZY_BODY_TOKEN"))

    {:ok, view, html} = live(conn, ~p"/chat/general", on_error: :warn)

    assert html =~ ~s(data-role="inline-canvas-placeholder")
    assert row(view, message) =~ "Lazy design pass"
    assert row(view, message) =~ "hero-document-text"
    assert row(view, message) =~ ~s(data-mounted="false")
    refute html =~ "LAZY_BODY_TOKEN"
    refute html =~ "canvas-doc-#{canvas.id}"
  end

  test "inline_canvas_mount renders that canvas's document in place of its placeholder", %{
    conn: conn,
    space: space,
    participant: participant
  } do
    {canvas, message} =
      canvas_message(space, participant, "Mount me", markdown_doc("MOUNT_BODY_TOKEN"))

    {_other_canvas, other} =
      canvas_message(space, participant, "Stay lazy", markdown_doc("LAZY_SIBLING_TOKEN"))

    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    html = render_hook(view, "inline_canvas_mount", %{"message_id" => message.id})

    assert html =~ "MOUNT_BODY_TOKEN"
    assert html =~ "canvas-doc-#{canvas.id}"
    assert row(view, message) =~ ~s(data-mounted="true")
    refute row(view, message) =~ "inline-canvas-placeholder"

    # Only the id that was pushed: its sibling stays a placeholder.
    refute html =~ "LAZY_SIBLING_TOKEN"
    assert row(view, other) =~ ~s(data-mounted="false")

    # The hook's batched form mounts several in one event.
    html = render_hook(view, "inline_canvas_mount", %{"message_ids" => [other.id]})
    assert html =~ "LAZY_SIBLING_TOKEN"
  end

  test "a mount for a message in another space is a no-op", %{
    conn: conn,
    user: user,
    space: space,
    participant: participant
  } do
    {_canvas, own} = canvas_message(space, participant, "Own", markdown_doc("OWN_TOKEN"))

    {:ok, other_space} =
      Chat.create_space(%{name: "Lazy Other", slug: "lazy-other", kind: "channel"})

    {:ok, other_participant} =
      Chat.add_participant(other_space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    {_foreign_canvas, foreign} =
      canvas_message(other_space, other_participant, "Foreign", markdown_doc("FOREIGN_TOKEN"))

    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    # Positive control first: the plumbing mounts an own-space id.
    assert render_hook(view, "inline_canvas_mount", %{"message_id" => own.id}) =~ "OWN_TOKEN"

    html = render_hook(view, "inline_canvas_mount", %{"message_id" => foreign.id})

    refute html =~ "FOREIGN_TOKEN"
    refute has_element?(view, "#inline-canvas-#{foreign.id}")

    assigns = :sys.get_state(view.pid).socket.assigns
    refute MapSet.member?(assigns.mounted_inline_canvas_ids, foreign.id)
    refute MapSet.member?(assigns.rendered_message_ids, foreign.id)
    refute Map.has_key?(assigns.msg_day_labels, foreign.id)

    # Garbage ids and a non-canvas id are dropped too.
    {:ok, text} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "plain text row"
      })

    render_hook(view, "inline_canvas_mount", %{"message_ids" => ["not-a-uuid", text.id, 7]})
    assigns = :sys.get_state(view.pid).socket.assigns
    assert MapSet.equal?(assigns.mounted_inline_canvas_ids, MapSet.new([own.id]))
  end

  test "{:canvas_updated, _} updates a mounted canvas and keeps an unmounted one a placeholder",
       %{conn: conn, space: space, participant: participant} do
    {mounted_canvas, mounted} =
      canvas_message(space, participant, "Mounted", markdown_doc("BEFORE_TOKEN"))

    {lazy_canvas, lazy} = canvas_message(space, participant, "Lazy", markdown_doc("LAZY_TOKEN"))

    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    assert render_hook(view, "inline_canvas_mount", %{"message_id" => mounted.id}) =~
             "BEFORE_TOKEN"

    {:ok, _} =
      Chat.update_canvas(:system, mounted_canvas, %{"document" => markdown_doc("AFTER_TOKEN")})

    {:ok, _} =
      Chat.update_canvas(:system, lazy_canvas, %{"document" => markdown_doc("LAZY_AFTER")})

    html = render(view)
    assert html =~ "AFTER_TOKEN"
    refute html =~ "BEFORE_TOKEN"
    refute html =~ "LAZY_AFTER"
    assert row(view, lazy) =~ ~s(data-mounted="false")
    assert row(view, mounted) =~ ~s(data-mounted="true")
  end

  test "a canvas that arrives while the space is open renders mounted", %{
    conn: conn,
    space: space,
    participant: participant
  } do
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    {_canvas, message} =
      canvas_message(space, participant, "Live arrival", markdown_doc("LIVE_ARRIVAL_TOKEN"))

    assert render(view) =~ "LIVE_ARRIVAL_TOKEN"
    assert row(view, message) =~ ~s(data-mounted="true")
  end

  test "the placeholder reserves the declared frame height; a document without one gets 240",
       %{conn: conn, space: space, participant: participant} do
    {_c1, embed} = canvas_message(space, participant, "Embed", embed_doc(480))
    {_c2, plain} = canvas_message(space, participant, "Plain", markdown_doc("PLAIN"))

    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

    # 480 frame + 40 for the heading beside it.
    assert row(view, embed) =~ "height: 520px;"
    assert row(view, embed) =~ "hero-window"
    refute row(view, embed) =~ "<iframe"
    assert row(view, plain) =~ "height: 240px;"

    html = render_hook(view, "inline_canvas_mount", %{"message_id" => embed.id})
    assert html =~ "<iframe"
  end

  test "a failed older-message load shows the retry line; a retry that succeeds clears it", %{
    conn: conn,
    space: space,
    participant: participant
  } do
    for i <- 1..55 do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: participant.id,
          content_type: "text",
          content: "history #{i}"
        })
    end

    {:ok, view, html} = live(conn, ~p"/chat/general", on_error: :warn)
    assert html =~ "Loading earlier messages"
    refute has_element?(view, "#chat-scroll-sentinel-top .animate-spin")
    refute has_element?(view, "#message-list p", ~r/^history 1$/)

    cursor = :sys.get_state(view.pid).socket.assigns.earliest_message_id

    # A malformed cursor makes `Chat.list_messages/2` raise Ecto.Query.CastError.
    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.earliest_message_id, "not-a-uuid")
    end)

    html = render_hook(view, "load_older_messages", %{})
    assert html =~ "Couldn&#39;t load earlier messages. Retry"
    assert has_element?(view, ~s([data-role="load-older-retry"]))
    assert has_element?(view, ~s(#chat-scroll-sentinel-top[data-failed="true"]))
    assert Process.alive?(view.pid)

    :sys.replace_state(view.pid, fn state ->
      put_in(state.socket.assigns.earliest_message_id, cursor)
    end)

    html = render_hook(view, "load_older_messages", %{})
    refute html =~ "Couldn&#39;t load earlier messages"
    assert has_element?(view, "#message-list p", ~r/^history 1$/)
  end
end
