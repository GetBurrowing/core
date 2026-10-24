defmodule Platform.Chat.Emoji do
  @moduledoc """
  The reaction picker's server-side emoji constants.

  The full inventory (~1,850 emoji with their CLDR search keywords) lives on the
  client, at `assets/emoji/data.js`, built as a separate esbuild entry point and
  fetched on first picker open. It is deliberately NOT duplicated here: two
  copies of the same list drift the first time one side is regenerated, and the
  server never needs to enumerate emoji — `Platform.Chat.Reaction`'s changeset
  validates by property, not by membership.

  What the server does own is the small static set the quick-react row renders
  without opening the picker at all.
  """

  # A STATIC, SYSTEM-WIDE set. There is deliberately no personalisation anywhere
  # in reactions: no recents, no last-used tracking, no per-user preference
  # column, no localStorage, no org-level default.
  #
  # The storage fact behind that, should it be revisited: `chat_reactions`
  # carries exactly one index and it is message-first —
  # `chat_reactions_unique` on `(message_id, participant_id, emoji)
  # WHERE deleted_at IS NULL`, from
  # priv/repo/migrations/20260429120000_soft_delete_reactions.exs. No migration
  # creates a standalone `participant_id` index, so a "this participant's most
  # recent reactions" query cannot use one and would seq-scan. Adding
  # personalisation later therefore costs an index, not just a column.
  #
  # Deferring costs nothing else, because every quick-react row in the product
  # reads from this one function.
  #
  # The designer's masters set (redesign rung 9, masters canvas 01a1382f node
  # `proto`: 👍 🔥 ❤️ 😂 👀 ✅, in that order). It replaced the old overlay's
  # 👍 🎉 ✅ ❤️ 😂 🙏. Reactions already stored with 🎉 or 🙏 are untouched:
  # this list only decides what the one-tap strip offers.
  #
  # `\u{2764}\u{FE0F}` carries its variation selector: reactions are grouped
  # by exact string match (`Chat.list_reactions_grouped/1` uses
  # `Enum.group_by(& &1.emoji)`), so emitting a bare `\u{2764}` here would split
  # every heart reaction in the product into a second pill, and no migration
  # repairs that.
  @quick_defaults [
    "\u{1F44D}",
    "\u{1F525}",
    "\u{2764}\u{FE0F}",
    "\u{1F602}",
    "\u{1F440}",
    "\u{2705}"
  ]

  # The accessible names the strip reads out ("React with <name>"), CLDR
  # short names. Keyed by the exact strings above.
  @quick_names %{
    "\u{1F44D}" => "thumbs up",
    "\u{1F525}" => "fire",
    "\u{2764}\u{FE0F}" => "red heart",
    "\u{1F602}" => "face with tears of joy",
    "\u{1F440}" => "eyes",
    "\u{2705}" => "check mark button"
  }

  @doc """
  The quick-react emoji offered without opening the full picker, in display
  order.

  Single source of truth: the message-actions sheet and the message pill's
  thumbs-up both read this rather than carrying their own literal.

      iex> Platform.Chat.Emoji.quick_defaults() |> length()
      6

  """
  @spec quick_defaults() :: [String.t()]
  def quick_defaults, do: @quick_defaults

  @doc """
  The accessible name of a quick-react emoji, for its "React with <name>"
  label. Anything outside `quick_defaults/0` falls back to the emoji itself.

      iex> Platform.Chat.Emoji.quick_name("\u{1F525}")
      "fire"

  """
  @spec quick_name(String.t()) :: String.t()
  def quick_name(emoji), do: Map.get(@quick_names, emoji, emoji)
end
