defmodule PlatformWeb.VaultFetchControllerTest do
  @moduledoc """
  Task 01a131c5 stage 1 — `GET /vault/fetch/:token`. No session: the token
  is the only auth.
  """
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Platform.VaultFixtures

  alias Platform.Vault.Fetch
  alias Platform.Vault.Shared

  @value "fake-controller-value"

  setup do
    admin = admin!()
    agent = agent!()
    slug = unique_slug()
    {:ok, cred} = Shared.create(admin, %{slug: slug, value: @value}, [agent.id])
    {:ok, %{url: url}} = Fetch.issue(agent.id, slug)
    path = "/vault/fetch/" <> (url |> String.split("/vault/fetch/") |> List.last())
    %{admin: admin, agent: agent, cred: cred, path: path}
  end

  test "200 with the raw body and no-store, then 410 on reuse", %{conn: conn, path: path} do
    conn1 = get(conn, path)

    assert conn1.status == 200
    assert conn1.resp_body == @value
    assert get_resp_header(conn1, "cache-control") == ["no-store"]
    assert get_resp_header(conn1, "content-type") == ["application/octet-stream"]
    assert get_resp_header(conn1, "content-disposition") == ["attachment"]

    conn2 = get(build_conn(), path)
    assert conn2.status == 410
    refute conn2.resp_body =~ @value
  end

  test "403 after the grant is removed", %{conn: conn, path: path} = ctx do
    :ok = Shared.set_grants(ctx.admin, ctx.cred.id, [])

    conn = get(conn, path)
    assert conn.status == 403
    refute conn.resp_body =~ @value
  end

  test "410 for an unknown token", %{conn: conn} do
    conn = get(conn, "/vault/fetch/not-a-real-token")
    assert conn.status == 410
  end

  describe "request logging" do
    setup do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "the token never reaches the request log; other paths still log", %{path: path} do
      "/vault/fetch/" <> token = path

      log = capture_log([level: :info], fn -> get(build_conn(), path) end)
      refute log =~ token
      refute log =~ @value

      # Positive control: the same capture DOES see an ordinary request line,
      # so the refute above is not passing on a silenced logger.
      control = capture_log([level: :info], fn -> get(build_conn(), "/favicon.ico") end)
      assert control =~ "GET /favicon.ico"
    end

    test "request_log_level/1 is false only for the vault fetch path" do
      assert PlatformWeb.Endpoint.request_log_level(%Plug.Conn{path_info: ~w(vault fetch x)}) ==
               false

      assert PlatformWeb.Endpoint.request_log_level(%Plug.Conn{path_info: ~w(chat)}) == :info
    end
  end
end
