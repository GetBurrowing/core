defmodule Platform.Social.Transcript do
  @moduledoc """
  Parses an episode transcript into timed segments with word times (task
  01a140a9-69b7, Social 5/7). Pure: no DB, no process.

      parse(binary, :vtt | :srt | :json) ::
        {:ok, [%{start_s, end_s, text, speaker, words: [%{w, start_s, end_s}]}]}
        | {:error, readable}

  ## Formats

    * **VTT.** Plain cues, `<v Speaker>` voice tags, and YouTube's
      auto-generated subtitles: those carry inline word timings
      (`word<00:00:01.234><c> next</c>`) and ROLL, repeating the previous
      line at the top of every cue plus 10 ms "hold" cues that repeat it
      again. When a file has inline timings only the timed lines are new
      speech, so only those are kept; without them, a cue whose first line
      repeats the previous cue's last line drops that line.
    * **SRT.** Numbered cues with `,` millisecond separators.
    * **JSON.** A list of `{start, end, text, speaker?}` (the HTC transcripts
      shape, also accepted wrapped as `{"segments": [...]}`) or
      youtube-transcript-api's `{text, start, duration}`. A segment may carry
      its own `words` (`[{word | w | text, start, end}]`). YouTube's caption
      segments overlap (each runs until the NEXT line finishes), so a
      segment's end is clamped to the next segment's start.

  Cues and segments without word times get them interpolated across the cue
  by each word's share of the cue's characters.
  """

  @type word :: %{w: String.t(), start_s: float(), end_s: float()}
  @type segment :: %{
          start_s: float(),
          end_s: float(),
          text: String.t(),
          speaker: String.t() | nil,
          words: [word()]
        }

  @doc "Parses a transcript of the given format."
  @spec parse(binary(), :vtt | :srt | :json) :: {:ok, [segment()]} | {:error, String.t()}
  def parse(binary, format) when is_binary(binary) do
    binary = strip_bom(binary)

    result =
      case format do
        :vtt -> parse_vtt(binary)
        :srt -> parse_srt(binary)
        :json -> parse_json(binary)
        other -> {:error, "unsupported transcript format #{inspect(other)}; use VTT, SRT or JSON"}
      end

    case result do
      {:ok, []} -> {:error, "the #{label(format)} transcript has no timed text"}
      other -> other
    end
  end

  def parse(_binary, _format), do: {:error, "the transcript is not text"}

  @doc """
  The format for a transcript file from its content type and file name:
  `{:ok, :vtt | :srt | :json}` or `{:error, readable}`.
  """
  @spec format_for(String.t() | nil, String.t() | nil) ::
          {:ok, :vtt | :srt | :json} | {:error, String.t()}
  def format_for(content_type, filename) do
    type = content_type |> to_string() |> String.split(";") |> hd() |> String.trim()
    ext = filename |> to_string() |> Path.extname() |> String.downcase()

    cond do
      type == "text/vtt" or ext == ".vtt" -> {:ok, :vtt}
      type in ["application/x-subrip", "text/srt"] or ext == ".srt" -> {:ok, :srt}
      type == "application/json" or ext == ".json" -> {:ok, :json}
      true -> {:error, "the transcript must be a VTT, SRT or JSON file; got #{filename || type}"}
    end
  end

  defp label(:vtt), do: "VTT"
  defp label(:srt), do: "SRT"
  defp label(:json), do: "JSON"
  defp label(other), do: to_string(other)

  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(binary), do: binary

  # ── VTT ──────────────────────────────────────────────────────────────

  @arrow ~r/^\s*(\S+)\s+-->\s+(\S+)/

  defp parse_vtt(binary) do
    blocks = blocks(binary)

    case blocks do
      [first | _] ->
        if String.starts_with?(String.trim_leading(first), "WEBVTT"),
          do: vtt_cues(tl(blocks)),
          else: {:error, "not a VTT transcript: it must start with WEBVTT"}

      [] ->
        {:error, "the VTT transcript is empty"}
    end
  end

  defp vtt_cues(blocks) do
    cues =
      blocks
      |> Enum.reject(&(String.starts_with?(&1, "NOTE") or String.starts_with?(&1, "STYLE")))
      |> rejoin()
      |> Enum.flat_map(&cue(&1, "."))

    if Enum.any?(cues, & &1.inline?), do: {:ok, youtube_cues(cues)}, else: {:ok, plain_cues(cues)}
  end

  # YouTube auto-subs: only the lines carrying inline word timings are new
  # speech; the rest repeat what is already on screen.
  defp youtube_cues(cues) do
    cues
    |> Enum.flat_map(fn cue ->
      cue.lines
      |> Enum.filter(&String.contains?(&1, "<"))
      |> Enum.filter(&Regex.match?(~r/<\d[\d:.]*>/, &1))
      |> Enum.map(&inline_segment(&1, cue))
    end)
    |> Enum.reject(&(&1.words == []))
  end

  defp inline_segment(line, cue) do
    # "first<00:00:01.234><c> second</c><00:00:01.500><c> third</c>"
    parts = Regex.split(~r/<(\d[\d:.]*)>/, line, include_captures: true)

    {words, _} =
      Enum.reduce(parts, {[], cue.start_s}, fn part, {acc, at} ->
        case Regex.run(~r/^<(\d[\d:.]*)>$/, part) do
          [_, ts] ->
            {acc, timestamp(ts, ".") || at}

          nil ->
            new = part |> clean() |> String.split(~r/\s+/, trim: true)
            {acc ++ Enum.map(new, &{&1, at}), at}
        end
      end)

    timed =
      words
      |> Enum.with_index()
      |> Enum.map(fn {{w, start}, i} ->
        next_start =
          case Enum.at(words, i + 1) do
            {_, s} when s > start -> s
            _ -> nil
          end

        %{w: w, start_s: start, end_s: next_start || max(cue.end_s, start)}
      end)
      |> spread_ties()

    %{
      start_s: cue.start_s,
      end_s: cue.end_s,
      text: Enum.map_join(timed, " ", & &1.w),
      speaker: cue.speaker,
      words: timed
    }
  end

  # Words that share a start time (no inline stamp between them) split the
  # span up to the next distinct time by character share.
  defp spread_ties(words) do
    words
    |> Enum.chunk_by(& &1.start_s)
    |> Enum.flat_map(fn
      [single] ->
        [single]

      [first | _] = group ->
        interpolate(Enum.map(group, & &1.w), first.start_s, List.last(group).end_s)
    end)
  end

  defp plain_cues(cues) do
    {segments, _} =
      Enum.reduce(cues, {[], nil}, fn cue, {acc, prev_last} ->
        lines =
          case cue.lines do
            [first | rest] when rest != [] and first == prev_last -> rest
            [only] when only == prev_last -> []
            lines -> lines
          end

        text = lines |> Enum.join(" ") |> clean()
        last = List.last(cue.lines)

        if text == "" do
          {acc, last}
        else
          {[segment(cue.start_s, cue.end_s, text, cue.speaker) | acc], last}
        end
      end)

    Enum.reverse(segments)
  end

  defp cue(block, ms_sep) do
    lines = String.split(block, "\n")
    {timing, text_lines} = split_timing(lines)

    with [timing_line] <- timing,
         [_, a, b] <- Regex.run(@arrow, timing_line),
         start when is_float(start) <- timestamp(a, ms_sep),
         stop when is_float(stop) <- timestamp(b, ms_sep),
         true <- stop >= start do
      {speaker, text_lines} = voice(text_lines)

      [
        %{
          start_s: start,
          end_s: stop,
          lines: Enum.map(text_lines, &String.trim/1) |> Enum.reject(&(&1 == "")),
          speaker: speaker,
          inline?: Enum.any?(text_lines, &Regex.match?(~r/<\d[\d:.]*>/, &1))
        }
      ]
    else
      _ -> []
    end
  end

  defp split_timing(lines) do
    case Enum.find_index(lines, &String.contains?(&1, "-->")) do
      nil -> {[], []}
      i -> {[Enum.at(lines, i)], Enum.drop(lines, i + 1)}
    end
  end

  defp voice([first | rest] = lines) do
    case Regex.run(~r/^<v(?:\.[^ >]*)?\s+([^>]+)>(.*)$/, first) do
      [_, name, text] -> {String.trim(name), [text | rest]}
      nil -> {nil, lines}
    end
  end

  defp voice([]), do: {nil, []}

  # ── SRT ──────────────────────────────────────────────────────────────

  defp parse_srt(binary) do
    cues = binary |> blocks() |> rejoin() |> Enum.flat_map(&cue(&1, ","))

    if cues == [] and String.trim(binary) != "" do
      {:error, "not an SRT transcript: no `00:00:01,000 --> 00:00:02,000` cue lines"}
    else
      {:ok, plain_cues(cues)}
    end
  end

  defp blocks(binary) do
    binary
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split(~r/\n\n+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # A cue's text can itself contain a blank (or whitespace-only) line, which
  # YouTube's auto-subs do on every cue: a block with no timing line belongs
  # to the cue before it.
  defp rejoin(blocks) do
    blocks
    |> Enum.reduce([], fn block, acc ->
      case acc do
        [prev | rest] ->
          if String.contains?(block, "-->"),
            do: [block | acc],
            else: [prev <> "\n" <> block | rest]

        [] ->
          [block]
      end
    end)
    |> Enum.reverse()
  end

  # "01:02:03.456", "02:03.456", "01:02:03,456"
  defp timestamp(ts, ms_sep) do
    ts = String.replace(ts, ms_sep, ".")

    case String.split(ts, ":") do
      [h, m, s] -> with_parts([h, m, s])
      [m, s] -> with_parts(["0", m, s])
      _ -> nil
    end
  end

  defp with_parts([h, m, s]) do
    with {h, ""} <- Integer.parse(h),
         {m, ""} <- Integer.parse(m),
         {s, ""} <- Float.parse(s) do
      h * 3600 + m * 60 + s * 1.0
    else
      _ -> nil
    end
  end

  # ── JSON ─────────────────────────────────────────────────────────────

  defp parse_json(binary) do
    case Jason.decode(binary) do
      {:ok, %{"segments" => list}} when is_list(list) -> json_segments(list)
      {:ok, list} when is_list(list) -> json_segments(list)
      {:ok, _} -> {:error, "the JSON transcript must be a list of {start, end, text} segments"}
      {:error, _} -> {:error, "the JSON transcript is not valid JSON"}
    end
  end

  defp json_segments(list) do
    rows = Enum.map(list, &json_row/1)

    case Enum.find_index(rows, &match?({:error, _}, &1)) do
      nil ->
        rows = rows |> Enum.map(fn {:ok, row} -> row end) |> Enum.sort_by(& &1.start_s)
        {:ok, rows |> clamp_overlaps() |> Enum.map(&json_segment/1)}

      i ->
        {:error, msg} = Enum.at(rows, i)
        {:error, "JSON transcript segment #{i + 1}: #{msg}"}
    end
  end

  defp json_row(%{"start" => start, "text" => text} = row) when is_number(start) do
    stop =
      cond do
        is_number(row["end"]) -> row["end"] * 1.0
        is_number(row["duration"]) -> start + row["duration"] * 1.0
        true -> nil
      end

    cond do
      not is_binary(text) ->
        {:error, "text must be a string"}

      is_nil(stop) ->
        {:error, "needs an end or a duration"}

      stop < start ->
        {:error, "ends before it starts"}

      true ->
        {:ok,
         %{
           start_s: start * 1.0,
           end_s: stop,
           text: text,
           speaker: speaker(row),
           words: row["words"]
         }}
    end
  end

  defp json_row(_), do: {:error, "needs a numeric start and a text"}

  defp speaker(%{"speaker" => s}) when is_binary(s) and s != "", do: s
  defp speaker(_), do: nil

  defp clamp_overlaps(rows) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, i} ->
      case Enum.at(rows, i + 1) do
        %{start_s: next} when next > row.start_s and next < row.end_s -> %{row | end_s: next}
        _ -> row
      end
    end)
  end

  defp json_segment(%{words: words} = row) when is_list(words) and words != [] do
    timed =
      for w <- words,
          is_map(w),
          text = w["word"] || w["w"] || w["text"],
          is_binary(text),
          is_number(w["start"]) and is_number(w["end"]) do
        %{w: String.trim(text), start_s: w["start"] * 1.0, end_s: w["end"] * 1.0}
      end

    if timed == [],
      do: segment(row.start_s, row.end_s, row.text, row.speaker),
      else: %{segment(row.start_s, row.end_s, row.text, row.speaker) | words: timed}
  end

  defp json_segment(row), do: segment(row.start_s, row.end_s, row.text, row.speaker)

  # ── Shared ───────────────────────────────────────────────────────────

  defp segment(start, stop, text, speaker) do
    text = clean(text)
    words = String.split(text, ~r/\s+/, trim: true)

    %{
      start_s: start,
      end_s: stop,
      text: text,
      speaker: speaker,
      words: interpolate(words, start, stop)
    }
  end

  @doc false
  # Word times by each word's share of the characters (a trailing space
  # counted per word so one-letter words still get time).
  def interpolate([], _start, _stop), do: []

  def interpolate(words, start, stop) do
    weights = Enum.map(words, &(String.length(&1) + 1))
    total = Enum.sum(weights)
    span = max(stop - start, 0.0)

    {timed, _} =
      words
      |> Enum.zip(weights)
      |> Enum.map_reduce(start * 1.0, fn {w, weight}, at ->
        stop_at = at + span * weight / total
        {%{w: w, start_s: round3(at), end_s: round3(stop_at)}, stop_at}
      end)

    # The last word ends exactly at the cue end, whatever the rounding did.
    List.update_at(timed, -1, &%{&1 | end_s: stop * 1.0})
  end

  defp round3(x), do: Float.round(x * 1.0, 3)

  @entities [
    {"&amp;", "&"},
    {"&lt;", "<"},
    {"&gt;", ">"},
    {"&quot;", "\""},
    {"&#39;", "'"},
    {"&apos;", "'"},
    {"&nbsp;", " "}
  ]

  defp clean(text) do
    text = Regex.replace(~r/<[^>]*>/, text, "")
    text = Enum.reduce(@entities, text, fn {e, c}, acc -> String.replace(acc, e, c) end)

    # YouTube captions mark a change of speaker with a bare ">>"; it is not
    # speech and must not be burned into a caption.
    text
    |> String.replace(~r/(^|\s)>>(?=\s|$)/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
