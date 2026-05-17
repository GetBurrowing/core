defmodule Platform.Chat.MessageVersionsTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.MessageVersions
  alias Platform.Repo

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space! do
    slug = "msgver-space-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, space} = Chat.create_space(%{name: "MsgVer Test", slug: slug, kind: "channel"})
    space
  end

  defp create_participant!(space_id, display_name \\ "Alice") do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    p
  end

  # Bypasses Chat.post_message/2 (which now auto-records v1 inside its
  # transaction) so these unit tests can exercise record_v1!/1 against a
  # fresh message that has no version rows yet.
  defp create_message!(space_id, participant_id, opts \\ []) do
    content = Keyword.get(opts, :content, "original content")
    display_name = Keyword.get(opts, :author_display_name, "Alice")

    %Message{}
    |> Message.changeset(%{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      author_display_name: display_name
    })
    |> Repo.insert!()
  end

  # ── record_v1!/1 ─────────────────────────────────────────────────────────────

  describe "record_v1!/1" do
    test "inserts version 1 with the original content" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id, content: "hello world")

      v1 = MessageVersions.record_v1!(msg)

      assert v1.message_id == msg.id
      assert v1.version_number == 1
      assert v1.content == "hello world"
      assert v1.edited_at == msg.inserted_at
      assert v1.edited_by_participant_id == msg.participant_id
    end

    test "falls back to '(unknown)' when author_display_name is nil" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)
      msg = %{msg | author_display_name: nil}

      v1 = MessageVersions.record_v1!(msg)
      assert v1.edited_by_display_name == "(unknown)"
    end

    test "treats nil content as empty string" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)
      msg = %{msg | content: nil}

      v1 = MessageVersions.record_v1!(msg)
      assert v1.content == ""
    end
  end

  # ── record_edit/2 ────────────────────────────────────────────────────────────

  describe "record_edit/2" do
    test "appends version 2 after v1, auto-incrementing version_number" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id, content: "v1 body")
      MessageVersions.record_v1!(msg)

      {:ok, v2} =
        MessageVersions.record_edit(msg.id, %{
          content: "v2 body",
          edited_by_participant_id: p.id,
          edited_by_display_name: "Alice"
        })

      assert v2.version_number == 2
      assert v2.content == "v2 body"
    end

    test "subsequent edits keep incrementing" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)
      MessageVersions.record_v1!(msg)

      {:ok, _v2} =
        MessageVersions.record_edit(msg.id, %{
          content: "v2",
          edited_by_participant_id: p.id,
          edited_by_display_name: "Alice"
        })

      {:ok, v3} =
        MessageVersions.record_edit(msg.id, %{
          content: "v3",
          edited_by_participant_id: p.id,
          edited_by_display_name: "Alice"
        })

      assert v3.version_number == 3
    end

    test "defaults edited_at to now when not provided" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)
      MessageVersions.record_v1!(msg)

      before_call = DateTime.utc_now()

      {:ok, v2} =
        MessageVersions.record_edit(msg.id, %{
          content: "v2",
          edited_by_participant_id: p.id,
          edited_by_display_name: "Alice"
        })

      after_call = DateTime.utc_now()

      assert DateTime.compare(v2.edited_at, before_call) in [:eq, :gt]
      assert DateTime.compare(v2.edited_at, after_call) in [:eq, :lt]
    end

    test "returns {:error, changeset} when required fields are missing" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)
      MessageVersions.record_v1!(msg)

      {:error, changeset} = MessageVersions.record_edit(msg.id, %{content: "incomplete"})
      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :edited_by_display_name)
    end
  end

  # ── list_versions/1 ──────────────────────────────────────────────────────────

  describe "list_versions/1" do
    test "returns versions newest-first" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)
      MessageVersions.record_v1!(msg)

      {:ok, _v2} =
        MessageVersions.record_edit(msg.id, %{
          content: "v2",
          edited_by_participant_id: p.id,
          edited_by_display_name: "Alice"
        })

      {:ok, _v3} =
        MessageVersions.record_edit(msg.id, %{
          content: "v3",
          edited_by_participant_id: p.id,
          edited_by_display_name: "Alice"
        })

      versions = MessageVersions.list_versions(msg.id)

      assert length(versions) == 3
      assert Enum.map(versions, & &1.version_number) == [3, 2, 1]
    end

    test "returns [] for a message with no versions" do
      assert MessageVersions.list_versions(Ecto.UUID.generate()) == []
    end
  end

  # ── count_versions/1 ─────────────────────────────────────────────────────────

  describe "count_versions/1" do
    test "counts versions for a message" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      assert MessageVersions.count_versions(msg.id) == 0

      MessageVersions.record_v1!(msg)
      assert MessageVersions.count_versions(msg.id) == 1

      {:ok, _} =
        MessageVersions.record_edit(msg.id, %{
          content: "v2",
          edited_by_participant_id: p.id,
          edited_by_display_name: "Alice"
        })

      assert MessageVersions.count_versions(msg.id) == 2
    end
  end

  # ── freeze/2 ─────────────────────────────────────────────────────────────────

  describe "freeze/2" do
    test "sets frozen_at and frozen_by_participant_id" do
      space = create_space!()
      p = create_participant!(space.id)
      freezer = create_participant!(space.id, "Saru")
      msg = create_message!(space.id, p.id)

      {:ok, frozen} = MessageVersions.freeze(msg, freezer.id)

      refute is_nil(frozen.frozen_at)
      assert frozen.frozen_by_participant_id == freezer.id
    end

    test "is a no-op on an already-frozen message (preserves original freeze)" do
      space = create_space!()
      p = create_participant!(space.id)
      freezer1 = create_participant!(space.id, "Saru")
      freezer2 = create_participant!(space.id, "OtherAgent")
      msg = create_message!(space.id, p.id)

      {:ok, frozen1} = MessageVersions.freeze(msg, freezer1.id)
      {:ok, frozen2} = MessageVersions.freeze(frozen1, freezer2.id)

      assert frozen2.frozen_at == frozen1.frozen_at
      assert frozen2.frozen_by_participant_id == freezer1.id
    end
  end
end
