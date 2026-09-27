defmodule Platform.Meetings.AskFloorWindowSignalTest do
  @moduledoc """
  Unit-level tests for `Meetings.send_livekit_room_data/3` (the raw Twirp
  `RoomService/SendData` call) and `Meetings.ask_floor_window_signal/3`
  (the ask-floor-specific caller, task 01a0e47c stage 2). End-to-end
  proof through a real press/release lives in
  `PlatformWeb.MeetingAskFloorVoiceGateTest`; this file isolates the two
  new module functions the same way `livekit_agent_dispatch_test.exs`
  isolates `create_livekit_agent_dispatch/3`.

  `async: false`: LiveKit config and the injected Req client are both
  application env.
  """

  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.AskFloor
  alias Platform.Repo

  @room_name "ask-floor-signal-test-room"
  @livekit_agent_name "meeting-voice-agent"

  defp configured do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
  end

  defp stub_livekit(response_fn) do
    {:ok, _} = Application.ensure_all_started(:req)

    Application.put_env(
      :platform,
      :livekit_req_client,
      Req.new(plug: {Req.Test, :ask_floor_signal_unit_test})
    )

    Req.Test.stub(:ask_floor_signal_unit_test, response_fn)
    on_exit(fn -> Application.delete_env(:platform, :livekit_req_client) end)
  end

  defp decode_claims(jwt) do
    jwt
    |> String.split(".")
    |> Enum.at(1)
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
  end

  defp user! do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "ask-floor-signal-#{n}@example.com",
      name: "Ask Floor Signal #{n}",
      oidc_sub: "oidc-ask-floor-signal-#{n}"
    })
  end

  defp agent!(slug_prefix) do
    n = System.unique_integer([:positive])

    %Agent{}
    |> Agent.changeset(%{
      slug: "#{slug_prefix}-#{n}",
      name: "#{slug_prefix} #{n}",
      status: "active"
    })
    |> Repo.insert!()
  end

  defp voice_gated_agent! do
    owner = user!()
    agent = agent!("voice-gated")

    {:ok, _runtime, _raw_token} =
      Federation.register_voice_runtime(owner.id, agent, %{
        metadata: %{
          "client_info" => %{
            "features" => ["meeting_voice"],
            "livekit_agent_name" => @livekit_agent_name
          }
        }
      })

    Repo.reload(agent)
  end

  # ── send_livekit_room_data/3 (the raw Twirp call) ─────────────────────────

  describe "send_livekit_room_data/3" do
    test "posts SendData with a roomAdmin-scoped token, base64 data, RELIABLE kind" do
      configured()

      stub_livekit(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/twirp/livekit.RoomService/SendData"
        assert ["Bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        assert %{"video" => %{"roomAdmin" => true, "room" => @room_name}} = decode_claims(jwt)

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["room"] == @room_name
        assert decoded["topic"] == "mva.ask_floor"
        assert decoded["kind"] == "RELIABLE"
        assert Base.decode64!(decoded["data"]) == ~s({"event":"open"})

        Req.Test.json(conn, %{})
      end)

      assert :ok =
               Meetings.send_livekit_room_data(@room_name, "mva.ask_floor", ~s({"event":"open"}))
    end

    test "without LiveKit configured returns :livekit_not_configured" do
      Application.put_env(:platform, :livekit, [])
      on_exit(fn -> Application.delete_env(:platform, :livekit) end)

      assert {:error, :livekit_not_configured} =
               Meetings.send_livekit_room_data(@room_name, "mva.ask_floor", "{}")
    end

    test "a non-2xx response is a clean error tuple, not a raise" do
      configured()
      stub_livekit(fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, {:http_error, 500, "boom"}} =
               Meetings.send_livekit_room_data(@room_name, "mva.ask_floor", "{}")
    end
  end

  # ── ask_floor_window_signal/3 ──────────────────────────────────────────────

  describe "ask_floor_window_signal/3" do
    test "sends an 'open' payload for a LiveKit-dispatch-capable agent" do
      configured()
      agent = voice_gated_agent!()
      test_pid = self()

      stub_livekit(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(test_pid, {:sent, decoded})
        Req.Test.json(conn, %{})
      end)

      space_id = Ecto.UUID.generate()
      assert :ok = Meetings.ask_floor_window_signal(agent.id, space_id, :open)

      assert_receive {:sent, decoded}, 1_000
      assert decoded["room"] == Meetings.room_name_for_space(space_id)
      payload = decoded["data"] |> Base.decode64!() |> Jason.decode!()
      assert payload == %{"event" => "open", "agent_id" => agent.id}
    end

    test "sends a 'closed' payload the same way" do
      configured()
      agent = voice_gated_agent!()
      test_pid = self()

      stub_livekit(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:sent, Jason.decode!(body)})
        Req.Test.json(conn, %{})
      end)

      space_id = Ecto.UUID.generate()
      assert :ok = Meetings.ask_floor_window_signal(agent.id, space_id, :closed)

      assert_receive {:sent, decoded}, 1_000
      payload = decoded["data"] |> Base.decode64!() |> Jason.decode!()
      assert payload["event"] == "closed"
    end

    test "is a silent no-op for an agent with no LiveKit dispatch target" do
      agent = agent!("text-only-signal")

      # No LiveKit stub configured at all — if this ever fell through to
      # an HTTP call it would hit the real network (or, unconfigured,
      # :livekit_not_configured) rather than resolving via the no-op
      # branch. Asserting `:ok` alone would not distinguish those, so this
      # also confirms no stub was ever exercised by never registering one.
      assert :ok = Meetings.ask_floor_window_signal(agent.id, Ecto.UUID.generate(), :open)
    end

    test "is a silent no-op for an unknown agent_id" do
      configured()

      assert :ok =
               Meetings.ask_floor_window_signal(Ecto.UUID.generate(), Ecto.UUID.generate(), :open)
    end

    test "is a silent no-op with no space_id" do
      configured()
      agent = voice_gated_agent!()
      assert :ok = Meetings.ask_floor_window_signal(agent.id, nil, :open)
    end

    test "a LiveKit failure is swallowed and still returns :ok" do
      configured()
      agent = voice_gated_agent!()
      stub_livekit(fn conn -> Plug.Conn.send_resp(conn, 500, "nope") end)

      assert :ok = Meetings.ask_floor_window_signal(agent.id, Ecto.UUID.generate(), :closed)
    end
  end

  # ── AskFloor's stuck-claim timeout also closes the LiveKit window ─────────

  describe "AskFloor.claim/6's space_id reaches the stuck-claim eviction path" do
    setup context do
      meeting_id = "meeting-#{inspect(context.test)}" |> :erlang.phash2() |> Integer.to_string()
      on_exit(fn -> AskFloor.clear_meeting(meeting_id) end)
      {:ok, meeting_id: meeting_id}
    end

    test "a dropped-socket claim (no explicit release) sends 'closed' when its stuck-claim timer fires",
         %{meeting_id: meeting_id} do
      configured()
      agent = voice_gated_agent!()
      space_id = Ecto.UUID.generate()
      test_pid = self()

      stub_livekit(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        payload = decoded["data"] |> Base.decode64!() |> Jason.decode!()
        send(test_pid, {:sent, payload})
        Req.Test.json(conn, %{})
      end)

      # No room_id on purpose -- a claim made before a room went active,
      # exactly like `AskFloorTest`'s own "no room id" stuck-claim cases.
      # Only `space_id` needs to survive to the eviction for THIS test.
      assert {:ok, holder} =
               AskFloor.claim(meeting_id, agent.id, "user:1", "Tester", nil, space_id)

      # `Req.Test.stub/2`'s registration is scoped to the CALLING process
      # (this test), but the Repo call and the LiveKit POST below both run
      # inside `AskFloor`'s own long-lived GenServer process once the
      # timer message is handled -- `Req.Test.allow/3` is the documented
      # cross-process escape hatch (same pattern `catalog_emitter_test.exs`
      # uses for its own background-process stub).
      Req.Test.allow(:ask_floor_signal_unit_test, self(), Process.whereis(AskFloor))

      # Inject the stuck-claim timer's own message directly, exactly like
      # `AskFloorTest.elapse_stuck_claim/5` -- nobody ever called
      # `release_ask_floor/4` for this claim (the socket dropped), so
      # this GenServer message is the ONLY thing that can close the gate.
      send(
        AskFloor,
        {:stuck_claim_elapsed, meeting_id, agent.id, holder.pressed_at, nil, space_id}
      )

      :sys.get_state(AskFloor)

      assert AskFloor.holder(meeting_id, agent.id) == :none
      assert_receive {:sent, %{"event" => "closed", "agent_id" => agent_id}}, 1_000
      assert agent_id == agent.id
    end
  end
end
