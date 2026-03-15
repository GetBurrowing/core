defmodule Platform.ChatTest do
  @moduledoc """
  Integration tests for `Platform.Chat` context — threads, reactions, pins,
  and the batch `list_reactions_for_messages/1` helper added in T6.
  """

  use Platform.DataCase, async: false

  alias Platform.Chat

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space(attrs \\ %{}) do
    default = %{name: "Test", slug: unique_slug(), kind: "channel"}

    {:ok, space} = Chat.create_space(Map.merge(default, attrs))
    space
  end

  defp create_participant(space_id, attrs \\ %{}) do
    default = %{
      participant_type: "user",
      participant_id: Ecto.UUID.generate(),
      joined_at: DateTime.utc_now()
    }

    {:ok, p} = Chat.add_participant(space_id, Map.merge(default, attrs))
    p
  end

  defp create_message(space_id, participant_id, attrs \\ %{}) do
    default = %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: "hello"
    }

    {:ok, msg} = Chat.post_message(Map.merge(default, attrs))
    msg
  end

  defp unique_slug do
    "test-#{System.unique_integer([:positive])}"
  end

  # ── Threads ───────────────────────────────────────────────────────────────────

  describe "create_thread/2 and get_thread_for_message/1" do
    test "creates a thread anchored to a parent message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, thread} =
        Chat.create_thread(space.id, %{parent_message_id: msg.id, title: "Discussion"})

      assert thread.space_id == space.id
      assert thread.parent_message_id == msg.id
      assert thread.title == "Discussion"
    end

    test "get_thread_for_message/1 returns the thread by parent message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: msg.id})

      found = Chat.get_thread_for_message(msg.id)
      assert found.id == thread.id
    end

    test "get_thread_for_message/1 returns nil when no thread exists" do
      assert Chat.get_thread_for_message(Ecto.UUID.generate()) == nil
    end

    test "thread messages are posted with thread_id" do
      space = create_space()
      p = create_participant(space.id)
      parent_msg = create_message(space.id, p.id)

      {:ok, thread} = Chat.create_thread(space.id, %{parent_message_id: parent_msg.id})

      {:ok, reply} =
        Chat.post_message(%{
          space_id: space.id,
          thread_id: thread.id,
          participant_id: p.id,
          content_type: "text",
          content: "a reply"
        })

      assert reply.thread_id == thread.id

      thread_msgs = Chat.list_messages(space.id, thread_id: thread.id)
      assert length(thread_msgs) == 1
      assert hd(thread_msgs).id == reply.id
    end
  end

  # ── Reactions ─────────────────────────────────────────────────────────────────

  describe "add_reaction/1 and remove_reaction/3" do
    test "adds a reaction to a message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, reaction} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: p.id,
          emoji: "👍"
        })

      assert reaction.message_id == msg.id
      assert reaction.emoji == "👍"
    end

    test "removes a reaction" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "❤️"})

      assert {:ok, _} = Chat.remove_reaction(msg.id, p.id, "❤️")
      assert Chat.list_reactions(msg.id) == []
    end

    test "remove_reaction returns :not_found for absent reaction" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      assert {:error, :not_found} = Chat.remove_reaction(msg.id, p.id, "🎉")
    end
  end

  describe "list_reactions_for_messages/1" do
    test "returns empty map for empty list" do
      assert Chat.list_reactions_for_messages([]) == %{}
    end

    test "returns reactions grouped by message_id" do
      space = create_space()
      p1 = create_participant(space.id)
      p2 = create_participant(space.id)
      msg1 = create_message(space.id, p1.id)
      msg2 = create_message(space.id, p1.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg1.id, participant_id: p1.id, emoji: "👍"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg1.id, participant_id: p2.id, emoji: "👍"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg1.id, participant_id: p1.id, emoji: "❤️"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg2.id, participant_id: p2.id, emoji: "😂"})

      result = Chat.list_reactions_for_messages([msg1.id, msg2.id])

      msg1_reactions = result[msg1.id]
      msg2_reactions = result[msg2.id]

      assert length(msg1_reactions) == 3
      assert length(msg2_reactions) == 1
      assert hd(msg2_reactions).emoji == "😂"
    end

    test "omits message IDs with no reactions" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      result = Chat.list_reactions_for_messages([msg.id])
      refute Map.has_key?(result, msg.id)
    end
  end

  # ── Attachments ───────────────────────────────────────────────────────────────

  describe "post_message_with_attachments/2" do
    test "creates the message and attachments in one transaction" do
      space = create_space()
      participant = create_participant(space.id)

      {:ok, message, attachments} =
        Chat.post_message_with_attachments(
          %{
            space_id: space.id,
            participant_id: participant.id,
            content_type: "text",
            content: "see attached"
          },
          [
            %{
              filename: "notes.txt",
              content_type: "text/plain",
              byte_size: 12,
              storage_key: "chat/test/notes.txt"
            }
          ]
        )

      assert message.content == "see attached"
      assert length(attachments) == 1
      assert hd(attachments).message_id == message.id
      assert hd(attachments).filename == "notes.txt"
    end
  end

  describe "list_attachments_for_messages/1" do
    test "returns attachments grouped by message_id" do
      space = create_space()
      participant = create_participant(space.id)
      message_one = create_message(space.id, participant.id)
      message_two = create_message(space.id, participant.id)

      {:ok, _} =
        Chat.create_attachment(%{
          message_id: message_one.id,
          filename: "one.txt",
          content_type: "text/plain",
          byte_size: 3,
          storage_key: "chat/test/one.txt"
        })

      {:ok, _} =
        Chat.create_attachment(%{
          message_id: message_one.id,
          filename: "two.txt",
          content_type: "text/plain",
          byte_size: 3,
          storage_key: "chat/test/two.txt"
        })

      {:ok, _} =
        Chat.create_attachment(%{
          message_id: message_two.id,
          filename: "three.txt",
          content_type: "text/plain",
          byte_size: 5,
          storage_key: "chat/test/three.txt"
        })

      result = Chat.list_attachments_for_messages([message_one.id, message_two.id])

      assert Enum.map(result[message_one.id], & &1.filename) == ["one.txt", "two.txt"]
      assert Enum.map(result[message_two.id], & &1.filename) == ["three.txt"]
    end
  end

  # ── Pins ──────────────────────────────────────────────────────────────────────

  describe "pin_message/1 and unpin_message/2" do
    test "pins a message in a space" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, pin} =
        Chat.pin_message(%{
          space_id: space.id,
          message_id: msg.id,
          pinned_by: p.id
        })

      assert pin.space_id == space.id
      assert pin.message_id == msg.id
    end

    test "unpins a message" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      {:ok, _} = Chat.pin_message(%{space_id: space.id, message_id: msg.id, pinned_by: p.id})

      assert {:ok, _} = Chat.unpin_message(space.id, msg.id)
      assert Chat.list_pins(space.id) == []
    end

    test "unpin_message returns :not_found when not pinned" do
      space = create_space()
      p = create_participant(space.id)
      msg = create_message(space.id, p.id)

      assert {:error, :not_found} = Chat.unpin_message(space.id, msg.id)
    end

    test "list_pins returns all pinned messages for a space" do
      space = create_space()
      p = create_participant(space.id)
      msg1 = create_message(space.id, p.id)
      msg2 = create_message(space.id, p.id)

      {:ok, _} = Chat.pin_message(%{space_id: space.id, message_id: msg1.id, pinned_by: p.id})
      {:ok, _} = Chat.pin_message(%{space_id: space.id, message_id: msg2.id, pinned_by: p.id})

      pins = Chat.list_pins(space.id)
      assert length(pins) == 2
    end
  end
end
