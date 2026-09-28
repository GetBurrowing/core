defmodule Platform.Tasks.DeliverySweep.Matcher do
  @moduledoc """
  Pure matching logic for the delivered-but-open sweep (task 01a044b0),
  plus one read-only query that resolves an 8-hex id prefix.

  Nothing here calls GitHub and nothing here writes: no Repo insert,
  update or delete, and no `Platform.Tasks` write function (a source guard
  in `delivery_sweep_test.exs` enforces this). The module only answers "which task ids does this text name, and on what
  evidence".

  ## Id references

  A full UUID matches only when it is bounded on both sides by a
  character that is neither hex nor `-`, so a UUID embedded in a longer
  hex/hyphen run is not a reference. An 8-hex prefix matches only as a
  standalone token under the same boundary rule, which is what keeps a
  40-char sha, a 12-hex run, and the head of a full UUID from yielding a
  prefix.

  ## The prefix trap

  A prefix names a task ONLY when `resolve_prefix/1` returns
  `{:unique, id}`. On 2026-09-28 the prefix `019f9cb8` matched five tasks.
  The lookup spans every row of `tasks` (every status, every project,
  done, cancelled and soft-deleted alike), because a prefix shared by one
  open and one closed task is still ambiguous. There is no other route
  from a prefix to a full id, and an ambiguous set is never narrowed by
  picking its first or newest row.
  """

  import Ecto.Query, warn: false

  alias Platform.Repo
  alias Platform.Tasks.Task

  # Boundaries: neither hex nor hyphen on either side.
  @full_uuid ~r/(?<![0-9a-f-])([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?![0-9a-f-])/i
  @prefix ~r/(?<![0-9a-f-])([0-9a-f]{8})(?![0-9a-f-])/i
  @hex8 ~r/\A[0-9a-f]{8}\z/

  @code_span ~r/`([^`\n]+)`/
  @max_defect_tokens 5
  @min_token_length 6
  @evidence_cap 300

  @type id_references :: %{full: [String.t()], prefixes: [String.t()]}

  @doc """
  Task-id references in `text`: full UUIDs and standalone 8-hex prefixes,
  each downcased and deduplicated in order of first appearance. A prefix
  equal to the head of a full UUID found in the same text is dropped.
  """
  @spec id_references(String.t() | nil) :: id_references()
  def id_references(nil), do: %{full: [], prefixes: []}

  def id_references(text) when is_binary(text) do
    full = scan(@full_uuid, text)
    heads = MapSet.new(full, &binary_part(&1, 0, 8))
    prefixes = @prefix |> scan(text) |> Enum.reject(&MapSet.member?(heads, &1))

    %{full: full, prefixes: prefixes}
  end

  defp scan(regex, text) do
    regex
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [match] -> String.downcase(match) end)
    |> Enum.uniq()
  end

  @doc """
  Resolves an 8-hex prefix against ALL tasks.

  Returns `{:unique, task_id}` when exactly one task id starts with it,
  `{:ambiguous, ids}` when two or more do (the query stops at two rows,
  which is enough to prove ambiguity), and `:none` otherwise. Only
  `{:unique, _}` may be treated as a match.
  """
  @spec resolve_prefix(String.t()) ::
          {:unique, String.t()} | {:ambiguous, [String.t()]} | :none
  def resolve_prefix(hex8) when is_binary(hex8) do
    hex8 = String.downcase(hex8)

    # The pattern is validated as 8 hex characters, so it can carry no
    # LIKE wildcard (`%`, `_`) into the query.
    unless Regex.match?(@hex8, hex8) do
      raise ArgumentError,
            "resolve_prefix/1 expects exactly 8 hex characters, got: #{inspect(hex8)}"
    end

    Task
    |> where([t], fragment("?::text LIKE ?", t.id, ^(hex8 <> "%")))
    |> select([t], t.id)
    |> limit(2)
    |> Repo.all()
    |> case do
      [] -> :none
      [id] -> {:unique, id}
      ids -> {:ambiguous, Enum.sort(ids)}
    end
  end

  @doc """
  The first line of `text` that contains `needle` (case-insensitively),
  trimmed and capped at #{@evidence_cap} characters. `nil` when no line
  contains it.
  """
  @spec evidence_line(String.t() | nil, String.t()) :: String.t() | nil
  def evidence_line(nil, _needle), do: nil

  def evidence_line(text, needle) when is_binary(text) and is_binary(needle) do
    down_needle = String.downcase(needle)

    text
    |> String.split(~r/\r?\n/)
    |> Enum.find(&String.contains?(String.downcase(&1), down_needle))
    |> case do
      nil -> nil
      line -> line |> String.trim() |> String.slice(0, @evidence_cap)
    end
  end

  @doc """
  Up to #{@max_defect_tokens} code-like tokens from the backtick spans of a
  ticket description, in order of first appearance.

  Each span is trimmed, then a trailing `/N` arity and a trailing `()` are
  stripped. A token is kept only when it is at least #{@min_token_length}
  characters, contains no whitespace, is not a UUID or bare hex run, and
  looks like code: it contains `_`, `.` or `::`, or has an internal
  lowercase-to-uppercase (CamelCase) boundary.
  """
  @spec defect_tokens(String.t() | nil) :: [String.t()]
  def defect_tokens(nil), do: []

  def defect_tokens(description) when is_binary(description) do
    @code_span
    |> Regex.scan(description, capture: :all_but_first)
    |> Enum.map(fn [span] -> normalize_token(span) end)
    |> Enum.filter(&code_token?/1)
    |> Enum.uniq()
    |> Enum.take(@max_defect_tokens)
  end

  defp normalize_token(span) do
    span
    |> String.trim()
    |> String.replace(~r/\/\d+\z/, "")
    |> String.replace(~r/\(\)\z/, "")
  end

  defp code_token?(token) do
    String.length(token) >= @min_token_length and
      not String.match?(token, ~r/\s/) and
      not String.match?(token, ~r/\A[0-9a-f-]+\z/i) and
      (String.contains?(token, ["_", ".", "::"]) or String.match?(token, ~r/[a-z][A-Z]/))
  end
end
