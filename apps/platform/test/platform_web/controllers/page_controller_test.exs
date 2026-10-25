defmodule PlatformWeb.PageControllerTest do
  use PlatformWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo

  test "GET / redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET / redirects authenticated users to /chat", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "user@example.com",
        name: "Test User",
        oidc_sub: "oidc-subject"
      })

    conn = init_test_session(conn, current_user_id: user.id)
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/chat"
  end

  test "GET /chat renders the chat surface for authenticated users", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "user@example.com",
        name: "Test User",
        oidc_sub: "oidc-subject"
      })

    conn = init_test_session(conn, current_user_id: user.id)

    {:ok, view, html} = live(conn, ~p"/chat")

    # Shell layout and the Chat list should be present (Burrow redesign 22
    # stage 2 deleted the desktop channel rail; the Chat list replaces it).
    # The shell brand is the install's app name, "Burrow" on a migrated DB
    # (task 01a120c5 stage 3).
    assert html =~ "Burrow"
    assert has_element?(view, ~s(section#chat-list[aria-label="Chat"]))
  end
end
