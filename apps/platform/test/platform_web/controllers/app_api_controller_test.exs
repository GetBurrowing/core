defmodule PlatformWeb.AppApiControllerTest do
  @moduledoc """
  Task 01a10882 stage 1: the native app's `/api/app` JSON surface.
  """
  # async: false: the log test raises the global Logger level.
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Platform.ExternalUserFixtures

  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Mobile
  alias Platform.Mobile.ApnsDevice
  alias Platform.Repo

  @device_token String.duplicate("d1ce", 16)

  # Every bearer-authenticated route, with a request that would otherwise be
  # well-formed. `POST /session` is deliberately absent: it is the one
  # unauthenticated route.
  @protected_routes [
    {:delete, "/api/app/session", %{}},
    {:post, "/api/app/handoff", %{}},
    {:post, "/api/app/devices",
     %{
       "token" => String.duplicate("d1ce", 16),
       "environment" => "sandbox",
       "bundle_id" => "com.kobo-ai.burrow",
       "app_install_id" => "install-1"
     }},
    {:delete, "/api/app/devices/install-1", %{}},
    {:get, "/api/app/spaces", %{}},
    {:post, "/api/app/spaces/:space_id/messages", %{"text" => "hello"}},
    {:get, "/api/app/counts", %{}}
  ]

  defp pkce do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp app_session!(user) do
    {verifier, challenge} = pkce()
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)
    {:ok, result} = Mobile.exchange_code(code, verifier, %{app_install_id: "install-1"})
    result
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp agent!(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "app-agent-#{n}", name: "#{name} #{n}", status: "active"})
  end

  defp request(conn, {method, path, params}, space_id) do
    path = String.replace(path, ":space_id", space_id)
    dispatch(conn, @endpoint, method, path, params)
  end

  setup %{conn: conn} do
    user = create_user!()
    space = channel!()
    add_user!(space.id, user.id)
    %{token: token, session: session} = app_session!(user)
    %{conn: conn, user: user, space: space, token: token, session: session}
  end

  describe "401 on every protected route" do
    test "with no bearer", %{conn: conn, space: space} do
      for route <- @protected_routes do
        conn = request(conn, route, space.id)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, inspect(route)
      end
    end

    test "with a garbage bearer", %{conn: conn, space: space} do
      for route <- @protected_routes do
        conn = conn |> bearer("garbage-token") |> request(route, space.id)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, inspect(route)
      end
    end

    test "with a non-Bearer authorization scheme", %{conn: conn, space: space, token: token} do
      for route <- @protected_routes do
        conn =
          conn |> put_req_header("authorization", "Basic " <> token) |> request(route, space.id)

        assert json_response(conn, 401) == %{"error" => "unauthorized"}, inspect(route)
      end
    end

    test "with a revoked bearer", %{conn: conn, space: space, token: token, session: session} do
      {:ok, _} = Mobile.revoke_session(session)

      for route <- @protected_routes do
        conn = conn |> bearer(token) |> request(route, space.id)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, inspect(route)
      end
    end

    test "for an archived user", %{conn: conn, space: space, token: token, user: user} do
      {:ok, _} = Accounts.archive_user(user)

      for route <- @protected_routes do
        conn = conn |> bearer(token) |> request(route, space.id)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, inspect(route)
      end
    end

    test "a live bearer gets through (positive control)", %{conn: conn, token: token} do
      conn = conn |> bearer(token) |> get("/api/app/counts")
      assert %{"approvals" => 0, "tasks" => 0, "as_of" => _} = json_response(conn, 200)
    end
  end

  describe "POST /api/app/session" do
    test "exchanges a code for a bearer and a handoff url", %{conn: conn} do
      user = create_user!()
      {verifier, challenge} = pkce()
      {:ok, code} = Mobile.issue_exchange_code(user, challenge)

      conn =
        post(conn, "/api/app/session", %{
          "code" => code,
          "code_verifier" => verifier,
          "app_install_id" => "install-9",
          "device_name" => "Rowan's iPhone"
        })

      assert %{"token" => token, "handoff_url" => handoff_url} = json_response(conn, 200)
      assert handoff_url =~ "/auth/app/handoff?code="
      assert {:ok, %{id: id}, session} = Mobile.verify_bearer(token)
      assert id == user.id
      assert session.app_install_id == "install-9"
      assert session.device_name == "Rowan's iPhone"
    end

    test "a wrong verifier, a reused code and an expired code are refused", %{conn: conn} do
      user = create_user!()
      {verifier, challenge} = pkce()
      {wrong, _} = pkce()

      {:ok, code} = Mobile.issue_exchange_code(user, challenge)
      conn1 = post(conn, "/api/app/session", %{"code" => code, "code_verifier" => wrong})
      assert json_response(conn1, 400) == %{"error" => "invalid_grant"}

      {:ok, code} = Mobile.issue_exchange_code(user, challenge)
      conn2 = post(conn, "/api/app/session", %{"code" => code, "code_verifier" => verifier})
      assert json_response(conn2, 200)
      conn3 = post(conn, "/api/app/session", %{"code" => code, "code_verifier" => verifier})
      assert json_response(conn3, 400) == %{"error" => "invalid_grant"}

      {:ok, code} = Mobile.issue_exchange_code(user, challenge)

      Repo.update_all(Platform.Mobile.AppLoginCode,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

      conn4 = post(conn, "/api/app/session", %{"code" => code, "code_verifier" => verifier})
      assert json_response(conn4, 400) == %{"error" => "invalid_grant"}
    end

    test "DELETE /api/app/session revokes the bearer", %{conn: conn, token: token} do
      conn1 = conn |> bearer(token) |> delete("/api/app/session")
      assert response(conn1, 204)
      conn2 = conn |> bearer(token) |> get("/api/app/counts")
      assert json_response(conn2, 401)
    end
  end

  describe "POST /api/app/handoff" do
    defp handoff_path(handoff_url) do
      %URI{path: path, query: query} = URI.parse(handoff_url)
      {path <> "?" <> query, URI.decode_query(query)}
    end

    test "returns a handoff url whose code signs the web view in exactly once", %{
      conn: conn,
      token: token,
      user: user
    } do
      %{"handoff_url" => handoff_url} =
        conn |> bearer(token) |> post("/api/app/handoff") |> json_response(200)

      {path, query} = handoff_path(handoff_url)
      assert String.starts_with?(path, "/auth/app/handoff?code=")
      refute Map.has_key?(query, "to")

      conn1 = get(build_conn(), path)
      assert redirected_to(conn1, 302) == "/"
      assert get_session(conn1, :current_user_id) == user.id

      conn2 = get(build_conn(), path)
      assert response(conn2, 401) == "Sign-in link is invalid or has expired"
      assert get_session(conn2, :current_user_id) == nil

      conn3 = get(build_conn(), "/auth/app/handoff?code=garbage")
      assert response(conn3, 401)
    end

    test "each call mints a different code", %{conn: conn, token: token} do
      urls =
        for _ <- 1..2 do
          conn |> bearer(token) |> post("/api/app/handoff") |> json_response(200)
        end

      assert [%{"handoff_url" => a}, %{"handoff_url" => b}] = urls
      refute a == b
    end

    test "a local path lands there; anything else lands on /", %{conn: conn, token: token} do
      for {path, landing} <- [
            {"/chat/design", "/chat/design"},
            {"/tasks/abc?tab=plan", "/tasks/abc?tab=plan"},
            {"//evil.example/x", "/"},
            {"https://evil.example/x", "/"},
            {"/\\evil.example", "/"},
            {"/auth/logout", "/"},
            {"chat", "/"}
          ] do
        %{"handoff_url" => url} =
          conn
          |> bearer(token)
          |> post("/api/app/handoff", %{"path" => path})
          |> json_response(200)

        {handoff, _query} = handoff_path(url)
        assert redirected_to(get(build_conn(), handoff), 302) == landing, inspect(path)
      end
    end

    test "a revoked bearer gets 401 and no code", %{conn: conn, token: token, session: session} do
      {:ok, _} = Mobile.revoke_session(session)
      before = Repo.aggregate(Platform.Mobile.AppLoginCode, :count)
      conn = conn |> bearer(token) |> post("/api/app/handoff")
      assert json_response(conn, 401) == %{"error" => "unauthorized"}
      assert Repo.aggregate(Platform.Mobile.AppLoginCode, :count) == before
    end

    test "logs neither the bearer nor the handoff code", %{conn: conn, token: token} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      {code, log} =
        with_log([level: :debug], fn ->
          %{"handoff_url" => url} =
            conn
            |> bearer(token)
            |> post("/api/app/handoff", %{"path" => "/chat/design"})
            |> json_response(200)

          {path, query} = handoff_path(url)
          build_conn() |> get(path) |> redirected_to(302)
          query["code"]
        end)

      assert log =~ "/api/app/handoff", "the request log was not captured at all"
      refute log =~ token
      refute log =~ code
    end
  end

  describe "devices" do
    test "register then unregister", %{conn: conn, token: token, user: user} do
      conn1 =
        conn
        |> bearer(token)
        |> post("/api/app/devices", %{
          "token" => @device_token,
          "environment" => "sandbox",
          "bundle_id" => "com.kobo-ai.burrow",
          "app_install_id" => "install-1"
        })

      assert json_response(conn1, 200) == %{"registered" => true}
      refute response(conn1, 200) =~ @device_token
      assert [%ApnsDevice{token: @device_token}] = Mobile.list_devices(user)

      conn2 = conn |> bearer(token) |> delete("/api/app/devices/install-1")
      assert response(conn2, 204)
      assert Mobile.list_devices(user) == []
    end

    test "an invalid device is refused without echoing the token", %{conn: conn, token: token} do
      conn =
        conn
        |> bearer(token)
        |> post("/api/app/devices", %{
          "token" => @device_token,
          "environment" => "voip",
          "bundle_id" => "com.kobo-ai.burrow",
          "app_install_id" => "install-1"
        })

      body = response(conn, 422)
      assert %{"error" => "invalid_device", "fields" => ["environment"]} = Jason.decode!(body)
      refute body =~ @device_token
    end
  end

  describe "GET /api/app/spaces" do
    test "lists only the user's spaces, each with its agents", %{
      conn: conn,
      token: token,
      space: space
    } do
      agent = agent!("Helper")
      add_agent!(space.id, agent.id)
      other = channel!()

      conn = conn |> bearer(token) |> get("/api/app/spaces")
      %{"spaces" => spaces} = json_response(conn, 200)

      ids = Enum.map(spaces, & &1["id"])
      assert space.id in ids
      refute other.id in ids

      listed = Enum.find(spaces, &(&1["id"] == space.id))
      assert [%{"id" => agent_id, "name" => agent_name}] = listed["agents"]
      assert agent_id == agent.id
      assert agent_name == agent.name
    end

    test "an external user sees only their scoped spaces", %{conn: conn} do
      world = external_world()
      %{token: token} = app_session!(world.ext)

      conn = conn |> bearer(token) |> get("/api/app/spaces")
      ids = conn |> json_response(200) |> Map.fetch!("spaces") |> Enum.map(& &1["id"])

      assert world.a.id in ids
      refute world.b.id in ids
    end
  end

  describe "POST /api/app/spaces/:space_id/messages" do
    test "posts text into a member space", %{conn: conn, token: token, space: space} do
      conn =
        conn |> bearer(token) |> post("/api/app/spaces/#{space.id}/messages", %{"text" => "hi"})

      assert %{"message" => %{"id" => id}} = json_response(conn, 201)
      assert %Message{content: "hi", space_id: space_id} = Repo.get!(Message, id)
      assert space_id == space.id
    end

    test "403 into a space the user is not a member of", %{conn: conn, token: token} do
      other = channel!()

      conn =
        conn |> bearer(token) |> post("/api/app/spaces/#{other.id}/messages", %{"text" => "hi"})

      assert json_response(conn, 403) == %{"error" => "forbidden"}
      assert Repo.aggregate(from(m in Message, where: m.space_id == ^other.id), :count) == 0
    end

    test "403 for a nonexistent or malformed space id", %{conn: conn, token: token} do
      for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        conn = conn |> bearer(token) |> post("/api/app/spaces/#{id}/messages", %{"text" => "x"})
        assert json_response(conn, 403) == %{"error" => "forbidden"}
      end
    end

    test "agent_id renders an @-mention of that agent", %{conn: conn, token: token, space: space} do
      agent = agent!("Mentioned")
      add_agent!(space.id, agent.id)

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{space.id}/messages", %{
          "text" => "look at this",
          "agent_id" => agent.id
        })

      %{"message" => %{"id" => id}} = json_response(conn, 201)
      assert Repo.get!(Message, id).content == "@[#{agent.name}] look at this"
    end

    test "an agent not in the space is refused", %{conn: conn, token: token, space: space} do
      agent = agent!("Stranger")

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{space.id}/messages", %{"text" => "x", "agent_id" => agent.id})

      assert json_response(conn, 422) == %{"error" => "unknown_agent"}
    end

    test "reply_to threads the message under its parent", %{
      conn: conn,
      token: token,
      space: space,
      user: user
    } do
      participant = participant_pk!(space.id, user.id)
      parent = post!(space.id, participant, "parent")

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{space.id}/messages", %{
          "text" => "reply",
          "reply_to" => parent.id
        })

      %{"message" => %{"thread_id" => thread_id}} = json_response(conn, 201)
      assert thread_id == Chat.get_thread_for_message(parent.id).id
    end

    test "a single file is attached", %{conn: conn, token: token, space: space} do
      dir = Path.join(System.tmp_dir!(), "app-api-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "note.txt")
      File.write!(path, "shared from the app")

      upload = %Plug.Upload{path: path, filename: "note.txt", content_type: "text/plain"}

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{space.id}/messages", %{"file" => upload})

      assert %{"attachments" => [%{"filename" => "note.txt"}]} = json_response(conn, 201)
    end

    test "an empty message is refused", %{conn: conn, token: token, space: space} do
      conn = conn |> bearer(token) |> post("/api/app/spaces/#{space.id}/messages", %{})
      assert json_response(conn, 422) == %{"error" => "empty_message"}
    end
  end

  describe "secrets never reach the log" do
    test "register, exchange, 401 and 403 paths log neither sentinel", %{conn: conn} do
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      user = create_user!()
      other = channel!()

      {bearer_token, log} =
        with_log([level: :debug], fn ->
          {verifier, challenge} = pkce()
          {:ok, code} = Mobile.issue_exchange_code(user, challenge)

          %{"token" => token} =
            conn
            |> post("/api/app/session", %{"code" => code, "code_verifier" => verifier})
            |> json_response(200)

          conn
          |> bearer(token)
          |> post("/api/app/devices", %{
            "token" => @device_token,
            "environment" => "sandbox",
            "bundle_id" => "com.kobo-ai.burrow",
            "app_install_id" => "install-1"
          })
          |> json_response(200)

          conn
          |> bearer(token)
          |> post("/api/app/spaces/#{other.id}/messages", %{"text" => "x"})
          |> json_response(403)

          {:ok, _user, session} = Mobile.verify_bearer(token)
          {:ok, _} = Mobile.revoke_session(session)

          conn |> bearer(token) |> get("/api/app/counts") |> json_response(401)

          token
        end)

      assert log != "", "the capture saw nothing, so its refutations prove nothing"
      refute log =~ bearer_token
      refute log =~ @device_token
    end
  end
end
