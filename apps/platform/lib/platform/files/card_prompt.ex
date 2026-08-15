defmodule Platform.Files.CardPrompt do
  @moduledoc """
  Prompt template + response parsing for the catalog-card LLM pass
  (task 01a0008c stage 2).

  Separated from `Platform.Files.Cataloger` for the same reason
  `Platform.Meetings.SummaryPrompt` is separated from
  `Platform.Meetings.Summarizer`: prompt quality iterates on a
  different clock from pipeline plumbing, and the parsing rules below
  are worth testing without standing up a file, a project and a wiki.

  ## Why the sibling list exists

  One pass sees one document. Asked "what does this supersede?" with
  nothing but that document in front of it, a model answers from the
  filename and confabulates a target — the failure this task's design
  canvas is built around (`…(Order Form).pdf` vs
  `…(Order Form) v1.3.pdf`).

  So the pass is handed a compact roster of its siblings, filenames
  and dates only, ~20 tokens a row. It is told to name a supersession
  target **verbatim from that roster or not at all**, and
  `resolve_supersession/2` then re-checks the answer against the same
  roster. An unresolvable name is dropped, not written. Dropping a
  true claim costs a missing edge that the nightly corpus pass can
  still find; writing a false one costs a dangling reference in a
  catalog whose entire value is being trustworthy.

  Ids are deliberately absent from the roster: a UUID costs more
  tokens than the filename and date together, and matching on the
  string the model was shown is a stricter check than matching on a
  string it was asked to copy.
  """

  @supersedes_marker "SUPERSEDES:"
  @none_tokens ~w(none n/a nil null nothing -)

  @doc """
  System prompt for the per-document card pass.

  Targets ~200 tokens of output: what the document is, its author,
  date and type, the questions it answers, and whether it reads as
  authoritative or historical.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are a librarian writing a catalog card for a single document. The card is read by other agents deciding whether this document is worth opening — it replaces the document in their context, so it must be honest about what the document does and does not settle.

    ## Output format

    Write 4-6 sentences of plain prose, about 150-200 words, covering:

    - What the document is, and what type (contract, order form, brief, spec, invoice, notes, …)
    - Who wrote it and when, if the document says so. If it does not say, say that rather than guessing.
    - What questions a reader could answer by opening it
    - Whether it reads as authoritative (the current statement of its subject) or historical (superseded, draft, or a point-in-time record)

    Then, as the FINAL line and nothing after it:

    #{@supersedes_marker} <exact filename from the sibling list>

    or, when this document supersedes nothing:

    #{@supersedes_marker} none

    ## Rules

    - Do not mention supersession anywhere in the prose. The final line is the only place it belongs.
    - The filename on the final line must be copied character-for-character from the sibling list you were given. A name that is not on that list will be discarded, so guessing costs you the claim.
    - Claim supersession only when this document plainly replaces a specific sibling — a later revision of the same instrument, a v2 of the same v1. Two documents about the same subject are not a supersession. When unsure, answer none.
    - Do not fabricate an author, a date or a party that the document does not state.
    - No headings, no bullet points, no preamble. Prose, then the final line.
    """
  end

  @doc """
  Renders the user message: the sibling roster, then the document.

  `siblings` is a list of `%{filename: String.t(), date: String.t()}`
  maps. `text` is the extracted document body, already truncated by
  the caller.
  """
  @spec user_message(String.t(), String.t(), [map()]) :: String.t()
  def user_message(filename, text, siblings) do
    """
    Sibling documents in this project (filename — date):
    #{render_siblings(siblings)}

    The document to catalog is "#{filename}". Its text follows.

    ---
    #{text}
    """
  end

  @doc """
  Renders the sibling roster — filenames and dates, nothing else.

  An empty roster still renders a line, so the model is told plainly
  that it has no siblings rather than being handed a blank where a
  list was promised. A single-document project claiming supersession
  is exactly the confabulation this guards.
  """
  @spec render_siblings([map()]) :: String.t()
  def render_siblings([]), do: "(none — this is the only catalogable document in the project)"

  def render_siblings(siblings) when is_list(siblings) do
    Enum.map_join(siblings, "\n", fn %{filename: name, date: date} ->
      "- #{name} — #{date}"
    end)
  end

  @doc """
  Splits a raw completion into `{prose, raw_supersession_claim}`.

  `raw_supersession_claim` is nil when the model omitted the marker
  line or answered with one of the none-tokens. The marker line is
  stripped from the prose either way: a card body must never carry
  the machine-readable line, resolved or not.

  Only the LAST marker line counts. A model that mentions the marker
  mid-prose despite being told not to gets that line stripped too,
  which is the conservative reading — a stray marker is noise, and
  the format says the real answer is last.
  """
  @spec split_response(String.t()) :: {String.t(), String.t() | nil}
  def split_response(raw) when is_binary(raw) do
    lines = String.split(raw, "\n")

    {kept, claims} =
      Enum.reduce(lines, {[], []}, fn line, {kept, claims} ->
        case marker_value(line) do
          nil -> {[line | kept], claims}
          value -> {kept, [value | claims]}
        end
      end)

    prose =
      kept
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim()

    {prose, List.first(claims) |> normalize_claim()}
  end

  @doc """
  Resolves a raw supersession claim against the sibling roster.

  Returns `{:ok, sibling}` only when the claim matches exactly one
  sibling. Everything else — no claim, no match, or an ambiguous
  match across two identically-named siblings — returns
  `{:error, reason}` and the caller drops the claim.

  Matching is case-insensitive and whitespace-trimmed, and tolerates
  a model that wrapped the name in quotes or backticks. It is
  deliberately not fuzzy beyond that: "close enough" on a filename is
  how a v1.3 order form gets recorded as superseding the wrong
  contract.
  """
  @spec resolve_supersession(String.t() | nil, [map()]) ::
          {:ok, map()} | {:error, :no_claim | :unresolvable | :ambiguous}
  def resolve_supersession(nil, _siblings), do: {:error, :no_claim}

  def resolve_supersession(claim, siblings) when is_binary(claim) and is_list(siblings) do
    needle = normalize_for_match(claim)

    case Enum.filter(siblings, &(normalize_for_match(&1.filename) == needle)) do
      [one] -> {:ok, one}
      [] -> {:error, :unresolvable}
      _many -> {:error, :ambiguous}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp marker_value(line) do
    trimmed = String.trim(line)

    if String.starts_with?(String.upcase(trimmed), @supersedes_marker) do
      trimmed
      |> String.slice(String.length(@supersedes_marker)..-1//1)
      |> String.trim()
    end
  end

  defp normalize_claim(nil), do: nil

  defp normalize_claim(value) do
    stripped = strip_wrappers(value)

    if stripped == "" or String.downcase(stripped) in @none_tokens do
      nil
    else
      stripped
    end
  end

  defp strip_wrappers(value) do
    value
    |> String.trim()
    |> String.trim("\"")
    |> String.trim("'")
    |> String.trim("`")
    |> String.trim()
  end

  defp normalize_for_match(value) do
    value
    |> strip_wrappers()
    |> String.downcase()
  end
end
