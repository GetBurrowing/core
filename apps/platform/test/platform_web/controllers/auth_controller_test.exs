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

  test "GET /auth/oidc/callback creates a user, stores avatar metadata, and signs them in", %{conn: conn} do
    mock_oidc_response(%{
      user: base_claims(),
      userinfo: Map.put(base_claims(), "picture", "https://issuer.example.com/userinfo-avatar.png"),
      id_token: Map.put(base_claims(), "picture", "https://issuer.example.com/id-token-avatar.png")
    })

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
    assert user.avatar_url == "https://issuer.example.com/id-token-avatar.png"
    assert user.avatar_source == :oidc
    assert get_session(conn, :oidc_id_token) == "test-id-token"
  end

  test "GET /auth/oidc/callback refreshes an existing user's name and avatar on repeat login",
       %{conn: conn} do
    existing_user =
      insert_user(%{
        name: "Old Name",
        avatar_url: "https://issuer.example.com/old-avatar.png",
        avatar_source: :generated
      })

    mock_oidc_response(%{
      user: base_claims(%{"name" => "Renamed User"}),
      userinfo: base_claims(%{"name" => "Renamed User"}),
      id_token:
        base_claims(%{
          "name" => "Renamed User",
          "picture" => "https://issuer.example.com/new-avatar.png"
        })
    })

    conn =
      init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

    conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=expected-state")

    assert redirected_to(conn, 302) == ~p"/"
    assert get_session(conn, :current_user_id) == existing_user.id

    user = Repo.get!(User, existing_user.id)
    assert user.name == "Renamed User"
    assert user.avatar_url == "https://issuer.example.com/new-avatar.png"
    assert user.avatar_source == :oidc
  end

  test "GET /auth/oidc/callback keeps the stored avatar when the provider omits picture", %{conn: conn} do
    existing_user =
      insert_user(%{
        avatar_url: "https://issuer.example.com/stable-avatar.png",
        avatar_source: :oidc
      })

    mock_oidc_response(%{
      user: base_claims(%{"name" => "Still Test User"}),
      userinfo: base_claims(%{"name" => "Still Test User"}),
      id_token: base_claims(%{"name" => "Still Test User"})
    })

    conn =
      init_test_session(conn, oidc_session_params: %{state: "expected-state", nonce: "n"})

    conn = get(conn, ~p"/auth/oidc/callback?code=test-code&state=expected-state")

    assert redirected_to(conn, 302) == ~p"/"
    assert get_session(conn, :current_user_id) == existing_user.id

    user = Repo.get!(User, existing_user.id)
    assert user.name == "Still Test User"
    assert user.avatar_url == "https://issuer.example.com/stable-avatar.png"
    assert user.avatar_source == :oidc
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

  defp mock_oidc_response(claim_sets) do
    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, Map.put(claim_sets, :token, %{"id_token" => "test-id-token"})}
    )
  end

  defp base_claims(overrides \\ %{}) do
    Map.merge(
      %{
        "sub" => "test-subject",
        "email" => "user@example.com",
        "name" => "Test User"
      },
      overrides
    )
  end

  defp insert_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(
      Map.merge(
        %{
          email: "user@example.com",
          name: "Test User",
          oidc_sub: "test-subject"
        },
        attrs
      )
    )
    |> Repo.insert!()
  end
end
