defmodule Platform.Chat.ReactionTest do
  use Platform.DataCase, async: false

  alias Platform.Chat

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp create_space! do
    slug = "reaction-space-#{System.unique_integer([:positive, :monotonic])}"
    {:ok, space} = Chat.create_space(%{name: "Reactions Test", slug: slug, kind: "channel"})
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
        content: "message for reactions"
      })

    msg
  end

  # ── add_reaction/1 ───────────────────────────────────────────────────────────

  describe "add_reaction/1" do
    test "creates a reaction for a message" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, reaction} =
        Chat.add_reaction(%{
          message_id: msg.id,
          participant_id: p.id,
          emoji: "👍"
        })

      assert reaction.message_id == msg.id
      assert reaction.participant_id == p.id
      assert reaction.emoji == "👍"
    end

    test "adding the same reaction twice returns a changeset error (unique constraint)" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "👍"})

      assert {:error, changeset} =
               Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "👍"})

      assert changeset.errors[:emoji]
    end

    test "different participants can react with the same emoji" do
      space = create_space!()
      p1 = create_participant!(space.id)
      p2 = create_participant!(space.id)
      msg = create_message!(space.id, p1.id)

      {:ok, r1} = Chat.add_reaction(%{message_id: msg.id, participant_id: p1.id, emoji: "❤️"})
      {:ok, r2} = Chat.add_reaction(%{message_id: msg.id, participant_id: p2.id, emoji: "❤️"})

      assert r1.id != r2.id
    end
  end

  # ── remove_reaction/3 ────────────────────────────────────────────────────────

  describe "remove_reaction/3" do
    test "removes an existing reaction" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "👍"})
      {:ok, deleted} = Chat.remove_reaction(msg.id, p.id, "👍")

      assert deleted.emoji == "👍"
      assert Chat.list_reactions(msg.id) == []
    end

    test "returns :not_found when reaction does not exist" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      assert {:error, :not_found} = Chat.remove_reaction(msg.id, p.id, "🎉")
    end
  end

  # ── toggle_reaction/3 ────────────────────────────────────────────────────────

  describe "toggle_reaction/3" do
    test "adds a reaction when absent" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, :added, reaction} = Chat.toggle_reaction(msg.id, p.id, "👍")

      assert reaction.emoji == "👍"
      assert length(Chat.list_reactions(msg.id)) == 1
    end

    test "removes a reaction when already present" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p.id, emoji: "👍"})
      {:ok, :removed, reaction} = Chat.toggle_reaction(msg.id, p.id, "👍")

      assert reaction.emoji == "👍"
      assert Chat.list_reactions(msg.id) == []
    end

    test "toggle twice returns to original state" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      {:ok, :added, _} = Chat.toggle_reaction(msg.id, p.id, "🔥")
      {:ok, :removed, _} = Chat.toggle_reaction(msg.id, p.id, "🔥")
      {:ok, :added, _} = Chat.toggle_reaction(msg.id, p.id, "🔥")

      assert length(Chat.list_reactions(msg.id)) == 1
    end
  end

  # ── list_reactions/1 ─────────────────────────────────────────────────────────

  describe "list_reactions/1" do
    test "returns all reactions for a message" do
      space = create_space!()
      p1 = create_participant!(space.id)
      p2 = create_participant!(space.id)
      msg = create_message!(space.id, p1.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p1.id, emoji: "👍"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p2.id, emoji: "❤️"})

      reactions = Chat.list_reactions(msg.id)
      assert length(reactions) == 2
    end

    test "returns empty list for a message with no reactions" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      assert Chat.list_reactions(msg.id) == []
    end
  end

  # ── list_reactions_grouped/1 ─────────────────────────────────────────────────

  describe "list_reactions_grouped/1" do
    test "groups reactions by emoji with count and participants" do
      space = create_space!()
      p1 = create_participant!(space.id)
      p2 = create_participant!(space.id)
      p3 = create_participant!(space.id)
      msg = create_message!(space.id, p1.id)

      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p1.id, emoji: "👍"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p2.id, emoji: "👍"})
      {:ok, _} = Chat.add_reaction(%{message_id: msg.id, participant_id: p3.id, emoji: "❤️"})

      groups = Chat.list_reactions_grouped(msg.id)

      thumbs = Enum.find(groups, &(&1.emoji == "👍"))
      heart = Enum.find(groups, &(&1.emoji == "❤️"))

      assert thumbs.count == 2
      assert length(thumbs.participants) == 2
      assert heart.count == 1
      assert length(heart.participants) == 1
    end

    test "returns empty list for a message with no reactions" do
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      assert Chat.list_reactions_grouped(msg.id) == []
    end
  end
end
