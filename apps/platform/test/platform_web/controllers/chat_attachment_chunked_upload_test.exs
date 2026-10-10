defmodule PlatformWeb.ChatAttachmentChunkedUploadTest do
  @moduledoc """
  Resumable chunked uploads on the presigned token URL (task 01a120be,
  stage 1): tus-style HEAD + PATCH with `Upload-Offset`, layered on the same
  `chat_attachments` reservation, token, controller and reaper as the
  single-POST `create/2` path (whose own tests stay in
  `chat_attachment_upload_controller_test.exs`, unchanged).
  """
  use PlatformWeb.ConnCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentPresigner
  alias Platform.Chat.AttachmentReaper
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Chat.AttachmentStorage.Root
  alias Platform.Repo

  setup do
    root = Path.join(System.tmp_dir!(), "platform-chunked-upload-test-#{Ecto.UUID.generate()}")
    Root.put_override(root)

    prev =
      for k <- [:upload_chunk_bytes, :chat_max_upload_bytes, :pending_ttl_seconds],
          do: {k, Application.fetch_env(:platform, k)}

    on_exit(fn ->
      File.rm_rf(root)

      Enum.each(prev, fn
        {k, {:ok, v}} -> Application.put_env(:platform, k, v)
        {k, :error} -> Application.delete_env(:platform, k)
      end)
    end)

    Application.put_env(:platform, :upload_chunk_bytes, 100)
    :ok
  end

  defp reserve(byte_size, opts \\ []) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Chunked Upload Test",
        slug: "chunk-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    key = "chat/upload/#{Ecto.UUID.generate()}.bin"

    {:ok, attachment} =
      Chat.create_attachment(%{
        space_id: space.id,
        filename: "big.bin",
        content_type: "application/octet-stream",
        byte_size: byte_size,
        storage_key: key,
        state: "pending",
        upload_expires_at:
          DateTime.utc_now() |> DateTime.add(Keyword.get(opts, :row_ttl, 900), :second)
      })

    expires =
      DateTime.utc_now()
      |> DateTime.add(Keyword.get(opts, :token_ttl, 900), :second)
      |> DateTime.to_unix()

    token =
      AttachmentPresigner.sign(%{
        key: key,
        max_bytes: Keyword.get(opts, :max_bytes, 1_000_000_000),
        expires_at: expires
      })

    %{attachment: attachment, token: token, key: key}
  end

  defp head_offset(token) do
    conn = head(build_conn(), "/chat/attachments/upload/#{token}")
    {conn.status, header(conn, "upload-offset"), header(conn, "upload-length")}
  end

  defp patch_chunk(token, offset, body, content_type \\ "application/offset+octet-stream") do
    build_conn()
    |> put_req_header("content-type", content_type)
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> put_req_header("upload-offset", Integer.to_string(offset))
    |> patch("/chat/attachments/upload/#{token}", body)
  end

  defp header(conn, name) do
    case get_resp_header(conn, name) do
      [v | _] -> v
      [] -> nil
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  test "three chunks: HEAD reports each offset, last chunk finalizes with the whole-file sha256" do
    body = :crypto.strong_rand_bytes(250)
    <<c1::binary-100, c2::binary-100, c3::binary-50>> = body
    %{token: token, attachment: att, key: key} = reserve(250)

    assert {200, "0", "250"} = head_offset(token)

    conn = patch_chunk(token, 0, c1)
    assert conn.status == 204
    assert header(conn, "upload-offset") == "100"
    assert {200, "100", "250"} = head_offset(token)

    assert patch_chunk(token, 100, c2).status == 204
    assert {200, "200", "250"} = head_offset(token)

    conn = patch_chunk(token, 200, c3)
    assert conn.status == 200
    assert header(conn, "upload-offset") == "250"
    payload = Jason.decode!(conn.resp_body)
    assert payload["id"] == att.id
    assert payload["byte_size"] == 250
    assert payload["content_hash"] == sha256(body)
    assert payload["deduplicated"] == false

    row = Repo.get!(Attachment, att.id)
    assert row.state == "ready"
    assert row.content_hash == sha256(body)
    assert File.read!(LocalDisk.path_for(key)) == body
    refute File.exists?(LocalDisk.part_path_for(key))
  end

  test "wrong Upload-Offset is 409 carrying the real offset, and stores nothing" do
    %{token: token, key: key} = reserve(250)
    assert patch_chunk(token, 0, :binary.copy("a", 100)).status == 204

    # Re-sending a received ALIGNED chunk is an idempotent 204 that rewrites
    # nothing (it was 409 before out-of-order chunks; see the
    # "out-of-order aligned chunks" tests below).
    conn = patch_chunk(token, 0, :binary.copy("b", 100))
    assert conn.status == 204
    assert header(conn, "upload-offset") == "100"

    # Behind, not on a chunk boundary.
    conn = patch_chunk(token, 50, :binary.copy("b", 50))
    assert conn.status == 409
    assert header(conn, "upload-offset") == "100"

    conn = patch_chunk(token, 150, :binary.copy("c", 50))
    assert conn.status == 409
    assert header(conn, "upload-offset") == "100"

    assert File.read!(LocalDisk.part_path_for(key)) == :binary.copy("a", 100)
  end

  test "missing Upload-Offset header is 400" do
    %{token: token} = reserve(10)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/offset+octet-stream")
      |> patch("/chat/attachments/upload/#{token}", "0123456789")

    assert conn.status == 400
  end

  test "resume after an aborted chunk continues from the stored offset" do
    body = :crypto.strong_rand_bytes(200)
    <<c1::binary-100, half::binary-40, rest::binary-60>> = body
    %{token: token, key: key} = reserve(200)

    assert patch_chunk(token, 0, c1).status == 204
    # The second chunk's connection dropped after 40 bytes reached disk.
    assert {:ok, 140} = LocalDisk.append_chunk(key, 100, {:binary, half})

    assert {200, "140", "200"} = head_offset(token)
    # A client that re-sends the whole lost chunk from 100 is told the truth.
    assert %{status: 409} = conn = patch_chunk(token, 100, <<half::binary, rest::binary>>)
    assert header(conn, "upload-offset") == "140"

    conn = patch_chunk(token, 140, rest)
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["content_hash"] == sha256(body)
  end

  test "a chunk over chunk_bytes is 413 and stores nothing" do
    %{token: token, key: key} = reserve(500)
    conn = patch_chunk(token, 0, :binary.copy("x", 101))
    assert conn.status == 413
    refute File.exists?(LocalDisk.part_path_for(key))
    assert {200, "0", _} = head_offset(token)
  end

  test "a chunk running past the reserved length is 413" do
    %{token: token} = reserve(50)
    assert patch_chunk(token, 0, :binary.copy("x", 60)).status == 413
  end

  test "a reservation over CHAT_MAX_UPLOAD_BYTES is refused before any byte moves" do
    Application.put_env(:platform, :chat_max_upload_bytes, 150)
    %{token: token, key: key} = reserve(151)

    assert patch_chunk(token, 0, :binary.copy("x", 100)).status == 413
    assert {413, _, _} = head_offset(token)
    refute File.exists?(LocalDisk.part_path_for(key))

    %{token: ok_token} = reserve(150)
    assert patch_chunk(ok_token, 0, :binary.copy("x", 100)).status == 204
  end

  test "each accepted chunk slides upload_expires_at forward by pending_ttl_seconds" do
    Application.put_env(:platform, :pending_ttl_seconds, 3600)
    %{token: token, attachment: att} = reserve(250, row_ttl: 30)

    before = Repo.get!(Attachment, att.id).upload_expires_at
    assert patch_chunk(token, 0, :binary.copy("x", 100)).status == 204
    after_first = Repo.get!(Attachment, att.id).upload_expires_at

    assert DateTime.diff(after_first, before, :second) > 3000
    assert DateTime.diff(after_first, DateTime.utc_now(), :second) in 3590..3600

    # A refused chunk does not slide it.
    assert patch_chunk(token, 50, :binary.copy("y", 100)).status == 409
    assert Repo.get!(Attachment, att.id).upload_expires_at == after_first
  end

  test "the token's minted expiry does not cut off a live upload; the row's expiry does" do
    %{token: token} = reserve(200, token_ttl: -60)
    assert patch_chunk(token, 0, :binary.copy("x", 100)).status == 204

    %{token: dead} = reserve(200, row_ttl: -60)
    assert patch_chunk(dead, 0, :binary.copy("x", 100)).status == 410
    assert {410, _, _} = head_offset(dead)
  end

  test "PATCH bypasses Plug.Parsers: a JSON chunk is stored byte-for-byte" do
    json = ~s({"type":"excalidraw","elements":[]})
    %{token: token, key: key} = reserve(byte_size(json))

    conn = patch_chunk(token, 0, json, "application/json")
    assert conn.status == 200
    assert File.read!(LocalDisk.path_for(key)) == json
  end

  test "a finalized row answers 409 on PATCH" do
    %{token: token} = reserve(10)
    assert patch_chunk(token, 0, "0123456789").status == 200
    assert patch_chunk(token, 10, "").status == 409
  end

  test "reaper removes an abandoned upload's .part with its row" do
    %{token: token, attachment: att, key: key} = reserve(250)
    assert patch_chunk(token, 0, :binary.copy("x", 100)).status == 204
    assert File.exists?(LocalDisk.part_path_for(key))

    att
    |> Ecto.Changeset.change(upload_expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()

    assert AttachmentReaper.sweep() >= 1
    refute File.exists?(LocalDisk.part_path_for(key))
    assert Repo.get(Attachment, att.id) == nil
  end

  test "an invalid token is 401 on both verbs" do
    assert {401, _, _} = head_offset("not-a-token")
    assert patch_chunk("not-a-token", 0, "x").status == 401
  end

  # ── Out-of-order aligned chunks (task 01a120be remediation) ────────────
  #
  # chunk_bytes is 100 here (setup), so aligned offsets are 0, 100, 200, ...

  test "out-of-order aligned chunks: last first, then the rest; one 200 with the whole-file hash" do
    body = :crypto.strong_rand_bytes(250)
    <<c1::binary-100, c2::binary-100, c3::binary-50>> = body
    %{token: token, attachment: att, key: key} = reserve(250)

    # The short last chunk first: accepted, but the contiguous offset is 0.
    conn = patch_chunk(token, 200, c3)
    assert conn.status == 204
    assert header(conn, "upload-offset") == "0"
    assert header(conn, "upload-length") == "250"

    conn = patch_chunk(token, 100, c2)
    assert conn.status == 204
    assert header(conn, "upload-offset") == "0"

    # Filling the gap at 0 completes coverage: this PATCH finalizes.
    conn = patch_chunk(token, 0, c1)
    assert conn.status == 200
    assert header(conn, "upload-offset") == "250"
    payload = Jason.decode!(conn.resp_body)
    assert payload["id"] == att.id
    assert payload["content_hash"] == sha256(body)

    assert Repo.get!(Attachment, att.id).state == "ready"
    assert File.read!(LocalDisk.path_for(key)) == body
    refute File.exists?(LocalDisk.part_path_for(key))
    refute File.exists?(LocalDisk.ranges_path_for(key))

    # Anything after the finalize is the finalized-row 409.
    assert patch_chunk(token, 200, c3).status == 409
  end

  test "HEAD reports the contiguous prefix while there is a gap" do
    %{token: token} = reserve(350)

    assert patch_chunk(token, 200, :binary.copy("c", 100)).status == 204
    assert {200, "0", "350"} = head_offset(token)

    assert patch_chunk(token, 0, :binary.copy("a", 100)).status == 204
    assert {200, "100", "350"} = head_offset(token)

    # Filling [100, 200) joins the recorded [200, 300): contiguous jumps to 300.
    conn = patch_chunk(token, 100, :binary.copy("b", 100))
    assert conn.status == 204
    assert header(conn, "upload-offset") == "300"
    assert {200, "300", "350"} = head_offset(token)
  end

  test "a non-aligned ahead offset is 409 carrying the contiguous offset, and records nothing" do
    %{token: token, key: key} = reserve(350)
    assert patch_chunk(token, 0, :binary.copy("a", 100)).status == 204

    conn = patch_chunk(token, 150, :binary.copy("x", 100))
    assert conn.status == 409
    assert header(conn, "upload-offset") == "100"
    assert {:ok, [{0, 100}]} = LocalDisk.upload_ranges(key)
  end

  test "an aligned ahead chunk of the wrong length is 409" do
    %{token: token, key: key} = reserve(350)

    # Not the full chunk_bytes...
    conn = patch_chunk(token, 100, :binary.copy("x", 60))
    assert conn.status == 409
    assert header(conn, "upload-offset") == "0"

    # ...and the last chunk must be exactly total - offset.
    assert patch_chunk(token, 300, :binary.copy("x", 40)).status == 409
    assert {:ok, []} = LocalDisk.upload_ranges(key)
  end

  test "a duplicate aligned chunk is 204 and rewrites nothing" do
    %{token: token, key: key} = reserve(350)
    assert patch_chunk(token, 200, :binary.copy("c", 100)).status == 204

    conn = patch_chunk(token, 200, :binary.copy("Z", 100))
    assert conn.status == 204
    assert header(conn, "upload-offset") == "0"

    assert binary_part(File.read!(LocalDisk.part_path_for(key)), 200, 100) ==
             :binary.copy("c", 100)

    assert {:ok, [{200, 300}]} = LocalDisk.upload_ranges(key)
  end

  test "concurrent PATCHes of different aligned chunks finalize exactly once" do
    body = :crypto.strong_rand_bytes(1_050)
    %{token: token, attachment: att, key: key} = reserve(1_050)

    chunks =
      for i <- 0..10 do
        offset = i * 100
        {offset, binary_part(body, offset, min(100, 1_050 - offset))}
      end

    statuses =
      chunks
      |> Enum.shuffle()
      |> Enum.map(fn {offset, chunk} ->
        Task.async(fn -> patch_chunk(token, offset, chunk) end)
      end)
      |> Task.await_many(30_000)
      |> Enum.map(& &1.status)

    assert Enum.count(statuses, &(&1 == 200)) == 1
    assert Enum.count(statuses, &(&1 == 204)) == 10

    row = Repo.get!(Attachment, att.id)
    assert row.state == "ready"
    assert row.content_hash == sha256(body)
    assert File.read!(LocalDisk.path_for(key)) == body
  end

  test "ranges survive in the sidecar: a fresh read sees what an earlier request recorded" do
    %{token: token, key: key} = reserve(350)
    assert patch_chunk(token, 100, :binary.copy("b", 100)).status == 204
    assert patch_chunk(token, 300, :binary.copy("d", 50)).status == 204

    assert File.read!(LocalDisk.ranges_path_for(key)) == "100-200\n300-350\n"
    assert {200, "0", "350"} = head_offset(token)
  end

  test "a held finalize claim makes a completing PATCH answer 204; a stale claim is re-taken" do
    body = :crypto.strong_rand_bytes(150)
    %{token: token, attachment: att, key: key} = reserve(150)
    {:ok, 150} = LocalDisk.append_chunk(key, 0, {:binary, body})

    # Another PATCH claimed the finalize a moment ago and is still running.
    claim = fn at ->
      Repo.get!(Attachment, att.id)
      |> Ecto.Changeset.change(
        metadata: %{"chunked_finalize_claimed_at" => DateTime.to_iso8601(at)}
      )
      |> Repo.update!()
    end

    claim.(DateTime.utc_now())

    conn = patch_chunk(token, 150, "")
    assert conn.status == 204
    assert header(conn, "upload-offset") == "150"
    assert Repo.get!(Attachment, att.id).state == "pending"

    # The claimant died: after the stale window the completing PATCH finalizes.
    claim.(DateTime.add(DateTime.utc_now(), -301, :second))

    conn = patch_chunk(token, 150, "")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["content_hash"] == sha256(body)
    assert Repo.get!(Attachment, att.id).state == "ready"
  end
end
