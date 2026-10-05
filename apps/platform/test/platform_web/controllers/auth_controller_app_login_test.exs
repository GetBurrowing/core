defmodule PlatformWeb.AuthControllerAppLoginTest do
  @moduledoc """
  Task 01a10882 stage 1: the native app's login path through
  `PlatformWeb.AuthController` (`app_challenge` on login, the
  `burrow://` landing on callback, and the web-view handoff).
  """
  # async: false: the log test raises the global Logger level, and the OIDC
  # mock lives in application env.
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Mobile
  alias Platform.Repo

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)
    :ok
  end

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp mock_oidc! do
    claims = %{"sub" => "app-login-subject", "email" => "app@example.com", "name" => "App User"}

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "idt"}}}
    )
  end

  defp callback(conn, session) do
    conn
    |> init_test_session(Map.merge(%{oidc_session_params: %{state: "s1", nonce: "n"}}, session))
    |> get(~p"/auth/oidc/callback?code=idp-code&state=s1")
  end

  describe "GET /auth/login" do
    test "stores a valid app_challenge and still redirects to the IdP", %{conn: conn} do
      {_verifier, challenge} = pkce()
      conn = get(conn, ~p"/auth/login?#{[app_challenge: challenge]}")

      assert redirected_to(conn, 302) =~ "https://issuer.example.com/authorize?"
      assert get_session(conn, :app_challenge) == challenge
    end

    test "refuses a malformed app_challenge", %{conn: conn} do
      conn = get(conn, ~p"/auth/login?#{[app_challenge: "not-s256"]}")
      assert response(conn, 400) == "Invalid app_challenge"
      assert get_session(conn, :app_challenge) == nil
    end

    test "a plain login clears a challenge left by an abandoned app login", %{conn: conn} do
      {_verifier, challenge} = pkce()

      conn =
        conn
        |> init_test_session(app_challenge: challenge)
        |> get(~p"/auth/login")

      assert redirected_to(conn, 302) =~ "https://issuer.example.com/authorize?"
      assert get_session(conn, :app_challenge) == nil
    end
  end

  describe "GET /auth/oidc/callback" do
    test "with an app_challenge, lands in the app with an exchange code", %{conn: conn} do
      mock_oidc!()
      {verifier, challenge} = pkce()

      conn = callback(conn, %{app_challenge: challenge})

      location = redirected_to(conn, 302)

      assert %URI{scheme: "burrow", host: "auth", path: "/callback", query: query} =
               URI.parse(location)

      assert %{"code" => code} = URI.decode_query(query)
      assert get_session(conn, :app_challenge) == nil

      user = Repo.get_by!(User, oidc_sub: "app-login-subject")
      assert {:ok, %{token: token}} = Mobile.exchange_code(code, verifier)
      assert {:ok, %{id: id}, _session} = Mobile.verify_bearer(token)
      assert id == user.id
    end

    test "without an app_challenge, the redirect is byte-identical to today's", %{conn: conn} do
      mock_oidc!()

      conn = callback(conn, %{})

      assert conn.status == 302
      assert get_resp_header(conn, "location") == ["/"]

      assert conn.resp_body ==
               ~s(<html><body>You are being <a href="/">redirected</a>.</body></html>)

      assert Repo.aggregate(Platform.Mobile.AppLoginCode, :count) == 0
    end

    test "the app scheme is fixed and ignores any redirect parameter", %{conn: conn} do
      mock_oidc!()
      {_verifier, challenge} = pkce()

      conn =
        conn
        |> init_test_session(%{
          oidc_session_params: %{state: "s1", nonce: "n"},
          app_challenge: challenge
        })
        |> get("/auth/oidc/callback?code=idp-code&state=s1&redirect_uri=https://evil.example")

      assert redirected_to(conn, 302) =~ ~r{\Aburrow://auth/callback\?code=}
    end
  end

  describe "GET /auth/app/handoff" do
    test "signs the browser in once, then refuses the same code", %{conn: conn} do
      user = Platform.ExternalUserFixtures.create_user!()
      {verifier, challenge} = pkce()
      {:ok, code} = Mobile.issue_exchange_code(user, challenge)
      {:ok, %{handoff_code: handoff}} = Mobile.exchange_code(code, verifier)

      conn1 = get(conn, ~p"/auth/app/handoff?#{[code: handoff]}")
      assert redirected_to(conn1, 302) == "/"
      assert get_session(conn1, :current_user_id) == user.id

      conn2 = get(conn, ~p"/auth/app/handoff?#{[code: handoff]}")
      assert response(conn2, 401) == "Sign-in link is invalid or has expired"
      assert get_session(conn2, :current_user_id) == nil
    end

    test "refuses a missing or unknown code without echoing it", %{conn: conn} do
      conn1 = get(conn, ~p"/auth/app/handoff")
      assert response(conn1, 401)

      conn2 = get(conn, ~p"/auth/app/handoff?#{[code: "code-SENTINEL"]}")
      body = response(conn2, 401)
      refute body =~ "code-SENTINEL"
    end

    test "logs neither the exchange code nor the handoff code", %{conn: conn} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      user = Platform.ExternalUserFixtures.create_user!()
      {verifier, challenge} = pkce()

      {{code, handoff}, log} =
        with_log([level: :debug], fn ->
          {:ok, code} = Mobile.issue_exchange_code(user, challenge)

          %{"handoff_url" => handoff_url} =
            conn
            |> post("/api/app/session", %{"code" => code, "code_verifier" => verifier})
            |> json_response(200)

          %URI{path: path, query: query} = URI.parse(handoff_url)
          conn |> get(path <> "?" <> query) |> redirected_to(302)

          {code, URI.decode_query(query)["code"]}
        end)

      assert log =~ "/auth/app/handoff", "the request log was not captured at all"
      refute log =~ code
      refute log =~ handoff
      refute log =~ verifier
    end
  end
end
