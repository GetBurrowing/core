defmodule Platform.Meetings.TranscriberAgentNameTest do
  @moduledoc """
  The LiveKit agent name core dispatches the meeting transcriber as is
  configurable (`MEETING_TRANSCRIBER_AGENT_NAME` →
  `config :platform, :meeting_transcriber_agent_name`).

  Several Suite installs share one LiveKit server. With a hardcoded name,
  every install dispatched the same worker, which persisted segments to a
  single install, so meetings on the others were never transcribed.

  Both dispatch sites must follow the config: the CreateRoom body
  (snake_case `agent_name`) and the participant JWT `roomConfig.agents`
  (camelCase `agentName`).
  """

  # Mutates application env, so not async.
  use ExUnit.Case, async: false

  alias Platform.Meetings

  setup do
    original_name = Application.get_env(:platform, :meeting_transcriber_agent_name)
    original_livekit = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn ->
      Application.put_env(:platform, :livekit, original_livekit)

      case original_name do
        nil -> Application.delete_env(:platform, :meeting_transcriber_agent_name)
        value -> Application.put_env(:platform, :meeting_transcriber_agent_name, value)
      end
    end)

    :ok
  end

  defp jwt_agents(room_name) do
    [_header, payload_b64, _sig] =
      room_name |> Meetings.generate_token("user:test") |> String.split(".", parts: 3)

    payload_b64
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> get_in(["roomConfig", "agents"])
  end

  defp create_room_agents(room_name) do
    room_name |> Meetings.build_create_room_body() |> Jason.decode!() |> Map.fetch!("agents")
  end

  test "defaults to meeting-transcriber when unset" do
    Application.delete_env(:platform, :meeting_transcriber_agent_name)

    assert Meetings.transcriber_agent_name() == "meeting-transcriber"
    assert create_room_agents("space-abc") == [%{"agent_name" => "meeting-transcriber"}]
    assert jwt_agents("space-abc") == [%{"agentName" => "meeting-transcriber"}]
  end

  test "a blank configured name falls back to the default" do
    Application.put_env(:platform, :meeting_transcriber_agent_name, "")

    assert Meetings.transcriber_agent_name() == "meeting-transcriber"
  end

  test "both dispatch sites use the configured name" do
    Application.put_env(:platform, :meeting_transcriber_agent_name, "meeting-transcriber-redstar")

    assert Meetings.transcriber_agent_name() == "meeting-transcriber-redstar"

    assert create_room_agents("space-abc") == [%{"agent_name" => "meeting-transcriber-redstar"}]

    assert jwt_agents("space-abc") == [%{"agentName" => "meeting-transcriber-redstar"}]
  end

  test "non-meeting rooms still carry no JWT dispatch" do
    Application.put_env(:platform, :meeting_transcriber_agent_name, "meeting-transcriber-redstar")

    assert jwt_agents("call-abc") == nil
  end

  test "a worker under a different agent name is still detected as the transcriber" do
    Application.put_env(:platform, :meeting_transcriber_agent_name, "meeting-transcriber-redstar")

    # The worker joins with identity `transcriber:<room>`; detection is keyed
    # on identity markers, not on the dispatch name.
    assert Meetings.transcriber_participant?(%{identity: "transcriber:space-abc", name: nil})
    assert Meetings.transcriber_participant?(%{name: "meeting-transcriber-redstar"})
  end
end
