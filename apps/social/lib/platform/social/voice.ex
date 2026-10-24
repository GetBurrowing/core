defmodule Platform.Social.Voice do
  @moduledoc """
  A brand's structured voice (Social authoring 4/11, task 01a16c4f-9041),
  embedded in `social_profiles.voice`:

    * `samples` - up to 10 of the brand's own posts, each at most 3,000
      characters. What drafting agents imitate.
    * `banned` - up to 50 phrases the brand never says. An AGENT draft
      containing one is refused (`Platform.Social.AgentDrafts`,
      `{:error, :banned_phrase, phrase}`); a human is only warned (the
      `banned_phrase` flag from `Platform.Social.PlatformLimits.flags/2`).
    * `learnings` - accepted notes (`Platform.Social.VoiceLearning`). Never
      cast from attrs: written only by the weekly-note flow (11/11), removed
      by an approver with `Platform.Social.remove_voice_learning/4`.

  `profile.voice_notes` stays the free-text "about this brand".

  ## Matching

  `banned_phrase/2` is case-insensitive, collapses runs of whitespace, and
  matches whole words at each end of the phrase when that end is a letter
  or digit (so "synergy" does not match "synergyx", while a phrase ending
  in punctuation matches wherever it appears).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_samples 10
  @max_sample_length 3000
  @max_banned 50
  @max_phrase_length 100

  @type t :: %__MODULE__{}

  @primary_key false
  embedded_schema do
    field(:samples, {:array, :string}, default: [])
    field(:banned, {:array, :string}, default: [])
    embeds_many(:learnings, Platform.Social.VoiceLearning, on_replace: :delete)
  end

  @doc "Limits: `%{samples, sample_length, banned, phrase_length}`."
  @spec limits() :: map()
  def limits,
    do: %{
      samples: @max_samples,
      sample_length: @max_sample_length,
      banned: @max_banned,
      phrase_length: @max_phrase_length
    }

  @doc "The voice of a profile (or nil), never nil."
  @spec of(map() | nil) :: t()
  def of(%{voice: %__MODULE__{} = voice}), do: voice
  def of(_), do: %__MODULE__{}

  @doc """
  The human changeset: casts `samples` and `banned` only (trimmed, blanks
  dropped, banned de-duplicated case-insensitively). `learnings` is never
  cast here.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = voice, attrs) do
    voice
    |> cast(attrs, [:samples, :banned])
    |> update_change(:samples, &clean/1)
    |> update_change(:banned, &(&1 |> clean() |> Enum.uniq_by(fn p -> normalize(p) end)))
    |> validate_length(:samples, max: @max_samples, message: "at most %{count} samples")
    |> validate_length(:banned, max: @max_banned, message: "at most %{count} phrases")
    |> validate_each(:samples, @max_sample_length, "each sample is at most %{count} characters")
    |> validate_each(:banned, @max_phrase_length, "each phrase is at most %{count} characters")
  end

  defp clean(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp clean(_), do: []

  defp validate_each(changeset, field, max, message) do
    validate_change(changeset, field, fn ^field, values ->
      if Enum.all?(values, &(String.length(&1) <= max)),
        do: [],
        else: [{field, {String.replace(message, "%{count}", Integer.to_string(max)), []}}]
    end)
  end

  @doc """
  The first of `banned` (a list, a `Voice`, or a profile) found in `text`,
  as written in the list; nil when none is.
  """
  @spec banned_phrase(String.t() | nil, [String.t()] | t() | map() | nil) :: String.t() | nil
  def banned_phrase(text, %__MODULE__{banned: banned}), do: banned_phrase(text, banned)
  def banned_phrase(text, %{voice: _} = profile), do: banned_phrase(text, of(profile))

  def banned_phrase(text, banned) when is_binary(text) and is_list(banned) do
    haystack = normalize(text)
    Enum.find(banned, &(is_binary(&1) and phrase_in?(haystack, &1)))
  end

  def banned_phrase(_text, _banned), do: nil

  defp phrase_in?(haystack, phrase) do
    case normalize(phrase) do
      "" ->
        false

      needle ->
        left = if word_char?(String.first(needle)), do: "(?<![\\p{L}\\p{N}_])", else: ""
        right = if word_char?(String.last(needle)), do: "(?![\\p{L}\\p{N}_])", else: ""
        Regex.match?(Regex.compile!(left <> Regex.escape(needle) <> right, "u"), haystack)
    end
  end

  defp word_char?(char), do: char != nil and Regex.match?(~r/^[\p{L}\p{N}_]$/u, char)

  defp normalize(text),
    do: text |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()
end
