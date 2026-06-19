defmodule Platform.Files.StorageTest do
  use ExUnit.Case, async: true

  alias Platform.Files.Storage

  describe "build_key/3" do
    test "puts files/ under the project id" do
      project_id = "00000000-0000-0000-0000-000000000001"
      file_id = "11111111-1111-1111-1111-111111111111"

      assert Storage.build_key(project_id, file_id, "Q1 plan.pdf") ==
               "files/#{project_id}/#{file_id}/Q1-plan.pdf"
    end

    test "sanitizes unsafe filename characters" do
      key = Storage.build_key("p", "f", "../../etc/passwd")
      assert key == "files/p/f/passwd"
    end

    test "falls back to 'attachment' when filename is empty after sanitization" do
      key = Storage.build_key("p", "f", "///")
      assert key == "files/p/f/attachment"
    end
  end

  describe "put/3 + get/1 round-trip" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "platform-files-storage-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)

      previous = Application.get_env(:platform, :chat_attachments_root)
      Application.put_env(:platform, :chat_attachments_root, root)

      on_exit(fn ->
        File.rm_rf!(root)

        if previous,
          do: Application.put_env(:platform, :chat_attachments_root, previous),
          else: Application.delete_env(:platform, :chat_attachments_root)
      end)

      :ok
    end

    test "persists a binary and returns size + sha256 hash" do
      project_id = "00000000-0000-0000-0000-000000000abc"

      assert {:ok, %{storage_key: key, content_hash: hash, byte_size: size}} =
               Storage.put({:binary, "hello world"}, project_id, filename: "greeting.txt")

      assert size == byte_size("hello world")

      assert hash ==
               :crypto.hash(:sha256, "hello world")
               |> Base.encode16(case: :lower)

      assert String.starts_with?(key, "files/#{project_id}/")
      assert String.ends_with?(key, "greeting.txt")
    end

    test "round-trips through get/1" do
      project_id = "00000000-0000-0000-0000-000000000def"

      {:ok, %{storage_key: key}} =
        Storage.put({:binary, "round trip payload"}, project_id, filename: "rt.bin")

      assert {:ok, stream} = Storage.get(key)
      assert Enum.into(stream, <<>>) == "round trip payload"
    end

    test "delete/1 removes the underlying file" do
      project_id = "00000000-0000-0000-0000-000000000fff"

      {:ok, %{storage_key: key}} =
        Storage.put({:binary, "soon to be gone"}, project_id, filename: "tmp.bin")

      assert :ok = Storage.delete(key)
      assert {:error, :enoent} = Storage.get(key)
    end

    test "passthrough_key/1 returns the input unchanged" do
      assert Storage.passthrough_key("chat/2026/06/19/uuid-foo.png") ==
               "chat/2026/06/19/uuid-foo.png"
    end
  end
end
