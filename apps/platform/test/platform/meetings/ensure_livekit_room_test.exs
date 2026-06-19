defmodule Platform.Meetings.EnsureLivekitRoomTest do
  @moduledoc """
  Regression tests for the JSON body sent to LiveKit's
  `RoomService/CreateRoom` Twirp endpoint.

  The `agents` field is what triggers server-side dispatch of the
  `meeting-transcriber` worker at room-creation time. Without it,
  transcripts never start on new meetings (the JWT `roomConfig.agents`
  path silently no-ops because the room already exists by the time the
  JWT arrives).

  Field-name nuance: LiveKit's REST/Twirp CreateRoom uses snake_case
  `agent_name`; the JWT roomConfig.agents path uses camelCase
  `agentName`. Two different LiveKit serialization conventions — do NOT
  normalize.
  """

  use ExUnit.Case, async: true

  alias Platform.Meetings

  describe "build_create_room_body/1" do
    test "includes the meeting-transcriber agent in agents list" do
      body = "space-abc" |> Meetings.build_create_room_body() |> Jason.decode!()

      assert body == %{
               "name" => "space-abc",
               "empty_timeout" => 300,
               "agents" => [%{"agent_name" => "meeting-transcriber"}]
             }
    end

    test "agent_name uses snake_case (LiveKit REST convention, not JWT camelCase)" do
      body = "space-test-456" |> Meetings.build_create_room_body() |> Jason.decode!()

      [agent] = body["agents"]
      assert Map.has_key?(agent, "agent_name")
      refute Map.has_key?(agent, "agentName")
      assert agent["agent_name"] == "meeting-transcriber"
    end

    test "preserves the supplied room name verbatim" do
      body =
        "space-019ee053-c319-7577-bd32-f44ebdcffe8a"
        |> Meetings.build_create_room_body()
        |> Jason.decode!()

      assert body["name"] == "space-019ee053-c319-7577-bd32-f44ebdcffe8a"
    end

    test "keeps empty_timeout at 300 seconds" do
      body = "space-xyz" |> Meetings.build_create_room_body() |> Jason.decode!()
      assert body["empty_timeout"] == 300
    end
  end
end
