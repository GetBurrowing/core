defmodule PlatformWeb.MeetingAgentControllerTest do
  @moduledoc """
  Tests for the `/api/meetings/segments` bypass endpoint that the
  `meeting-transcriber` agent posts against.

  Task 019f3312 stage 1 added `Meetings.legit_room?/1` as a
  payload-level guard on top of the pre-existing bearer-token check:
  an attacker with the shared token could still POST fabricated
  `space-<random-uuid>` names, so we gate on the same regex +
  chat_spaces existence check the LiveKit webhook uses.
  """

  # NOT async: `verify_token/1` reads MEETING_AGENT_TOKEN via System.get_env
  # at request time, and this suite mutates that env for the empty-token
  # branch. Async would let sibling suites see the empty value mid-run.
  use PlatformWeb.ConnCase, async: false

  alias Platform.Meetings

  @path "/api/meetings/segments"
  @agent_token "test-agent-token-#{System.unique_integer([:positive])}"

  setup do
    # `verify_token/1` reads MEETING_AGENT_TOKEN at request time; set it
    # for the duration of the test.
    prior = System.get_env("MEETING_AGENT_TOKEN")
    System.put_env("MEETING_AGENT_TOKEN", @agent_token)

    on_exit(fn ->
      if is_nil(prior),
        do: System.delete_env("MEETING_AGENT_TOKEN"),
        else: System.put_env("MEETING_AGENT_TOKEN", prior)
    end)

    :ok
  end

  defp with_bearer(conn), do: put_req_header(conn, "authorization", "Bearer #{@agent_token}")

  defp app_room_name do
    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Agent Space #{System.unique_integer([:positive])}",
        slug: "agent-space-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    "space-#{space.id}"
  end

  defp sample_segment(overrides \\ %{}) do
    Map.merge(
      %{
        "participant_identity" => "user-#{System.unique_integer([:positive])}",
        "speaker_name" => "Ada",
        "text" => "Hello from the agent.",
        "start_time" => 0,
        "end_time" => 500,
        "language" => "en",
        "final" => true
      },
      overrides
    )
  end

  describe "POST #{@path} — auth" do
    test "401 when the Authorization header is missing", %{conn: conn} do
      conn = post(conn, @path, %{"room_sid" => "RM_x", "segments" => []})

      assert %{"status" => "unauthorized"} = json_response(conn, 401)
    end

    test "401 when the bearer token doesn't match", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer WRONG_TOKEN")
        |> post(@path, %{"room_sid" => "RM_x", "segments" => []})

      assert %{"status" => "unauthorized"} = json_response(conn, 401)
    end

    test "401 when MEETING_AGENT_TOKEN is empty", %{conn: conn} do
      # Explicit override for this test.
      System.put_env("MEETING_AGENT_TOKEN", "")

      conn = with_bearer(conn) |> post(@path, %{"room_sid" => "RM_x", "segments" => []})

      assert %{"status" => "unauthorized"} = json_response(conn, 401)
    end
  end

  describe "POST #{@path} — legit_room?/1 payload guard" do
    test "ignores segments for a well-formed name whose chat_space doesn't exist",
         %{conn: conn} do
      # The bearer token is valid — but the room name is a fabricated
      # `space-<random-uuid>` that no Suite space registered. Stage 1's
      # payload-level guard closes this attack even when the token is
      # compromised.
      fake_name = "space-#{Ecto.UUID.generate()}"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn
            |> with_bearer()
            |> post(@path, %{
              "room_sid" => "RM_forged",
              "room_name" => fake_name,
              "segments" => [sample_segment(%{"text" => "never persist"})]
            })

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(conn, 200)
        end)

      assert log =~ "Ignoring segments for unregistered room"

      # No transcript created for either the sid or the fake name.
      assert Meetings.get_transcript_for_room("RM_forged") == nil
      assert Meetings.get_transcript_for_room(fake_name) == nil
    end

    test "ignores segments for RM_<random> phantom room names", %{conn: conn} do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            conn
            |> with_bearer()
            |> post(@path, %{
              "room_sid" => "RM_phantom",
              "room_name" => "RM_phantom",
              "segments" => [sample_segment()]
            })

          assert %{"status" => "ignored", "reason" => "unregistered room"} =
                   json_response(conn, 200)
        end)

      assert log =~ "Ignoring segments for unregistered room"
      assert Meetings.get_transcript_for_room("RM_phantom") == nil
    end

    test "ignores segments when room_name is missing entirely", %{conn: conn} do
      conn =
        conn
        |> with_bearer()
        |> post(@path, %{
          "room_sid" => "RM_no_name",
          "segments" => [sample_segment()]
        })

      assert %{"status" => "ignored", "reason" => "unregistered room"} =
               json_response(conn, 200)

      assert Meetings.get_transcript_for_room("RM_no_name") == nil
    end
  end

  describe "POST #{@path} — legit room happy path" do
    test "appends segments to an ensured transcript keyed off room_name",
         %{conn: conn} do
      room_name = app_room_name()
      sid = "RM_legit_#{System.unique_integer([:positive])}"

      conn =
        conn
        |> with_bearer()
        |> post(@path, %{
          "room_sid" => sid,
          "room_name" => room_name,
          "segments" => [
            sample_segment(%{"text" => "one"}),
            sample_segment(%{"text" => "two"})
          ]
        })

      assert %{
               "status" => "appended",
               "transcript_id" => transcript_id,
               "count" => 2
             } = json_response(conn, 200)

      # Under stage 1's `name || sid` precedence, the persisted
      # `room_id` is the app-controlled name — matching what the
      # LiveKit webhook writes for the same room.
      transcript = Meetings.get_transcript(transcript_id)
      assert transcript.room_id == room_name
      refute transcript.room_id == sid

      texts = Enum.map(transcript.segments, & &1["text"])
      assert "one" in texts
      assert "two" in texts
    end

    test "400 on missing required fields", %{conn: conn} do
      conn =
        conn
        |> with_bearer()
        |> post(@path, %{"segments" => []})

      assert %{"status" => "bad_request"} = json_response(conn, 400)
    end
  end

  describe "POST #{@path} — transcript delivery (task 01a06672)" do
    test "POST segments delivers a final segment to a seated agent's brain topic",
         %{conn: conn} do
      # The same space `app_room_name/0` derives its name from, so the
      # Room row `Meetings.get_room_by_name/1` resolves is the one the
      # agent is seated in.
      room_name = app_room_name()
      "space-" <> space_id = room_name
      {:ok, room} = Meetings.ensure_room(space_id)
      {:ok, room} = Meetings.activate_room(room)
      assert room.livekit_room_name == room_name

      n = System.unique_integer([:positive])

      owner =
        Platform.Repo.insert!(%Platform.Accounts.User{
          email: "mac-owner-#{n}@example.com",
          name: "MAC Owner #{n}",
          oidc_sub: "oidc-mac-owner-#{n}"
        })

      agent =
        Platform.Repo.insert!(%Platform.Agents.Agent{
          slug: "mac-agent-#{n}",
          name: "MAC Agent #{n}",
          status: "active"
        })

      {:ok, runtime} =
        Platform.Federation.register_runtime(owner.id, %{runtime_id: "mac-brain-#{n}"})

      {:ok, activated, _raw_token} = Platform.Federation.activate_runtime(runtime)
      {:ok, agent} = Platform.Federation.link_agent(activated, agent)
      brain_topic = Platform.Meetings.IntentRuntimeAdapter.runtime_topic(activated.runtime_id)

      {:ok, _row} = Platform.Chat.add_agent_participant(space_id, agent)

      {:ok, _participant} =
        Meetings.participant_joined(room, %{display_name: agent.name, agent_id: agent.id})

      :ok = PlatformWeb.Endpoint.subscribe(brain_topic)

      conn =
        conn
        |> with_bearer()
        |> post(@path, %{
          "room_sid" => "RM_deliver_#{n}",
          "room_name" => room_name,
          "segments" => [sample_segment(%{"text" => "heard by the brain"})]
        })

      assert %{"status" => "appended", "count" => 1} = json_response(conn, 200)

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: ^brain_topic,
                       event: "meeting_transcript",
                       payload: %{text: "heard by the brain", room_name: ^room_name}
                     },
                     500
    end
  end
end
