defmodule Platform.Chat.PinTest do
  use Platform.DataCase, async: false

  alias Platform.Chat

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space! do
    slug = "pin-space-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, space} = Chat.create_space(%{name: "Pins Test", slug: slug, kind: "channel"})
    space
  end

  defp create_participant!(space_id) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp create_message!(space_id, participant_id) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant_id,
        content_type: "text",
        content: "message to pin"
      })

    msg
  end

  # ── pin_message/1 ────────────────────────────────────────────────────────────

  describe "pin_message/1" do
    test "pins a message in a space" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, pin} =
        Chat.pin_message(%{
          space_id: space.id,
          message_id: msg.id,
          pinned_by: p.id
        })

      assert pin.space_id == space.id
      assert pin.message_id == msg.id
      assert pin.pinned_by == p.id
    end

    test "pinning different messages in the same space creates distinct pin records" do
      space = create_space!()
      p = create_participant!(space.id)
      msg1 = create_message!(space.id, p.id)
      msg2 = create_message!(space.id, p.id)

      {:ok, pin1} = Chat.pin_message(%{space_id: space.id, message_id: msg1.id, pinned_by: p.id})
      {:ok, pin2} = Chat.pin_message(%{space_id: space.id, message_id: msg2.id, pinned_by: p.id})

      assert pin1.id != pin2.id
      assert length(Chat.list_pins(space.id)) == 2
    end

    test "requires space_id" do
      p_id = Ecto.UUID.generate()
      msg_id = Ecto.UUID.generate()

      assert {:error, changeset} =
               Chat.pin_message(%{message_id: msg_id, pinned_by: p_id})

      assert changeset.errors[:space_id]
    end
  end

  # ── unpin_message/2 ──────────────────────────────────────────────────────────

  describe "unpin_message/2" do
    test "removes an existing pin" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, _pin} = Chat.pin_message(%{space_id: space.id, message_id: msg.id, pinned_by: p.id})
      {:ok, deleted} = Chat.unpin_message(space.id, msg.id)

      assert deleted.message_id == msg.id
      assert Chat.list_pins(space.id) == []
    end

    test "returns :not_found when message is not pinned" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      assert {:error, :not_found} = Chat.unpin_message(space.id, msg.id)
    end
  end

  # ── list_pins/1 ──────────────────────────────────────────────────────────────

  describe "list_pins/1" do
    test "returns all pins for a space" do
      space = create_space!()
      p = create_participant!(space.id)
      msg1 = create_message!(space.id, p.id)
      msg2 = create_message!(space.id, p.id)

      {:ok, _} = Chat.pin_message(%{space_id: space.id, message_id: msg1.id, pinned_by: p.id})
      {:ok, _} = Chat.pin_message(%{space_id: space.id, message_id: msg2.id, pinned_by: p.id})

      pins = Chat.list_pins(space.id)
      assert length(pins) == 2
      message_ids = Enum.map(pins, & &1.message_id)
      assert msg1.id in message_ids
      assert msg2.id in message_ids
    end

    test "returns empty list when no messages are pinned" do
      space = create_space!()

      assert Chat.list_pins(space.id) == []
    end

    test "does not leak pins from another space" do
      space1 = create_space!()
      space2 = create_space!()
      p1 = create_participant!(space1.id)
      msg = create_message!(space1.id, p1.id)

      {:ok, _} = Chat.pin_message(%{space_id: space1.id, message_id: msg.id, pinned_by: p1.id})

      assert Chat.list_pins(space2.id) == []
    end

    test "returns pins ordered oldest first" do
      space = create_space!()
      p = create_participant!(space.id)
      msg1 = create_message!(space.id, p.id)
      msg2 = create_message!(space.id, p.id)

      {:ok, pin1} =
        Chat.pin_message(%{space_id: space.id, message_id: msg1.id, pinned_by: p.id})

      {:ok, pin2} =
        Chat.pin_message(%{space_id: space.id, message_id: msg2.id, pinned_by: p.id})

      [first, second] = Chat.list_pins(space.id)
      assert first.id == pin1.id
      assert second.id == pin2.id
    end
  end
end
