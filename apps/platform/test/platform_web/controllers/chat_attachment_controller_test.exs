defmodule PlatformWeb.ChatAttachmentControllerTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias Platform.Repo

  setup do
    previous_root = Application.get_env(:platform, :chat_attachments_root)

    upload_root =
      Path.join(
        System.tmp_dir!(),
        "platform_test_chat_uploads_#{System.unique_integer([:positive])}"
      )

    Application.put_env(:platform, :chat_attachments_root, upload_root)

    on_exit(fn ->
      File.rm_rf(upload_root)
      Application.put_env(:platform, :chat_attachments_root, previous_root)
    end)

    :ok
  end

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "chat-attachment-#{System.unique_integer([:positive])}@example.com",
        name: "Chat Attachment User",
        oidc_sub: "oidc-chat-attachment-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_attachment_fixture do
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
      Path.join(
        System.tmp_dir!(),
        "chat-attachment-source-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(source_path, "hello attachment")

    {:ok, stored} = AttachmentStorage.persist_upload(source_path, "hello.txt", "text/plain")
    File.rm(source_path)

    {:ok, attachment} = Chat.create_attachment(Map.put(stored, :message_id, message.id))

    %{space: space, participant: participant, message: message, attachment: attachment}
  end

  test "GET /chat/attachments/:id redirects unauthenticated users to login", %{conn: conn} do
    %{attachment: attachment} = create_attachment_fixture()

    conn = get(conn, ~p"/chat/attachments/#{attachment.id}")
    assert redirected_to(conn) == "/auth/login"
  end

  test "GET /chat/attachments/:id downloads the attachment for authenticated users", %{conn: conn} do
    %{attachment: attachment} = create_attachment_fixture()
    conn = authenticated_conn(conn)

    conn = get(conn, ~p"/chat/attachments/#{attachment.id}")

    assert response(conn, 200) == "hello attachment"
    assert get_resp_header(conn, "content-type") == ["text/plain"]

    [content_disposition] = get_resp_header(conn, "content-disposition")
    assert content_disposition =~ "inline"
    assert content_disposition =~ "hello.txt"
  end

  test "GET /chat/attachments/:id returns 404 when parent message is deleted", %{conn: conn} do
    %{attachment: attachment, message: message} = create_attachment_fixture()
    conn = authenticated_conn(conn)

    assert {:ok, _} = Chat.delete_message(message)

    conn = get(conn, ~p"/chat/attachments/#{attachment.id}")
    assert response(conn, 404) =~ "Not found"
  end
end
