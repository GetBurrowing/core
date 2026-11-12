defmodule PlatformWeb.SwitcherKeyControllerTest do
  @moduledoc """
  Task 01a1ccd4 stage 3: `DELETE /api/switcher/key`, the best-effort revoke
  install A's web switcher sends when the person removes install B. The key
  revokes ITSELF, under the same CORS and origin binding as the unread route.
  """
  use PlatformWeb.ConnCase, async: true

  import Platform.ExternalUserFixtures

  alias Platform.Switcher

  @a "https://a.example"

  setup %{conn: conn} do
    user = create_user!()
    {:ok, %{token: token, key: key}} = Switcher.mint(user, @a)
    %{conn: conn, user: user, token: token, key: key}
  end

  defp with_key(conn, token, origin) do
    conn
    |> then(&if(token, do: put_req_header(&1, "authorization", "Bearer " <> token), else: &1))
    |> then(&if(origin, do: put_req_header(&1, "origin", origin), else: &1))
  end

  test "a live key from its bound origin revokes itself: 204, then unread is 401", %{
    conn: conn,
    token: token
  } do
    conn1 = conn |> with_key(token, @a) |> delete("/api/switcher/key")
    assert conn1.status == 204
    assert get_resp_header(conn1, "access-control-allow-origin") == [@a]
    assert get_resp_header(conn1, "access-control-allow-credentials") == []

    assert :error = Switcher.verify(token, @a)

    conn2 = build_conn() |> with_key(token, @a) |> get("/api/switcher/unread")
    assert conn2.status == 401
  end

  test "another origin, no key, or a wrong key cannot revoke it", %{conn: conn, token: token} do
    for {t, origin} <- [{token, "https://evil.example"}, {nil, @a}, {"bk_nope", @a}] do
      c = conn |> recycle() |> with_key(t, origin) |> delete("/api/switcher/key")
      assert c.status == 401
      assert get_resp_header(c, "access-control-allow-origin") == []
    end

    assert {:ok, _user, _key} = Switcher.verify(token, @a)
  end

  test "a second DELETE with the now-revoked key is 401", %{conn: conn, token: token} do
    assert (conn |> with_key(token, @a) |> delete("/api/switcher/key")).status == 204
    assert (build_conn() |> with_key(token, @a) |> delete("/api/switcher/key")).status == 401
  end

  test "it revokes only that key, not the user's keys for other origins", %{
    conn: conn,
    user: user,
    token: token
  } do
    {:ok, %{token: other}} = Switcher.mint(user, "https://b.example")
    assert (conn |> with_key(token, @a) |> delete("/api/switcher/key")).status == 204
    assert {:ok, _, _} = Switcher.verify(other, "https://b.example")
  end

  test "the preflight allows DELETE with Authorization for a well-formed origin", %{conn: conn} do
    c = conn |> put_req_header("origin", @a) |> options("/api/switcher/key")
    assert c.status == 204
    assert get_resp_header(c, "access-control-allow-origin") == [@a]
    assert get_resp_header(c, "access-control-allow-methods") == ["GET, DELETE"]
    assert get_resp_header(c, "access-control-allow-headers") == ["Authorization"]
  end
end
