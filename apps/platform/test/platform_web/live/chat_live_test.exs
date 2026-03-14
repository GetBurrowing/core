defmodule PlatformWeb.ChatLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "chat_test@example.com",
        name: "Chat Test User",
        oidc_sub: "oidc-chat-test"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  test "GET /chat redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/chat")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /chat renders chat surface for authenticated users", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/chat")

    # Shell layout and channel sidebar should be present
    assert html =~ "Channels"
    assert html =~ "Startup Suite"
  end

  test "shell sidebar is rendered on /chat", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/chat")

    # Shell nav and top bar present
    assert html =~ "Startup Suite"
    assert html =~ "/chat"
    assert html =~ "/control"
  end

  test "sending a message renders it in the chat", %{conn: conn} do
    conn = authenticated_conn(conn)
    # Navigate to a specific space (auto-created via bootstrap_space/1)
    {:ok, view, _html} = live(conn, ~p"/chat/general")

    html =
      view
      |> form("#compose-form", compose: %{text: "hello from test"})
      |> render_submit()

    assert html =~ "hello from test"
  end
end
