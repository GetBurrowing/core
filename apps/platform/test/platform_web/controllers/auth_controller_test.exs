defmodule PlatformWeb.AuthControllerTest do
  use PlatformWeb.ConnCase

  alias Platform.Accounts.User
  alias Platform.Repo

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)
    :ok
  end

  test "GET /auth/login redirects to the provider and stores session params", %{conn: conn} do
    conn = get(conn, ~p"/auth/login")

    assert redirected_to(conn, 302) =~ "https://issuer.example.com/authorize?"
    assert %{state: _, nonce: _} = get_session(conn, :oidc_session_params)
  end

  test "GET /auth/oidc/callback creates a user and signs them in", %{conn: conn} do
    conn =
      init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

    conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=expected-state")

    assert redirected_to(conn, 302) == ~p"/"

    user_id = get_session(conn, :current_user_id)
    assert user_id

    user = Repo.get!(User, user_id)
    assert user.email == "user@example.com"
    assert user.name == "Test User"
    assert user.oidc_sub == "test-subject"
    assert get_session(conn, :oidc_id_token) == "test-id-token"
  end

  test "GET /auth/oidc/callback rejects an invalid state", %{conn: conn} do
    conn =
      init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

    conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=wrong-state")

    assert response(conn, 401) =~ "Invalid OIDC state"
  end

  test "GET /auth/logout clears the session and redirects to the end-session endpoint", %{
    conn: conn
  } do
    conn =
      conn
      |> init_test_session(
        current_user_id: Ecto.UUID.generate(),
        oidc_id_token: "signed-id-token"
      )
      |> get(~p"/auth/logout")

    redirect_url = redirected_to(conn, 302)

    assert redirect_url =~ "https://issuer.example.com/end-session?"
    assert redirect_url =~ "id_token_hint=signed-id-token"
    assert redirect_url =~ "post_logout_redirect_uri=http%3A%2F%2Fwww.example.com"
  end
end
