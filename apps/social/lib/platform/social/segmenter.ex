defmodule Platform.Social.Segmenter do
  @moduledoc """
  Sentence segmentation, clip-boundary snapping and caption line breaking
  (task 01a140a9-69b7, Social 5/7). PURE: no DB, no process, no clock.

    * `sentences/1` turns `Platform.Social.Transcript` segments into
      sentences with word times. A sentence ends at a word ending in `.`,
      `?`, `!` or an ellipsis (optionally followed by a closing quote or
      bracket). Splitting is on whitespace first, so a decimal (`3.5`) or a
      time (`10:30`) is never a boundary; abbreviations (`Mr.`, `Dr.`,
      `e.g.`), dotted acronyms (`U.S.`) and single initials (`J.`) are not
      either. A change of speaker also ends a sentence.
    * `snap/4` moves an agent's requested clip to sentence boundaries.
    * `lines/2` breaks caption words into cards of at most two lines of 3-5
      words, never splitting a name or a number group.
  """

  @abbreviations ~w(mr mrs ms dr prof sr jr st vs etc e.g i.e a.m p.m no fig approx dept est inc ltd co corp mt ft)
  @magnitudes ~w(hundred thousand million billion trillion percent per cent k m bn % pm am)

  @type word :: %{w: String.t(), start_s: float(), end_s: float()}
  @type sentence :: %{
          start_s: float(),
          end_s: float(),
          text: String.t(),
          speaker: String.t() | nil,
          words: [word()]
        }

  # ── Sentences ────────────────────────────────────────────────────────

  @doc "Sentences from transcript segments (see the moduledoc for the rules)."
  @spec sentences([map()]) :: [sentence()]
  def sentences(segments) when is_list(segments) do
    words =
      for seg <- segments, w <- Map.get(seg, :words, []) do
        Map.put(w, :speaker, Map.get(seg, :speaker))
      end

    {done, current} =
      Enum.reduce(words, {[], []}, fn word, {done, current} ->
        {done, current} =
          case current do
            [prev | _] when prev.speaker != word.speaker -> {[current | done], []}
            _ -> {done, current}
          end

        current = [word | current]

        if sentence_end?(word.w), do: {[current | done], []}, else: {done, current}
      end)

    [current | done]
    |> Enum.reject(&(&1 == []))
    |> Enum.reverse()
    |> Enum.map(&to_sentence(Enum.reverse(&1)))
  end

  defp to_sentence([first | _] = words) do
    last = List.last(words)

    %{
      start_s: first.start_s,
      end_s: last.end_s,
      text: Enum.map_join(words, " ", & &1.w),
      speaker: first.speaker,
      words: Enum.map(words, &Map.delete(&1, :speaker))
    }
  end

  @doc "Whether a whitespace-delimited token ends a sentence."
  @spec sentence_end?(String.t()) :: boolean()
  def sentence_end?(token) do
    bare = String.replace(token, ~r/["'\)\]\x{201D}\x{2019}]+$/u, "")

    cond do
      String.ends_with?(bare, ["...", "…"]) -> true
      String.ends_with?(bare, ["?", "!"]) -> true
      String.ends_with?(bare, ".") -> not abbreviation?(bare)
      true -> false
    end
  end

  defp abbreviation?(token) do
    stem = token |> String.trim_trailing(".") |> String.trim_leading("(") |> String.downcase()

    stem in @abbreviations or
      Regex.match?(~r/^(\p{L}\.)+\p{L}$/u, stem) or
      Regex.match?(~r/^\p{Lu}$/u, String.trim_trailing(token, "."))
  end

  # ── Snap ─────────────────────────────────────────────────────────────

  @doc """
  Snaps a requested clip `[start_s, end_s]` to sentence boundaries.

  Options: `:tolerance_s` (default 3.0), `:min_s` (5), `:max_s` (600),
  `:duration_s` (the source's length; `nil` when unknown).

  The start moves to the nearest sentence START and the end to the nearest
  sentence END within the tolerance (inclusive). A side with no sentence
  boundary in tolerance falls back to the nearest word boundary (`snapped:
  :word`). The end never passes the source duration; a request past it is
  clamped first. The result never has `end <= start`, and its duration stays
  within `min_s..max_s`: a request outside those bounds, or one that
  snapping would invert or push out of them, is `{:error, :invalid_range}`.
  """
  @spec snap([sentence()], number(), number(), keyword()) ::
          {:ok, %{start_s: float(), end_s: float(), snapped: :sentence | :word}}
          | {:error, :invalid_range}
  def snap(sentences, start_s, end_s, opts \\ [])

  def snap(sentences, start_s, end_s, opts) when is_number(start_s) and is_number(end_s) do
    tol = Keyword.get(opts, :tolerance_s, 3.0) + 1.0e-9
    min_s = Keyword.get(opts, :min_s, 5)
    max_s = Keyword.get(opts, :max_s, 600)
    duration = Keyword.get(opts, :duration_s)

    start_s = max(start_s * 1.0, 0.0)
    end_s = clamp_end(end_s * 1.0, duration)
    words = Enum.flat_map(sentences, & &1.words)

    if end_s <= start_s or end_s - start_s < min_s or end_s - start_s > max_s do
      {:error, :invalid_range}
    else
      {new_start, start_kind} =
        nearest(Enum.map(sentences, & &1.start_s), start_s, tol)
        |> or_word(Enum.map(words, & &1.start_s), start_s)

      {new_end, end_kind} =
        nearest(Enum.map(sentences, & &1.end_s), end_s, tol)
        |> or_word(Enum.map(words, & &1.end_s), end_s)

      new_end = clamp_end(new_end, duration)
      length = new_end - new_start

      cond do
        new_end <= new_start -> {:error, :invalid_range}
        length < min_s or length > max_s -> {:error, :invalid_range}
        true -> {:ok, %{start_s: new_start, end_s: new_end, snapped: kind(start_kind, end_kind)}}
      end
    end
  end

  def snap(_sentences, _start_s, _end_s, _opts), do: {:error, :invalid_range}

  defp clamp_end(end_s, duration) when is_number(duration), do: min(end_s, duration * 1.0)
  defp clamp_end(end_s, _), do: end_s

  defp nearest(points, target, tol) do
    points
    |> Enum.filter(&(abs(&1 - target) <= tol))
    |> Enum.min_by(&{abs(&1 - target), &1}, fn -> nil end)
    |> case do
      nil -> nil
      point -> {point * 1.0, :sentence}
    end
  end

  # No sentence boundary in tolerance: the nearest word boundary, or the
  # requested time itself when the transcript has no words at all.
  defp or_word({_, :sentence} = hit, _points, _target), do: hit

  defp or_word(nil, points, target) do
    case Enum.min_by(points, &{abs(&1 - target), &1}, fn -> nil end) do
      nil -> {target, :word}
      point -> {point * 1.0, :word}
    end
  end

  defp kind(:sentence, :sentence), do: :sentence
  defp kind(_, _), do: :word

  # ── Caption lines ────────────────────────────────────────────────────

  @doc """
  Breaks caption words into CARDS: a list of cards, each a list of at most
  `:max_lines` (2) lines, each line a list of the given words (strings or
  `%{w: ...}` maps, returned as given).

  Lines hold `:min_words`..`:max_words` (3..5) words where the word count
  allows, balanced across a sentence. A card never spans two sentences.
  A run of Capitalised words (a name: "Dr. Smith") and a number group
  ("$3.5 million", "2 000", "10:30 am") are never split across lines, so a
  line may exceed `:max_words` only when one such group alone does.
  """
  @spec lines([String.t() | map()], keyword()) :: [[[String.t() | map()]]]
  def lines(words, opts \\ []) do
    max_words = Keyword.get(opts, :max_words, 5)
    max_lines = Keyword.get(opts, :max_lines, 2)

    words
    |> split_sentences()
    |> Enum.flat_map(fn sentence ->
      sentence
      |> units()
      |> balance(max_words)
      |> Enum.chunk_every(max_lines)
    end)
  end

  defp text(%{w: w}), do: w
  defp text(w) when is_binary(w), do: w

  defp split_sentences(words) do
    words
    |> Enum.chunk_while(
      [],
      fn w, acc ->
        acc = [w | acc]
        if sentence_end?(text(w)), do: {:cont, Enum.reverse(acc), []}, else: {:cont, acc}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  # Groups words that must stay on one line.
  defp units(words) do
    words
    |> Enum.reduce([], fn w, acc ->
      case acc do
        [prev | rest] -> if joins?(prev, w), do: [prev ++ [w] | rest], else: [[w] | acc]
        [] -> [[w]]
      end
    end)
    |> Enum.reverse()
  end

  defp joins?(prev_unit, w) do
    last = prev_unit |> List.last() |> text()
    cur = text(w)

    cond do
      # a sentence end closes the unit
      sentence_end?(last) and not abbreviation?(strip(last)) -> false
      # a name: Capitalised followed by Capitalised (an abbreviation like Dr. counts)
      capitalised?(last) and capitalised?(cur) -> true
      # a number group: number followed by a number or a magnitude word
      number?(last) and (number?(cur) or magnitude?(cur)) -> true
      true -> false
    end
  end

  defp strip(token), do: String.replace(token, ~r/[,;:"'\)\]]+$/, "")

  defp capitalised?(token) do
    bare = token |> String.replace(~r/^["'\(\[]+/, "") |> strip()
    Regex.match?(~r/^\p{Lu}/u, bare) and bare not in ["I"]
  end

  defp number?(token) do
    bare = token |> String.replace(~r/^["'\(\[]+/, "") |> String.replace(~r/[,;"'\)\]]+$/, "")
    Regex.match?(~r/^[$\x{00A3}\x{20AC}#~]?\d[\d.,:]*(%|k|m|bn|s)?$/iu, bare)
  end

  defp magnitude?(token) do
    bare = token |> String.replace(~r/[.,;:!?"'\)\]]+$/, "") |> String.downcase()
    bare in @magnitudes
  end

  # Spreads units over the fewest lines that keep each at or under
  # max_words, filling each line towards an even share.
  defp balance([], _max_words), do: []

  defp balance(units, max_words) do
    total = units |> Enum.map(&length/1) |> Enum.sum()
    line_count = max(div(total + max_words - 1, max_words), 1)
    target = div(total + line_count - 1, line_count)

    units
    |> Enum.reduce([[]], fn unit, [line | done] ->
      size = length(line)

      cond do
        line == [] -> [unit | done]
        size + length(unit) <= target -> [line ++ unit | done]
        size + length(unit) <= max_words and size < 3 -> [line ++ unit | done]
        true -> [unit, line | done]
      end
    end)
    |> Enum.reverse()
  end
end
