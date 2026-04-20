defmodule Platform.Chat.Attachments.ToolHandlersTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Attachment
  alias Platform.Chat.Attachments.ToolHandlers
  alias Platform.Chat.AttachmentStorage.Adapter.LocalDisk
  alias Platform.Repo

  setup do
    root =
      Path.join(System.tmp_dir!(), "platform-attachment-handlers-test-#{Ecto.UUID.generate()}")

    prev = Application.get_env(:platform, :chat_attachments_root)
    Application.put_env(:platform, :chat_attachments_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      if prev, do: Application.put_env(:platform, :chat_attachments_root, prev)
    end)

    {:ok, root: root}
  end

  defp setup_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Attachment Test",
        slug: "att-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Tester",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant}
  end

  defp context(participant, extra \\ %{}) do
    Map.merge(%{agent_participant_id: participant.id}, extra)
  end

  describe "upload_inline/2" do
    test "happy path: writes, returns url + content_hash, dedup=false" do
      %{space: space, participant: participant} = setup_space()

      payload = :crypto.strong_rand_bytes(2048)

      args = %{
        "space_id" => space.id,
        "filename" => "hello.bin",
        "content_type" => "application/octet-stream",
        "data_base64" => Base.encode64(payload)
      }

      assert {:ok, result} = ToolHandlers.upload_inline(args, context(participant))
      assert is_binary(result.id)
      assert result.url == "/chat/attachments/#{result.id}"
      assert result.byte_size == byte_size(payload)
      assert result.content_hash == :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
      assert result.content_type == "application/octet-stream"
      assert result.deduplicated == false
    end

    test "over-cap returns structured :too_large error with suggested alternative" do
      %{space: space, participant: participant} = setup_space()

      prev = Application.get_env(:platform, :inline_upload_max_bytes)
      Application.put_env(:platform, :inline_upload_max_bytes, 100)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:platform, :inline_upload_max_bytes, prev),
          else: Application.delete_env(:platform, :inline_upload_max_bytes)
      end)

      args = %{
        "space_id" => space.id,
        "filename" => "big.bin",
        "content_type" => "application/octet-stream",
        "data_base64" => Base.encode64(:crypto.strong_rand_bytes(200))
      }

      assert {:error, payload} = ToolHandlers.upload_inline(args, context(participant))
      assert payload.limit == 100
      assert payload.use == "attachment.upload_start"
      assert payload.error =~ "exceeds limit"
    end

    test "dedup: two identical uploads yield the same canonical id" do
      %{space: space, participant: participant} = setup_space()

      payload = :crypto.strong_rand_bytes(512)

      base_args = %{
        "space_id" => space.id,
        "filename" => "dupe.bin",
        "content_type" => "application/octet-stream",
        "data_base64" => Base.encode64(payload)
      }

      assert {:ok, first} = ToolHandlers.upload_inline(base_args, context(participant))
      assert first.deduplicated == false

      assert {:ok, second} = ToolHandlers.upload_inline(base_args, context(participant))
      assert second.id == first.id
      assert second.deduplicated == true
    end

    test "rejects when participant is not a member" do
      %{space: space} = setup_space()

      args = %{
        "space_id" => space.id,
        "filename" => "nope.bin",
        "content_type" => "application/octet-stream",
        "data_base64" => Base.encode64("x")
      }

      assert {:error, payload} =
               ToolHandlers.upload_inline(args, %{agent_id: Ecto.UUID.generate()})

      assert payload.recoverable == false
      assert payload.error =~ "not a participant"
    end
  end

  describe "upload_start/2" do
    test "reserves a pending row and returns a signable upload_url" do
      %{space: space, participant: participant} = setup_space()

      args = %{
        "space_id" => space.id,
        "filename" => "big.pdf",
        "content_type" => "application/pdf",
        "byte_size" => 1_000_000
      }

      assert {:ok, result} = ToolHandlers.upload_start(args, context(participant))
      assert is_binary(result.id)
      assert String.starts_with?(result.upload_url, "/chat/attachments/upload/")
      assert result.url == "/chat/attachments/#{result.id}"
      assert %DateTime{} = result.expires_at
      assert result.max_bytes > 0

      row = Repo.get!(Attachment, result.id)
      assert row.state == "pending"
      assert row.space_id == space.id
      assert row.byte_size == 1_000_000
    end

    test "rejects when declared byte_size exceeds upload_max_bytes" do
      %{space: space, participant: participant} = setup_space()

      prev = Application.get_env(:platform, :upload_max_bytes)
      Application.put_env(:platform, :upload_max_bytes, 1_000)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:platform, :upload_max_bytes, prev),
          else: Application.delete_env(:platform, :upload_max_bytes)
      end)

      args = %{
        "space_id" => space.id,
        "filename" => "huge.bin",
        "content_type" => "application/octet-stream",
        "byte_size" => 5_000
      }

      assert {:error, payload} = ToolHandlers.upload_start(args, context(participant))
      assert payload.recoverable == true
      assert payload.limit == 1_000
    end
  end

  describe "finalize_pending/2" do
    test "cross-path dedup: inline, then a start+finish of same content dedups on finish" do
      %{space: space, participant: participant} = setup_space()

      payload = :crypto.strong_rand_bytes(512)
      hash = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)

      # Inline path creates a canonical ready row
      assert {:ok, first} =
               ToolHandlers.upload_inline(
                 %{
                   "space_id" => space.id,
                   "filename" => "content.bin",
                   "content_type" => "application/octet-stream",
                   "data_base64" => Base.encode64(payload)
                 },
                 context(participant)
               )

      # upload_start reserves a pending row for the same content
      assert {:ok, started} =
               ToolHandlers.upload_start(
                 %{
                   "space_id" => space.id,
                   "filename" => "content.bin",
                   "content_type" => "application/octet-stream",
                   "byte_size" => byte_size(payload)
                 },
                 context(participant)
               )

      # Write the bytes to the adapter at the pending row's storage_key, then finalize
      pending = Repo.get!(Attachment, started.id)
      {:ok, _} = LocalDisk.persist(pending.storage_key, {:binary, payload})

      assert {:ok, finalized} =
               ToolHandlers.finalize_pending(started.id, %{
                 byte_size: byte_size(payload),
                 content_hash: hash
               })

      assert finalized.id == first.id
      assert finalized.deduplicated == true

      # Pending row was deleted in favor of the canonical
      assert Repo.get(Attachment, started.id) == nil
    end
  end
end
