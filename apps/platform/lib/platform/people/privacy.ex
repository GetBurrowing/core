defmodule Platform.People.Privacy do
  @moduledoc """
  Pure privacy rules for people pages: contact/financial scrubbing, the
  closed trait-language list, and the "subject reads it" contract text.

  Everything here runs on plain strings. No Repo, no clock, no model call —
  the Historian-role holder writes pages itself through the memory tools, so
  these rules have to be enforceable on the markdown that reaches the wiki.
  """

  @redaction_kinds [:phone, :address, :financial]

  # Phone numbers --------------------------------------------------------------
  # International: +CC then 2..5 digit groups (e.g. +44 20 7946 0958).
  @intl_phone ~r/(?<![\d\w])\+\d{1,3}(?:[\s.-]?\d{1,5}){2,5}(?![\d\w])/u
  # NANP in three shapes: 904-555-0100, (904) 555 0100, 904.555.0100, with an
  # optional leading 1. Lookarounds keep it off longer digit runs.
  @nanp_phone ~r/(?<![\d\w])(?:1[\s.-]?)?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}(?![\d\w])/u

  # Street addresses -----------------------------------------------------------
  @street_words ~w(St Street Ave Avenue Road Rd Blvd Boulevard Lane Ln Drive Dr Court Ct Way)
  @address ~r/(?<![\w-])\d{1,6}\s+(?:[A-Z][A-Za-z']*\s+){1,3}(?:#{Enum.join(@street_words, "|")})\b\.?(?:[^\n.]{0,40}?\b(?:\d{5}(?:-\d{4})?|[A-Z]{1,2}\d[A-Z\d]?\s?\d[A-Z]{2})\b)?/u

  # Financial identifiers ------------------------------------------------------
  @iban ~r/\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]{4}){2,7}(?:\s?[A-Z0-9]{1,4})?\b/u
  # Candidate card-like runs: 13..19 digits with optional single space/hyphen
  # separators, not glued to other alphanumerics (so hex ids never qualify).
  @digit_run ~r/(?<![0-9A-Za-z-])\d(?:[ -]?\d){12,18}(?![0-9A-Za-z-])/u
  @amount ~r/\$\s?\d[\d,]*(?:\.\d+)?|\bUSD\s?\d[\d,]*(?:\.\d+)?|\b\d[\d,]*(?:\.\d+)?\s?USD\b/u
  @money_context ~r/\b(?:salary|owes|owed|paid|invoice|net worth)\b/iu
  @money_window 40

  # Trait language -------------------------------------------------------------
  @trait_terms [
    "lazy",
    "arrogant",
    "difficult",
    "unreliable",
    "slow playing",
    "flaky",
    "brilliant",
    "genius",
    "toxic",
    "shady",
    "aggressive",
    "passive-aggressive",
    "personality",
    "temperament",
    "seems like a",
    "the kind of person",
    "motivated by",
    "is clearly",
    "untrustworthy",
    "dishonest",
    "incompetent",
    "manipulative"
  ]

  # An empty list means nothing is trait language, never "everything is".
  @trait_regex (if @trait_terms == [] do
                  ~r/(?!)/
                else
                  Regex.compile!(
                    "(?<![\\w-])(?:" <>
                      (@trait_terms
                       |> Enum.sort_by(&(-String.length(&1)))
                       |> Enum.map_join("|", &Regex.escape/1)) <>
                      ")(?![\\w-])",
                    "iu"
                  )
                end)

  @subject_reads_it_note """
  The subject of this page reads it. A people page is a catalogue of
  interactions, not a dossier. Perspectives are the subject's OWN statements,
  cited to where they said them; nothing is written in the subject's voice
  that they did not say. No personality reads, motives or temperament. Nothing
  on health, family, money or private contact details. When in doubt, leave
  it out.
  """

  @doc """
  Replaces phone numbers, street addresses and financial identifiers with
  `[REDACTED: phone|address|financial]`. Returns the scrubbed text and a list
  of `%{kind, count}` for every kind that fired, in the order
  #{inspect(@redaction_kinds)}.

  UUIDs, git shas, dates, clock times and version strings pass untouched.
  """
  @spec scrub(String.t()) :: {String.t(), [%{kind: atom(), count: non_neg_integer()}]}
  def scrub(text) when is_binary(text) do
    {text, address_count} = replace_counting(text, @address, "[REDACTED: address]")
    {text, intl_count} = replace_counting(text, @intl_phone, "[REDACTED: phone]")
    {text, nanp_count} = replace_counting(text, @nanp_phone, "[REDACTED: phone]")
    {text, iban_count} = replace_counting(text, @iban, "[REDACTED: financial]")
    {text, luhn_count} = replace_luhn(text)
    {text, amount_count} = replace_money(text)

    counts = [
      {:phone, intl_count + nanp_count},
      {:address, address_count},
      {:financial, iban_count + luhn_count + amount_count}
    ]

    report =
      for {kind, count} <- counts, count > 0 do
        %{kind: kind, count: count}
      end

    {text, report}
  end

  @doc """
  True when `text` contains a term from the closed trait-language list,
  matched as whole words, case-insensitively. The list is a module attribute
  and is the whole rule; there is no model in the loop.
  """
  @spec trait_language?(String.t()) :: boolean()
  def trait_language?(text) when is_binary(text), do: Regex.match?(@trait_regex, text)

  @doc "The closed list of trait terms `trait_language?/1` tests against."
  @spec trait_terms() :: [String.t()]
  def trait_terms, do: @trait_terms

  @doc "The contract text every people page is written under."
  @spec subject_reads_it_note() :: String.t()
  def subject_reads_it_note,
    do: @subject_reads_it_note |> String.trim() |> String.replace(~r/\s*\n\s*/, " ")

  # -- internals --------------------------------------------------------------

  defp replace_counting(text, regex, replacement) do
    count = regex |> Regex.scan(text) |> length()
    {Regex.replace(regex, text, replacement), count}
  end

  defp replace_luhn(text) do
    {out, count} =
      Regex.split(@digit_run, text, include_captures: true)
      |> Enum.reduce({[], 0}, fn chunk, {acc, n} ->
        if Regex.match?(~r/\A\d(?:[ -]?\d){12,18}\z/u, chunk) and luhn_valid?(chunk) do
          {["[REDACTED: financial]" | acc], n + 1}
        else
          {[chunk | acc], n}
        end
      end)

    {out |> Enum.reverse() |> IO.iodata_to_binary(), count}
  end

  defp luhn_valid?(run) do
    digits =
      run
      |> String.replace(~r/[ -]/, "")
      |> String.graphemes()
      |> Enum.map(&String.to_integer/1)
      |> Enum.reverse()

    sum =
      digits
      |> Enum.with_index()
      |> Enum.reduce(0, fn {d, i}, acc ->
        if rem(i, 2) == 1 do
          doubled = d * 2
          acc + if doubled > 9, do: doubled - 9, else: doubled
        else
          acc + d
        end
      end)

    rem(sum, 10) == 0
  end

  defp replace_money(text) do
    matches = Regex.scan(@amount, text, return: :index)

    {pieces, last, count} =
      Enum.reduce(matches, {[], 0, 0}, fn [{start, len}], {acc, cursor, n} ->
        if money_context?(text, start, len) do
          before = binary_part(text, cursor, start - cursor)
          {["[REDACTED: financial]", before | acc], start + len, n + 1}
        else
          {acc, cursor, n}
        end
      end)

    tail = binary_part(text, last, byte_size(text) - last)
    {[tail | pieces] |> Enum.reverse() |> IO.iodata_to_binary(), count}
  end

  defp money_context?(text, start, len) do
    from = max(start - @money_window, 0)
    to = min(start + len + @money_window, byte_size(text))
    window = binary_part(text, from, to - from)
    Regex.match?(@money_context, window)
  end
end
