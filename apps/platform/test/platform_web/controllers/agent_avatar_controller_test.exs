defmodule PlatformWeb.AgentAvatarControllerTest do
  @moduledoc """
  Tests for `/agents/:id/avatar` (task `01a00122` stage 1).

  ## Coverage matrix

    * 200 inline for an agent with a stored avatar, on an authenticated
      session, with `x-content-type-options: nosniff`.
    * The served `Content-Type` comes from the stored key, not the request.
    * 404 for an unknown agent id, an agent with no avatar, and a row whose
      `avatar_storage_key` points at bytes that are gone.
    * 404 (not a 500) for a non-UUID id — `Repo.get(Agent, id)` RAISES on a
      malformed binary id, and the id arrives straight off the URL.
    * 302 to login for an unauthenticated session.
  """

  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AvatarStorage
  alias Platform.Chat.AttachmentStorage
  alias Platform.Repo

  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)

    scratch =
      Path.join(System.tmp_dir!(), "agent_avatar_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(scratch)
    Application.put_env(:platform, :chat_attachments_root, scratch)

    on_exit(fn ->
      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end

      File.rm_rf!(scratch)
    end)

    :ok
  end

  # ── Fixtures ───────────────────────────────────────────────────────────

  defp png_bytes do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  defp insert_user do
    uniq = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "avatar_user_#{uniq}@example.com",
      name: "Avatar User",
      oidc_sub: "oidc-avatar-#{uniq}"
    })
  end

  defp insert_agent(attrs \\ %{}) do
    uniq = System.unique_integer([:positive])

    base = %{
      slug: "avatar-agent-#{uniq}",
      name: "Avatar Agent",
      status: "active",
      workspace_id: Ecto.UUID.generate()
    }

    %Agent{}
    |> Agent.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  # Stores a real avatar blob for the agent and writes the key to the row,
  # which is exactly the sequence the stage-2 upload handler will perform.
  defp insert_agent_with_avatar(opts \\ []) do
    agent = insert_agent()

    {:ok, result} =
      AvatarStorage.put({:binary, png_bytes()}, agent.id,
        filename: Keyword.get(opts, :filename, "face.png"),
        content_type: Keyword.get(opts, :content_type, "image/png")
      )

    agent =
      agent
      |> Agent.changeset(%{
        avatar_storage_key: result.storage_key,
        avatar_url: "/agents/#{agent.id}/avatar"
      })
      |> Repo.update!()

    {agent, result.storage_key}
  end

  defp authed_conn(conn, user), do: init_test_session(conn, current_user_id: user.id)

  # ── Tests ──────────────────────────────────────────────────────────────

  describe "GET /agents/:id/avatar — authenticated" do
    test "serves the stored avatar inline with nosniff", %{conn: conn} do
      {agent, _key} = insert_agent_with_avatar()

      conn =
        conn
        |> authed_conn(insert_user())
        |> get(~p"/agents/#{agent.id}/avatar")

      assert conn.status == 200
      assert conn.resp_body == png_bytes()
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "inline"
    end

    test "content type is read off the stored key, not the request", %{conn: conn} do
      {agent, _key} = insert_agent_with_avatar(content_type: "image/webp", filename: "face")

      conn =
        conn
        |> authed_conn(insert_user())
        # A lying Accept header must not steer the response type.
        |> put_req_header("accept", "text/html")
        |> get(~p"/agents/#{agent.id}/avatar")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "image/webp"
    end

    test "an avatar is served to ANY authenticated user, not just one org" do
      # The gate is deliberately the session and nothing narrower: an agent
      # renders in chat, meetings, the control center and the activity
      # feed, so a membership gate would blank it for legitimate viewers.
      # Two unrelated users, neither sharing an org or a space with the
      # other, both get the bytes.
      {agent, _key} = insert_agent_with_avatar()

      for _ <- 1..2 do
        conn =
          build_conn()
          |> authed_conn(insert_user())
          |> get(~p"/agents/#{agent.id}/avatar")

        assert conn.status == 200
        assert conn.resp_body == png_bytes()
      end
    end

    test "404 for an agent that has no avatar", %{conn: conn} do
      agent = insert_agent()

      conn =
        conn
        |> authed_conn(insert_user())
        |> get(~p"/agents/#{agent.id}/avatar")

      assert conn.status == 404
    end

    test "404 for an unknown agent id", %{conn: conn} do
      conn =
        conn
        |> authed_conn(insert_user())
        |> get(~p"/agents/#{Ecto.UUID.generate()}/avatar")

      assert conn.status == 404
    end

    test "404, not 500, for a non-UUID id", %{conn: conn} do
      # `Repo.get(Agent, "not-a-uuid")` raises Ecto.Query.CastError. The id
      # comes straight off the URL, so the guard is what keeps this a 404.
      conn =
        conn
        |> authed_conn(insert_user())
        |> get("/agents/not-a-uuid/avatar")

      assert conn.status == 404
    end

    test "404 when the row points at bytes that are gone", %{conn: conn} do
      {agent, key} = insert_agent_with_avatar()
      File.rm!(AttachmentStorage.path_for(key))

      conn =
        conn
        |> authed_conn(insert_user())
        |> get(~p"/agents/#{agent.id}/avatar")

      assert conn.status == 404
    end
  end

  describe "GET /agents/:id/avatar — unauthenticated" do
    test "redirects to login without serving bytes", %{conn: conn} do
      {agent, _key} = insert_agent_with_avatar()

      # No init_test_session — the :require_auth plug halts the conn before
      # the controller runs at all.
      conn = get(conn, ~p"/agents/#{agent.id}/avatar")

      assert conn.status == 302
      assert redirected_to(conn) == "/auth/login"
      refute conn.resp_body == png_bytes()
    end
  end
end
