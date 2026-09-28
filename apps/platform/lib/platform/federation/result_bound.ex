defmodule Platform.Federation.ResultBound do
  @moduledoc """
  Size bounds for federated tool results (task 01a049de).

  An MCP tool result is spent out of the calling agent's context window. Before
  this module the tool surface had no transport-level ceiling: `task_list` on a
  805-task project serialized to 1,054,017 bytes and `review_item_list` on a
  gate holding 258 superseded requests to 1,518,186 bytes. Neither call is
  unusual, and neither could be made safely.

  Three separate bounds, applied at three different places, because they answer
  three different questions:

    1. **Per-field text truncation** (`snippet/2`) — a list row carries a
       *preview* of its long prose, never the whole thing. Applied by the
       individual tool head, because only the head knows which fields are prose
       and which are identity.

    2. **Per-call record limits** (`page/2`) — `limit`/`offset` on the list
       heads. Deterministic, caller-controlled, and reported back so a caller
       can page rather than guess.

    3. **A whole-payload backstop** (`fit/2`) — a hard byte ceiling applied at
       the transport boundary to *every* tool, including ones nobody has
       audited yet. This is the bound that makes "the MCP surface cannot flood
       a context window" a property of the transport rather than a property of
       each of the ~98 handlers remembering to be careful.

  ## Why the backstop drops structure instead of slicing the string

  The obvious implementation — `String.slice(Jason.encode!(data), 0, cap)` — is
  worse than no cap at all. It cuts mid-token, so the result stops being JSON
  and the caller gets a parse error instead of a short answer. Every bound here
  operates on the Elixir term and re-encodes, so the output is valid JSON by
  construction, at every size, including the degenerate case where nothing
  fits. `Platform.Federation.ToolSurface`'s `memory_search` bound established
  this shape; this module generalizes it.
  """

  require Logger

  # The transport backstop. Deliberately well under the 500_000-character
  # ceiling `anthropic/maxResultSizeChars` allows: that field is an *escape
  # hatch to permit larger results*, not a cap, and declaring the ceiling would
  # raise the client's own default rather than lower it. 100 KB is roughly
  # 25_000 tokens — about one page of an agent's budget for one tool call.
  @max_result_bytes 100_000

  # Default preview length for a prose field in a LIST result. The full value
  # stays reachable through the per-record getter (`task_get`, `plan_get`,
  # `review_request_get`), which is the point of truncating here rather than
  # dropping the field: a caller that reads `description` still gets a string.
  @snippet_chars 500

  @default_limit 50
  @max_limit 500

  def max_result_bytes, do: @max_result_bytes
  def snippet_chars, do: @snippet_chars
  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  @doc """
  Truncate one prose field on a record, leaving an explicit marker.

  Returns the map with `field` sliced to `chars` graphemes plus two sibling
  keys — `<field>_truncated` (boolean) and `<field>_length` (the ORIGINAL byte
  size). Both are always present, so "this is the whole value" and "this is a
  preview" are distinguishable without comparing lengths by hand.

  A short value is returned untouched apart from the two markers, and
  `<field>_truncated` is `false`. That is the positive-control case: normal
  small responses must keep carrying their fields intact.
  """
  def snippet(record, field, chars \\ @snippet_chars)

  def snippet(record, field, chars) when is_map(record) and is_atom(field) do
    case Map.get(record, field) do
      value when is_binary(value) ->
        sliced = String.slice(value, 0, chars)

        record
        |> Map.put(field, sliced)
        |> Map.put(:"#{field}_truncated", byte_size(sliced) < byte_size(value))
        |> Map.put(:"#{field}_length", byte_size(value))

      _ ->
        record
    end
  end

  @doc """
  Resolve `limit`/`offset` from an MCP arguments map.

  `limit` defaults to `#{@default_limit}` and is clamped to `#{@max_limit}`; a
  caller asking for more than the maximum gets the maximum rather than a
  refusal, because a refusal here would break a caller that was previously
  served an unbounded list. Garbage (a string, a negative, a float) falls back
  to the default rather than raising.
  """
  def page(args, default \\ @default_limit) when is_map(args) do
    {coerce_limit(Map.get(args, "limit"), default), coerce_offset(Map.get(args, "offset"))}
  end

  defp coerce_limit(nil, default), do: default
  defp coerce_limit(n, _default) when is_integer(n) and n > 0, do: min(n, @max_limit)

  defp coerce_limit(n, default) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} -> coerce_limit(parsed, default)
      _ -> default
    end
  end

  defp coerce_limit(_, default), do: default

  defp coerce_offset(n) when is_integer(n) and n >= 0, do: n

  defp coerce_offset(n) when is_binary(n) do
    case Integer.parse(n) do
      {parsed, ""} -> coerce_offset(parsed)
      _ -> 0
    end
  end

  defp coerce_offset(_), do: 0

  @doc """
  Build a paged list envelope: `rows` under `rows_key`, plus `total` and
  `has_more` (task 01a04a7a).

  `total` is the size of the whole corpus the page was cut from, as counted by
  the caller (a real `SELECT count(*)`, or the length of the full in-memory
  list) — never inferred from the page. `has_more` is
  `offset + length(rows) < total`, NEVER `length(rows) == limit`: the cheap
  form reports "more" on a corpus of exactly `limit` and sends the caller to
  fetch an empty page.

  `extra` carries the head's other keys (`limit`, `offset`, `filters`,
  `count`, ...). `total` and `has_more` are merged LAST, so a caller-supplied
  key of the same name can never override them.
  """
  def paged(rows_key, rows, total, offset, extra \\ %{})
      when is_list(rows) and is_integer(total) and total >= 0 and is_integer(offset) and
             offset >= 0 and is_map(extra) do
    Map.merge(extra, %{rows_key => rows, total: total, has_more: offset + length(rows) < total})
  end

  @doc """
  Build a list envelope for a head that provably returns EVERYTHING it read:
  `total` is `length(rows)` and `has_more` is `false`.

  Only correct where nothing between the read and the response drops rows. A
  head that pages, caps (`LIMIT n`), or filters after counting must use
  `paged/5` with a real total instead. Like `paged/5`, `total` and `has_more`
  win over any same-named key in `extra`.
  """
  def whole(rows_key, rows, extra \\ %{}) when is_list(rows) and is_map(extra) do
    Map.merge(extra, %{rows_key => rows, total: length(rows), has_more: false})
  end

  @doc """
  Whole-payload backstop: shrink `data` until it encodes to at most
  `max_bytes`.

  Returns `{:ok, json}` when the payload already fits, or
  `{:truncated, json, note}` when records had to be dropped — `note` is a
  human-readable sentence naming how many were dropped and how to get them.

  Shrinking is structural, never textual:

    * a bare list drops elements from the TAIL;
    * a map carrying a list under `:items` or `"items"` — or under its only
      list-valued key — drops from that list's tail and keeps every sibling
      key (so a `count` or `total` sibling still reports the true total);
    * anything else that is already too large is returned whole with a note,
      because there is no safe generic way to shrink an opaque map and a
      truthful oversized answer beats a corrupted one.

  In every branch the returned string is `Jason.encode!` output for a real
  term, so it parses.
  """
  def fit(data, max_bytes \\ @max_result_bytes) do
    json = Jason.encode!(data)

    if byte_size(json) <= max_bytes do
      {:ok, json}
    else
      shrink(data, max_bytes, json)
    end
  end

  defp shrink(data, max_bytes, original_json) when is_list(data) do
    kept = drop_to_fit(data, &Jason.encode!/1, max_bytes)
    dropped = length(data) - length(kept)

    finish(kept, dropped, length(data), max_bytes, original_json)
  end

  defp shrink(data, max_bytes, original_json) when is_map(data) and not is_struct(data) do
    case items_key(data) do
      nil ->
        {:truncated, original_json, oversize_note(byte_size(original_json), max_bytes)}

      key ->
        items = Map.fetch!(data, key)
        kept = drop_to_fit(items, &Jason.encode!(Map.put(data, key, &1)), max_bytes)
        dropped = length(items) - length(kept)

        shrunk =
          data
          |> Map.put(key, kept)
          |> mark_has_more(dropped)

        finish(shrunk, dropped, length(items), max_bytes, original_json)
    end
  end

  defp shrink(_data, max_bytes, original_json),
    do: {:truncated, original_json, oversize_note(byte_size(original_json), max_bytes)}

  # If the envelope carries a `has_more` flag and the backstop just dropped
  # records, the flag must be TRUE — records the caller asked for are not in
  # this payload, whoever removed them.
  #
  # Without this the backstop can turn a truthful flag into a lie, and only on
  # the last page: `task_list` computes `has_more` from a database count, so
  # the final page of a corpus correctly reports `false`; if that page is then
  # too large and gets shrunk here, `false` becomes a claim that the dropped
  # records do not exist. That is the exact failure this whole ticket is
  # about — a silently short list — reintroduced one layer lower.
  #
  # Only ever raises the flag, never lowers it, and only when something was
  # actually dropped.
  defp mark_has_more(data, 0), do: data

  defp mark_has_more(data, _dropped) do
    cond do
      Map.has_key?(data, :has_more) -> Map.put(data, :has_more, true)
      Map.has_key?(data, "has_more") -> Map.put(data, "has_more", true)
      true -> data
    end
  end

  # Which key holds the records this map is a list OF.
  #
  # `:items` / `"items"` first, by name. Failing that, the SOLE list-valued
  # key: a map with exactly one list in it is unambiguously a list result
  # wearing an envelope, and shrinking that list is the only shrink available.
  # Task 01a04a7a's `task_list` envelope is `%{tasks:, total:, limit:,
  # offset:, has_more:}` — before this fallback the backstop could not shrink
  # it at all and would have returned an over-cap payload whole, which is the
  # exact failure `fit/2` exists to prevent, and a REGRESSION against the bare
  # array the envelope replaced.
  #
  # Two or more list-valued keys returns nil rather than guessing. A wrong
  # guess silently deletes records from whichever list the author cared about
  # least, and a truthful oversized answer beats a quietly wrong one.
  defp items_key(data) do
    cond do
      is_list(Map.get(data, :items)) -> :items
      is_list(Map.get(data, "items")) -> "items"
      true -> sole_list_key(data)
    end
  end

  defp sole_list_key(data) do
    case Enum.filter(data, fn {_k, v} -> is_list(v) end) do
      [{key, _value}] -> key
      _ -> nil
    end
  end

  # Binary search would be faster, but a linear halving keeps the "kept is
  # always a prefix of the input" property obvious, which is what makes the
  # result interpretable — a caller can re-request from `offset + length(kept)`.
  defp drop_to_fit([], _encode, _max_bytes), do: []

  defp drop_to_fit(items, encode, max_bytes) do
    if byte_size(encode.(items)) <= max_bytes do
      items
    else
      drop_to_fit(Enum.take(items, div(length(items), 2)), encode, max_bytes)
    end
  end

  defp finish(_shrunk, 0, _total, _max_bytes, original_json), do: {:ok, original_json}

  defp finish(shrunk, dropped, total, _max_bytes, _original_json) do
    Logger.warning(
      "federation tool result exceeded #{@max_result_bytes} bytes; dropped #{dropped} of #{total} records"
    )

    note =
      "NOTE: this result was truncated by the server to stay under " <>
        "#{@max_result_bytes} bytes. #{dropped} of #{total} records were dropped from the end. " <>
        "Re-request with `offset` to page through the rest, or narrow the filters."

    {:truncated, Jason.encode!(shrunk), note}
  end

  defp oversize_note(size, max_bytes) do
    "NOTE: this result is #{size} bytes, over the #{max_bytes}-byte server limit, " <>
      "and has no list the server could safely shorten. It was returned whole. " <>
      "Prefer a narrower call."
  end
end
