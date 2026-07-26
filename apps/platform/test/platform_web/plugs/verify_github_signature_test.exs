defmodule PlatformWeb.Plugs.VerifyGithubSignatureTest do
  @moduledoc """
  Tests for `PlatformWeb.Plugs.VerifyGithubSignature`.

  Exercises the plug in isolation with a hand-built conn whose
  `assigns[:raw_body]` matches (or intentionally mismatches) the bytes the
  signature was computed over. Also asserts the feature-flag rollback path
  (`github_webhook_signature_required: false`) passes bad signatures through
  with only a warning log.

  Task 019f9b11 stage 2 — GitHub webhook auth-bypass fix.
  """

  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias PlatformWeb.Plugs.VerifyGithubSignature

  @path "/api/webhooks/github"
  @flag :github_webhook_signature_required
  @secret_key :github_webhook_secret
  @secret "plug-test-github-secret"

  setup do
    prev_flag = Application.get_env(:platform, @flag)
    prev_secret = Application.get_env(:platform, @secret_key)

    Application.put_env(:platform, @flag, true)
    Application.put_env(:platform, @secret_key, @secret)

    on_exit(fn ->
      restore_env(@flag, prev_flag)
      restore_env(@secret_key, prev_secret)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:platform, key)
  defp restore_env(key, value), do: Application.put_env(:platform, key, value)

  defp sign(body, secret) do
    "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower))
  end

  defp payload do
    Jason.encode!(%{
      "action" => "completed",
      "check_suite" => %{"conclusion" => "success", "head_branch" => "task/abc"},
      "repository" => %{"html_url" => "https://github.com/example/repo"}
    })
  end

  # Mirrors what the endpoint hands the router: `Plug.Parsers` has already
  # decoded `body_params`, and `CacheBodyReader` has stashed the raw bytes.
  defp plug_conn(opts) do
    raw = Keyword.get(opts, :raw_body, "")
    signature = Keyword.get(opts, :signature)

    base =
      Plug.Test.conn(:post, @path, raw)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-github-event", "check_suite")
      |> Plug.Conn.put_req_header("x-github-delivery", "delivery-abc-123")
      |> Plug.Conn.assign(:raw_body, raw)
      |> Map.put(:body_params, decode_body(raw))

    if signature do
      Plug.Conn.put_req_header(base, "x-hub-signature-256", signature)
    else
      base
    end
  end

  defp decode_body(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = params} -> params
      _ -> %{}
    end
  end

  defp call(conn), do: VerifyGithubSignature.call(conn, VerifyGithubSignature.init([]))

  defp call_capturing(conn) do
    log =
      capture_log(fn ->
        send(self(), {:out, call(conn)})
      end)

    assert_received {:out, out}
    {out, log}
  end

  describe "call/2 with enforcement on" do
    test "passes a correctly signed delivery through" do
      body = payload()
      conn = plug_conn(raw_body: body, signature: sign(body, @secret))

      out = call(conn)

      refute out.halted
      assert out.status == nil
    end

    test "rejects a delivery with no signature header (:missing_signature)" do
      {out, log} = call_capturing(plug_conn(raw_body: payload()))

      assert out.halted
      assert out.status == 401

      assert Jason.decode!(out.resp_body) == %{
               "status" => "error",
               "reason" => "missing_signature"
             }

      assert log =~ "missing_signature"
      assert log =~ "x-github-event=\"check_suite\""
      assert log =~ "x-github-delivery=\"delivery-abc-123\""
    end

    test "rejects a malformed signature header (:malformed_signature)" do
      {out, log} = call_capturing(plug_conn(raw_body: payload(), signature: "not-a-signature"))

      assert out.halted
      assert out.status == 401

      assert Jason.decode!(out.resp_body) == %{
               "status" => "error",
               "reason" => "malformed_signature"
             }

      assert log =~ "malformed_signature"
    end

    test "rejects a signature computed under the wrong secret (:signature_mismatch)" do
      body = payload()

      {out, log} = call_capturing(plug_conn(raw_body: body, signature: sign(body, "wrong")))

      assert out.halted
      assert out.status == 401

      assert Jason.decode!(out.resp_body) == %{
               "status" => "error",
               "reason" => "signature_mismatch"
             }

      assert log =~ "signature_mismatch"
    end

    test "rejects a valid signature served over tampered bytes (:signature_mismatch)" do
      signed = payload()
      tampered = String.replace(signed, "success", "failure")
      refute signed == tampered

      out = plug_conn(raw_body: tampered, signature: sign(signed, @secret)) |> call_quietly()

      assert out.halted
      assert out.status == 401
      assert Jason.decode!(out.resp_body)["reason"] == "signature_mismatch"
    end

    test "hashes conn.assigns[:raw_body], not a re-encoded body_params" do
      # Same JSON, different key order + whitespace: a plug that re-encoded
      # `body_params` would compute a different digest and 401 here.
      raw =
        ~s({"repository": {"html_url": "https://github.com/example/repo"},  "action": "completed"})

      out = plug_conn(raw_body: raw, signature: sign(raw, @secret)) |> call()

      refute out.halted
    end

    test "rejects when no secret is configured anywhere (:no_secret_configured)" do
      Application.delete_env(:platform, @secret_key)
      body = payload()

      out = plug_conn(raw_body: body, signature: sign(body, @secret)) |> call_quietly()

      assert out.halted
      assert out.status == 401

      assert Jason.decode!(out.resp_body) == %{
               "status" => "error",
               "reason" => "no_secret_configured"
             }
    end

    test "prefers the per-project secret and still accepts the app-level one" do
      {:ok, _project} =
        Platform.Tasks.create_project(%{
          name: "Github Sig Plug #{System.unique_integer([:positive])}",
          repo_url: "https://github.com/example/repo",
          deploy_config: %{"webhook_secret" => "project-level-secret"}
        })

      body = payload()

      refute plug_conn(raw_body: body, signature: sign(body, "project-level-secret"))
             |> call()
             |> Map.fetch!(:halted)

      refute plug_conn(raw_body: body, signature: sign(body, @secret))
             |> call()
             |> Map.fetch!(:halted)
    end

    test "ignores a query string trying to steer secret selection" do
      # `body_params` (not `params`) is the source of `repository.html_url`,
      # so the query string below cannot point verification at another
      # project's secret.
      body = Jason.encode!(%{"action" => "completed"})

      conn =
        Plug.Test.conn(:post, @path <> "?repository[html_url]=https://github.com/evil/repo", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.assign(:raw_body, body)
        |> Map.put(:body_params, Jason.decode!(body))
        |> Plug.Conn.put_req_header("x-hub-signature-256", sign(body, @secret))

      refute call(conn).halted
    end
  end

  describe "call/2 with enforcement off (rollback safety valve)" do
    setup do
      prev = Application.get_env(:platform, @flag)
      Application.put_env(:platform, @flag, false)
      on_exit(fn -> restore_env(@flag, prev) end)
      :ok
    end

    test "passes a bad-signature request through with a warning log" do
      body = payload()

      {out, log} = call_capturing(plug_conn(raw_body: body, signature: sign(body, "wrong")))

      assert log =~ "github_webhook_signature_required is false"
      refute out.halted
      assert out.status == nil
    end

    test "passes an unsigned request through with a warning log" do
      {out, log} = call_capturing(plug_conn(raw_body: payload()))

      assert log =~ "github_webhook_signature_required is false"
      refute out.halted
    end

    test "still passes valid signatures through cleanly" do
      body = payload()

      out = call(plug_conn(raw_body: body, signature: sign(body, @secret)))

      refute out.halted
      assert out.status == nil
    end
  end

  # These go through the real endpoint + router rather than calling the plug
  # directly, so they fail if `pipeline :github_webhook` is ever unwired from
  # the `/api/webhooks/github` scope — the plug being correct is not the same
  # claim as the route being guarded.
  describe "router pipeline wiring" do
    test "an unsigned POST to /api/webhooks/github is rejected before the controller runs",
         %{conn: conn} do
      body = payload()

      conn =
        capture_log_around(fn ->
          conn
          |> put_req_header("content-type", "application/json")
          |> post(@path, body)
        end)

      assert conn.halted
      assert json_response(conn, 401) == %{"status" => "error", "reason" => "missing_signature"}
    end

    test "a mis-signed POST to /api/webhooks/github is rejected", %{conn: conn} do
      body = payload()

      conn =
        capture_log_around(fn ->
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("x-hub-signature-256", sign(body, "wrong"))
          |> post(@path, body)
        end)

      assert json_response(conn, 401) == %{"status" => "error", "reason" => "signature_mismatch"}
    end

    test "a correctly signed POST reaches the controller", %{conn: conn} do
      body = Jason.encode!(%{"action" => "opened", "issue" => %{}})

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", sign(body, @secret))
        |> post(@path, body)

      refute conn.halted
      assert %{"status" => "ignored"} = json_response(conn, 200)
    end
  end

  defp capture_log_around(fun) do
    capture_log(fn -> send(self(), {:out, fun.()}) end)
    assert_received {:out, out}
    out
  end

  defp call_quietly(conn) do
    {out, _log} = call_capturing(conn)
    out
  end
end
