defmodule Platform.Chat.AttachmentStorage.Adapter.LocalDiskChunkedTest do
  @moduledoc "LocalDisk append_chunk / upload_offset / complete_upload (task 01a120be)."
  use ExUnit.Case, async: true

  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Chat.AttachmentStorage.Root

  setup do
    root = Path.join(System.tmp_dir!(), "platform-local-disk-chunked-#{Ecto.UUID.generate()}")
    Root.put_override(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, key: "chat/chunked/#{Ecto.UUID.generate()}.bin"}
  end

  test "appends at the stored offset and refuses any other", %{key: key} do
    assert {:ok, 0} = LocalDisk.upload_offset(key)
    assert {:ok, 3} = LocalDisk.append_chunk(key, 0, {:binary, "abc"})
    assert {:ok, 3} = LocalDisk.upload_offset(key)
    assert {:error, {:offset_mismatch, 3}} = LocalDisk.append_chunk(key, 0, {:binary, "zzz"})
    assert {:error, {:offset_mismatch, 3}} = LocalDisk.append_chunk(key, 4, {:binary, "zzz"})
    assert {:ok, 6} = LocalDisk.append_chunk(key, 3, {:binary, "def"})
    assert File.read!(LocalDisk.part_path_for(key)) == "abcdef"
  end

  test "complete_upload hashes the .part and renames it to the key's path", %{key: key} do
    {:ok, _} = LocalDisk.append_chunk(key, 0, {:binary, "hello "})
    {:ok, _} = LocalDisk.append_chunk(key, 6, {:binary, "world"})

    assert {:ok, %{byte_size: 11, content_hash: hash}} = LocalDisk.complete_upload(key)
    assert hash == "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
    assert File.read!(LocalDisk.path_for(key)) == "hello world"
    refute File.exists?(LocalDisk.part_path_for(key))

    # Re-completing after the rename (finalize did not run) is idempotent.
    assert {:ok, 11} = LocalDisk.upload_offset(key)
    assert {:ok, %{byte_size: 11, content_hash: ^hash}} = LocalDisk.complete_upload(key)
  end

  test "delete/1 removes a stray .part", %{key: key} do
    {:ok, _} = LocalDisk.append_chunk(key, 0, {:binary, "abc"})
    assert :ok = LocalDisk.delete(key)
    refute File.exists?(LocalDisk.part_path_for(key))
  end

  test "write_at is positioned and records nothing; record_range merges and reports the contiguous prefix",
       %{key: key} do
    assert :ok = LocalDisk.write_at(key, 6, {:binary, "world"})
    # Written past a hole, not recorded: the offset is still 0.
    assert {:ok, 0} = LocalDisk.upload_offset(key)
    assert {:ok, []} = LocalDisk.upload_ranges(key)

    assert {:ok, 0} = LocalDisk.record_range(key, 6, 11)
    assert :ok = LocalDisk.write_at(key, 0, {:binary, "hello "})
    assert {:ok, 11} = LocalDisk.record_range(key, 0, 6)
    assert {:ok, [{0, 11}]} = LocalDisk.upload_ranges(key)
    assert {:ok, 11} = LocalDisk.upload_offset(key)

    assert {:ok, %{byte_size: 11}} = LocalDisk.complete_upload(key)
    assert File.read!(LocalDisk.path_for(key)) == "hello world"
    refute File.exists?(LocalDisk.ranges_path_for(key))
  end

  test "record_range keeps disjoint ranges sorted and merges overlaps", %{key: key} do
    {:ok, 0} = LocalDisk.record_range(key, 200, 300)
    {:ok, 0} = LocalDisk.record_range(key, 100, 150)
    {:ok, 0} = LocalDisk.record_range(key, 140, 200)
    assert {:ok, [{100, 300}]} = LocalDisk.upload_ranges(key)
    assert {:ok, 300} = LocalDisk.record_range(key, 0, 100)
  end

  test "delete/1 and discard_part/1 remove the ranges sidecar too", %{key: key} do
    {:ok, _} = LocalDisk.append_chunk(key, 0, {:binary, "abc"})
    assert File.exists?(LocalDisk.ranges_path_for(key))
    assert :ok = LocalDisk.discard_part(key)
    refute File.exists?(LocalDisk.ranges_path_for(key))
    refute File.exists?(LocalDisk.part_path_for(key))
  end
end
