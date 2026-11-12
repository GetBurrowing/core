defmodule PlatformWeb.SwitcherUnreadControllerTest do
  @moduledoc """
  Task 01a1ccd4 stage 2: `GET /api/switcher/unread` and its preflight
  (`PlatformWeb.Plugs.SwitcherBadgeAuth`). CORS is bound to the key's origin,
  the body is exactly `unread` + `as_of`, and a badge key opens no
  `/api/app/*` route.
  """
  use PlatformWeb.ConnCase, async: true

  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Switcher

  @a "https://a.example"

  setup %{conn: conn} do
    user = create_user!()
    {:ok, %{token: token, key: key}} = Switcher.mint(user, @a)
    %{conn: conn, user: user, token: token, key: key}
  end

  defp unread(conn, token, origin) do
    conn
    |> then(&if(token, do: put_req_header(&1, "authorization", "Bearer " <> token), else: &1))
    |> then(&if(origin, do: put_req_header(&1, "origin", origin), else: &1))
    |> get("/api/switcher/unread")
  end

  defp header(conn, name), do: get_resp_header(conn, name)

  describe "GET with a valid key from its bound origin" do
    test "answers unread and as_of only, CORS allowed for that origin", %{
      conn: conn,
      token: token
    } do
      conn = unread(conn, token, @a)
      body = json_response(conn, 200)

      assert body |> Map.keys() |> Enum.sort() == ["as_of", "unread"]
      assert body["unread"] == 0
      assert {:ok, _, 0} = DateTime.from_iso8601(body["as_of"])

      assert header(conn, "access-control-allow-origin") == [@a]
      assert header(conn, "vary") == ["Origin"]
      assert header(conn, "access-control-allow-credentials") == []
      assert header(conn, "cache-control") == ["no-store"]
    end

    test "the count is the viewer's Chat unread total", %{conn: conn, user: user, token: token} do
      space = channel!()
      add_user!(space.id, user.id)
      author = add_user!(space.id, create_user!().id)

      for i <- 1..3 do
        {:ok, _} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: author.id,
            content_type: "text",
            content: "unread #{i}"
          })
      end

      assert Chat.total_unread_for_viewer(user) == 3
      assert json_response(unread(conn, token, @a), 200)["unread"] == 3
    end

    test "does not touch the session cookie", %{conn: conn, token: token} do
      conn = unread(conn, token, @a)
      assert conn.status == 200
      assert header(conn, "set-cookie") == []
      refute Map.has_key?(conn.private, :plug_session)
    end
  end

  # The refusal's CORS (stage 3, narrowed in stage 4): a 401 is readable
  # ONLY by the presented key's own bound origin, so the switcher holding a
  # dead key can show "Reconnect" while a hostile page replaying the key (or
  # any unknown key) gets no allow header. Never credentials.
  describe "refusals are 401, readable only by the key's own origin" do
    test "origin mismatch: no allow header for any other origin", %{conn: conn, token: token} do
      for origin <- ["https://evil.example", "https://a.example:8443", "http://a.example", nil] do
        conn = unread(conn, token, origin)
        assert json_response(conn, 401) == %{"error" => "unauthorized"}, inspect(origin)
        assert header(conn, "access-control-allow-origin") == [], inspect(origin)
        assert header(conn, "access-control-allow-credentials") == []
        assert header(conn, "vary") == ["Origin"]
      end
    end

    test "unknown, missing, revoked and expired keys", %{
      conn: conn,
      user: user,
      token: token,
      key: key
    } do
      # An unknown or missing key: nobody may read the refusal.
      for t <- ["bk_garbage", nil] do
        conn = unread(conn, t, @a)
        assert conn.status == 401
        assert header(conn, "access-control-allow-origin") == []
      end

      {:ok, %{token: expired}} =
        Switcher.mint(user, "https://e.example", now: DateTime.add(DateTime.utc_now(), -91, :day))

      conn2 = unread(conn, expired, "https://e.example")
      assert conn2.status == 401
      assert header(conn2, "access-control-allow-origin") == ["https://e.example"]

      {:ok, _} = Switcher.revoke(user, key.id)
      conn3 = unread(conn, token, @a)
      assert conn3.status == 401
      assert header(conn3, "access-control-allow-origin") == [@a]
      assert json_response(conn3, 401) == %{"error" => "unauthorized"}

      # The same dead key replayed from another origin: not readable there.
      conn4 = unread(conn, token, "https://d.example")
      assert conn4.status == 401
      assert header(conn4, "access-control-allow-origin") == []
      assert header(build_conn() |> unread(expired, @a), "access-control-allow-origin") == []
    end

    test "the key in the query string is not read", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("origin", @a)
        |> get("/api/switcher/unread?access_token=#{token}&key=#{token}&token=#{token}")

      assert conn.status == 401
    end

    test "a session cookie is not a credential here", %{conn: conn, user: user} do
      conn =
        conn
        |> init_test_session(current_user_id: user.id)
        |> put_req_header("origin", @a)
        |> get("/api/switcher/unread")

      assert conn.status == 401
    end

    test "an app_sessions bearer is not a badge key", %{conn: conn, user: user} do
      %{token: app_token} = app_session!(user)
      conn = unread(conn, app_token, @a)
      assert conn.status == 401
    end
  end

  describe "OPTIONS preflight" do
    test "echoes a well-formed Origin, allows GET + Authorization, never credentials", %{
      conn: conn
    } do
      conn =
        conn
        |> put_req_header("origin", "https://any.example")
        |> put_req_header("access-control-request-method", "GET")
        |> put_req_header("access-control-request-headers", "authorization")
        |> options("/api/switcher/unread")

      assert conn.status == 204
      assert header(conn, "access-control-allow-origin") == ["https://any.example"]
      assert header(conn, "access-control-allow-methods") == ["GET, DELETE"]
      assert header(conn, "access-control-allow-headers") == ["Authorization"]
      assert header(conn, "access-control-allow-credentials") == []
      assert header(conn, "vary") == ["Origin"]
      refute "*" in header(conn, "access-control-allow-origin")
    end

    test "a missing or malformed Origin gets no allow header", %{conn: conn} do
      for origin <- [nil, "null", "https://a.example/path", "http://evil.example"] do
        conn =
          if(origin, do: put_req_header(conn, "origin", origin), else: conn)
          |> options("/api/switcher/unread")

        assert conn.status == 204
        assert header(conn, "access-control-allow-origin") == [], inspect(origin)
      end
    end
  end

  describe "a badge key opens no /api/app route" do
    test "/api/app/spaces and /api/app/counts", %{conn: conn, token: token} do
      for path <- ["/api/app/spaces", "/api/app/counts"] do
        conn =
          conn
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("origin", @a)
          |> get(path)

        assert json_response(conn, 401) == %{"error" => "unauthorized"}, path
      end
    end

    test "every bearer-authenticated /api/app route", %{conn: conn, token: token} do
      # The two unauthenticated routes (they mint or describe, see the router).
      open = [{"POST", "/api/app/session"}, {"GET", "/api/app/install"}]

      routes =
        for %{verb: verb, path: "/api/app" <> _ = path} <- PlatformWeb.Router.__routes__(),
            verb = verb |> to_string() |> String.upcase(),
            {verb, path} not in open,
            do: {verb, path}

      assert length(routes) > 20

      for {verb, path} <- routes do
        concrete = String.replace(path, ~r/:[a-z_]+/, Ecto.UUID.generate())

        conn =
          conn
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("origin", @a)
          |> dispatch(@endpoint, verb, concrete, %{})

        assert conn.status == 401, "#{verb} #{path} answered #{conn.status}"
      end
    end
  end

  defp app_session!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Platform.Mobile.issue_exchange_code(user, challenge)
    {:ok, result} = Platform.Mobile.exchange_code(code, verifier, %{app_install_id: "i-1"})
    result
  end
end
