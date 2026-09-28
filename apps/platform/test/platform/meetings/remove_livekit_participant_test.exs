defmodule Platform.Meetings.RemoveLivekitParticipantTest do
  @moduledoc """
  Task 01a0e906 stage 1 — `Meetings.remove_livekit_participant/2`, the
  `RoomService/RemoveParticipant` Twirp call that forces an identity off the
  LiveKit media room.

  Pins the wire shape (method, path, exact body, a `roomAdmin` token scoped
  to the room), exactly one request per call, and that every way LiveKit can
  fail to answer is an `{:error, _}` tuple rather than a raise.

  `async: false`: the LiveKit config and the injected Req client are
  application env.
  """
  use Platform.DataCase, async: false

  alias Platform.Meetings

  @room "space-33333333-3333-3333-3333-333333333333"
  @identity "agent:some-slug"

  defp put_livekit_env(attrs) do
    original = Application.get_env(:platform, :livekit, [])
    Application.put_env(:platform, :livekit, attrs)
    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
  end

  defp configured,
    do: put_livekit_env(api_key: "k", api_secret: "s-0123456789abcdef", url: "wss://livekit.test")

  # Same Req.Test pattern as `Platform.Meetings.MediaRoomPresenceTest`. Every
  # request the stub sees is reported to the test process, so a test can
  # assert an exact request count (1 or 0), not merely that the stub ran.
  defp stub_livekit(response_fn) do
    {:ok, _} = Application.ensure_all_started(:req)
    test_pid = self()
    Application.put_env(:platform, :livekit_req_client, Req.new(plug: {Req.Test, :livekit_test}))

    Req.Test.stub(:livekit_test, fn conn ->
      send(test_pid, {:livekit_request, conn.request_path})
      response_fn.(conn)
    end)

    on_exit(&Platform.LivekitStubPlug.restore_default_req_client/0)
  end

  defp request_count(acc \\ 0) do
    receive do
      {:livekit_request, _path} -> request_count(acc + 1)
    after
      0 -> acc
    end
  end

  describe "remove_livekit_participant/2" do
    test "posts room+identity to RemoveParticipant with a room-scoped roomAdmin token, once" do
      configured()

      stub_livekit(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/twirp/livekit.RoomService/RemoveParticipant"
        assert conn.scheme == :https
        assert conn.host == "livekit.test"

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"room" => @room, "identity" => @identity}

        ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")

        assert %{"video" => %{"roomAdmin" => true, "room" => @room}, "iss" => "k"} =
                 decode_claims(jwt)

        Req.Test.json(conn, %{})
      end)

      assert Meetings.remove_livekit_participant(@room, @identity) == :ok
      # Positive control for the 0-request tests below: this counter reads 1.
      assert request_count() == 1
    end

    test "404 with a Twirp not_found body is {:error, :not_found}" do
      configured()

      stub_livekit(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"code" => "not_found", "msg" => "participant not found"})
      end)

      assert Meetings.remove_livekit_participant(@room, @identity) == {:error, :not_found}
      assert request_count() == 1
    end

    test "a Twirp not_found body under a non-404 status is still {:error, :not_found}" do
      configured()

      stub_livekit(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.text(~s({"code":"not_found","msg":"participant not found"}))
      end)

      assert Meetings.remove_livekit_participant(@room, @identity) == {:error, :not_found}
    end

    test "HTTP 500 is {:error, {:http_error, 500, _}}, not :not_found" do
      configured()

      stub_livekit(fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"code" => "internal", "msg" => "boom"})
      end)

      assert {:error, {:http_error, 500, _body}} =
               Meetings.remove_livekit_participant(@room, @identity)
    end

    test "a transport error is {:error, _} and does not raise" do
      configured()
      stub_livekit(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Meetings.remove_livekit_participant(@room, @identity)
    end

    test "unconfigured LiveKit is {:error, :livekit_not_configured} with 0 requests" do
      put_livekit_env([])
      stub_livekit(fn conn -> Req.Test.json(conn, %{}) end)

      assert Meetings.remove_livekit_participant(@room, @identity) ==
               {:error, :livekit_not_configured}

      assert request_count() == 0
    end
  end

  defp decode_claims(jwt) do
    jwt
    |> String.split(".")
    |> Enum.at(1)
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end
end
