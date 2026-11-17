defmodule PlatformWeb.ReturnPathTest do
  @moduledoc """
  Task 01a1ccd4 stage 2: `RequireAuth` stores the requested local path before
  sending a signed-out browser to `/auth/login`, and the OIDC callback lands
  there. Every unsafe shape is refused on both sides. The OIDC request itself
  is unchanged (no `prompt`, no `login_hint`).
  """
  use PlatformWeb.ConnCase, async: false

  alias PlatformWeb.ReturnPath

  @unsafe [
    "//evil.example",
    "//evil.example/path",
    "https://evil.example",
    "https://evil.example/chat",
    "http:/evil.example",
    "/\\evil.example",
    "/\\\\evil.example",
    "/chat\\..\\evil",
    "javascript:alert(1)",
    "evil.example",
    "",
    "/chat\r\nSet-Cookie: x=1",
    "/chat\tx",
    "/chat x",
    "/chat#frag",
    "/auth/logout",
    "/auth/login",
    "/auth",
    "/" <> String.duplicate("a", 2048),
    nil,
    123
  ]

  describe "safe/1" do
    test "accepts local paths with queries" do
      for ok <- [
            "/",
            "/chat",
            "/chat/design",
            "/switcher/connect?origin=https%3A%2F%2Fa.example",
            "/tasks/abc?x=1&y=2",
            "/m/social?invite=abc",
            "/authors"
          ] do
        assert ReturnPath.safe(ok) == {:ok, ok}, ok
      end
    end

    test "refuses every unsafe shape" do
      for bad <- @unsafe do
        assert ReturnPath.safe(bad) == :error, inspect(bad)
      end
    end
  end

  defp mock_login do
    claims = %{"sub" => "return-path-sub", "email" => "rp@example.com", "name" => "Return Path"}

    Application.put_env(
      :platform,
      :oidc_mock_response,
      {:ok, %{user: claims, userinfo: claims, id_token: claims, token: %{"id_token" => "t"}}}
    )
  end

  setup do
    on_exit(fn -> Application.delete_env(:platform, :oidc_mock_response) end)
    :ok
  end

  defp sign_in_from(conn) do
    conn = get(conn, ~p"/auth/login")
    authorize = conn |> redirected_to(302) |> URI.parse()
    state = get_session(conn, :oidc_session_params).state
    mock_login()
    {conn |> recycle() |> get(~p"/auth/oidc/callback?code=c&state=#{state}"), authorize}
  end

  test "round trip: a signed-out GET lands back on its path and query", %{conn: conn} do
    path = "/switcher/connect?origin=https%3A%2F%2Fa.example"
    conn = get(conn, path)
    assert redirected_to(conn, 302) == "/auth/login"

    {conn, authorize} = conn |> recycle() |> sign_in_from()
    assert redirected_to(conn, 302) == path
    assert get_session(conn, :current_user_id)
    assert get_session(conn, :return_to) == nil

    # The OIDC request carries no prompt, login_hint or forwarded token.
    params = URI.decode_query(authorize.query || "")

    for key <- ["prompt", "login_hint", "id_token_hint", "id_token", "access_token"] do
      refute Map.has_key?(params, key), key
    end
  end

  test "a login with nothing stored lands on /", %{conn: conn} do
    {conn, _} = sign_in_from(conn)
    assert redirected_to(conn, 302) == "/"
  end

  test "a non-GET is not remembered", %{conn: conn} do
    conn = post(conn, "/switcher/connect", %{"origin" => "https://a.example"})
    assert redirected_to(conn, 302) == "/auth/login"
    assert get_session(conn, :return_to) == nil
  end

  test "an unsafe value planted in the session is ignored at the callback", %{conn: conn} do
    for bad <- ["//evil.example", "https://evil.example", "/\\evil.example"] do
      conn = build_conn() |> init_test_session(return_to: bad)
      {conn, _} = sign_in_from(conn)
      assert redirected_to(conn, 302) == "/", inspect(bad)
    end

    _ = conn
  end

  test "the hand-over landing still wins over a stored path", %{conn: conn} do
    interaction = "e8a7f28d-4e78-4f21-bec0-53dc068d471f"

    Req.Test.stub(Platform.OIDC, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/interaction?interaction=#{interaction}")
      |> Plug.Conn.send_resp(302, "")
    end)

    conn =
      conn
      |> init_test_session(return_to: "/chat/design")
      |> get(~p"/auth/handover?code=ABCDEFGHJKLM")

    assert get_session(conn, :post_login_path) == "/setup/connect-ai"
    assert get_session(conn, :return_to) == "/chat/design"
    state = get_session(conn, :oidc_session_params).state
    mock_login()

    conn = conn |> recycle() |> get(~p"/auth/oidc/callback?code=c&state=#{state}")
    assert redirected_to(conn, 302) == "/setup/connect-ai"
    assert get_session(conn, :return_to) == nil
  end
end
