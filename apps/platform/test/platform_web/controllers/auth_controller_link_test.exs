defmodule PlatformWeb.AuthControllerLinkTest do
  @moduledoc """
  `GET /auth/link?token=`: the durable form of the hand-over. A valid token
  mints a FRESH pocket-id one-time code (stubbed with Req.Test), then does
  exactly what `/auth/handover` does. A bad, expired or archived-user token
  is a plain-language 400 and never reaches pocket-id.
  """
  # async: false: sets the pocket-id URL and key in the application env.
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts
  alias Platform.SignIn.DurableLink

  @interaction "e8a7f28d-4e78-4f21-bec0-53dc068d471f"
  @expired "This sign-in link has expired. Ask your Burrow admin to send a new one."

  setup do
    for key <- [:sign_in_admin_url, :sign_in_admin_api_key] do
      prev = Application.fetch_env(:platform, key)

      on_exit(fn ->
        case prev do
          {:ok, v} -> Application.put_env(:platform, key, v)
          :error -> Application.delete_env(:platform, key)
        end
      end)
    end

    Application.put_env(:platform, :sign_in_admin_url, "http://pocket-id.test")
    Application.put_env(:platform, :sign_in_admin_api_key, "link-test-key-0123456789")
    test_pid = self()
    counter = :counters.new(1, [])

    Req.Test.stub(Platform.OIDC, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/interaction?interaction=#{@interaction}")
      |> Plug.Conn.send_resp(302, "")
    end)

    # A new code per call, so "fresh on every click" is observable.
    Req.Test.stub(Platform.SignInAdmin.PocketId, fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:pocket_id, conn.method, conn.request_path})
      Req.Test.json(Plug.Conn.put_status(conn, 201), %{"token" => "FRESHCODE#{n}ABC"})
    end)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oidc(%{
        sub: "pid-#{n}",
        email: "link-#{n}@example.test",
        name: "Link #{n}"
      })

    %{user: user}
  end

  defp link_path(user, purpose, opts \\ []) do
    DurableLink.url(user, purpose, opts) |> URI.parse() |> then(&"#{&1.path}?#{&1.query}")
  end

  test "a valid handover token mints a fresh code and redirects to pocket-id", %{
    conn: conn,
    user: user
  } do
    conn = get(conn, link_path(user, :handover))
    uri = conn |> redirected_to(302) |> URI.parse()

    assert {uri.scheme, uri.host, uri.path} ==
             {"https", "issuer.example.com", "/lc/FRESHCODE1ABC"}

    assert URI.decode_query(uri.query) == %{
             "redirect" => "/interaction?interaction=#{@interaction}"
           }

    assert_received {:pocket_id, "POST", "/api/users/" <> rest}
    assert rest == "#{user.oidc_sub}/one-time-access-token"
    assert get_session(conn, :oidc_session_params)
    assert get_session(conn, :post_login_path) == "/setup/connect-ai"
    assert get_session(conn, :signed_in_with_link) == true
  end

  test "the same link works again and mints a different code", %{conn: conn, user: user} do
    path = link_path(user, :handover)
    first = conn |> get(path) |> redirected_to(302)
    second = build_conn() |> get(path) |> redirected_to(302)
    assert first =~ "/lc/FRESHCODE1ABC"
    assert second =~ "/lc/FRESHCODE2ABC"
  end

  test "an invite token redirects but sets no connect-ai landing", %{conn: conn, user: user} do
    conn = get(conn, link_path(user, :invite))
    assert redirected_to(conn, 302) =~ "/lc/FRESHCODE1ABC"
    assert get_session(conn, :oidc_session_params)
    refute get_session(conn, :post_login_path)
    refute get_session(conn, :signed_in_with_link)
  end

  test "bad, missing, expired and archived-user tokens are a plain 400", %{
    conn: conn,
    user: user
  } do
    expired = link_path(user, :handover, signed_at: 0)

    for path <- ["/auth/link", "/auth/link?token=", "/auth/link?token=garbage", expired] do
      conn = get(build_conn(), path)
      assert conn.status == 400, path
      assert conn.resp_body == @expired
      refute get_session(conn, :oidc_session_params)
    end

    good = link_path(user, :handover)
    {:ok, _} = Accounts.archive_user(user, reason: "sign-in disabled")
    conn = get(conn, good)
    assert conn.status == 400
    assert conn.resp_body == @expired

    # None of the refusals reached pocket-id.
    refute_received {:pocket_id, _, _}
  end
end
