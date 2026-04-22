defmodule Platform.Chat.AttachmentStorageTest do
  use ExUnit.Case, async: false

  alias Platform.Chat.AttachmentStorage

  setup do
    root =
      Path.join(System.tmp_dir!(), "platform-attachment-storage-test-#{Ecto.UUID.generate()}")

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

  describe "persist_upload/3" do
    test "writes the file and returns metadata", %{root: root} do
      src = Path.join(System.tmp_dir!(), "att-src-#{Ecto.UUID.generate()}.txt")
      File.write!(src, "hello")

      try do
        assert {:ok, meta} = AttachmentStorage.persist_upload(src, "hello.txt", "text/plain")
        assert meta.filename == "hello.txt"
        assert meta.content_type == "text/plain"
        assert meta.byte_size == 5
        assert is_binary(meta.storage_key)
        assert File.exists?(Path.join(root, meta.storage_key))
      after
        File.rm(src)
      end
    end

    test "infers content_type from extension when not provided", %{root: _root} do
      src = Path.join(System.tmp_dir!(), "att-src-#{Ecto.UUID.generate()}.png")
      File.write!(src, <<137, 80, 78, 71>>)

      try do
        assert {:ok, meta} = AttachmentStorage.persist_upload(src, "shot.png", nil)
        assert meta.content_type == "image/png"
      after
        File.rm(src)
      end
    end

    test "re-infers content_type when client reports application/octet-stream with a known image extension",
         %{root: _root} do
      src = Path.join(System.tmp_dir!(), "att-src-#{Ecto.UUID.generate()}.png")
      File.write!(src, <<137, 80, 78, 71>>)

      try do
        assert {:ok, meta} =
                 AttachmentStorage.persist_upload(src, "photo.png", "application/octet-stream")

        assert meta.content_type == "image/png"
      after
        File.rm(src)
      end
    end

    test "keeps application/octet-stream when the extension is unknown", %{root: _root} do
      src = Path.join(System.tmp_dir!(), "att-src-#{Ecto.UUID.generate()}.bin")
      File.write!(src, "opaque-bytes")

      try do
        assert {:ok, meta} =
                 AttachmentStorage.persist_upload(
                   src,
                   "mystery.unknownext",
                   "application/octet-stream"
                 )

        assert meta.content_type == "application/octet-stream"
      after
        File.rm(src)
      end
    end

    test "does NOT re-label .html to text/html (XSS allowlist — stored XSS prevention)",
         %{root: _root} do
      src = Path.join(System.tmp_dir!(), "att-src-#{Ecto.UUID.generate()}.html")
      File.write!(src, "<script>alert(1)</script>")

      try do
        assert {:ok, meta} =
                 AttachmentStorage.persist_upload(src, "evil.html", "application/octet-stream")

        assert meta.content_type == "application/octet-stream"
      after
        File.rm(src)
      end
    end

    test "does NOT re-label .svg to image/svg+xml (SVG can embed scripts)", %{root: _root} do
      src = Path.join(System.tmp_dir!(), "att-src-#{Ecto.UUID.generate()}.svg")
      File.write!(src, "<svg></svg>")

      try do
        assert {:ok, meta} =
                 AttachmentStorage.persist_upload(src, "icon.svg", "application/octet-stream")

        assert meta.content_type == "application/octet-stream"
      after
        File.rm(src)
      end
    end

    test "re-infers content_type for nil client_type with image extension", %{root: _root} do
      src = Path.join(System.tmp_dir!(), "att-src-#{Ecto.UUID.generate()}.webp")
      File.write!(src, "webp-bytes")

      try do
        assert {:ok, meta} = AttachmentStorage.persist_upload(src, "pic.webp", nil)
        assert meta.content_type == "image/webp"
      after
        File.rm(src)
      end
    end

    test "falls back to application/octet-stream for nil client_type with non-allowlisted extension",
         %{root: _root} do
      src = Path.join(System.tmp_dir!(), "att-src-#{Ecto.UUID.generate()}.html")
      File.write!(src, "<b>safe-as-download</b>")

      try do
        assert {:ok, meta} = AttachmentStorage.persist_upload(src, "note.html", nil)
        assert meta.content_type == "application/octet-stream"
      after
        File.rm(src)
      end
    end
  end

  describe "ensure_writable!/0" do
    test "returns :ok when the storage root is writable" do
      assert AttachmentStorage.ensure_writable!() == :ok
    end

    test "raises with guidance when the storage root cannot be written" do
      # Use /dev/null as the would-be parent — it's a character device on
      # every Unix-like system (macOS dev + Linux CI container), so
      # File.mkdir_p of a child path always fails with :enotdir regardless
      # of whether the process runs as root (which bypasses chmod checks).
      bad_root = "/dev/null/platform-bootcheck-test-#{Ecto.UUID.generate()}"
      Application.put_env(:platform, :chat_attachments_root, bad_root)

      assert_raise RuntimeError, ~r/attachment storage is not writable/i, fn ->
        AttachmentStorage.ensure_writable!()
      end
    end
  end

  describe "storage_root/0" do
    test "returns the configured path", %{root: root} do
      assert AttachmentStorage.storage_root() == root
    end
  end
end
