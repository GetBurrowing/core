defmodule PlatformWeb.Plugs.VerifyLivekitSignatureTest do
  @moduledoc """
  Tests for `PlatformWeb.Plugs.VerifyLivekitSignature`.

  Exercises the plug in isolation with a hand-built conn whose
  `assigns[:raw_body]` matches (or intentionally mismatches) the body
  the JWT was minted against. Also asserts the feature-flag rollback
  path (`livekit_webhook_signature_required: false`) passes bad
  signatures through with only a warning log.

  Task 019f3312 stage 2 — phantom-fix v4.
  """

  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Platform.LivekitTestHelpers
  alias Platform.Meetings
  alias PlatformWeb.Plugs.VerifyLivekitSignature

  @path "/api/webhooks/livekit"
  @flag :livekit_webhook_signature_required
  @livekit_key :livekit

  setup do
    prev_flag = Application.get_env(:platform, @flag)
    prev_livekit = Application.get_env(:platform, @livekit_key)
    # Point the app at the fixture secret so `verify_livekit_jwt/2` finds
    # a real value in `livekit_config()`. Restored on exit.
    Application.put_env(:platform, @livekit_key,
      api_key: "test-livekit-key",
      api_secret: LivekitTestHelpers.default_secret()
    )

    # Force the flag ON — controller-level tests keep it off, so we
    # explicitly opt this suite into enforcement.
    Application.put_env(:platform, @flag, true)

    on_exit(fn ->
      restore_env(@flag, prev_flag)
      restore_env(@livekit_key, prev_livekit)
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:platform, key)
  defp restore_env(key, value), do: Application.put_env(:platform, key, value)

  defp signed_conn(body, opts \\ []) do
    {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)
    auth = Keyword.get(opts, :auth, jwt)
    raw = Keyword.get(opts, :raw_body, body)

    plug_conn(auth: auth, raw_body: raw)
  end

  defp plug_conn(opts) do
    auth = Keyword.get(opts, :auth)
    raw = Keyword.get(opts, :raw_body, "")

    base =
      Plug.Test.conn(:post, @path, raw)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.assign(:raw_body, raw)

    if auth do
      Plug.Conn.put_req_header(base, "authorization", auth)
    else
      base
    end
  end

  describe "call/2 with enforcement on" do
    test "passes a fully valid signed payload through" do
      body = Jason.encode!(%{"event" => "room_started", "room" => %{"name" => "space-x"}})
      conn = signed_conn(body)

      out = VerifyLivekitSignature.call(conn, VerifyLivekitSignature.init([]))

      refute out.halted
      assert out.status == nil
    end

    test "accepts `Bearer ` prefix on the Authorization header" do
      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      conn = plug_conn(auth: "Bearer " <> jwt, raw_body: body)

      out = VerifyLivekitSignature.call(conn, VerifyLivekitSignature.init([]))

      refute out.halted
      assert out.status == nil
    end

    test "rejects a request with no Authorization header (:malformed)" do
      conn = plug_conn(raw_body: Jason.encode!(%{"event" => "x"}))

      out =
        capture_log(fn ->
          send(self(), {:out, VerifyLivekitSignature.call(conn, VerifyLivekitSignature.init([]))})
        end)

      assert out =~ "signature verification failed"
      assert_received {:out, halted_conn}

      assert halted_conn.halted
      assert halted_conn.status == 401

      assert Jason.decode!(halted_conn.resp_body) == %{
               "status" => "error",
               "reason" => "malformed"
             }
    end

    test "rejects a valid signature over a different body (:body_hash_mismatch)" do
      original = Jason.encode!(%{"event" => "room_started", "room" => %{"name" => "space-x"}})
      {_original, jwt} = LivekitTestHelpers.sign_livekit_payload(original)

      # Serve a different raw body than the one the JWT was minted for.
      tampered = Jason.encode!(%{"event" => "room_started", "room" => %{"name" => "space-y"}})
      conn = plug_conn(auth: jwt, raw_body: tampered)

      out =
        capture_log(fn ->
          send(self(), {:out, VerifyLivekitSignature.call(conn, VerifyLivekitSignature.init([]))})
        end)

      assert out =~ "body_hash_mismatch"
      assert_received {:out, halted_conn}
      assert halted_conn.halted
      assert halted_conn.status == 401

      assert Jason.decode!(halted_conn.resp_body) ==
               %{"status" => "error", "reason" => "body_hash_mismatch"}
    end

    test "rejects a tampered signature (:bad_signature)" do
      body = Jason.encode!(%{"event" => "room_started"})
      {body, jwt} = LivekitTestHelpers.sign_livekit_payload(body)

      # Flip the last character of the signature segment to invalidate HS256.
      [h, p, s] = String.split(jwt, ".", parts: 3)

      flipped =
        String.slice(s, 0..-2//1) <>
          if String.last(s) == "A", do: "B", else: "A"

      bad_jwt = Enum.join([h, p, flipped], ".")

      conn = plug_conn(auth: bad_jwt, raw_body: body)

      out =
        capture_log(fn ->
          send(self(), {:out, VerifyLivekitSignature.call(conn, VerifyLivekitSignature.init([]))})
        end)

      assert out =~ "bad_signature"
      assert_received {:out, halted_conn}
      assert halted_conn.halted
      assert halted_conn.status == 401

      assert Jason.decode!(halted_conn.resp_body) ==
               %{"status" => "error", "reason" => "bad_signature"}
    end

    test "rejects an expired token (:expired)" do
      body = Jason.encode!(%{"event" => "room_started"})
      body_hash = :crypto.hash(:sha256, body) |> Base.encode64()

      past = System.system_time(:second) - 3600

      claims = %{
        "iss" => "test-livekit-key",
        "nbf" => past - 600,
        "exp" => past,
        "sha256" => body_hash
      }

      jwt = Meetings.encode_jwt(claims, LivekitTestHelpers.default_secret())
      conn = plug_conn(auth: jwt, raw_body: body)

      out =
        capture_log(fn ->
          send(self(), {:out, VerifyLivekitSignature.call(conn, VerifyLivekitSignature.init([]))})
        end)

      assert out =~ "expired"
      assert_received {:out, halted_conn}
      assert halted_conn.halted
      assert halted_conn.status == 401
      assert Jason.decode!(halted_conn.resp_body) == %{"status" => "error", "reason" => "expired"}
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
      body = Jason.encode!(%{"event" => "room_started"})
      conn = plug_conn(auth: "not-a-real-jwt", raw_body: body)

      log =
        capture_log(fn ->
          send(self(), {:out, VerifyLivekitSignature.call(conn, VerifyLivekitSignature.init([]))})
        end)

      assert log =~ "livekit_webhook_signature_required is false"
      assert_received {:out, out}
      refute out.halted
      assert out.status == nil
    end

    test "still passes valid signatures through cleanly" do
      body = Jason.encode!(%{"event" => "room_started"})
      conn = signed_conn(body)

      out = VerifyLivekitSignature.call(conn, VerifyLivekitSignature.init([]))

      refute out.halted
      assert out.status == nil
    end
  end
end
