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

  # Task 01a14d12: the `/dev/login` route is compiled only in :dev, so these
  # call the action directly, as auth_controller_test.exs does.
  describe "AuthController.dev_login with app_challenge" do
    defp dev_login(conn, params) do
      conn
      |> init_test_session(%{})
      |> PlatformWeb.AuthController.dev_login(params)
    end

    test "a valid challenge lands in the app with a redeemable exchange code", %{conn: conn} do
      {verifier, challenge} = pkce()
      slug = "appdev#{System.unique_integer([:positive])}"

      conn = dev_login(conn, %{"as" => slug, "app_challenge" => challenge})

      assert %URI{scheme: "burrow", host: "auth", path: "/callback", query: query} =
               URI.parse(redirected_to(conn, 302))

      assert %{"code" => code} = URI.decode_query(query)
      assert get_session(conn, :app_challenge) == nil

      user = Repo.get_by!(User, oidc_sub: "dev-#{slug}")
      assert {:ok, %{token: token}} = Mobile.exchange_code(code, verifier)
      assert {:ok, %{id: id}, _session} = Mobile.verify_bearer(token)
      assert id == user.id
    end

    # The app window carries its own return path, so an app sign-in must
    # neither honour nor clear a browser's pending return target (the
    # `:login_return_to` key task 01a14d33 adds). Pinned here before that key
    # lands so whichever merges second keeps both behaviours.
    test "neither reads nor clears a stored return target", %{conn: conn} do
      {_verifier, challenge} = pkce()
      return_to = %{path: "/m/social?invite=x", at: System.system_time(:second)}

      seed = %{login_return_to: return_to, app_challenge: challenge}
      seeded = fn -> init_test_session(conn, seed) end

      dev =
        PlatformWeb.AuthController.dev_login(seeded.(), %{
          "as" => "appdevret#{System.unique_integer([:positive])}",
          "app_challenge" => challenge
        })

      mock_oidc!()

      oidc =
        seeded.()
        |> put_session(:oidc_session_params, %{state: "s1", nonce: "n"})
        |> get(~p"/auth/oidc/callback?code=idp-code&state=s1")

      for conn <- [dev, oidc] do
        assert redirected_to(conn, 302) =~ ~r{\Aburrow://auth/callback\?code=}
        assert get_session(conn, :login_return_to) == return_to
      end
    end

    test "a malformed challenge is refused and mints nothing", %{conn: conn} do
      conn = dev_login(conn, %{"as" => "appdevbad", "app_challenge" => "not-s256"})

      assert response(conn, 400) == "Invalid app_challenge"
      assert get_session(conn, :current_user_id) == nil
      assert Repo.aggregate(Platform.Mobile.AppLoginCode, :count) == 0
    end

    test "without the param, the landing is today's /chat and mints nothing", %{conn: conn} do
      conn = dev_login(conn, %{"as" => "appdevweb#{System.unique_integer([:positive])}"})

      assert get_resp_header(conn, "location") == ["/chat"]

      assert conn.resp_body ==
               ~s(<html><body>You are being <a href="/chat">redirected</a>.</body></html>)

      assert get_session(conn, :current_user_id)
      assert Repo.aggregate(Platform.Mobile.AppLoginCode, :count) == 0
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

  # Task 01a1e58b stage 3: a sign-in by code (`/auth/sign-in`: an emailed
  # code, or a pasted invitation, both `{:setup_code, _}`) lands on the
  # add-a-passkey prompt, in the app's web view and on the web. The code
  # login here is the pasted-invitation route (`POST /auth/invitation`), which
  # reaches `setup_code_login/3` with no mail rig; stage 2's tests drive the
  # emailed-code route to the same function.
  describe "a code sign-in lands on the add-a-passkey prompt" do
    @code "AbCd1234EfGh"

    setup do
      keys = [:sign_in_admin_enabled, :sign_in_admin_url, :sign_in_admin_api_key]
      saved = for key <- keys, do: {key, Application.fetch_env(:platform, key)}

      on_exit(fn ->
        for {key, old} <- saved do
          case old do
            {:ok, value} -> Application.put_env(:platform, key, value)
            :error -> Application.delete_env(:platform, key)
          end
        end
      end)

      Application.put_env(:platform, :sign_in_admin_enabled, true)
      Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test")
      Application.put_env(:platform, :sign_in_admin_api_key, "test-key-not-a-secret")
      :ets.delete_all_objects(:sign_in_email_setup_rate)

      Req.Test.stub(Platform.OIDC, fn conn ->
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "/interaction?interaction=e8a7f28d-4e78-4f21-bec0-53dc068d471f"
        )
        |> Plug.Conn.send_resp(302, "")
      end)

      user =
        Platform.ExternalUserFixtures.create_user!(%{
          oidc_sub: "app-login-subject",
          email: "app@example.com"
        })

      Platform.ExternalUserFixtures.plain_member!(user, Platform.Tenancy.get_org_by_slug!("acme"))
      mock_oidc!()
      %{user: user}
    end

    defp invitation_link, do: "https://issuer.example.com/lc/" <> @code

    defp handover_link,
      do: PlatformWeb.Endpoint.url() <> "/auth/handover?" <> URI.encode_query(code: @code)

    # The code login: pocket-id's /lc/<code>, then (recycled, as the browser
    # returns) Burrow's OIDC callback with the state the login stored.
    defp code_sign_in(conn, link) do
      started = conn |> recycle() |> post("/auth/invitation", %{setup_link: link})
      assert redirected_to(started) =~ "https://issuer.example.com/lc/" <> @code
      provider_return(started)
    end

    defp passkey_sign_in(conn) do
      started = conn |> recycle() |> post("/auth/passkey")
      assert redirected_to(started) =~ "https://issuer.example.com/authorize?"
      provider_return(started)
    end

    defp provider_return(started) do
      state = get_session(started, :oidc_session_params).state

      started
      |> recycle()
      |> get("/auth/oidc/callback?" <> URI.encode_query(%{code: "idp-code", state: state}))
    end

    defp app_login(challenge) do
      login = get(build_conn(), ~p"/auth/login?#{[app_challenge: challenge]}")
      assert redirected_to(login) == "/auth/sign-in"
      login
    end

    defp exchange!(callback, verifier) do
      location = URI.parse(redirected_to(callback, 302))
      assert {location.scheme, location.host, location.path} == {"burrow", "auth", "/callback"}
      %{"code" => code} = URI.decode_query(location.query)

      %{"handoff_url" => handoff_url} =
        build_conn()
        |> post("/api/app/session", %{"code" => code, "code_verifier" => verifier})
        |> json_response(200)

      URI.parse(handoff_url)
    end

    # The web view's fresh cookie store: every 302 followed with recycle/1.
    defp follow(%Plug.Conn{status: 302} = conn, hops) when length(hops) < 10 do
      location = redirected_to(conn, 302)
      refute String.starts_with?(location, "/auth/login"), "the chain reached #{location}"
      conn |> recycle() |> get(location) |> follow([location | hops])
    end

    defp follow(conn, hops), do: {conn, Enum.reverse(hops)}

    defp prompt?(conn),
      do:
        conn
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#passkey-add-prompt")
        |> Enum.count() == 1

    test "an app code sign-in's handoff_url lands the web view on the prompt" do
      {verifier, challenge} = pkce()

      handoff =
        challenge
        |> app_login()
        |> code_sign_in(invitation_link())
        |> exchange!(verifier)

      assert URI.decode_query(handoff.query)["to"] == "/settings?passkey=add"

      {conn, hops} = build_conn() |> get(handoff.path <> "?" <> handoff.query) |> follow([])
      assert hops == ["/settings?passkey=add"]
      assert prompt?(conn)
    end

    test "an app passkey sign-in's handoff_url has no `to` and lands on /", %{user: user} do
      {verifier, challenge} = pkce()

      handoff =
        challenge
        |> app_login()
        |> passkey_sign_in()
        |> exchange!(verifier)

      refute Map.has_key?(URI.decode_query(handoff.query), "to")

      {conn, hops} = build_conn() |> get(handoff.path <> "?" <> handoff.query) |> follow([])
      assert hops == ["/", "/chat"]
      assert get_session(conn, :current_user_id) == user.id
      refute html_response(conn, 200) =~ "passkey-add-prompt"
    end

    test "a web code sign-in redirects to /settings?passkey=add and shows the prompt" do
      callback = get(build_conn(), "/auth/login") |> code_sign_in(invitation_link())

      assert redirected_to(callback, 302) == "/settings?passkey=add"
      assert get_session(callback, :signed_in_with_email_code) == nil
      assert Repo.aggregate(Platform.Mobile.AppLoginCode, :count) == 0

      {conn, _hops} = follow(callback, [])
      assert prompt?(conn)
    end

    test "abandoned code login, then passkey login, lands on /" do
      login = get(build_conn(), "/auth/login")
      abandoned = login |> recycle() |> post("/auth/invitation", %{setup_link: invitation_link()})
      assert get_session(abandoned, :signed_in_with_email_code) == true

      callback = passkey_sign_in(abandoned)
      assert redirected_to(callback, 302) == "/"
    end

    test "a hand-over still lands on /setup/connect-ai, by link or by pasted code" do
      handover =
        build_conn()
        |> get("/auth/handover?" <> URI.encode_query(code: @code))
        |> provider_return()

      assert redirected_to(handover, 302) == "/setup/connect-ai"

      pasted = get(build_conn(), "/auth/login") |> code_sign_in(handover_link())
      assert redirected_to(pasted, 302) == "/setup/connect-ai"
    end
  end
end
