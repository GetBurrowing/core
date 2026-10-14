defmodule PlatformWeb.AppApiUploadTest do
  @moduledoc """
  Task 01a120be stage 2: the app API's server-reported upload limits and the
  user large-file reservation whose last chunk posts the message.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Platform.ExternalUserFixtures

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Chat.AttachmentStorage.Root
  alias Platform.Chat.Attachments.ToolHandlers
  alias Platform.Chat.Message
  alias Platform.Mobile
  alias Platform.Repo

  setup %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "platform-app-upload-test-#{Ecto.UUID.generate()}")
    Root.put_override(root)

    prev =
      for k <- [:chat_max_upload_bytes, :upload_chunk_bytes],
          do: {k, Application.fetch_env(:platform, k)}

    on_exit(fn ->
      File.rm_rf(root)

      Enum.each(prev, fn
        {k, {:ok, v}} -> Application.put_env(:platform, k, v)
        {k, :error} -> Application.delete_env(:platform, k)
      end)
    end)

    Application.put_env(:platform, :upload_chunk_bytes, 100)

    user = create_user!()
    space = channel!()
    add_user!(space.id, user.id)
    %{conn: conn, user: user, space: space, token: token!(user)}
  end

  defp token!(user) do
    verifier = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {:ok, code} = Mobile.issue_exchange_code(user, challenge)

    {:ok, %{token: token}} =
      Mobile.exchange_code(code, verifier, %{
        app_install_id: "install-#{System.unique_integer([:positive])}"
      })

    token
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp reserve(conn, token, space_id, params) do
    conn
    |> bearer(token)
    |> post("/api/app/spaces/#{space_id}/uploads", params)
  end

  defp file_params(byte_size, extra \\ %{}) do
    Map.merge(
      %{
        "filename" => "clip.mov",
        "content_type" => "application/octet-stream",
        "byte_size" => byte_size
      },
      extra
    )
  end

  defp patch_chunks(upload_url, body) do
    for {chunk, i} <- body |> chunk_every(100) |> Enum.with_index(), reduce: nil do
      _ ->
        build_conn()
        |> put_req_header("content-type", "application/offset+octet-stream")
        |> put_req_header("upload-offset", Integer.to_string(i * 100))
        |> patch(upload_url, chunk)
    end
  end

  defp chunk_every(<<>>, _n), do: []
  defp chunk_every(bin, n) when byte_size(bin) <= n, do: [bin]

  defp chunk_every(bin, n),
    do: [binary_part(bin, 0, n) | chunk_every(binary_part(bin, n, byte_size(bin) - n), n)]

  defp messages_in(space_id),
    do: Repo.all(from(m in Message, where: m.space_id == ^space_id, order_by: m.inserted_at))

  describe "GET /api/app/upload_config" do
    test "reports the configured limit, label and chunk size, not a constant", %{
      conn: conn,
      token: token
    } do
      Application.put_env(:platform, :chat_max_upload_bytes, 1_000_000_000)
      body = conn |> bearer(token) |> get("/api/app/upload_config") |> json_response(200)

      assert body == %{
               "max_upload_bytes" => 1_000_000_000,
               "max_upload_label" => "1 GB",
               "chunk_bytes" => 100,
               "multipart_max_bytes" => 8_000_000
             }

      # A binary limit reads in decimal like everything else (task 01a120be).
      Application.put_env(:platform, :chat_max_upload_bytes, 2_147_483_648)
      body = build_conn() |> bearer(token) |> get("/api/app/upload_config") |> json_response(200)
      assert body["max_upload_bytes"] == 2_147_483_648
      assert body["max_upload_label"] == "2.1 GB"
    end
  end

  describe "POST /api/app/spaces/:space_id/uploads" do
    test "over the limit is 413 with the label, and reserves nothing", %{
      conn: conn,
      token: token,
      space: space
    } do
      Application.put_env(:platform, :chat_max_upload_bytes, 1_000_000_000)
      conn = reserve(conn, token, space.id, file_params(1_000_000_001))

      assert json_response(conn, 413) == %{
               "error" => "file_too_large",
               "max_upload_bytes" => 1_000_000_000,
               "max_upload_label" => "1 GB"
             }

      assert Repo.aggregate(from(a in Attachment, where: a.space_id == ^space.id), :count) == 0
    end

    test "403 for a non-member", %{conn: conn, token: token} do
      other = channel!()
      conn = reserve(conn, token, other.id, file_params(500))
      assert json_response(conn, 403) == %{"error" => "forbidden"}
      assert Repo.aggregate(from(a in Attachment, where: a.space_id == ^other.id), :count) == 0
    end

    test "403 for an archived space", %{conn: conn, token: token, space: space} do
      {:ok, _} = Chat.archive_space(space)
      conn = reserve(conn, token, space.id, file_params(500))
      assert json_response(conn, 403) == %{"error" => "forbidden"}
    end

    test "422 for a missing or bad byte_size", %{conn: conn, token: token, space: space} do
      conn = reserve(conn, token, space.id, file_params("lots"))
      assert json_response(conn, 422) == %{"error" => "invalid_file"}
    end

    test "full chunked upload posts exactly one message with the attachment linked and broadcast",
         %{conn: conn, token: token, space: space, user: user} do
      body = :crypto.strong_rand_bytes(250)
      Chat.PubSub.subscribe(space.id)

      reservation =
        conn
        |> reserve(token, space.id, file_params(250, %{"text" => "the clip"}))
        |> json_response(201)

      assert %{"id" => id, "upload_url" => url, "chunk_bytes" => 100, "offset" => 0} =
               reservation

      row = Repo.get!(Attachment, id)
      assert row.state == "pending"
      assert row.uploaded_by_user_id == user.id
      # An iOS .mov labelled octet-stream is typed as video.
      assert row.content_type == "video/quicktime"
      assert messages_in(space.id) == []

      final = patch_chunks(url, body)

      assert %{"message_id" => message_id, "id" => ^id, "deduplicated" => false} =
               json_response(final, 200)

      assert [%Message{id: ^message_id, content: "the clip"}] = messages_in(space.id)
      assert_receive {:new_message, %Message{id: ^message_id}}

      row = Repo.get!(Attachment, id)
      assert row.state == "ready"
      assert row.message_id == message_id
      assert row.content_hash == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert File.read!(LocalDisk.path_for(row.storage_key)) == body
    end

    test "out-of-order aligned chunks (last first) post exactly one message from the one 200",
         %{conn: conn, token: token, space: space} do
      body = :crypto.strong_rand_bytes(250)

      %{"id" => id, "upload_url" => url} =
        conn
        |> reserve(token, space.id, file_params(250, %{"text" => "backwards"}))
        |> json_response(201)

      responses =
        for offset <- [200, 100, 0] do
          chunk = binary_part(body, offset, min(100, 250 - offset))

          build_conn()
          |> put_req_header("content-type", "application/offset+octet-stream")
          |> put_req_header("content-length", Integer.to_string(byte_size(chunk)))
          |> put_req_header("upload-offset", Integer.to_string(offset))
          |> patch(url, chunk)
        end

      assert Enum.map(responses, & &1.status) == [204, 204, 200]
      assert %{"message_id" => message_id, "id" => ^id} = json_response(List.last(responses), 200)
      assert [%Message{id: ^message_id, content: "backwards"}] = messages_in(space.id)
      assert Repo.get!(Attachment, id).message_id == message_id
    end

    test "concurrent aligned PATCHes on one token post exactly one message",
         %{conn: conn, token: token, space: space} do
      body = :crypto.strong_rand_bytes(1_050)

      %{"id" => id, "upload_url" => url} =
        conn |> reserve(token, space.id, file_params(1_050)) |> json_response(201)

      responses =
        for(i <- 0..10, do: i * 100)
        |> Enum.shuffle()
        |> Enum.map(fn offset ->
          chunk = binary_part(body, offset, min(100, 1_050 - offset))

          Task.async(fn ->
            build_conn()
            |> put_req_header("content-type", "application/offset+octet-stream")
            |> put_req_header("content-length", Integer.to_string(byte_size(chunk)))
            |> put_req_header("upload-offset", Integer.to_string(offset))
            |> patch(url, chunk)
          end)
        end)
        |> Task.await_many(30_000)

      assert [final] = Enum.filter(responses, &(&1.status == 200))
      assert Enum.count(responses, &(&1.status == 204)) == 10
      assert %{"message_id" => message_id} = json_response(final, 200)
      assert [%Message{id: ^message_id}] = messages_in(space.id)
      assert Repo.get!(Attachment, id).message_id == message_id
    end

    test "two users uploading identical bytes get two messages (dedup skipped for user rows)",
         %{conn: conn, token: token, space: space} do
      other = create_user!()
      add_user!(space.id, other.id)
      other_token = token!(other)
      body = :crypto.strong_rand_bytes(150)

      %{"upload_url" => url1} =
        conn |> reserve(token, space.id, file_params(150)) |> json_response(201)

      %{"upload_url" => url2} =
        build_conn() |> reserve(other_token, space.id, file_params(150)) |> json_response(201)

      %{"message_id" => m1, "id" => a1} = url1 |> patch_chunks(body) |> json_response(200)
      %{"message_id" => m2, "id" => a2} = url2 |> patch_chunks(body) |> json_response(200)

      assert m1 != m2
      assert a1 != a2
      assert length(messages_in(space.id)) == 2
      assert Repo.get!(Attachment, a1).message_id == m1
      assert Repo.get!(Attachment, a2).message_id == m2
    end

    test "agent-style reservations (no pending_message) still dedup", %{space: space} do
      body = :crypto.strong_rand_bytes(64)
      hash = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

      {:ok, ready} =
        Chat.create_attachment(%{
          space_id: space.id,
          filename: "a.bin",
          content_type: "application/octet-stream",
          byte_size: 64,
          storage_key: "chat/dedup/#{Ecto.UUID.generate()}.bin",
          content_hash: hash,
          state: "ready"
        })

      {:ok, pending} =
        Chat.create_attachment(%{
          space_id: space.id,
          filename: "b.bin",
          content_type: "application/octet-stream",
          byte_size: 64,
          storage_key: "chat/dedup/#{Ecto.UUID.generate()}.bin",
          state: "pending"
        })

      assert {:ok, %{id: canonical, deduplicated: true} = result} =
               ToolHandlers.finalize_pending(pending.id, %{byte_size: 64, content_hash: hash})

      assert canonical == ready.id
      refute Map.has_key?(result, :message_id)
    end
  end
end
