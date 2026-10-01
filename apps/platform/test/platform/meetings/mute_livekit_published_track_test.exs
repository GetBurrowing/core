defmodule Platform.Meetings.MuteLivekitPublishedTrackTest do
  @moduledoc """
  Task 01a0f842 stage 5, canvas 01a0f846-cfb1 —
  `Meetings.mute_livekit_published_track/3`, the `RoomService/
  MutePublishedTrack` Twirp call that mutes/unmutes an agent's published
  audio track. NET-NEW: no agent mute wire call existed anywhere on main
  before this stage.

  Unlike `remove_livekit_participant/2` (one request: `RemoveParticipant`
  only needs an identity), this is a TWO-REQUEST call: `MutePublishedTrack`
  addresses a track, not a participant, so this first resolves the
  identity's published audio track sid via `RoomService/ListParticipants`
  (the same call `list_livekit_participants/1` makes) and only then mutes
  it. Pins both request shapes, the exact order, and that every way either
  leg can fail to answer is an `{:error, _}` tuple rather than a raise.

  Same `Req.Test` stub pattern as `RemoveLivekitParticipantTest`.
  `async: false`: the LiveKit config and the injected Req client are
  application env.
  """
  use Platform.DataCase, async: false

  alias Platform.Meetings

  @room "space-33333333-3333-3333-3333-333333333333"
  @identity "agent:some-slug"
  @track_sid "TR_audio123"

  defp put_livekit_env(attrs) do
    original = Application.get_env(:platform, :livekit, [])
    Application.put_env(:platform, :livekit, attrs)
    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
  end

  defp configured,
    do: put_livekit_env(api_key: "k", api_secret: "s-0123456789abcdef", url: "wss://livekit.test")

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

  defp list_participants_body(tracks) do
    %{
      "participants" => [
        %{"identity" => @identity, "tracks" => tracks},
        # A second participant, to prove the resolver matches on IDENTITY
        # rather than just taking the first audio track in the room.
        %{
          "identity" => "user:someone-else",
          "tracks" => [%{"sid" => "TR_other", "type" => "AUDIO"}]
        }
      ]
    }
  end

  defp list_ok(conn, tracks), do: Req.Test.json(conn, list_participants_body(tracks))

  describe "mute_livekit_published_track/3" do
    test "resolves the audio track via ListParticipants, then MUTES it — two requests, in order" do
      configured()

      stub_livekit(fn conn ->
        case conn.request_path do
          "/twirp/livekit.RoomService/ListParticipants" ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(raw) == %{"room" => @room}

            list_ok(
              conn,
              # A VIDEO track alongside AUDIO, to prove the resolver filters
              # by type rather than taking whatever sid comes first.
              [
                %{"sid" => "TR_video", "type" => "VIDEO"},
                %{"sid" => @track_sid, "type" => "AUDIO"}
              ]
            )

          "/twirp/livekit.RoomService/MutePublishedTrack" ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)

            assert Jason.decode!(raw) == %{
                     "room" => @room,
                     "identity" => @identity,
                     "track_sid" => @track_sid,
                     "muted" => true
                   }

            ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")

            assert %{"video" => %{"roomAdmin" => true, "room" => @room}, "iss" => "k"} =
                     decode_claims(jwt)

            Req.Test.json(conn, %{})
        end
      end)

      assert Meetings.mute_livekit_published_track(@room, @identity, true) == :ok
      assert request_count() == 2
    end

    test "UNMUTES with muted: false" do
      configured()

      stub_livekit(fn conn ->
        case conn.request_path do
          "/twirp/livekit.RoomService/ListParticipants" ->
            list_ok(conn, [%{"sid" => @track_sid, "type" => "AUDIO"}])

          "/twirp/livekit.RoomService/MutePublishedTrack" ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            assert Jason.decode!(raw)["muted"] == false
            Req.Test.json(conn, %{})
        end
      end)

      assert Meetings.mute_livekit_published_track(@room, @identity, false) == :ok
      assert request_count() == 2
    end

    test "no audio track published is {:error, :no_audio_track}; MutePublishedTrack never fires" do
      configured()

      stub_livekit(fn conn ->
        assert conn.request_path == "/twirp/livekit.RoomService/ListParticipants"
        list_ok(conn, [%{"sid" => "TR_video", "type" => "VIDEO"}])
      end)

      assert Meetings.mute_livekit_published_track(@room, @identity, true) ==
               {:error, :no_audio_track}

      assert request_count() == 1
    end

    test "an identity absent from ListParticipants is {:error, :no_audio_track}" do
      configured()

      stub_livekit(fn conn ->
        Req.Test.json(conn, %{"participants" => []})
      end)

      assert Meetings.mute_livekit_published_track(@room, @identity, true) ==
               {:error, :no_audio_track}
    end

    test "ListParticipants 404 not_found is {:error, :not_found}; MutePublishedTrack never fires" do
      configured()

      stub_livekit(fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"code" => "not_found", "msg" => "room not found"})
      end)

      assert Meetings.mute_livekit_published_track(@room, @identity, true) ==
               {:error, :not_found}

      assert request_count() == 1
    end

    test "ListParticipants 500 is {:error, {:http_error, 500, _}}" do
      configured()

      stub_livekit(fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"code" => "internal", "msg" => "boom"})
      end)

      assert {:error, {:http_error, 500, _body}} =
               Meetings.mute_livekit_published_track(@room, @identity, true)

      assert request_count() == 1
    end

    test "MutePublishedTrack 404 Twirp not_found is {:error, :not_found}" do
      configured()

      stub_livekit(fn conn ->
        case conn.request_path do
          "/twirp/livekit.RoomService/ListParticipants" ->
            list_ok(conn, [%{"sid" => @track_sid, "type" => "AUDIO"}])

          "/twirp/livekit.RoomService/MutePublishedTrack" ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"code" => "not_found", "msg" => "track not found"})
        end
      end)

      assert Meetings.mute_livekit_published_track(@room, @identity, true) ==
               {:error, :not_found}

      assert request_count() == 2
    end

    test "a transport error on ListParticipants is {:error, _} and does not raise" do
      configured()
      stub_livekit(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Meetings.mute_livekit_published_track(@room, @identity, true)
    end

    test "unconfigured LiveKit is {:error, :livekit_not_configured} with 0 requests" do
      put_livekit_env([])
      stub_livekit(fn conn -> Req.Test.json(conn, %{}) end)

      assert Meetings.mute_livekit_published_track(@room, @identity, true) ==
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
