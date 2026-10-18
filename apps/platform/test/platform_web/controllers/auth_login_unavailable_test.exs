defmodule PlatformWeb.AuthLoginUnavailableTest do
  @moduledoc """
  `/auth/login` on an install whose sign-in is not set up, or cannot reach
  its provider (task 01a10322 stage 6): a readable 503, never a raise and
  never an inspected exception struct.

  Measured on test-host (release image 336bdefe, empty DB, 2026-10-09): a release
  with no OIDC settings refuses to boot (`Platform.Config.validate!/0`), and
  one whose issuer is unreachable answered `/auth/login` with a 500 that
  printed `%Assent.ServerUnreachableError{...}`. The missing-settings branch
  is what a dev or test boot without the settings reached (`oidc.ex` raised).
  """
  use PlatformWeb.ConnCase, async: false

  defmodule FailingStrategy do
    @moduledoc false
    def authorize_url(_config),
      do: {:error, %RuntimeError{message: "request_url=https://idp.invalid/secret-detail"}}
  end

  setup do
    previous = Application.get_env(:platform, :oidc)
    on_exit(fn -> Application.put_env(:platform, :oidc, previous) end)
    %{oidc: previous}
  end

  test "no issuer or client id: a 503 naming the settings", %{conn: conn, oidc: oidc} do
    Application.put_env(
      :platform,
      :oidc,
      oidc |> Keyword.put(:issuer, nil) |> Keyword.put(:client_id, "")
    )

    conn = get(conn, "/auth/login")

    assert conn.status == 503
    assert conn.resp_body =~ "OIDC_ISSUER"
    assert conn.resp_body =~ "OIDC_CLIENT_ID"
    refute conn.resp_body =~ "OIDC_CLIENT_SECRET"
    assert conn.resp_body =~ "Sign-in is not set up on this install."
  end

  test "nothing configured names all three", %{conn: conn} do
    Application.put_env(:platform, :oidc, app_url: "http://www.example.com")
    conn = get(conn, "/auth/login")

    assert conn.status == 503
    assert conn.resp_body =~ "OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET"
  end

  test "an unreachable provider: a readable 503, no struct", %{conn: conn, oidc: oidc} do
    Application.put_env(:platform, :oidc, Keyword.put(oidc, :strategy, FailingStrategy))

    {conn, log} =
      ExUnit.CaptureLog.with_log(fn -> get(conn, "/auth/login") end)

    assert conn.status == 503
    assert conn.resp_body =~ "could not reach its sign-in provider"
    refute conn.resp_body =~ "%"
    refute conn.resp_body =~ "secret-detail"
    refute log =~ "secret-detail"
    assert log =~ "RuntimeError"
  end

  test "POSITIVE CONTROL: configured login still redirects to the provider", %{conn: conn} do
    conn = get(conn, "/auth/login")
    assert conn.status == 302
    assert redirected_to(conn) =~ "https://issuer.example.com/authorize?"
  end
end
