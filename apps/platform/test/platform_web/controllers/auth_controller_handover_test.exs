defmodule PlatformWeb.AuthControllerHandoverTest do
  @moduledoc """
  Task 01a10315 stage 6 round 2: a new install's hand-over sign-in link is
  `/auth/handover?code=<pocket-id one-time code>`. It starts Burrow's own
  OIDC login and sends the code to pocket-id's `/lc/<code>` with `redirect=`
  the RELATIVE authorize request, so after pocket-id signs the owner in it
  returns to `/auth/oidc/callback`, which lands on `/setup/connect-ai`
  instead of `/`.
  """
  use PlatformWeb.ConnCase

  @code "ABCDEFGHJKLM"

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)
    :ok
  end

  defp mock_login do
    claims = %{"sub" => "handover-sub", "email" => "owner@example.com", "name" => "Owner"}

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "t"}}}
    )
  end

  test "hands the code to pocket-id with the authorize request as a relative redirect",
       %{conn: conn} do
    conn = get(conn, ~p"/auth/handover?code=#{@code}")
    location = redirected_to(conn, 302)
    uri = URI.parse(location)

    assert {uri.scheme, uri.host, uri.path} == {"https", "issuer.example.com", "/lc/#{@code}"}
    %{"redirect" => redirect} = URI.decode_query(uri.query)

    # Same-origin and relative: pocket-id's code page refuses anything else.
    assert "/authorize?" <> query = redirect
    authorize = URI.decode_query(query)
    session_params = get_session(conn, :oidc_session_params)
    assert authorize["state"] == session_params.state
    assert authorize["redirect_uri"] =~ "/auth/oidc/callback"
    assert get_session(conn, :post_login_path) == "/setup/connect-ai"
    assert get_session(conn, :signed_in_with_link) == true
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
