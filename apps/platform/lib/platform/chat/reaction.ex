defmodule Platform.Chat.Reaction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "chat_reactions" do
    field(:message_id, :binary_id)
    field(:participant_id, :binary_id)
    field(:emoji, :string)

    # Reactor identity snapshot — captured at write time so the reactor's
    # name survives the participant being hard-deleted from the space.
    # Mirrors ADR 0038's author snapshots on chat_messages.
    field(:reactor_display_name, :string)
    field(:reactor_avatar_url, :string)
    field(:reactor_participant_type, :string)

    field(:inserted_at, :utc_datetime_usec, autogenerate: {DateTime, :utc_now, []})

    # Soft-delete timestamp. NULL = active. Set by `Chat.remove_reaction/3`.
    # The unique index on (message_id, participant_id, emoji) is partial
    # (WHERE deleted_at IS NULL), so a re-reaction after soft-delete is
    # allowed at the storage layer; `Chat.add_reaction/1` prefers
    # resurrection over inserting a duplicate.
    field(:deleted_at, :utc_datetime_usec)
  end

  # Longest sequence the shipped picker can emit is 1 grapheme / 28 bytes (the
  # subdivision flags, e.g. \u{1F3F4} + 5 tag characters + cancel tag, and the
  # four-person kiss ZWJ sequences). The ceilings are set well above that so a
  # legitimate emoji an agent posts through the MCP `react` tool is not rejected
  # for being newer or longer than anything we ship, while an accidental
  # paragraph is.
  @max_emoji_graphemes 8
  @max_emoji_bytes 64

  # A PROPERTY check, deliberately NOT an allowlist. Compiling the ~1,850-entry
  # client inventory (assets/emoji/data.js) into Elixir would duplicate it, drift
  # from it the first time one side is regenerated, and reject emoji that agents
  # legitimately post through the MCP `react` tool from outside our picker.
  #
  # Anchored to the WHOLE string rather than left as a bare `\p{Emoji}` search,
  # because an unanchored match accepts "ship it \u{1F680}" — 8 graphemes of free
  # text that would then render as a reaction pill.
  #
  # The class is `\p{Emoji}` plus the joiners and selectors that are NOT
  # themselves Emoji=Yes: ZWJ, the two variation selectors, the combining
  # enclosing keycap, the skin-tone modifiers, and the tag characters that spell
  # out subdivision flags.
  #
  # Known and accepted looseness: ASCII digits, `#` and `*` carry Emoji=Yes in
  # Unicode (they are the bases of the keycap sequences), so "12345678" passes.
  # Tightening that costs an Extended_Pictographic clause that the keycaps
  # themselves would then fail, to stop a string nobody sends.
  @emoji_shaped ~r/^[\p{Emoji}\x{200D}\x{FE0F}\x{FE0E}\x{20E3}\x{1F3FB}-\x{1F3FF}\x{E0020}-\x{E007F}]+$/u

  def changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [
      :message_id,
      :participant_id,
      :emoji,
      :reactor_display_name,
      :reactor_avatar_url,
      :reactor_participant_type
    ])
    |> validate_required([:message_id, :participant_id, :emoji])
    |> validate_emoji()
    |> unique_constraint(:emoji, name: :chat_reactions_unique)
  end

  # Until this existed there was NO validation of `emoji` on any path: both the
  # LiveView `react` handler and the agent-facing MCP `react` tool pass the
  # client string straight through to the database.
  #
  # Byte length is checked before grapheme length so a megabyte of text is
  # rejected without segmenting it.
  defp validate_emoji(changeset) do
    case get_change(changeset, :emoji) do
      nil ->
        changeset

      emoji when byte_size(emoji) > @max_emoji_bytes ->
        add_error(changeset, :emoji, "is too long",
          validation: :length,
          kind: :max,
          count: @max_emoji_bytes
        )

      emoji ->
        cond do
          not Regex.match?(@emoji_shaped, emoji) ->
            add_error(changeset, :emoji, "must be an emoji", validation: :format)

          length(String.graphemes(emoji)) > @max_emoji_graphemes ->
            add_error(changeset, :emoji, "is too long",
              validation: :length,
              kind: :max,
              count: @max_emoji_graphemes
            )

          true ->
            changeset
        end
    end
  end

  @doc """
  Soft-delete-only changeset. Casts only `deleted_at` (set to a timestamp to
  hide, or `nil` to restore). Mirrors `Canvas.delete_changeset/2`.
  """
  def delete_changeset(reaction, attrs) do
    reaction
    |> cast(attrs, [:deleted_at])
  end
end
