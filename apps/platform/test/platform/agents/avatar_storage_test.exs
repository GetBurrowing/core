defmodule Platform.Agents.AvatarStorageTest do
  @moduledoc """
  Tests for `Platform.Agents.AvatarStorage` (task `01a00122` stage 1).

  ## Coverage

    * `put/3` writes under the `agent-avatars/` namespace and NOT under
      `chat/` — the namespace separation is the point of the module.
    * `delete/1` removes the blob.
    * The content-type allowlist rejects SVG, HTML and PDF at consume time.
    * The stored key's extension is normalized from the resolved content
      type, so `content_type_for_key/1` can round-trip it. No column
      records an avatar's content type, so this is the only record of it.
  """

  use ExUnit.Case, async: true

  alias Platform.Agents.AvatarStorage
  alias Platform.Chat.AttachmentStorage

  # Point the attachment store at a writable per-test scratch dir. The
  # default in `test.exs` is `/data/platform/chat_uploads`, which exists in
  # the dev container but not in CI / local sandboxes.
  setup do
    prev = Application.get_env(:platform, :chat_attachments_root)

    scratch =
      Path.join(System.tmp_dir!(), "avatar_storage_test_#{System.unique_integer([:positive])}")

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

    {:ok, agent_id: Ecto.UUID.generate()}
  end

  # A one-pixel PNG, so the bytes we assert on are a real image rather than
  # an arbitrary blob that happens to be named .png.
  defp png_bytes do
    Base.decode64!(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    )
  end

  describe "put/3 key namespace" do
    test "writes under agent-avatars/ and never under chat/", %{agent_id: agent_id} do
      {:ok, result} =
        AvatarStorage.put({:binary, png_bytes()}, agent_id,
          filename: "face.png",
          content_type: "image/png"
        )

      # Reads the key that was actually STORED, not a recomputed one — this
      # is the assertion the @namespace anti-vacuity mutation must break.
      assert String.starts_with?(result.storage_key, "agent-avatars/")
      refute String.starts_with?(result.storage_key, "chat/")
      assert result.storage_key =~ agent_id

      # And the bytes really landed at that key on disk.
      assert File.exists?(AttachmentStorage.path_for(result.storage_key))
    end

    test "two uploads for the same agent get distinct keys", %{agent_id: agent_id} do
      opts = [filename: "face.png", content_type: "image/png"]

      {:ok, first} = AvatarStorage.put({:binary, png_bytes()}, agent_id, opts)
      {:ok, second} = AvatarStorage.put({:binary, png_bytes()}, agent_id, opts)

      # Replacing an avatar must not overwrite the old blob in place: the
      # serving URL does not change when the bytes do, so an in-place
      # overwrite would leave caches serving the previous face.
      refute first.storage_key == second.storage_key
      assert File.exists?(AttachmentStorage.path_for(first.storage_key))
      assert File.exists?(AttachmentStorage.path_for(second.storage_key))
    end

    test "build_key/2 places the file in the agent-avatars namespace" do
      key = AvatarStorage.build_key("agent-123", "face.png")
      assert key == "agent-avatars/agent-123/face.png"
    end

    test "put/3 reports the real byte size and content hash", %{agent_id: agent_id} do
      bytes = png_bytes()

      {:ok, result} =
        AvatarStorage.put({:binary, bytes}, agent_id,
          filename: "face.png",
          content_type: "image/png"
        )

      assert result.byte_size == byte_size(bytes)
      assert result.content_hash == :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      assert result.content_type == "image/png"
    end
  end

  describe "get/1 and delete/1" do
    test "get/1 streams the stored bytes back", %{agent_id: agent_id} do
      bytes = png_bytes()

      {:ok, result} =
        AvatarStorage.put({:binary, bytes}, agent_id,
          filename: "face.png",
          content_type: "image/png"
        )

      {:ok, stream} = AvatarStorage.get(result.storage_key)
      assert stream |> Enum.join() == bytes
    end

    test "delete/1 removes the blob", %{agent_id: agent_id} do
      {:ok, result} =
        AvatarStorage.put({:binary, png_bytes()}, agent_id,
          filename: "face.png",
          content_type: "image/png"
        )

      path = AttachmentStorage.path_for(result.storage_key)
      assert File.exists?(path)

      assert :ok == AvatarStorage.delete(result.storage_key)
      refute File.exists?(path)
      assert {:error, :enoent} == AvatarStorage.get(result.storage_key)
    end

    test "delete/1 on an already-absent key is still :ok", %{agent_id: agent_id} do
      assert :ok == AvatarStorage.delete(AvatarStorage.build_key(agent_id, "never-written.png"))
    end
  end

  describe "content-type allowlist" do
    test "accepts every allowed image type", %{agent_id: agent_id} do
      for content_type <- AvatarStorage.allowed_content_types() do
        assert {:ok, result} =
                 AvatarStorage.put({:binary, png_bytes()}, agent_id,
                   filename: "face",
                   content_type: content_type
                 ),
               "expected #{content_type} to be accepted"

        assert result.content_type == content_type
      end
    end

    test "rejects SVG — SVG can embed <script>", %{agent_id: agent_id} do
      assert {:error, {:unsupported_content_type, "image/svg+xml"}} =
               AvatarStorage.put({:binary, "<svg/>"}, agent_id,
                 filename: "face.svg",
                 content_type: "image/svg+xml"
               )
    end

    test "rejects text/html — it executes as HTML", %{agent_id: agent_id} do
      assert {:error, {:unsupported_content_type, "text/html"}} =
               AvatarStorage.put({:binary, "<script>alert(1)</script>"}, agent_id,
                 filename: "face.html",
                 content_type: "text/html"
               )
    end

    test "rejects application/pdf — allowed for attachments, not for a face", %{
      agent_id: agent_id
    } do
      assert {:error, {:unsupported_content_type, "application/pdf"}} =
               AvatarStorage.put({:binary, "%PDF-"}, agent_id,
                 filename: "face.pdf",
                 content_type: "application/pdf"
               )
    end

    test "a rejected upload writes nothing to disk", %{agent_id: agent_id} do
      root = AttachmentStorage.path_for("agent-avatars")

      assert {:error, _} =
               AvatarStorage.put({:binary, "<svg/>"}, agent_id,
                 filename: "face.svg",
                 content_type: "image/svg+xml"
               )

      refute File.exists?(Path.join(root, agent_id))
    end

    test "a generic octet-stream label falls back to the filename extension", %{
      agent_id: agent_id
    } do
      # iOS Safari labels photos application/octet-stream on upload.
      assert {:ok, result} =
               AvatarStorage.put({:binary, png_bytes()}, agent_id,
                 filename: "IMG_0001.png",
                 content_type: "application/octet-stream"
               )

      assert result.content_type == "image/png"
    end

    test "octet-stream with a non-image extension is still rejected", %{agent_id: agent_id} do
      assert {:error, {:unsupported_content_type, "application/octet-stream"}} =
               AvatarStorage.put({:binary, "nope"}, agent_id,
                 filename: "evil.html",
                 content_type: "application/octet-stream"
               )
    end

    test "a content type with parameters is normalized before the check", %{agent_id: agent_id} do
      assert {:ok, result} =
               AvatarStorage.put({:binary, png_bytes()}, agent_id,
                 filename: "face.png",
                 content_type: "image/png; charset=binary"
               )

      assert result.content_type == "image/png"
    end
  end

  describe "content_type_for_key/1" do
    test "round-trips the content type put/3 resolved", %{agent_id: agent_id} do
      for content_type <- AvatarStorage.allowed_content_types() do
        {:ok, result} =
          AvatarStorage.put({:binary, png_bytes()}, agent_id,
            filename: "face",
            content_type: content_type
          )

        assert AvatarStorage.content_type_for_key(result.storage_key) == content_type
      end
    end

    test "the extension comes from the resolved type, not the client filename", %{
      agent_id: agent_id
    } do
      # A client claiming image/png while naming the file .gif must not be
      # able to steer the served Content-Type via the filename.
      {:ok, result} =
        AvatarStorage.put({:binary, png_bytes()}, agent_id,
          filename: "spoof.gif",
          content_type: "image/png"
        )

      assert AvatarStorage.content_type_for_key(result.storage_key) == "image/png"
    end

    test "an unrecognized key degrades to octet-stream rather than guessing" do
      assert AvatarStorage.content_type_for_key("agent-avatars/a/face.html") ==
               "application/octet-stream"

      assert AvatarStorage.content_type_for_key("agent-avatars/a/face.svg") ==
               "application/octet-stream"

      assert AvatarStorage.content_type_for_key("agent-avatars/a/noextension") ==
               "application/octet-stream"
    end
  end
end
