defmodule PlatformWeb.PageControllerTest do
  use PlatformWeb.ConnCase
  import Phoenix.LiveViewTest

  test "GET / renders the chat surface", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Core Chat"

    html =
      view
      |> form("#chat-form", chat: %{message: "hello"})
      |> render_submit()

    assert html =~ "hello"
    assert html =~ "Message received locally"
  end
end
