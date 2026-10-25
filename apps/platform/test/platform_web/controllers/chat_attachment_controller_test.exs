defmodule PlatformWeb.ChatAttachmentControllerTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias Platform.Repo

  setup do
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Platform.TestTemp.path("platform_test_chat_uploads")

    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      File.rm_rf(upload_root)
      Application.put_env(:platform, :chat_attachments_root, previous_root)
    end)

    :ok
  end

  defp insert_user do
    Repo.insert!(%User{
      email: "chat-attachment-#{System.unique_integer([:positive])}@example.com",
      name: "Chat Attachment User",
      oidc_sub: "oidc-chat-attachment-#{System.unique_integer([:positive])}"
    })
  end

  defp authenticate_session(conn, user) do
    init_test_session(conn, current_user_id: user.id)
  end

  defp authenticate_bearer(conn, token) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end

  defp insert_agent_and_runtime do
    agent =
      Repo.insert!(%Agent{
        name: "attachment-test-agent-#{System.unique_integer([:positive])}",
        slug: "attachment-test-agent-#{System.unique_integer([:positive])}"
      })

    token = "runtime-token-#{System.unique_integer([:positive])}"

    owner = insert_user()

    runtime =
      Repo.insert!(%AgentRuntime{
        agent_id: agent.id,
        owner_user_id: owner.id,
        status: "active",
        auth_token_hash: AgentRuntime.hash_token(token),
        runtime_id: "runtime-#{System.unique_integer([:positive])}"
      })

    {agent, runtime, token}
  end

  defp create_attachment_fixture(
         filename \\ "hello.txt",
         content_type \\ "text/plain",
         body \\ "hello attachment"
       ) do
    {:ok, space} =
      Chat.create_space(%{
        name: "General",
        slug: "general-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now()
      })

    {:ok, message} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "attachment test"
      })

    source_path =
      Platform.TestTemp.path("chat-attachment-source") <> ".txt"

    File.write!(source_path, body)

    {:ok, stored} = AttachmentStorage.persist_upload(source_path, filename, content_type)
    File.rm(source_path)

    # Store the literal content_type verbatim, even if persist_upload
    # normalises a mixed-case or param-bearing type.
    {:ok, attachment} =
      Chat.create_attachment(
        stored
        |> Map.put(:content_type, content_type)
        |> Map.put(:message_id, message.id)
        |> Map.put(:space_id, space.id)
      )

    %{space: space, participant: participant, message: message, attachment: attachment}
  end

  defp join_space_as_user(space_id, %User{} = user) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp join_space_as_agent(space_id, %Agent{} = agent) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "agent",
        participant_id: agent.id,
        joined_at: DateTime.utc_now()
      })

    participant
  end

  test "GET /chat/attachments/:id redirects unauthenticated users to login", %{conn: conn} do
    %{attachment: attachment} = create_attachment_fixture()

    conn = get(conn, ~p"/chat/attachments/#{attachment.id}")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /chat/attachments/:id downloads for a session user who is a member", %{conn: conn} do
    %{space: space, attachment: attachment} = create_attachment_fixture()
    user = insert_user()
    _ = join_space_as_user(space.id, user)

    conn =
      conn
      |> authenticate_session(user)
      |> get(~p"/chat/attachments/#{attachment.id}")

    assert response(conn, 200) == "hello attachment"
    assert get_resp_header(conn, "content-type") == ["text/plain"]
  end

  test "GET /chat/attachments/:id returns 404 for a session user who is not a member", %{
    conn: conn
  } do
    %{attachment: attachment} = create_attachment_fixture()
    user = insert_user()

    conn =
      conn
      |> authenticate_session(user)
      |> get(~p"/chat/attachments/#{attachment.id}")

    assert response(conn, 404) =~ "Not found"
  end

  test "GET /chat/attachments/:id downloads for a runtime bearer whose agent is a member", %{
    conn: conn
  } do
    %{space: space, attachment: attachment} = create_attachment_fixture()
    {agent, _runtime, token} = insert_agent_and_runtime()
    _ = join_space_as_agent(space.id, agent)

    conn =
      conn
      |> authenticate_bearer(token)
      |> get(~p"/chat/attachments/#{attachment.id}")

    assert response(conn, 200) == "hello attachment"
  end

  test "GET /chat/attachments/:id returns 404 for a runtime whose agent is not a member", %{
    conn: conn
  } do
    %{attachment: attachment} = create_attachment_fixture()
    {_agent, _runtime, token} = insert_agent_and_runtime()

    conn =
      conn
      |> authenticate_bearer(token)
      |> get(~p"/chat/attachments/#{attachment.id}")

    assert response(conn, 404) =~ "Not found"
  end

  test "GET /chat/attachments/:id returns 401 when bearer token is invalid", %{conn: conn} do
    %{attachment: attachment} = create_attachment_fixture()

    conn =
      conn
      |> authenticate_bearer("definitely-not-a-real-token")
      |> get(~p"/chat/attachments/#{attachment.id}")

    assert response(conn, 401)
  end

  test "GET /chat/attachments/:id returns 404 when parent message is deleted", %{conn: conn} do
    %{space: space, attachment: attachment, message: message} = create_attachment_fixture()
    user = insert_user()
    _ = join_space_as_user(space.id, user)

    assert {:ok, _} = Chat.delete_message(message)

    conn =
      conn
      |> authenticate_session(user)
      |> get(~p"/chat/attachments/#{attachment.id}")

    assert response(conn, 404) =~ "Not found"
  end

  describe "response policy (task 01a16a08)" do
    defp fetch_as_member(conn, filename, content_type, req_headers \\ []) do
      %{space: space, attachment: attachment} =
        create_attachment_fixture(filename, content_type, "<html><script>alert(1)</script>")

      user = insert_user()
      _ = join_space_as_user(space.id, user)

      conn = authenticate_session(conn, user)

      conn =
        Enum.reduce(req_headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

      get(conn, ~p"/chat/attachments/#{attachment.id}")
    end

    defp assert_sandboxed_download(conn) do
      [disposition] = get_resp_header(conn, "content-disposition")
      assert String.starts_with?(disposition, "attachment;")
      assert get_resp_header(conn, "content-security-policy") == ["sandbox;"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "text/html is served as a sandboxed attachment", %{conn: conn} do
      conn = fetch_as_member(conn, "page.html", "text/html")
      assert conn.status == 200
      assert_sandboxed_download(conn)
    end

    test "text/html range request (206) is a sandboxed attachment", %{conn: conn} do
      conn = fetch_as_member(conn, "page.html", "text/html", [{"range", "bytes=0-3"}])
      assert conn.status == 206
      assert_sandboxed_download(conn)
    end

    test "image/svg+xml is served as a sandboxed attachment", %{conn: conn} do
      conn = fetch_as_member(conn, "pic.svg", "image/svg+xml")
      assert conn.status == 200
      assert_sandboxed_download(conn)
    end

    test "text/plain is served as a sandboxed attachment (deliberate change)", %{conn: conn} do
      conn = fetch_as_member(conn, "notes.txt", "text/plain")
      assert conn.status == 200
      assert_sandboxed_download(conn)
    end

    test "mixed-case, param-bearing TEXT/HTML is a sandboxed attachment", %{conn: conn} do
      conn = fetch_as_member(conn, "page.html", "TEXT/HTML; charset=utf-8")
      assert conn.status == 200
      assert_sandboxed_download(conn)
    end

    for {filename, content_type} <- [
          {"pic.png", "image/png"},
          {"doc.pdf", "application/pdf"},
          {"clip.mp4", "video/mp4"},
          {"song.mp3", "audio/mpeg"}
        ] do
      test "#{content_type} stays inline with no CSP", %{conn: conn} do
        conn = fetch_as_member(conn, unquote(filename), unquote(content_type))
        assert conn.status == 200
        [disposition] = get_resp_header(conn, "content-disposition")
        assert String.starts_with?(disposition, "inline;")
        assert get_resp_header(conn, "content-security-policy") == []
        assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      end
    end
  end
end
