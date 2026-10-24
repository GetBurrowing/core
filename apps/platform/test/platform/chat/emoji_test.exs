defmodule Platform.Chat.EmojiTest do
  # No database: this file tests a constant list, a changeset, and a generated
  # data file.
  use ExUnit.Case, async: true

  alias Platform.Chat.Emoji
  alias Platform.Chat.Reaction

  # The generated client inventory. Read from disk rather than duplicated,
  # because the whole point of Platform.Chat.Emoji NOT carrying the inventory is
  # that there is one copy of it.
  @inventory_path Path.expand("../../../assets/emoji/data.js", __DIR__)
  @external_resource @inventory_path

  # `{ e: "\u{1F600}", ... }` — the generator emits every sequence as ASCII
  # escapes precisely so it can be read back without guessing at encodings.
  defp inventory do
    ~r/\{ e: "((?:\\u\{[0-9A-F]+\}|\\u[0-9A-F]{4})+)"/
    |> Regex.scan(File.read!(@inventory_path), capture: :all_but_first)
    |> Enum.map(fn [escaped] -> unescape(escaped) end)
  end

  defp unescape(escaped) do
    ~r/\\u\{([0-9A-F]+)\}|\\u([0-9A-F]{4})/
    |> Regex.scan(escaped, capture: :all_but_first)
    |> Enum.map_join(fn parts ->
      parts
      |> Enum.reject(&(&1 == ""))
      |> hd()
      |> String.to_integer(16)
      |> List.wrap()
      |> List.to_string()
    end)
  end

  describe "quick_defaults/0" do
    test "returns a stable, non-empty list of distinct emoji" do
      defaults = Emoji.quick_defaults()

      assert is_list(defaults)
      assert length(defaults) > 0
      assert Enum.all?(defaults, &is_binary/1)
      assert defaults == Enum.uniq(defaults)
      assert defaults == Emoji.quick_defaults(), "must be a constant, not computed per call"
    end

    test "is the masters' six, in order, byte for byte" do
      # The designer's masters set (redesign rung 9): 👍 🔥 ❤️ 😂 👀 ✅.
      # Frozen here as escapes, not as glyphs: `\u{2764}\u{FE0F}` and a bare
      # `\u{2764}` look identical in an editor and are different strings to
      # `Chat.list_reactions_grouped/1`, which groups by exact match. Getting
      # this wrong splits every existing heart reaction into a second pill and
      # no migration can repair it after the fact.
      assert Emoji.quick_defaults() == [
               "\u{1F44D}",
               "\u{1F525}",
               "\u{2764}\u{FE0F}",
               "\u{1F602}",
               "\u{1F440}",
               "\u{2705}"
             ]
    end

    test "the heart carries U+FE0F and no bare heart is offered" do
      heart = Enum.at(Emoji.quick_defaults(), 2)
      assert String.to_charlist(heart) == [0x2764, 0xFE0F]
      refute "\u{2764}" in Emoji.quick_defaults()
    end

    test "every quick default has a spoken name" do
      for emoji <- Emoji.quick_defaults() do
        refute Emoji.quick_name(emoji) == emoji, "#{emoji} has no quick_name"
      end

      assert Emoji.quick_name("\u{1F44D}") == "thumbs up"
    end

    test "every default carries the variation selector it needs, and is accepted by the guard" do
      for emoji <- Emoji.quick_defaults() do
        assert valid?(emoji), "quick default #{inspect(emoji)} is rejected by its own guard"
      end
    end
  end

  describe "the generated inventory" do
    test "is present and is the expected order of magnitude" do
      count = length(inventory())
      assert count > 1500, "only #{count} emoji parsed out of #{@inventory_path}"
      assert count < 2200
    end

    test "every quick default is in the client inventory, byte-identical" do
      # The join between the two halves of this stage. The JS suite asserts the
      # inventory against the emoji already in the database; this asserts the
      # server's constant against the same inventory. Together they chain
      # quick_defaults/0 -> data.js -> what is stored today.
      shipped = MapSet.new(inventory())

      for emoji <- Emoji.quick_defaults() do
        assert MapSet.member?(shipped, emoji),
               "#{emoji} is a quick default but is not in assets/emoji/data.js"
      end
    end

    test "the guard accepts every emoji the picker can offer" do
      # A guard that rejects something in our own picker is a production bug the
      # unit tests below would not catch: they check four hand-picked strings,
      # this checks all 1,849.
      rejected = Enum.reject(inventory(), &valid?/1)
      assert rejected == [], "the changeset guard rejects shipped emoji: #{inspect(rejected)}"
    end

    test "the whole inventory fits the storage column with room to spare" do
      # `chat_reactions.emoji` is `add(:emoji, :string)` (create_chat_tables),
      # i.e. varchar(255) — 255 CHARACTERS in Postgres, not bytes. Measured
      # rather than assumed, because a truncation mid-ZWJ corrupts both the
      # glyph and the unique-index key.
      inventory = inventory()

      max_codepoints = inventory |> Enum.map(&String.length/1) |> Enum.max()
      max_bytes = inventory |> Enum.map(&byte_size/1) |> Enum.max()
      max_graphemes = inventory |> Enum.map(&length(String.graphemes(&1))) |> Enum.max()

      assert max_codepoints <= 255, "#{max_codepoints} codepoints would not fit varchar(255)"
      assert max_bytes <= 64, "#{max_bytes} bytes exceeds the changeset guard's ceiling"

      assert max_graphemes <= 8,
             "#{max_graphemes} graphemes exceeds the changeset guard's ceiling"

      # The headroom, asserted so a future change that eats it is visible rather
      # than merely still-passing. The widest entries today are the subdivision
      # flags (1F3F4 + 5 tag characters + cancel tag) and the four-person kiss
      # ZWJ sequences.
      assert max_codepoints <= 10
      assert max_bytes <= 32
      assert max_graphemes == 1, "every shipped emoji is a single grapheme cluster"
    end
  end

  defp valid?(emoji) do
    %Reaction{}
    |> Reaction.changeset(%{
      message_id: Ecto.UUID.generate(),
      participant_id: Ecto.UUID.generate(),
      emoji: emoji
    })
    |> Map.fetch!(:valid?)
  end
end
