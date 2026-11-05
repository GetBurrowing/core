defmodule Platform.People.Identity do
  @moduledoc """
  Pure name resolution for the people responsibility.

  Maps a free-text mention (a transcript token, an `@[Name]` wrapper, a
  first name) onto a roster entry without a database, a clock or a model
  call. Every later stage and both dispatch paths (native/federated and
  external) compose these functions, so the rules here are the only place
  identity is decided.

  Resolution order in `resolve/3`:

    1. exact normalised key on the entry name or any alias;
    2. a single-token mention that equals the first name of exactly one
       entry;
    3. `String.jaro_distance/2` against the normalised name, aliases and
       (for single-token mentions) each name token, gated by
       `opts[:threshold]` (default #{0.84}).

  Two or more fuzzy candidates above the threshold and within 0.03 of each
  other are `{:ambiguous, slugs}`; the resolver never picks one of them.
  """

  @default_threshold 0.84
  @ambiguity_window 0.03
  @honorifics ~w(mr ms mrs mx dr prof sir madam)

  @type roster_entry :: %{
          required(:slug) => String.t(),
          required(:name) => String.t(),
          optional(:aliases) => [String.t()],
          optional(:user_id) => String.t() | nil
        }

  @type resolution :: {:match, String.t()} | {:ambiguous, [String.t()]} | :unknown

  @doc """
  Normalises a mention into a comparison key: strips `@` / `@[..]` mention
  wrappers, lowercases, removes diacritics, drops punctuation and honorifics
  (mr, ms, mrs, dr ...) and collapses whitespace.

      iex> Platform.People.Identity.normalize_key("@[Dr. Marisol Tennebrook]")
      "marisol tennebrook"
  """
  @spec normalize_key(String.t() | nil) :: String.t()
  def normalize_key(nil), do: ""

  def normalize_key(mention) when is_binary(mention) do
    mention
    |> strip_mention_wrapper()
    |> String.downcase()
    |> strip_diacritics()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 in @honorifics))
    |> Enum.join(" ")
  end

  @doc """
  Resolves `mention` against `roster`.

  Options:

    * `:threshold` — minimum Jaro similarity for a fuzzy candidate
      (default #{@default_threshold}).
  """
  @spec resolve(String.t() | nil, [roster_entry()], keyword()) :: resolution()
  def resolve(mention, roster, opts \\ []) when is_list(roster) do
    key = normalize_key(mention)

    cond do
      key == "" ->
        :unknown

      (slugs = exact_slugs(key, roster)) != [] ->
        unique_or_ambiguous(slugs)

      (slugs = first_name_slugs(key, roster)) != [] ->
        unique_or_ambiguous(slugs)

      true ->
        fuzzy(key, roster, Keyword.get(opts, :threshold, @default_threshold))
    end
  end

  @doc """
  Hyphenated slug for a name. Pass the slugs already in use as the second
  argument and a collision gets a numeric suffix (`-2`, `-3`, ...).
  """
  @spec slug_for(String.t(), [String.t()]) :: String.t()
  def slug_for(name, taken \\ []) do
    base =
      case name |> normalize_key() |> String.replace(~r/\s+/, "-") do
        "" -> "person"
        slug -> slug
      end

    if base in taken, do: next_free(base, taken, 2), else: base
  end

  # -- internals --------------------------------------------------------------

  defp next_free(base, taken, n) do
    candidate = "#{base}-#{n}"
    if candidate in taken, do: next_free(base, taken, n + 1), else: candidate
  end

  defp strip_mention_wrapper(mention) do
    mention
    |> String.trim()
    |> String.replace(~r/\A@\[(.*)\]\z/su, "\\1")
    |> String.replace(~r/\A@/u, "")
  end

  defp strip_diacritics(text) do
    text
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
  end

  defp exact_slugs(key, roster) do
    roster
    |> Enum.filter(fn entry -> key in entry_keys(entry) end)
    |> Enum.map(& &1.slug)
    |> Enum.uniq()
  end

  defp first_name_slugs(key, roster) do
    if String.contains?(key, " ") do
      []
    else
      roster
      |> Enum.filter(fn entry ->
        Enum.any?(entry_keys(entry), fn full -> List.first(String.split(full)) == key end)
      end)
      |> Enum.map(& &1.slug)
      |> Enum.uniq()
    end
  end

  defp unique_or_ambiguous([slug]), do: {:match, slug}
  defp unique_or_ambiguous(slugs), do: {:ambiguous, Enum.sort(slugs)}

  defp fuzzy(key, roster, threshold) do
    scored =
      roster
      |> Enum.map(fn entry -> {entry.slug, best_score(key, entry)} end)
      |> Enum.filter(fn {_slug, score} -> score >= threshold end)
      |> Enum.sort_by(fn {slug, score} -> {-score, slug} end)

    case scored do
      [] ->
        :unknown

      [{slug, _score}] ->
        {:match, slug}

      [{top_slug, top_score} | _] ->
        close =
          scored
          |> Enum.filter(fn {_slug, score} -> top_score - score <= @ambiguity_window end)
          |> Enum.map(fn {slug, _score} -> slug end)
          |> Enum.uniq()

        case close do
          [^top_slug] -> {:match, top_slug}
          slugs -> {:ambiguous, Enum.sort(slugs)}
        end
    end
  end

  defp best_score(key, entry) do
    single_token? = not String.contains?(key, " ")

    candidates =
      entry
      |> entry_keys()
      |> Enum.flat_map(fn full ->
        if single_token?, do: [full | String.split(full)], else: [full]
      end)
      |> Enum.uniq()

    candidates
    |> Enum.map(&String.jaro_distance(key, &1))
    |> Enum.max(fn -> 0.0 end)
  end

  defp entry_keys(entry) do
    [Map.get(entry, :name) | Map.get(entry, :aliases) || []]
    |> Enum.map(&normalize_key/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end
