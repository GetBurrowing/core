defmodule PlatformWeb.ChatLiveGameStreamInlineTest do
  @moduledoc """
  A Play canvas posted in chat never opens the canvas sidebar from its inline
  card, and the user's own path (canvas selector, then an explorer row) still
  opens it (task 01a0ee4f stage 1). Alex, 2026-09-29: *"we need to ensure that
  it never opens that sidebar, but also, if i were to engage the sidebar
  myself, by going through the canvas selector in the chat shell ... that that
  is where we connect."*

  NOT async: toggles `:game_stream, :enabled` (global app env).
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Repo

  @sha "0123456789abcdef0123456789abcdef01234567"

  setup do
    previous = Application.get_env(:game_stream, :enabled)
    Application.put_env(:game_stream, :enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:game_stream, :enabled),
        else: Application.put_env(:game_stream, :enabled, previous)
    end)

    :ok
  end

  defp document(children) do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{"id" => "root", "type" => "stack", "props" => %{}, "children" => children},
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  defp play_doc do
    document([
      %{
        "id" => "game-stream",
        "type" => "game_stream",
        "props" => %{"review_sha" => @sha, "title" => "Review build"}
      }
    ])
  end

  defp markdown_doc,
    do: document([%{"id" => "md", "type" => "markdown", "props" => %{"content" => "Notes"}}])

  defp inline_wrapper(view, canvas_id),
    do: element(view, "#canvas-doc-#{canvas_id}-chat-message-inline-inline")

  test "the Play card's inline wrapper has no canvas_open; markdown's does; the explorer row opens Play",
       %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "gs_inline_#{System.unique_integer([:positive])}@example.com",
        name: "Play Tester",
        oidc_sub: "gs-inline-#{System.unique_integer([:positive])}"
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/chat/general", on_error: :warn)

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

    {:ok, play, _} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        "title" => "Review build",
        "document" => play_doc()
      })

    {:ok, notes, _} =
      Chat.create_canvas_with_message(space.id, participant.id, %{
        "title" => "Notes",
        "document" => markdown_doc()
      })

    render(view)

    play_html = view |> inline_wrapper(play.id) |> render()
    notes_html = view |> inline_wrapper(notes.id) |> render()

    # The Play node really rendered inline (not the unknown-kind fallback).
    assert play_html =~ ~s(phx-hook="GameStream")
    [play_tag] = Regex.run(~r/\A<div[^>]*>/, play_html)
    refute play_tag =~ "phx-click"
    refute play_tag =~ "cursor-pointer"
    refute play_tag =~ "phx-value-canvas-id"

    [notes_tag] = Regex.run(~r/\A<div[^>]*>/, notes_html)
    assert notes_tag =~ ~s(phx-click="canvas_open")
    assert notes_tag =~ ~s(phx-value-canvas-id="#{notes.id}")
    assert notes_tag =~ "cursor-pointer"

    # Nothing is open yet: posting the Play canvas did not open the sidebar.
    refute has_element?(view, "#canvas-sidebar")

    # The user's own path: the header's canvas selector, then the Play row.
    render_click(view, "canvas_panel_toggle", %{})

    view
    |> element(~s([data-role="canvas-explorer-row"][data-canvas-id="#{play.id}"]))
    |> render_click()

    assert has_element?(view, "#canvas-sidebar")

    assert has_element?(
             view,
             "#canvas-sidebar #canvas-doc-#{play.id}-chat-live-canvas-panel-expanded"
           )
  end
end
