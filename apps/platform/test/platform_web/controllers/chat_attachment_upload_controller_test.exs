defmodule PlatformWeb.ChatAttachmentUploadControllerTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentPresigner
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Files
  alias Platform.Files.File, as: PFile
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

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

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "fabrikam") do
      nil ->
        {:ok, org} =
          %Tenancy.Org{}
          |> Tenancy.Org.changeset(%{slug: "fabrikam", name: "Fabrikam", parent_org_id: nil})
          |> Repo.insert()

        org

      org ->
        org
    end
  end

  # Mirrors `file_add_presigned/4` in ToolSurface (task 01a091b7): a
  # `platform_files` reservation with no content_hash, keyed under the
  # `files/` namespace, and a token from the SAME signer the LocalDisk
  # adapter uses (see "presigned_url token verifies" below).
  defp reserve_pending_file(byte_size, content_type \\ "text/plain") do
    fabrikam = ensure_root_org()
    n = System.unique_integer([:positive])

    {:ok, org} =
      %Tenancy.Org{}
      |> Tenancy.Org.changeset(%{
        slug: "ul-files-#{n}",
        name: "Upload Files",
        parent_org_id: fabrikam.id
      })
      |> Repo.insert()

    {:ok, project} = Tasks.create_project(%{name: "Upload-#{n}", org_id: org.id})
    key = Files.Storage.build_key(project.id, Ecto.UUID.generate(), "upload.txt")

    {:ok, file} =
      Files.create_file(%{
        project_id: project.id,
        org_id: org.id,
        name: "upload.txt",
        original_filename: "upload.txt",
        content_type: content_type,
        byte_size: byte_size,
        storage_key: key,
        ingest_status: "pending"
      })

    assert is_nil(file.content_hash)

    %{project: project, file: file, token: sign_key(key, byte_size), key: key}
  end

  defp sign_key(key, max_bytes, expires_in \\ 900) do
    expires = DateTime.utc_now() |> DateTime.add(expires_in, :second) |> DateTime.to_unix()
    AttachmentPresigner.sign(%{key: key, max_bytes: max_bytes, expires_at: expires})
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

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

  # ---------------------------------------------------------------------
  # platform_files reservations (task 01a091b7 stage 2). `file_add`'s
  # presigned branch reserves a platform_files row and hands back a URL
  # under THIS controller, which until now only knew chat_attachments —
  # so the byte POST 404'd. Case (1) is the red-on-main proof.
  # ---------------------------------------------------------------------

  test "Files.Storage.presigned_url mints a token this controller's verifier accepts" do
    key = Files.Storage.build_key(Ecto.UUID.generate(), Ecto.UUID.generate(), "a.txt")
    assert {:ok, %{url: "/chat/attachments/upload/" <> token}} = Files.Storage.presigned_url(key)
    assert {:ok, %{key: ^key}} = AttachmentPresigner.verify(token)
  end

  test "(1) Files happy path: bytes land at the key, row finalized, state ready", %{conn: conn} do
    body = "presigned file body #{System.unique_integer([:positive])}\n"

    %{file: file, token: token, key: key, project: project} =
      reserve_pending_file(byte_size(body))

    conn = post_body(conn, token, "text/plain", body)

    assert response = json_response(conn, 200)
    assert response["id"] == file.id
    assert response["project_id"] == project.id
    assert response["state"] == "ready"
    assert response["deduplicated"] == false
    assert response["byte_size"] == byte_size(body)
    assert response["content_hash"] == sha256(body)
    assert response["content_type"] == "text/plain"
    refute Map.has_key?(response, "url")

    row = Repo.get!(PFile, file.id)
    assert row.byte_size == byte_size(body)
    assert row.content_hash == sha256(body)
    assert File.read!(LocalDisk.path_for(key)) == body
  end

  test "(2) 410 on an expired Files token; the row stays pending with no hash", %{conn: conn} do
    %{file: file, key: key} = reserve_pending_file(64)
    token = sign_key(key, 64, -10)

    conn = post_body(conn, token, "text/plain", "late")

    assert json_response(conn, 410) == %{"error" => "upload token expired"}
    row = Repo.get!(PFile, file.id)
    assert row.ingest_status == "pending"
    assert is_nil(row.content_hash)
    refute File.exists?(LocalDisk.path_for(key))
  end

  test "(3) 413 when a Files body exceeds max_bytes; nothing written", %{conn: conn} do
    %{key: key} = reserve_pending_file(10)
    body = String.duplicate("x", 11)

    conn = post_body(conn, sign_key(key, 10), "text/plain", body)

    assert json_response(conn, 413) == %{"error" => "body exceeds max_bytes"}
    refute File.exists?(LocalDisk.path_for(key))
  end

  test "(4) 400 when the Content-Type doesn't match the Files row", %{conn: conn} do
    %{token: token} = reserve_pending_file(16, "text/plain")

    conn = post_body(conn, token, "application/pdf", "not a pdf")

    assert response(conn, 400) =~ "content-type"
  end

  test "(5) second POST on a finalized Files reservation is 409", %{conn: conn} do
    body = "once"
    %{file: file, token: token} = reserve_pending_file(byte_size(body))

    assert json_response(post_body(conn, token, "text/plain", body), 200)["state"] == "ready"

    # Ingest is async: the row may still be `ingest_status: "pending"`
    # here. That must not reopen the reservation — the hash is set.
    assert Repo.get!(PFile, file.id).content_hash == sha256(body)

    conn = post_body(build_conn(), token, "text/plain", body)
    assert response(conn, 409) =~ "already finalized"
  end

  test "(6) 401 on a tampered Files token", %{conn: conn} do
    %{token: token} = reserve_pending_file(16)

    conn = post_body(conn, token <> "x", "text/plain", "garbage")

    assert response(conn, 401) =~ "invalid upload token"
  end

  test "(7) a files/ key with no row in either table is 404", %{conn: conn} do
    key = Files.Storage.build_key(Ecto.UUID.generate(), Ecto.UUID.generate(), "ghost.txt")

    conn = post_body(conn, sign_key(key, 16), "text/plain", "ghost")

    assert json_response(conn, 404) == %{"error" => "no pending reservation for key"}
    refute File.exists?(LocalDisk.path_for(key))
  end

  test "(8) a soft-deleted pending Files reservation is 404", %{conn: conn} do
    %{file: file, token: token, key: key} = reserve_pending_file(16)

    {:ok, _} =
      file |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()

    conn = post_body(conn, token, "text/plain", "too late")

    assert json_response(conn, 404) == %{"error" => "no pending reservation for key"}
    refute File.exists?(LocalDisk.path_for(key))
  end

  test "(9) aliasing guard: a ready chat row wins over a pending Files row on the same key",
       %{conn: conn} do
    # Stage 6 backfill (`Files.Storage.passthrough_key/1`) can point a
    # platform_files row at a chat_attachments key. The chat row is the
    # authority for that key in every state: ready must still 409, never
    # fall through and re-finalize the Files row.
    %{attachment: attachment, token: token, key: key} = reserve_pending(512)

    attachment
    |> Attachment.changeset(%{state: "ready", content_hash: String.duplicate("a", 64)})
    |> Repo.update!()

    %{project: project} = reserve_pending_file(512)

    {:ok, aliased} =
      Files.create_file(%{
        project_id: project.id,
        org_id: project.org_id,
        name: "aliased.bin",
        original_filename: "aliased.bin",
        content_type: "application/octet-stream",
        byte_size: 512,
        storage_key: Files.Storage.passthrough_key(key),
        ingest_status: "pending"
      })

    conn = post_body(conn, token, "application/octet-stream", :crypto.strong_rand_bytes(512))

    assert response(conn, 409) =~ "already finalized"
    assert Repo.get!(PFile, aliased.id).ingest_status == "pending"
    assert is_nil(Repo.get!(PFile, aliased.id).content_hash)
  end
end
