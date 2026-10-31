defmodule PlatformWeb.AuthControllerHandoverTest do
  @moduledoc """
  Task 01a10315 stage 6 round 2: a new install's hand-over sign-in link is
  `/auth/handover?code=<pocket-id one-time code>`. It starts Burrow's own
  OIDC login, opens the matching pocket-id sign-in interaction server-side
  (`GET /authorize`, stubbed here with Req.Test) and sends the code to
  pocket-id's `/lc/<code>` with `redirect=` that interaction's RELATIVE path,
  so after pocket-id signs the owner in (and one "Sign in" click) it returns
  to `/auth/oidc/callback`, which lands on `/setup/connect-ai` instead of `/`.
  """
  use PlatformWeb.ConnCase

  @code "ABCDEFGHJKLM"
  @interaction "e8a7f28d-4e78-4f21-bec0-53dc068d471f"

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)
    test_pid = self()

    # pocket-id's answer to a cookie-less GET /authorize (measured on v2.18.0).
    Req.Test.stub(Platform.OIDC, fn conn ->
      send(test_pid, {:authorize_request, conn.host, conn.request_path, conn.query_string})

      conn
      |> Plug.Conn.put_resp_header("location", "/interaction?interaction=#{@interaction}")
      |> Plug.Conn.send_resp(302, "")
    end)

    :ok
  end

  defp stub_authorize(status, location) do
    Req.Test.stub(Platform.OIDC, fn conn ->
      conn = if location, do: Plug.Conn.put_resp_header(conn, "location", location), else: conn
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp mock_login do
    claims = %{"sub" => "handover-sub", "email" => "owner@example.com", "name" => "Owner"}

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "t"}}}
    )
  end

  test "opens the interaction for THIS login and hands the code to pocket-id with it",
       %{conn: conn} do
    conn = get(conn, ~p"/auth/handover?code=#{@code}")
    location = redirected_to(conn, 302)
    uri = URI.parse(location)

    assert {uri.scheme, uri.host, uri.path} == {"https", "issuer.example.com", "/lc/#{@code}"}
    # Relative, and one of pocket-id's own pages: its code page refuses anything else.
    assert URI.decode_query(uri.query) == %{
             "redirect" => "/interaction?interaction=#{@interaction}"
           }

    # The interaction was opened with this session's authorize request.
    assert_received {:authorize_request, "issuer.example.com", "/authorize", query}
    authorize = URI.decode_query(query)
    session_params = get_session(conn, :oidc_session_params)
    assert authorize["state"] == session_params.state
    assert authorize["redirect_uri"] =~ "/auth/oidc/callback"
    assert get_session(conn, :post_login_path) == "/setup/connect-ai"
    assert get_session(conn, :signed_in_with_link) == true
  end

  test "an absolute same-origin interaction location is accepted as its relative path",
       %{conn: conn} do
    stub_authorize(302, "https://issuer.example.com/interaction?interaction=#{@interaction}")
    uri = conn |> get(~p"/auth/handover?code=#{@code}") |> redirected_to(302) |> URI.parse()

    assert URI.decode_query(uri.query) == %{
             "redirect" => "/interaction?interaction=#{@interaction}"
           }
  end

  test "anything but a same-origin interaction redirect is a 503, with no landing set",
       %{conn: conn} do
    for {status, location} <- [
          {303, "https://www.example.com/auth/oidc/callback?error=invalid_request&state=x"},
          {302, "https://evil.example/interaction?interaction=#{@interaction}"},
          {302, "/interaction?interaction=#{@interaction}&next=https://evil.example"},
          {302, "/login?redirect=%2Fsettings"},
          {302, nil},
          {200, nil}
        ] do
      stub_authorize(status, location)
      conn = get(conn, ~p"/auth/handover?code=#{@code}")
      assert conn.status == 503, inspect({status, location})
      refute conn.resp_body =~ @code
      refute get_session(conn, :post_login_path)
    end
  end

  test "the callback that follows lands on /setup/connect-ai, once", %{conn: conn} do
    conn = get(conn, ~p"/auth/handover?code=#{@code}")
    state = get_session(conn, :oidc_session_params).state
    mock_login()

    conn = conn |> recycle() |> get(~p"/auth/oidc/callback?code=c&state=#{state}")
    assert redirected_to(conn, 302) == "/setup/connect-ai"
    assert get_session(conn, :current_user_id)
    assert get_session(conn, :post_login_path) == nil
  end

  test "an ordinary login after an abandoned hand-over lands on /", %{conn: conn} do
    conn = get(conn, ~p"/auth/handover?code=#{@code}")
    conn = conn |> recycle() |> get(~p"/auth/login")
    state = get_session(conn, :oidc_session_params).state
    mock_login()

    conn = conn |> recycle() |> get(~p"/auth/oidc/callback?code=c&state=#{state}")
    assert redirected_to(conn, 302) == "/"
  end

  test "a malformed or missing code is refused and never echoed", %{conn: conn} do
    for path <- [
          "/auth/handover",
          "/auth/handover?code=",
          "/auth/handover?code=short",
          "/auth/handover?code=ABCDEF%2F..%2Fx",
          "/auth/handover?code=https%3A%2F%2Fevil.example"
        ] do
      conn = get(build_conn(), path)
      assert conn.status == 400, path
      assert conn.resp_body == "Sign-in link is invalid or has expired"
      refute get_session(conn, :post_login_path)
    end

    # Positive control: the same conn helper does redirect a valid code.
    assert get(conn, ~p"/auth/handover?code=#{@code}").status == 302
  end
end
