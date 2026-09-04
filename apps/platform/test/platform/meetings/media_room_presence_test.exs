defmodule Platform.Meetings.MediaRoomPresenceTest do
  @moduledoc """
  Task 01a06925 stage 3 — `Meetings.media_room_presence/2` and the
  `ListParticipants` call under it.

  The roster says who INTENDED to be in the call (the row is written
  server-side before the browser connects); LiveKit says who is in the
  media room. These tests pin the fold from LiveKit's answer to the
  presence map, and that every way LiveKit can fail to answer is
  `:unavailable` rather than a raise — the invite flash reads this after a
  delivered invite and must never turn that invite into an error.

  `async: false`: the LiveKit config and the injected Req client are
  application env.
  """
  use Platform.DataCase, async: false

  alias Platform.Meetings

  @viewer "user:11111111-1111-1111-1111-111111111111"
  @room "space-22222222-2222-2222-2222-222222222222"

  defp put_livekit_env(attrs) do
    original = Application.get_env(:platform, :livekit, [])
    Application.put_env(:platform, :livekit, attrs)
    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
  end

  defp configured,
    do: put_livekit_env(api_key: "k", api_secret: "s-0123456789abcdef", url: "wss://livekit.test")

  # The Req.Test pattern `Platform.ExternalAgentsTest` uses: a named stub,
  # the injected client pointed at it, env cleared on exit.
  defp stub_livekit(response_fn) do
    {:ok, _} = Application.ensure_all_started(:req)
    Application.put_env(:platform, :livekit_req_client, Req.new(plug: {Req.Test, :livekit_test}))
    Req.Test.stub(:livekit_test, response_fn)
    on_exit(fn -> Application.delete_env(:platform, :livekit_req_client) end)
  end

  defp participants(identities) do
    %{"participants" => Enum.map(identities, &%{"identity" => &1, "name" => &1})}
  end

  describe "presence_from_identities/2 (pure)" do
    test "the viewer is present and never counted among the others" do
      # Two others, never 0 or 1, so a dropped mapping cannot coincide with a
      # default and counting the viewer shows as 3.
      assert %{viewer_present?: true, others: others} =
               Meetings.presence_from_identities(
                 [@viewer, "agent:other", "user:someone"],
                 @viewer
               )

      assert others == ["agent:other", "user:someone"]
      assert length(others) == 2
    end

    test "only agents means the viewer is absent" do
      assert %{viewer_present?: false, others: ["agent:other"]} =
               Meetings.presence_from_identities(["agent:other"], @viewer)
    end

    test "an empty room is absent with nobody else" do
      assert %{viewer_present?: false, others: []} =
               Meetings.presence_from_identities([], @viewer)
    end
  end

  describe "media_room_presence/2 over ListParticipants" do
    test "viewer plus two others: present, others has exactly the two" do
      configured()

      stub_livekit(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/twirp/livekit.RoomService/ListParticipants"
        assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        # The grant ListParticipants actually requires: roomAdmin, scoped to
        # THIS room. `roomCreate` alone is refused by LiveKit.
        assert %{"video" => %{"roomAdmin" => true, "room" => @room}} = decode_claims(jwt)
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body) == %{"room" => @room}
        Req.Test.json(conn, participants([@viewer, "agent:other", "user:someone-else"]))
      end)

      assert %{viewer_present?: true, others: others} =
               Meetings.media_room_presence(@room, @viewer)

      assert others == ["agent:other", "user:someone-else"]
    end

    test "only agents in the room: the viewer is absent" do
      configured()
      stub_livekit(fn conn -> Req.Test.json(conn, participants(["agent:other"])) end)

      assert %{viewer_present?: false, others: ["agent:other"]} =
               Meetings.media_room_presence(@room, @viewer)
    end

    test "LiveKit's empty-room answer omits the participants key: absent, nobody else" do
      configured()
      stub_livekit(fn conn -> Req.Test.json(conn, %{}) end)

      assert %{viewer_present?: false, others: []} = Meetings.media_room_presence(@room, @viewer)
    end

    test "unconfigured LiveKit is :unavailable, and nothing is called" do
      put_livekit_env([])

      stub_livekit(fn _conn ->
        flunk("ListParticipants must not be called without credentials")
      end)

      assert Meetings.media_room_presence(@room, @viewer) == :unavailable
      assert Meetings.list_livekit_participants(@room) == {:error, :livekit_not_configured}
    end

    test "HTTP 500 is :unavailable" do
      configured()
      stub_livekit(fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.text("boom") end)

      assert Meetings.media_room_presence(@room, @viewer) == :unavailable
      assert {:error, {:http_error, 500, _}} = Meetings.list_livekit_participants(@room)
    end

    test "a transport timeout is :unavailable" do
      configured()
      stub_livekit(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert Meetings.media_room_presence(@room, @viewer) == :unavailable

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Meetings.list_livekit_participants(@room)
    end

    test "the wss URL is rewritten to https for the twirp call" do
      put_livekit_env(
        api_key: "k",
        api_secret: "s-0123456789abcdef",
        url: "wss://sfu.example.test"
      )

      stub_livekit(fn conn ->
        assert conn.scheme == :https
        assert conn.host == "sfu.example.test"
        Req.Test.json(conn, participants([@viewer]))
      end)

      assert %{viewer_present?: true, others: []} = Meetings.media_room_presence(@room, @viewer)
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
