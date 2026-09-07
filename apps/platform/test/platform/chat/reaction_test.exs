defmodule Platform.Chat.ReactionTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Reaction

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

  # ── changeset/2 emoji guard ──────────────────────────────────────────────────

  describe "changeset/2 emoji guard" do
    # Until this guard existed there was NO validation of `emoji` on any path.
    # `validate_required` was the whole of it, and both the LiveView `react`
    # handler and the agent-facing MCP `react` tool pass the client string
    # straight through — the MCP layer's `ToolArguments.validate/2` checks
    # presence only, never shape. So an agent or a crafted socket frame could
    # store an arbitrary string that then renders as a reaction pill.
    #
    # A PROPERTY check, deliberately not an allowlist: compiling the ~1,850-entry
    # inventory into Elixir would duplicate assets/emoji/data.js and reject
    # emoji agents legitimately post from outside our picker.
    # Platform.Chat.EmojiTest asserts the complementary direction — that the
    # guard accepts all 1,849 emoji the picker can actually offer.

    defp emoji_changeset(emoji) do
      Reaction.changeset(%Reaction{}, %{
        message_id: Ecto.UUID.generate(),
        participant_id: Ecto.UUID.generate(),
        emoji: emoji
      })
    end

    test "accepts a plain emoji" do
      assert emoji_changeset("\u{1F44D}").valid?
    end

    test "accepts an emoji carrying a variation selector" do
      # The spelling already in the database. Rejecting it would break every
      # existing heart reaction.
      assert emoji_changeset("\u{2764}\u{FE0F}").valid?
    end

    test "accepts a ZWJ family sequence" do
      # Four people joined by ZWJ: 7 codepoints, 25 bytes, ONE grapheme. ZWJ
      # sequences are not skin-tone modifiers and must pass.
      assert emoji_changeset("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}").valid?
    end

    test "accepts a subdivision flag, the longest sequence the picker can emit" do
      # 1F3F4 plus five tag characters plus the cancel tag: 28 bytes.
      england = "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
      assert byte_size(england) == 28
      assert emoji_changeset(england).valid?
    end

    test "rejects plain text" do
      refute emoji_changeset("lgtm").valid?
      assert {"must be an emoji", _} = emoji_changeset("lgtm").errors[:emoji]
    end

    test "rejects an emoji with text attached" do
      # The reason the check is anchored to the whole string rather than left as
      # a bare `\p{Emoji}` search: an unanchored match accepts this, and it
      # would render as a reaction pill reading "ship it 🚀".
      refute emoji_changeset("ship it \u{1F680}").valid?
    end

    test "rejects over-length input" do
      # Nine thumbs-ups: 9 graphemes, over the 8-grapheme ceiling, but only
      # 36 bytes — so this exercises the grapheme rule rather than the byte one.
      long = String.duplicate("\u{1F44D}", 9)
      assert byte_size(long) < 64
      refute emoji_changeset(long).valid?
      assert {"is too long", _} = emoji_changeset(long).errors[:emoji]
    end

    test "rejects input over the byte ceiling without segmenting it" do
      refute emoji_changeset(String.duplicate("a", 5_000)).valid?
      assert {"is too long", _} = emoji_changeset(String.duplicate("a", 5_000)).errors[:emoji]
    end

    test "still rejects a missing or blank emoji" do
      refute emoji_changeset(nil).valid?
      refute emoji_changeset("").valid?
    end

    test "the guard runs on the write path, not just on the struct" do
      # The unit assertions above build a changeset directly. This proves the
      # guard is actually reached by Chat.add_reaction/1, which is what the
      # LiveView handler and the MCP tool call.
      space = create_space!()
      p = create_participant!(space.id)
      msg = create_message!(space.id, p.id)

      assert {:error, changeset} =
               Chat.add_reaction(%{
                 message_id: msg.id,
                 participant_id: p.id,
                 emoji: "not an emoji"
               })

      assert changeset.errors[:emoji]
      assert Chat.list_reactions_grouped(msg.id) == []
    end
  end
end
