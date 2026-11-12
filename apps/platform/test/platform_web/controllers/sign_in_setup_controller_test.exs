defmodule PlatformWeb.SignInSetupControllerTest do
  use PlatformWeb.ConnCase, async: false
  alias Platform.{Accounts, Repo}
  alias Platform.SignInAdmin.PocketId
  alias Platform.SignIn.EmailSetup
  alias Platform.Mail.System, as: SystemMail
  @code "AbCd1234EfGh"

  setup do
    keys = [:sign_in_admin_enabled, :sign_in_admin_url, :sign_in_admin_api_key, :oidc_mock_response, SystemMail]
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
    Application.put_env(:platform, SystemMail, from: "Burrow <noreply@example.test>", host: "smtp.example.test")
    :ets.delete_all_objects(:sign_in_email_setup_rate)
    user = Repo.insert!(%Accounts.User{email: "new@example.test", name: "New", oidc_sub: Ecto.UUID.generate()})
    %{user: user}
  end

  defp provider(user, opts \\ []) do
    pid = self()
    Req.Test.stub(PocketId, fn conn ->
      send(pid, {:provider_request, conn.request_path})
      case conn.request_path do
        "/api/users/" <> rest when rest == user.oidc_sub ->
          Req.Test.json(conn, %{id: user.oidc_sub, email: opts[:email] || user.email, emailVerified: true, disabled: opts[:disabled] || false})
        path ->
          if String.ends_with?(path, "/webauthn-credentials") do
            Req.Test.json(conn, if(opts[:enrolled], do: [%{id: "passkey"}], else: []))
          else
            Req.Test.json(conn, %{token: @code})
          end
      end
    end)
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
    assert EmailSetup.request("new@example.test", {1, 2, 3, 4}) != EmailSetup.digest(@code)
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

  test "sends only a code, retains only its digest, and preserves the native PKCE handoff", %{conn: conn, user: user} do
    provider(user)
    challenge = String.duplicate("a", 43)
    conn = conn |> init_test_session(app_challenge: challenge) |> post("/auth/email/setup", %{email: " NEW@example.test "})
    assert html_response(conn, 200) =~ "If your account is invited"
    refute conn.resp_body =~ @code
    assert get_session(conn, :email_setup).hash == EmailSetup.digest(@code)
    assert_received {:mail_test_adapter, mail, _}
    assert mail.to == [{"", user.email}]
    assert mail.text_body =~ @code
    assert Repo.get!(Accounts.User, user.id).sign_in_link_expires_at
    Req.Test.stub(Platform.OIDC, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "/interaction?interaction=e8a7f28d-4e78-4f21-bec0-53dc068d471f") |> Plug.Conn.send_resp(302, "")
    end)
    completed = conn |> recycle() |> post("/auth/email/complete", %{code: @code})
    assert redirected_to(completed) =~ "https://issuer.example.com/lc/" <> @code
    assert get_session(completed, :app_challenge) == challenge
    assert get_session(completed, :email_setup) == nil
    refute get_session(completed, :post_login_path)
    # Reusing the completion form cannot start another login.
    replay = completed |> recycle() |> post("/auth/email/complete", %{code: @code})
    assert replay.status == 400
  end

  test "unknown, archived, disabled, enrolled and mismatched-email accounts never get codes", %{conn: conn, user: user} do
    generic = post(conn, "/auth/email/setup", %{email: "unknown@example.test"})
    assert html_response(generic, 200) =~ "If your account is invited"
    refute_received {:provider_request, _}
    for opts <- [[disabled: true], [enrolled: true], [email: "other@example.test"]] do
      :ets.delete_all_objects(:sign_in_email_setup_rate)
      provider(user, opts)
      result = post(build_conn(), "/auth/email/setup", %{email: user.email})
      assert html_response(result, 200) =~ "If your account is invited"
      refute_received {:mail_test_adapter, _, _}
      refute get_session(result, :email_setup).hash == EmailSetup.digest(@code)
    end
    Repo.update!(Ecto.Changeset.change(user, archived_at: DateTime.utc_now()))
    :ets.delete_all_objects(:sign_in_email_setup_rate)
    result = post(build_conn(), "/auth/email/setup", %{email: user.email})
    assert html_response(result, 200) =~ "If your account is invited"
    refute_received {:mail_test_adapter, _, _}
  end

  test "email request limits prevent repeated sends and wrong or expired codes are refused", %{conn: conn, user: user} do
    provider(user)
    for _ <- 1..3 do
      post(build_conn(), "/auth/email/setup", %{email: user.email})
      assert_received {:mail_test_adapter, _, _}
    end
    result = post(conn, "/auth/email/setup", %{email: user.email})
    refute_received {:mail_test_adapter, _, _}
    assert html_response(result, 200) =~ "If your account is invited"
    wrong = result |> recycle() |> post("/auth/email/complete", %{code: "wrongcode1234"})
    assert wrong.status == 400
    expired = build_conn() |> init_test_session(email_setup: %{hash: EmailSetup.digest(@code), expires_at: 0}) |> post("/auth/email/complete", %{code: @code})
    assert expired.status == 400
  end
end
