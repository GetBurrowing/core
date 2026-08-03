defmodule PlatformTest.ICSContentLines do
  @moduledoc """
  A parser over the RFC 5545 **content-line grammar**, for the assertions
  `ICalendar.from_ics/1` structurally cannot make.

  ## Why this exists alongside a real parser

  `ICalendar.from_ics/1` is the primary assertion tool for
  `Platform.Meetings.CalendarFeed` — it unfolds lines, unescapes TEXT
  values and hands back `%ICalendar.Event{}` structs. But it parses only
  `VEVENT` blocks and discards everything else, so it **cannot see
  calendar-level properties at all**: `METHOD`, `PRODID`, `VERSION` and
  `CALSCALE` are invisible to it. It also never exposes `DTSTAMP`
  (`:modified` is `LAST-MODIFIED`), and it unescapes destructively —
  `desanitized/1` strips every backslash, so an escaped value cannot be
  distinguished from an unescaped one that happened to contain the same
  characters.

  The tempting substitute is `assert body =~ "METHOD:PUBLISH"`. That is
  **forbidden in this task's tests** and this module is the reason it
  does not have to be used. A substring match passes on:

    * output that was never folded (so the assertion says nothing about
      a document long enough to need folding),
    * a `METHOD` misplaced *inside* the `VEVENT`, where it is illegal,
    * a `METHOD:PUBLISH` occurring inside a `SUMMARY` value.

  Parsing the grammar distinguishes all three.

  ## What it does

  1. Splits on CRLF, **strictly**. LF alone does not terminate a content
     line in RFC 5545, and this module does not pretend otherwise — that
     is deliberate, because `ICalendar.from_ics/1` *does* tolerate LF and
     the whole point of having both is that they disagree about it.
  2. Unfolds per §3.1: a line beginning with SPACE or HTAB continues the
     previous one, minus that single leading character.
  3. Splits each logical line into `{name, params, value}`, honouring
     DQUOTE around parameter values so a quoted `:` or `;` does not end
     the segment.

  Values are returned **raw** — still escaped exactly as emitted — so a
  test can assert on the escaped bytes. Use `ICalendar.from_ics/1` when
  you want the unescaped round-trip instead.
  """

  @enforce_keys [:name, :params, :value]
  defstruct [:name, :params, :value]

  @type t :: %__MODULE__{name: binary(), params: %{binary() => binary()}, value: binary()}

  @doc """
  Parse `body` into an ordered list of content lines.

  Property names are returned **verbatim**, not upcased. RFC 5545 makes
  names case-insensitive, but the renderer under test emits canonical
  uppercase and a test should be able to pin that.
  """
  @spec parse(binary()) :: [t()]
  def parse(body) when is_binary(body) do
    body
    |> physical_lines()
    |> unfold()
    |> Enum.map(&content_line/1)
  end

  @doc """
  The physical (still-folded) lines of `body`, trailing CRLF removed.

  Use this for octet-length assertions — after unfolding there is
  nothing left to measure.
  """
  @spec physical_lines(binary()) :: [binary()]
  def physical_lines(body) when is_binary(body) do
    # A well-formed document ends with CRLF, so the split always leaves a
    # trailing "". Anything else means the terminator is missing.
    {last, rest} = body |> String.split("\r\n") |> List.pop_at(-1)

    if last != "" do
      raise ArgumentError, "document does not end with CRLF; last segment: #{inspect(last)}"
    end

    rest
  end

  @doc "The ordered property names of `body_or_lines`."
  @spec names(binary() | [t()]) :: [binary()]
  def names(body_or_lines), do: body_or_lines |> lines() |> Enum.map(& &1.name)

  @doc """
  The one content line named `name`, raising unless there is exactly one.

  "Exactly one" is part of the assertion: two `DTSTART` lines is a
  different bug from a missing one, and both should fail loudly.
  """
  @spec fetch_one!(binary() | [t()], binary()) :: t()
  def fetch_one!(body_or_lines, name) do
    case body_or_lines |> lines() |> Enum.filter(&(&1.name == name)) do
      [line] ->
        line

      other ->
        raise ArgumentError,
              "expected exactly one #{name} content line, found #{length(other)}: #{inspect(other)}"
    end
  end

  @doc "The raw (still-escaped) value of the one content line named `name`."
  @spec value!(binary() | [t()], binary()) :: binary()
  def value!(body_or_lines, name), do: fetch_one!(body_or_lines, name).value

  defp lines(body) when is_binary(body), do: parse(body)
  defp lines(lines) when is_list(lines), do: lines

  # RFC 5545 §3.1 unfolding.
  defp unfold(physical_lines) do
    physical_lines
    |> Enum.reduce([], fn
      <<continuation, rest::binary>>, [previous | earlier] when continuation in [?\s, ?\t] ->
        [previous <> rest | earlier]

      <<continuation, _rest::binary>>, [] when continuation in [?\s, ?\t] ->
        raise ArgumentError, "document begins with a folded continuation line"

      line, acc ->
        [line | acc]
    end)
    |> Enum.reverse()
  end

  defp content_line(line) do
    {name_and_params, value} = split_at_colon(line)
    [name | params] = split_unquoted(name_and_params, ?;)

    %__MODULE__{name: name, params: Map.new(params, &param/1), value: value}
  end

  defp param(segment) do
    case String.split(segment, "=", parts: 2) do
      [key, value] -> {key, unquote_value(value)}
      [key] -> raise ArgumentError, "parameter #{inspect(key)} has no value"
    end
  end

  defp unquote_value(<<?", rest::binary>>) do
    case String.split(rest, ~s("), parts: 2) do
      [inner, ""] -> inner
      _ -> raise ArgumentError, "unterminated quoted parameter value"
    end
  end

  defp unquote_value(value), do: value

  # The value starts after the first colon that is not inside a quoted
  # parameter value. Scanning rather than `String.split/3` because a
  # SUMMARY may legitimately contain colons.
  defp split_at_colon(line), do: split_at_colon(line, [], false)

  defp split_at_colon(<<>>, acc, _quoted) do
    raise ArgumentError,
          "content line has no value separator: #{inspect(IO.iodata_to_binary(acc))}"
  end

  defp split_at_colon(<<?:, rest::binary>>, acc, false), do: {IO.iodata_to_binary(acc), rest}

  defp split_at_colon(<<?", rest::binary>>, acc, quoted),
    do: split_at_colon(rest, [acc, ?"], not quoted)

  defp split_at_colon(<<char::utf8, rest::binary>>, acc, quoted),
    do: split_at_colon(rest, [acc, <<char::utf8>>], quoted)

  defp split_unquoted(segment, separator), do: split_unquoted(segment, separator, [], [], false)

  defp split_unquoted(<<>>, _separator, current, done, _quoted),
    do: Enum.reverse([IO.iodata_to_binary(current) | done])

  defp split_unquoted(<<char, rest::binary>>, separator, current, done, false)
       when char == separator,
       do: split_unquoted(rest, separator, [], [IO.iodata_to_binary(current) | done], false)

  defp split_unquoted(<<?", rest::binary>>, separator, current, done, quoted),
    do: split_unquoted(rest, separator, [current, ?"], done, not quoted)

  defp split_unquoted(<<char::utf8, rest::binary>>, separator, current, done, quoted),
    do: split_unquoted(rest, separator, [current, <<char::utf8>>], done, quoted)
end
