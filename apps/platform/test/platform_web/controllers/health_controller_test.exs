defmodule PlatformWeb.HealthControllerTest do
  @moduledoc """
  `GET /health` reports the build commit (task 01a089d5). The response must
  be shown to TRACK the build input: two injected shas produce two different
  bodies, and with nothing injected the fallback file path is exercised (the
  test env ships no `priv/build_commit`, asserted rather than assumed).
  """

  # async: false — mutates Application env.
  use PlatformWeb.ConnCase, async: false

  @sha_a "0123456789abcdef0123456789abcdef01234567"
  @sha_b "fedcba9876543210fedcba9876543210fedcba98"

  setup do
    on_exit(fn -> Application.delete_env(:platform, :build_commit) end)
    :ok
  end

  defp health(conn) do
    conn = get(conn, "/health")
    assert conn.status == 200
    assert [content_type | _] = get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
    Jason.decode!(conn.resp_body)
  end

  test "reports the injected commit and tracks it when it changes", %{conn: conn} do
    Application.put_env(:platform, :build_commit, @sha_a)
    body_a = health(conn)
    assert body_a == %{"status" => "ok", "commit" => @sha_a}

    Application.put_env(:platform, :build_commit, @sha_b)
    body_b = health(conn)
    assert body_b == %{"status" => "ok", "commit" => @sha_b}
    refute body_a == body_b
  end

  test "falls back to unknown when no commit is injected and no build file exists", %{conn: conn} do
    Application.delete_env(:platform, :build_commit)

    refute File.exists?(Application.app_dir(:platform, "priv/build_commit")),
           "test env unexpectedly ships priv/build_commit — the fallback path is not what this exercises"

    assert health(conn) == %{"status" => "ok", "commit" => "unknown"}
  end
end
