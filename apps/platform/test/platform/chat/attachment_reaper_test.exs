defmodule Platform.Chat.AttachmentReaperTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.AttachmentReaper
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Repo

  setup do
    root = Path.join(System.tmp_dir!(), "platform-attachment-reaper-test-#{Ecto.UUID.generate()}")

    prev = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev, do: Application.put_env(:platform, :chat_attachments_root, prev)
    end)

    {:ok, root: root}
  end

  defp create_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Reaper Test",
        slug: "reaper-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp insert_pending(space, expires_at, bytes \\ <<"pending">>) do
    key = "chat/reaper/#{Ecto.UUID.generate()}.bin"
    {:ok, _} = LocalDisk.persist(key, {:binary, bytes})

    {:ok, row} =
      Chat.create_attachment(%{
        space_id: space.id,
        filename: "p.bin",
        content_type: "application/octet-stream",
        byte_size: byte_size(bytes),
        storage_key: key,
        state: "pending",
        upload_expires_at: expires_at
      })

    {row, key}
  end

  describe "sweep/0" do
    test "deletes expired pending rows and their storage files" do
      space = create_space()
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      {expired_row, expired_key} = insert_pending(space, past)

      assert File.exists?(LocalDisk.path_for(expired_key))

      count = AttachmentReaper.sweep()

      assert count >= 1
      assert Repo.get(Attachment, expired_row.id) == nil
      refute File.exists?(LocalDisk.path_for(expired_key))
    end

    test "preserves pending rows whose expiry is in the future" do
      space = create_space()
      future = DateTime.utc_now() |> DateTime.add(300, :second)

      {fresh_row, fresh_key} = insert_pending(space, future)

      _ = AttachmentReaper.sweep()

      assert %Attachment{state: "pending"} = Repo.get(Attachment, fresh_row.id)
      assert File.exists?(LocalDisk.path_for(fresh_key))
    end

    test "ignores rows already in :ready state regardless of upload_expires_at" do
      space = create_space()
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      key = "chat/reaper/ready-#{Ecto.UUID.generate()}.bin"
      {:ok, _} = LocalDisk.persist(key, {:binary, <<"ready">>})

      {:ok, row} =
        Chat.create_attachment(%{
          space_id: space.id,
          filename: "r.bin",
          content_type: "application/octet-stream",
          byte_size: 5,
          storage_key: key,
          state: "ready",
          upload_expires_at: past
        })

      _ = AttachmentReaper.sweep()

      assert %Attachment{state: "ready"} = Repo.get(Attachment, row.id)
      assert File.exists?(LocalDisk.path_for(key))
    end
  end
end
