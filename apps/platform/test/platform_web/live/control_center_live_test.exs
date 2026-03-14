defmodule PlatformWeb.ControlCenterLiveTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "control_test@example.com",
        name: "Control Test User",
        oidc_sub: "oidc-control-test"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  test "GET /control redirects unauthenticated users to login", %{conn: conn} do
    conn = get(conn, ~p"/control")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /control renders the control center placeholder", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Control Center"
    assert html =~ "Coming soon"
  end

  test "shell sidebar is rendered on /control", %{conn: conn} do
    conn = authenticated_conn(conn)
    {:ok, _view, html} = live(conn, ~p"/control")

    assert html =~ "Startup Suite"
    assert html =~ "/chat"
    assert html =~ "/control"
  end
end
