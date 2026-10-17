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
  @fcm_token "fcmCtrl00001:APA91b" <> String.duplicate("Ctr1_T0k-", 12)

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
    {:get, "/api/app/counts", %{}},
    {:get, "/api/app/upload_config", %{}},
    {:post, "/api/app/spaces/:space_id/uploads",
     %{"filename" => "a.bin", "content_type" => "application/octet-stream", "byte_size" => 10}}
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

  describe "android devices (task 01a10d8e)" do
    test "platform=android registers an FCM device; unregister removes it",
         %{conn: conn, token: token, user: user} do
      conn1 =
        conn
        |> bearer(token)
        |> post("/api/app/devices", %{
          "platform" => "android",
          "token" => @fcm_token,
          "package_name" => "com.koboai.burrow",
          "app_install_id" => "install-1"
        })

      assert json_response(conn1, 200) == %{"registered" => true}
      refute response(conn1, 200) =~ @fcm_token
      assert [%{token: @fcm_token}] = Mobile.list_fcm_devices(user)
      assert Mobile.list_devices(user) == []

      conn2 = conn |> bearer(token) |> delete("/api/app/devices/install-1")
      assert response(conn2, 204)
      assert Mobile.list_fcm_devices(user) == []
    end

    test "a refused android device answers 422 with field names only, never the token",
         %{conn: conn, token: token} do
      conn =
        conn
        |> bearer(token)
        |> post("/api/app/devices", %{
          "platform" => "android",
          "token" => @fcm_token,
          "package_name" => "com.kobo-ai.burrow",
          "app_install_id" => "install-1"
        })

      body = response(conn, 422)
      assert %{"error" => "invalid_device", "fields" => ["package_name"]} = Jason.decode!(body)
      refute body =~ @fcm_token
    end

    test "a malformed android token answers 422 without echoing it",
         %{conn: conn, token: token} do
      bad = "fcm token with spaces " <> String.duplicate("z", 30)

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/devices", %{
          "platform" => "android",
          "token" => bad,
          "package_name" => "com.koboai.burrow",
          "app_install_id" => "install-1"
        })

      body = response(conn, 422)
      assert %{"fields" => ["token"]} = Jason.decode!(body)
      refute body =~ "spaces"
    end
  end

  defp device_key(bytes \\ 32),
    do: :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)

  defp register(conn, token, extra) do
    conn
    |> bearer(token)
    |> post(
      "/api/app/devices",
      Map.merge(
        %{
          "token" => @device_token,
          "environment" => "sandbox",
          "bundle_id" => "com.kobo-ai.burrow",
          "app_install_id" => "install-1"
        },
        extra
      )
    )
  end

  defp seed_unread!(space, count) do
    author = add_user!(space.id, create_user!().id)

    for i <- 1..count do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "unread #{i}"
        })
    end
  end

  describe "push_public_key on registration (task 01a1261e)" do
    test "an iOS registration with a valid key stores it", %{conn: conn, token: token, user: user} do
      key = device_key()
      conn = register(conn, token, %{"push_public_key" => key})

      assert json_response(conn, 200) == %{"registered" => true}
      refute response(conn, 200) =~ key
      assert [%ApnsDevice{push_public_key: ^key}] = Mobile.list_devices(user)
    end

    test "an android registration with a valid key stores it",
         %{conn: conn, token: token, user: user} do
      key = device_key()

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/devices", %{
          "platform" => "android",
          "token" => @fcm_token,
          "package_name" => "com.koboai.burrow",
          "app_install_id" => "install-1",
          "push_public_key" => key
        })

      assert json_response(conn, 200) == %{"registered" => true}
      assert [%{push_public_key: ^key}] = Mobile.list_fcm_devices(user)
    end

    test "a 31-byte key is a 422 naming only the field", %{conn: conn, token: token, user: user} do
      key = device_key(31)
      body = conn |> register(token, %{"push_public_key" => key}) |> response(422)

      assert Jason.decode!(body) == %{
               "error" => "invalid_device",
               "fields" => ["push_public_key"]
             }

      refute body =~ key
      refute body =~ @device_token
      assert Mobile.list_devices(user) == []
    end

    test "a padded key is a 422 naming only the field", %{conn: conn, token: token} do
      padded = :crypto.strong_rand_bytes(32) |> Base.url_encode64()
      assert String.ends_with?(padded, "=")

      body = conn |> register(token, %{"push_public_key" => padded}) |> response(422)

      assert Jason.decode!(body) == %{
               "error" => "invalid_device",
               "fields" => ["push_public_key"]
             }
    end

    test "a bad key on android is refused the same way", %{conn: conn, token: token} do
      body =
        conn
        |> bearer(token)
        |> post("/api/app/devices", %{
          "platform" => "android",
          "token" => @fcm_token,
          "package_name" => "com.koboai.burrow",
          "app_install_id" => "install-1",
          "push_public_key" => device_key(33)
        })
        |> response(422)

      assert Jason.decode!(body) == %{
               "error" => "invalid_device",
               "fields" => ["push_public_key"]
             }
    end

    test "a key-less registration (TestFlight build 1: no platform, no key) still returns 200",
         %{conn: conn, token: token, user: user} do
      conn = register(conn, token, %{})

      assert json_response(conn, 200) == %{"registered" => true}
      assert [%ApnsDevice{token: @device_token, push_public_key: nil}] = Mobile.list_devices(user)
    end

    test "re-registering the token replaces the stored key", %{
      conn: conn,
      token: token,
      user: user
    } do
      first = device_key()
      second = device_key()

      assert json_response(register(conn, token, %{"push_public_key" => first}), 200)
      assert json_response(register(conn, token, %{"push_public_key" => second}), 200)

      assert [%ApnsDevice{push_public_key: ^second}] = Mobile.list_devices(user)
    end
  end

  describe "push_category_scheme on registration (task 01a14ba1)" do
    test "an iOS registration declaring burrow stores it",
         %{conn: conn, token: token, user: user} do
      conn = register(conn, token, %{"push_category_scheme" => "burrow"})

      assert json_response(conn, 200) == %{"registered" => true}
      assert [%ApnsDevice{push_category_scheme: "burrow"}] = Mobile.list_devices(user)
    end

    test "an android registration declaring burrow stores it",
         %{conn: conn, token: token, user: user} do
      conn =
        conn
        |> bearer(token)
        |> post("/api/app/devices", %{
          "platform" => "android",
          "token" => @fcm_token,
          "package_name" => "com.koboai.burrow",
          "app_install_id" => "install-1",
          "push_category_scheme" => "burrow"
        })

      assert json_response(conn, 200) == %{"registered" => true}
      assert [%{push_category_scheme: "burrow"}] = Mobile.list_fcm_devices(user)
    end

    test "a registration without the field stores nil (every shipped build)",
         %{conn: conn, token: token, user: user} do
      assert json_response(register(conn, token, %{}), 200) == %{"registered" => true}
      assert [%ApnsDevice{push_category_scheme: nil}] = Mobile.list_devices(user)
    end

    test "an unknown scheme is a 422 naming only the field",
         %{conn: conn, token: token, user: user} do
      body = conn |> register(token, %{"push_category_scheme" => "suite"}) |> response(422)

      assert Jason.decode!(body) == %{
               "error" => "invalid_device",
               "fields" => ["push_category_scheme"]
             }

      refute body =~ @device_token
      assert Mobile.list_devices(user) == []
    end
  end

  describe "GET /api/app/counts unread (task 01a1261e)" do
    test "unread equals Chat.total_unread_for_viewer/1 and excludes an archived space",
         %{conn: conn, token: token, user: user, space: space} do
      seed_unread!(space, 3)

      archived = channel!()
      add_user!(archived.id, user.id)
      seed_unread!(archived, 4)
      {:ok, _} = Chat.archive_space(archived)

      # Precondition: the archived space really holds unread for this user,
      # so its absence from the total is the intersection's work, not an
      # empty space's.
      assert Map.get(Chat.unread_counts_for_user(user.id), archived.id) == 4

      body = conn |> bearer(token) |> get("/api/app/counts") |> json_response(200)

      assert body["unread"] == 3
      assert body["unread"] == Chat.total_unread_for_viewer(user)
      assert {:ok, _, 0} = DateTime.from_iso8601(body["as_of"])
    end

    test "a user with nothing unread gets 0", %{conn: conn, token: token} do
      body = conn |> bearer(token) |> get("/api/app/counts") |> json_response(200)
      assert body["unread"] == 0
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

    # Slack semantics (Lock Screen Reply, 2026-10-05): the reply to a
    # top-level message is itself top-level, so it shows in the timeline;
    # it must NOT open a thread under the message it answers.
    test "reply_to a top-level message posts top-level, opening no thread", %{
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

      %{"message" => %{"id" => id, "thread_id" => thread_id}} = json_response(conn, 201)
      assert thread_id == nil
      assert %Message{thread_id: nil, space_id: space_id} = Repo.get!(Message, id)
      assert space_id == space.id
      assert Chat.get_thread_for_message(parent.id) == nil
    end

    test "reply_to a message inside a thread posts into that thread", %{
      conn: conn,
      token: token,
      space: space,
      user: user
    } do
      participant = participant_pk!(space.id, user.id)
      root = post!(space.id, participant, "root")
      {:ok, thread} = Chat.create_thread_for_message(space.id, root.id)

      {:ok, in_thread} =
        Chat.post_message(%{
          space_id: space.id,
          thread_id: thread.id,
          participant_id: participant,
          content_type: "text",
          content: "in thread"
        })

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{space.id}/messages", %{
          "text" => "reply",
          "reply_to" => in_thread.id
        })

      %{"message" => %{"id" => id, "thread_id" => thread_id}} = json_response(conn, 201)
      assert thread_id == thread.id
      assert Repo.get!(Message, id).thread_id == thread.id
    end

    test "reply_to a message in another space is refused", %{
      conn: conn,
      token: token,
      space: space
    } do
      other = channel!()
      stranger = create_user!()
      add_user!(other.id, stranger.id)
      foreign = post!(other.id, participant_pk!(other.id, stranger.id), "elsewhere")

      conn =
        conn
        |> bearer(token)
        |> post("/api/app/spaces/#{space.id}/messages", %{
          "text" => "reply",
          "reply_to" => foreign.id
        })

      assert json_response(conn, 422) == %{"error" => "invalid_reply_to"}
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
