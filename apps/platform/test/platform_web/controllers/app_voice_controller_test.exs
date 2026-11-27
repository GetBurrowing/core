defmodule PlatformWeb.AppVoiceControllerTest do
  @moduledoc """
  Task 01a21e75 stage 2: the native Voice turn routes under `/api/app/voice`.
  Fixture names are generic.
  """
  # async: false: the log tests raise the global Logger level.
  use PlatformWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Platform.ExternalUserFixtures

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings.OnDeviceVoice
  alias Platform.Mobile
  alias Platform.Repo

  @routes [
    {:get, "/api/app/voice/partner", %{}},
    {:post, "/api/app/voice/turns", %{"agent_id" => Ecto.UUID.generate(), "text" => "hi"}},
    {:get, "/api/app/voice/turns/turn-1", %{}}
  ]

  defp app_session!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, result} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    result
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp agent!(status \\ "active") do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "voice-app-#{n}", name: "Build agent #{n}", status: status})
  end

  defp turn_id, do: "turn-#{System.unique_integer([:positive])}"

  defp debug_log! do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  # The log minus Ecto's own query entries. At debug the repo prints every
  # query's parameters, the stored message included; that is the repo's
  # logging (production runs at :info), not this endpoint's. Everything else,
  # the router's "Parameters:" line among it, stays in.
  defp without_query_entries(log) do
    log
    |> String.split(~r/^(?=\d{2}:\d{2}:\d{2}\.\d{3} \[)/m)
    |> Enum.reject(&(&1 =~ ~r/\[debug\] QUERY (OK|ERROR)/))
    |> Enum.join()
  end

  setup %{conn: conn} do
    user = create_user!()
    %{token: token} = app_session!(user)
    %{conn: conn, user: user, token: token}
  end

  test "every route is 401 without a bearer", %{conn: conn} do
    for {method, path, params} <- @routes do
      conn = dispatch(conn, @endpoint, method, path, params)
      assert json_response(conn, 401) == %{"error" => "unauthorized"}, inspect(path)
    end
  end

  describe "partner" do
    test "null, then the agent of the last turn", %{conn: conn, token: token} do
      assert conn |> bearer(token) |> get("/api/app/voice/partner") |> json_response(200) ==
               %{"partner" => nil}

      agent = agent!()

      conn
      |> bearer(token)
      |> post("/api/app/voice/turns", %{
        "agent_id" => agent.id,
        "text" => "Hi",
        "client_turn_id" => turn_id()
      })
      |> json_response(201)

      %{"partner" => partner} =
        conn |> bearer(token) |> get("/api/app/voice/partner") |> json_response(200)

      assert partner["agent_id"] == agent.id
      assert partner["name"] == agent.name
      assert {:ok, _, 0} = DateTime.from_iso8601(partner["last_used_at"])
    end
  end

  describe "create_turn" do
    test "201, and the same client_turn_id twice posts once", %{conn: conn, token: token} do
      agent = agent!()
      id = turn_id()
      body = %{"agent_id" => agent.id, "text" => "Plan my day", "client_turn_id" => id}

      first = conn |> bearer(token) |> post("/api/app/voice/turns", body) |> json_response(201)
      second = conn |> bearer(token) |> post("/api/app/voice/turns", body) |> json_response(201)

      assert first == second
      assert %{"space_id" => space_id, "path_segment" => _, "client_turn_id" => ^id} = first

      contents =
        space_id
        |> Chat.list_messages(limit: 50)
        |> Enum.map(& &1.content)

      assert contents == ["Plan my day"]
    end

    test "422 blank, 404 unknown agent, 403 an agent the user may not DM", %{
      conn: conn,
      token: token
    } do
      agent = agent!()

      assert conn
             |> bearer(token)
             |> post("/api/app/voice/turns", %{
               "agent_id" => agent.id,
               "text" => "  ",
               "client_turn_id" => turn_id()
             })
             |> json_response(422) == %{"error" => "blank"}

      assert conn
             |> bearer(token)
             |> post("/api/app/voice/turns", %{
               "agent_id" => Ecto.UUID.generate(),
               "text" => "Hi",
               "client_turn_id" => turn_id()
             })
             |> json_response(404) == %{"error" => "not_found"}

      assert conn
             |> bearer(token)
             |> post("/api/app/voice/turns", %{
               "agent_id" => agent!("paused").id,
               "text" => "Hi",
               "client_turn_id" => turn_id()
             })
             |> json_response(403) == %{"error" => "forbidden"}
    end
  end

  describe "reply" do
    setup %{conn: conn, token: token, user: user} do
      agent = agent!()
      id = turn_id()

      conn
      |> bearer(token)
      |> post("/api/app/voice/turns", %{
        "agent_id" => agent.id,
        "text" => "Hi",
        "client_turn_id" => id
      })
      |> json_response(201)

      {:ok, voice} = OnDeviceVoice.open(user, agent)
      %{id: id, voice: voice}
    end

    test "the posted reply, past the spoken sentences", %{
      conn: conn,
      token: token,
      id: id,
      voice: voice
    } do
      {:ok, _} =
        Chat.post_message(%{
          space_id: voice.space_id,
          participant_id: voice.agent_participant_id,
          content_type: "text",
          content: "One. Two."
        })

      assert conn
             |> bearer(token)
             |> get("/api/app/voice/turns/#{id}", %{"spoken" => "1", "wait_ms" => "100"})
             |> json_response(200) ==
               %{"state" => "done", "sentences" => ["Two."], "spoken" => 2, "final" => true}
    end

    test "nothing yet is thinking", %{conn: conn, token: token, id: id} do
      assert conn
             |> bearer(token)
             |> get("/api/app/voice/turns/#{id}", %{"wait_ms" => "50"})
             |> json_response(200) ==
               %{"state" => "thinking", "sentences" => [], "spoken" => 0, "final" => false}
    end

    test "another user's turn id is 404", %{conn: conn, id: id} do
      %{token: other} = app_session!(create_user!())

      assert conn
             |> bearer(other)
             |> get("/api/app/voice/turns/#{id}", %{"wait_ms" => "50"})
             |> json_response(404) == %{"error" => "not_found"}
    end
  end

  describe "logs" do
    test "the turn text never reaches the log on POST", %{conn: conn, token: token} do
      debug_log!()
      agent = agent!()
      sentinel = "SENTINEL-TURN-#{System.unique_integer([:positive])}"

      log =
        capture_log([level: :debug], fn ->
          conn
          |> bearer(token)
          |> post("/api/app/voice/turns", %{
            "agent_id" => agent.id,
            "text" => "Words #{sentinel}",
            "client_turn_id" => turn_id()
          })
          |> json_response(201)
        end)

      # Positive control: the request was logged (Plug's request line), and
      # the stored message carries the sentinel, so the capture is not empty.
      assert log =~ "POST /api/app/voice/turns"
      assert log =~ sentinel, "the repo's own debug line should carry it (control)"
      refute without_query_entries(log) =~ sentinel
      refute without_query_entries(log) =~ agent.name
    end

    test "the reply text never reaches the log on GET", %{
      conn: conn,
      token: token,
      user: user
    } do
      agent = agent!()
      id = turn_id()
      sentinel = "SENTINEL-REPLY-#{System.unique_integer([:positive])}"

      conn
      |> bearer(token)
      |> post("/api/app/voice/turns", %{
        "agent_id" => agent.id,
        "text" => "Hi",
        "client_turn_id" => id
      })
      |> json_response(201)

      {:ok, voice} = OnDeviceVoice.open(user, agent)

      {:ok, _} =
        Chat.post_message(%{
          space_id: voice.space_id,
          participant_id: voice.agent_participant_id,
          content_type: "text",
          content: "Reply #{sentinel}."
        })

      debug_log!()

      {body, log} =
        with_log([level: :debug], fn ->
          conn
          |> bearer(token)
          |> get("/api/app/voice/turns/#{id}", %{"wait_ms" => "100"})
          |> response(200)
        end)

      assert body =~ sentinel
      assert log =~ "GET /api/app/voice/turns/"
      refute without_query_entries(log) =~ sentinel
    end
  end
end
