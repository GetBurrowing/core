defmodule Platform.Chat.AttachmentStorage.Adapter.LocalDiskTest do
  use ExUnit.Case, async: false

  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk

  setup do
    root = Path.join(System.tmp_dir!(), "platform-local-disk-test-#{Ecto.UUID.generate()}")

    prev = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:platform, :chat_attachments_root, prev)
      else
        Application.delete_env(:platform, :chat_attachments_root)
      end
    end)

    {:ok, root: root}
  end

  describe "persist/2" do
    test "writes the file and returns byte_size + content_hash from a :path source" do
      src = Path.join(System.tmp_dir!(), "src-#{Ecto.UUID.generate()}.txt")
      File.write!(src, "hello world")
      key = "chat/2026/04/19/example.txt"

      try do
        assert {:ok, %{byte_size: 11, content_hash: hash}} =
                 LocalDisk.persist(key, {:path, src})

        # sha256("hello world") — stable value makes the test a regression gate
        # against accidental algorithm or encoding drift.
        assert hash ==
                 "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"

        assert File.exists?(LocalDisk.path_for(key))
      after
        File.rm(src)
      end
    end

    test "accepts a :binary source" do
      key = "chat/2026/04/19/from-binary.bin"

      assert {:ok, %{byte_size: 5, content_hash: hash}} =
               LocalDisk.persist(key, {:binary, <<1, 2, 3, 4, 5>>})

      assert is_binary(hash) and byte_size(hash) == 64
      assert File.read!(LocalDisk.path_for(key)) == <<1, 2, 3, 4, 5>>
    end
  end

  describe "read_stream/1" do
    test "returns an enumerable of file chunks" do
      key = "chat/2026/04/19/streamable.txt"
      {:ok, _} = LocalDisk.persist(key, {:binary, "ABCDEFGH"})

      assert {:ok, stream} = LocalDisk.read_stream(key)
      assert Enum.join(stream) == "ABCDEFGH"
    end

    test "returns {:error, :enoent} for missing keys" do
      assert LocalDisk.read_stream("chat/missing/nope.bin") == {:error, :enoent}
    end
  end

  describe "delete/1" do
    test "removes a previously-written file" do
      key = "chat/2026/04/19/delete-me.txt"
      {:ok, _} = LocalDisk.persist(key, {:binary, "bye"})
      assert File.exists?(LocalDisk.path_for(key))

      assert LocalDisk.delete(key) == :ok
      refute File.exists?(LocalDisk.path_for(key))
    end

    test "is idempotent — deleting a missing key returns :ok" do
      assert LocalDisk.delete("chat/never-existed/nope.bin") == :ok
    end
  end

  describe "presign_upload/3" do
    test "returns a signable URL with the configured ttl" do
      key = "chat/2026/04/19/pending.bin"

      assert {:ok, %{url: url, expires_at: expires_at}} =
               LocalDisk.presign_upload(key, 1_000_000, 900)

      assert String.starts_with?(url, "/chat/attachments/upload/")
      assert DateTime.diff(expires_at, DateTime.utc_now(), :second) in 895..905

      # Token round-trips through verify with the signing key from config/test.exs.
      "/chat/attachments/upload/" <> token = url
      signing_key = Application.fetch_env!(:platform, :attachment_signing_key)

      assert {:ok, %{key: ^key, max_bytes: 1_000_000, expires_at: _}} =
               Plug.Crypto.verify(signing_key, "attachment_upload", token, max_age: 900)
    end
  end
end
