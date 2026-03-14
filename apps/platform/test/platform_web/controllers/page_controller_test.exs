defmodule PlatformWeb.PageControllerTest do
  use PlatformWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo

  test "GET / redirects unauthenticated users to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/")
  end

  test "GET / renders the chat surface for authenticated users", %{conn: conn} do
    user =
      Repo.insert!(%User{
        email: "user@example.com",
        name: "Test User",
        oidc_sub: "oidc-subject"
      })

    conn = init_test_session(conn, current_user_id: user.id)

    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Core Chat"

    html =
      view
      |> form("#chat-form", chat: %{message: "hello"})
      |> render_submit()

    assert html =~ "hello"
    assert html =~ "Agent online"
  end
end
