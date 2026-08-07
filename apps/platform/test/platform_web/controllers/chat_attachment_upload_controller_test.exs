defmodule PlatformWeb.ChatAttachmentUploadControllerTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentPresigner
  alias Platform.Repo

  setup do
    root = Path.join(System.tmp_dir!(), "platform-upload-controller-test-#{Ecto.UUID.generate()}")
    prev = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev, do: Application.put_env(:platform, :chat_attachments_root, prev)
    end)

    :ok
  end

  defp reserve_pending(byte_size \\ 1_000_000, content_type \\ "application/octet-stream") do
    {:ok, space} =
      Chat.create_space(%{
        name: "Upload Test",
        slug: "ul-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    key = "chat/upload/#{Ecto.UUID.generate()}.bin"

    {:ok, attachment} =
      Chat.create_attachment(%{
        space_id: space.id,
        filename: "upload.bin",
        content_type: content_type,
        byte_size: byte_size,
        storage_key: key,
        state: "pending",
        upload_expires_at: DateTime.utc_now() |> DateTime.add(900, :second)
      })

    expires = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.to_unix()

    token =
      AttachmentPresigner.sign(%{
        key: key,
        max_bytes: byte_size,
        expires_at: expires
      })

    %{space: space, attachment: attachment, token: token, key: key}
  end

  defp post_body(conn, token, content_type, body) do
    conn
    |> Plug.Conn.put_req_header("content-type", content_type)
    |> Plug.Conn.put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> post(~p"/chat/attachments/upload/#{token}", body)
  end

  # Regression, task 019fcfcf stage 5. `Plug.Parsers` in the endpoint claims
  # any body it recognises, and `application/json` is one of them — so a JSON
  # upload arrived at this controller with an already-drained body and
  # finalized at ZERO bytes while a PNG of the same shape stored fine. Nothing
  # errored: the row went `ready`, the canvas rendered a link, and the file
  # behind it was empty. The router has claimed a parser skip-list since ADR
  # 0039; `PlatformWeb.Plugs.RawBodyPaths` is that skip-list.
  #
  # Verified to FAIL before the fix (byte_size 0, stored file empty), which is
  # how the defect was found in the first place.
  test "an application/json body is stored whole, not eaten by the body parsers", %{conn: conn} do
    body = Jason.encode!(%{"type" => "scene", "elements" => Enum.to_list(1..200)})

    %{attachment: attachment, token: token, key: key} =
      reserve_pending(byte_size(body), "application/json")

    conn = post_body(conn, token, "application/json", body)

    assert response = json_response(conn, 200)
    assert response["id"] == attachment.id

    stored = Repo.get!(Attachment, attachment.id)
    assert stored.state == "ready"
    # Equality, not "> 0": a truncated body is the same class of bug as an
    # empty one and reads as success just as easily.
    assert stored.byte_size == byte_size(body)

    root = Application.get_env(:platform, :chat_attachments_root)
    assert File.read!(Path.join(root, key)) == body
  end

  test "happy path: writes the body, finalizes the row to :ready, returns id + url", %{conn: conn} do
    %{attachment: attachment, token: token} = reserve_pending(2_048)
    body = :crypto.strong_rand_bytes(2_048)

    conn = post_body(conn, token, "application/octet-stream", body)

    assert response = json_response(conn, 200)
    assert response["id"] == attachment.id
    assert response["url"] == "/chat/attachments/#{attachment.id}"
    assert response["byte_size"] == 2_048
    assert is_binary(response["content_hash"])
    assert response["deduplicated"] == false

    row = Repo.get!(Attachment, attachment.id)
    assert row.state == "ready"
    assert row.content_hash == response["content_hash"]
  end

  test "401 when the HMAC token is tampered", %{conn: conn} do
    %{token: token} = reserve_pending()

    tampered = token <> "x"
    body = <<"garbage">>

    conn = post_body(conn, tampered, "application/octet-stream", body)

    assert response(conn, 401) =~ "invalid upload token"
  end

  test "413 when the body exceeds max_bytes", %{conn: conn} do
    %{token: token} = reserve_pending(100)
    body = :crypto.strong_rand_bytes(500)

    conn = post_body(conn, token, "application/octet-stream", body)

    assert response(conn, 413) =~ "max_bytes"
  end

  test "400 when the Content-Type doesn't match the reserved row", %{conn: conn} do
    %{token: token} = reserve_pending(1_024, "image/png")
    body = :crypto.strong_rand_bytes(1_024)

    conn = post_body(conn, token, "application/pdf", body)

    assert response(conn, 400) =~ "content-type"
  end

  test "409 if the row is already finalized", %{conn: conn} do
    %{attachment: attachment, token: token} = reserve_pending(512)

    # Transition the row to :ready out of band
    attachment
    |> Attachment.changeset(%{state: "ready", content_hash: String.duplicate("a", 64)})
    |> Repo.update!()

    body = :crypto.strong_rand_bytes(512)
    conn = post_body(conn, token, "application/octet-stream", body)

    assert response(conn, 409) =~ "already finalized"
  end
end
