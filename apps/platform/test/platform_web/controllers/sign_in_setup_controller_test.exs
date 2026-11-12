defmodule PlatformWeb.SignInSetupControllerTest do
  use PlatformWeb.ConnCase, async: false
  alias Platform.{Accounts, Repo}
  alias Platform.SignInAdmin.PocketId
  alias Platform.SignIn.EmailSetup
  alias Platform.Mail.System, as: SystemMail
  @code "AbCd1234EfGh"

  setup do
    keys = [
      :sign_in_admin_enabled,
      :sign_in_admin_url,
      :sign_in_admin_api_key,
      :oidc_mock_response,
      :trust_proxy_headers,
      SystemMail
    ]

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

    Application.put_env(:platform, SystemMail,
      from: "Burrow <noreply@example.test>",
      host: "smtp.example.test"
    )

    :ets.delete_all_objects(:sign_in_email_setup_rate)
    handler = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:platform, :sign_in, :setup, :delivery],
        fn _, _, meta, pid ->
          send(pid, {:setup_delivery, meta.challenge_id, meta.result})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    user =
      Repo.insert!(%Accounts.User{
        email: "new@example.test",
        name: "New",
        oidc_sub: Ecto.UUID.generate()
      })

    %{user: user}
  end

  defp provider(user, opts \\ []) do
    pid = self()

    Req.Test.stub(PocketId, fn conn ->
      send(pid, {:provider_request, conn.request_path})

      case conn.request_path do
        "/api/users/" <> rest when rest == user.oidc_sub ->
          Req.Test.json(conn, %{
            id: user.oidc_sub,
            email: opts[:email] || user.email,
            emailVerified: true,
            disabled: opts[:disabled] || false
          })

        path ->
          if String.ends_with?(path, "/webauthn-credentials") do
            Req.Test.json(conn, if(opts[:enrolled], do: [%{id: "passkey"}], else: []))
          else
            send(pid, :provider_token_minted)
            Req.Test.json(conn, %{token: @code})
          end
      end
    end)
  end

  defp delivered(conn) do
    id = get_session(conn, :email_setup).id
    assert_receive {:setup_delivery, ^id, result}, 2_000
    result
  end

  defp mailed_code(mail) do
    [_, code] = Regex.run(~r/\n([A-Z2-7]{8})\n/, mail.text_body)
    code
  end

  test "bundled login offers first-time setup without losing native continuation", %{conn: conn} do
    challenge = String.duplicate("a", 43)
    conn = get(conn, "/auth/login?app_challenge=" <> challenge)
    assert redirected_to(conn) == "/auth/sign-in"
    assert get_session(conn, :app_challenge) == challenge
    page = conn |> recycle() |> get("/auth/sign-in")
    doc = LazyHTML.from_document(html_response(page, 200))
    assert LazyHTML.query(doc, "#email-setup-request") |> LazyHTML.to_tree() != []
    assert LazyHTML.query(doc, "#passkey-sign-in") |> LazyHTML.to_tree() != []

    if dir = System.get_env("SIGN_IN_SETUP_EVIDENCE") do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "sign-in.html"), page.resp_body)
    end
  end

  test "external provider keeps the ordinary redirect", %{conn: conn} do
    Application.put_env(:platform, :sign_in_admin_enabled, false)
    conn = get(conn, "/auth/login")
    assert redirected_to(conn) =~ "https://issuer.example.com/authorize?"
    assert %{id: _, binding: _} = EmailSetup.request("new@example.test", {1, 2, 3, 4})
    refute_received {:mail_test_adapter, _, _}
  end

  test "without SMTP the same-device invitation fallback is explicit", %{conn: conn} do
    Application.delete_env(:platform, SystemMail)
    page = get(conn, "/auth/sign-in")
    doc = LazyHTML.from_document(html_response(page, 200))
    assert LazyHTML.query(doc, "#email-setup-unavailable") |> LazyHTML.to_tree() != []
    assert LazyHTML.query(doc, "#email-setup-request") |> LazyHTML.to_tree() == []
    conn = post(recycle(page), "/auth/email/setup", %{email: "new@example.test"})
    assert conn.status == 503
    refute_received {:mail_test_adapter, _, _}
  end

  test "sends only a code, retains only its digest, and preserves the native PKCE handoff", %{
    conn: conn,
    user: user
  } do
    provider(user)
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

    conn =
      conn
      |> init_test_session(app_challenge: challenge)
      |> post("/auth/email/setup", %{email: " NEW@example.test "})

    assert html_response(conn, 200) =~ "If an eligible account exists"
    refute conn.resp_body =~ @code
    pending = get_session(conn, :email_setup)
    assert Map.keys(pending) |> Enum.sort() == [:binding, :id]
    assert delivered(conn) == :sent

    if dir = System.get_env("SIGN_IN_SETUP_EVIDENCE") do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "code.html"), conn.resp_body)
    end

    assert_receive {:mail_test_adapter, mail, _}, 2_000
    assert mail.to == [{"", user.email}]
    refute_received :provider_token_minted
    refute mail.text_body =~ @code
    code = mailed_code(mail)
    refute conn.resp_body =~ code

    assert {:error, :invalid} =
             EmailSetup.complete(%{pending | binding: "wrong-browser-binding"}, code)

    Req.Test.stub(Platform.OIDC, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "location",
        "/interaction?interaction=e8a7f28d-4e78-4f21-bec0-53dc068d471f"
      )
      |> Plug.Conn.send_resp(302, "")
    end)

    completed = conn |> recycle() |> post("/auth/email/complete", %{code: code})
    assert redirected_to(completed) =~ "https://issuer.example.com/lc/" <> @code
    assert_received :provider_token_minted
    assert get_session(completed, :app_challenge) == challenge
    assert get_session(completed, :email_setup) == nil
    refute get_session(completed, :post_login_path)
    assert Repo.get!(Accounts.User, user.id).sign_in_link_expires_at
    assert {:error, :invalid} = EmailSetup.complete(pending, code)
    claims = %{"sub" => user.oidc_sub, "email" => user.email, "name" => user.name}

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "t"}}}
    )

    state = get_session(completed, :oidc_session_params).state

    callback =
      completed
      |> recycle()
      |> get("/auth/oidc/callback?" <> URI.encode_query(%{code: "provider-code", state: state}))

    location = URI.parse(redirected_to(callback))
    assert location.scheme == "burrow"
    assert location.host == "auth"
    assert location.path == "/callback"
    %{"code" => exchange} = URI.decode_query(location.query)
    assert {:ok, %{session: session}} = Platform.Mobile.exchange_code(exchange, verifier)
    assert session.user_id == user.id
    # Reusing the completion form cannot start another login.
    replay = completed |> recycle() |> post("/auth/email/complete", %{code: code})
    assert replay.status == 400
  end

  test "unknown, archived, disabled, enrolled and mismatched-email accounts never get codes", %{
    conn: conn,
    user: user
  } do
    generic = post(conn, "/auth/email/setup", %{email: "unknown@example.test"})
    assert html_response(generic, 200) =~ "If an eligible account exists"
    assert delivered(generic) == :skipped
    refute_received {:provider_request, _}

    for opts <- [[disabled: true], [enrolled: true], [email: "other@example.test"]] do
      :ets.delete_all_objects(:sign_in_email_setup_rate)
      provider(user, opts)
      result = post(build_conn(), "/auth/email/setup", %{email: user.email})
      assert html_response(result, 200) =~ "If an eligible account exists"
      assert delivered(result) == :skipped
      refute_received {:mail_test_adapter, _, _}
    end

    Repo.update!(Ecto.Changeset.change(user, archived_at: DateTime.utc_now()))
    :ets.delete_all_objects(:sign_in_email_setup_rate)
    result = post(build_conn(), "/auth/email/setup", %{email: user.email})
    assert html_response(result, 200) =~ "If an eligible account exists"
    assert delivered(result) == :skipped
    refute_received {:mail_test_adapter, _, _}
  end

  test "email request limits prevent repeated sends and wrong or expired codes are refused", %{
    conn: conn,
    user: user
  } do
    provider(user)

    attempts =
      for _ <- 1..3 do
        sent = post(build_conn(), "/auth/email/setup", %{email: user.email})
        assert delivered(sent) == :sent
        assert_receive {:mail_test_adapter, mail, _}, 2_000
        {get_session(sent, :email_setup), mailed_code(mail)}
      end

    result = post(conn, "/auth/email/setup", %{email: user.email})
    refute_received {:mail_test_adapter, _, _}
    assert html_response(result, 200) =~ "If an eligible account exists"
    {pending, code} = List.first(attempts)
    for _ <- 1..5, do: assert({:error, :invalid} == EmailSetup.complete(pending, "WRONG123"))
    assert {:error, :invalid} = EmailSetup.complete(pending, code)
    {pending, code} = List.last(attempts)
    row = Repo.get!(Platform.SignIn.SetupChallenge, pending.id)

    Repo.update!(
      Ecto.Changeset.change(row, expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    )

    assert {:error, :invalid} = EmailSetup.complete(pending, code)
  end

  test "pasting the existing provider invitation keeps the native app session even without SMTP",
       %{conn: conn} do
    Application.delete_env(:platform, SystemMail)
    challenge = String.duplicate("a", 43)

    Req.Test.stub(Platform.OIDC, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "location",
        "/interaction?interaction=e8a7f28d-4e78-4f21-bec0-53dc068d471f"
      )
      |> Plug.Conn.send_resp(302, "")
    end)

    result =
      conn
      |> init_test_session(app_challenge: challenge)
      |> post("/auth/invitation", %{
        setup_link: "https://issuer.example.com/lc/" <> @code <> "?redirect=%2Fsettings%2Faccount"
      })

    assert redirected_to(result) =~ "https://issuer.example.com/lc/" <> @code
    assert get_session(result, :app_challenge) == challenge
    refute_received {:mail_test_adapter, _, _}
  end

  test "invitation parser refuses foreign origins, HTTP, credentials, fragments and tampered signed links",
       %{conn: conn} do
    for value <- [
          "https://evil.example/lc/" <> @code,
          "http://issuer.example.com/lc/" <> @code,
          "https://user:password@issuer.example.com/lc/" <> @code,
          "https://issuer.example.com/lc/" <> @code <> "#fragment",
          "https://issuer.example.com/authorize?token=" <> @code,
          "/lc/" <> @code,
          String.duplicate("a", 8193)
        ] do
      result = post(conn, "/auth/invitation", %{setup_link: value})
      assert result.status == 400
      refute result.resp_body =~ @code
      refute get_session(result, :oidc_session_params)
    end

    refute_received {:provider_request, _}
  end

  test "a valid signed invitation is verified for this install and archived users cannot redeem it",
       %{conn: conn, user: user} do
    provider(user)
    link = Platform.SignIn.DurableLink.url(user, :invite)

    assert {:ok, %{token: %PocketId.Token{value: @code}, purpose: :invite}} =
             Platform.SignIn.SetupLink.redeem(link)

    assert {:error, _} = Platform.SignIn.SetupLink.redeem(link <> "tampered")
    Repo.update!(Ecto.Changeset.change(user, archived_at: DateTime.utc_now()))
    result = post(conn, "/auth/invitation", %{setup_link: link})
    assert result.status == 400
    refute get_session(result, :oidc_session_params)
  end

  test "adding a passkey after code delivery ends eligibility before a provider token is minted",
       %{conn: conn, user: user} do
    provider(user)
    sent = post(conn, "/auth/email/setup", %{email: user.email})
    assert delivered(sent) == :sent
    assert_receive {:mail_test_adapter, mail, _}, 2_000
    provider(user, enrolled: true)

    assert {:error, :invalid} =
             EmailSetup.complete(get_session(sent, :email_setup), mailed_code(mail))

    refute_received :provider_token_minted
  end

  test "a pasted owner link retains owner onboarding and the app continuation", %{
    conn: conn,
    user: user
  } do
    provider(user)

    Req.Test.stub(Platform.OIDC, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "location",
        "/interaction?interaction=e8a7f28d-4e78-4f21-bec0-53dc068d471f"
      )
      |> Plug.Conn.send_resp(302, "")
    end)

    result =
      conn
      |> init_test_session(app_challenge: String.duplicate("a", 43))
      |> post("/auth/invitation", %{setup_link: Platform.SignIn.DurableLink.url(user, :handover)})

    assert redirected_to(result) =~ "/lc/" <> @code
    assert get_session(result, :post_login_path) == "/setup/connect-ai"
    assert get_session(result, :signed_in_with_link) == true
    assert get_session(result, :app_challenge) == String.duplicate("a", 43)
  end

  test "proxy-added final hop, rather than spoofed leftmost XFF, controls request limits" do
    Application.put_env(:platform, :trust_proxy_headers, true)

    for n <- 1..4 do
      conn =
        build_conn()
        |> put_req_header("x-forwarded-for", "203.0.113.#{n}, 198.51.100.9")
        |> post("/auth/email/setup", %{email: "unknown-#{n}@example.test"})

      assert delivered(conn) == :skipped
    end

    ips = for {{{:ip, ip}, _}, count} <- :ets.tab2list(:sign_in_email_setup_rate), do: {ip, count}
    assert ips == [{{198, 51, 100, 9}, 4}]
  end

  test "counter capacity does not disable invitation completion globally" do
    :ets.insert(:sign_in_email_setup_rate, for(n <- 1..20_000, do: {{{:noise, n}, 0}, 1}))
    assert :ok = Platform.SignIn.EmailSetupRateLimit.verify({198, 51, 100, 10})
  end

  test "concurrent redemption of one browser challenge mints only one provider token", %{
    conn: conn,
    user: user
  } do
    provider(user)
    sent = post(conn, "/auth/email/setup", %{email: user.email})
    assert delivered(sent) == :sent
    assert_receive {:mail_test_adapter, mail, _}, 2_000
    pending = get_session(sent, :email_setup)
    code = mailed_code(mail)
    supervisor = start_supervised!(Task.Supervisor)

    tasks =
      Enum.map(1..2, fn _ ->
        Task.Supervisor.async_nolink(supervisor, fn -> EmailSetup.complete(pending, code) end)
      end)

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, %PocketId.Token{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :invalid})) == 1
    assert_received :provider_token_minted
    refute_received :provider_token_minted
  end
end
