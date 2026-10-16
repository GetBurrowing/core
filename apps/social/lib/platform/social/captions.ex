defmodule Platform.Social.Captions do
  @moduledoc """
  Builds the ASS (Advanced SubStation Alpha) scripts libass burns into a
  clip (task 01a140a9-69b7, Social 5/7). PURE: text in, text out; the tests
  read the script, not pixels.

  Design canvas 01a140fc-14a9-7000-b3cc-bcd3663c92c0 governs every number:

    * frame 1080x1920 (`PlayResX`/`PlayResY`);
    * captions in the brand font (Public Sans Black, bundled) at 68px, white
      (`brand.caption_text`) with a 3px dark outline (`caption_outline`,
      `outline_px`) and NO box (`BorderStyle 1`, no shadow);
    * centred, the caption block's baseline about 65% down (y 1250, the block centred near 61%), so two
      lines sit inside the shared safe zone: nothing above y 220 or below y
      1520 (bottom 400px), and 140px clear on the right (and, to stay
      centred, on the left);
    * at most two lines of 3-5 words (`Platform.Social.Segmenter.lines/2`),
      cards never spanning a sentence; one event per spoken word with that
      word in `brand.highlight`, the clip's one colour moment;
    * the first card starts at t=0 so frame 0 (the thumbnail) has a caption;
    * a speaker label in small type above the caption for 1.5s when the
      speaker changes, never on every line;
    * the end card: solid `end_card_ground` (drawn by the renderer), the
      channel name about 96px, the call to action on ONE line, the handle
      about 48px, all in `end_card_text`, inside the same safe zone.

  A line whose estimated width would cross the side margins is set smaller
  (never below 52px) instead of wrapping onto a third line.
  """

  alias Platform.Social.{Brand, Segmenter}

  @width 1080
  @height 1920
  @caption_size 68
  @min_caption_size 52
  @label_size 40
  @label_s 1.5
  @side_margin 140
  # baseline of the caption block: about 62% down the frame
  @caption_baseline 1250
  @safe_top 220
  @safe_bottom @height - 400
  @line_height 1.2
  # Rough advance of Public Sans Black per character, as a share of the size.
  @char_em 0.62

  @doc "The safe zone the captions and end card keep to: `%{top, bottom, left, right}` in px."
  @spec safe_zone() :: map()
  def safe_zone,
    do: %{top: @safe_top, bottom: @safe_bottom, left: @side_margin, right: @width - @side_margin}

  @doc """
  The caption script for one clip. `words` are `%{w, start_s, end_s}` with
  times RELATIVE to the clip start; `speakers` are `%{start_s, name}`
  change points (relative); `duration_s` is the clip length (captions are
  cleared at the end, before the end card).
  """
  @spec captions([map()], [map()], map(), number()) :: String.t()
  def captions(words, speakers, brand, duration_s) do
    brand = Map.merge(Brand.defaults(), brand || %{})
    cards = cards(words, duration_s)

    events =
      Enum.flat_map(cards, &card_events(&1, brand)) ++ speaker_events(speakers, duration_s)

    header([
      style(
        "Caption",
        brand,
        @caption_size,
        brand["caption_text"],
        2,
        @height - @caption_baseline
      ),
      style("Speaker", brand, @label_size, brand["caption_text"], 2, label_margin_v())
    ]) <> Enum.join(events, "\n") <> "\n"
  end

  @doc "The end-card script: name, call to action and handle on the brand's ground."
  @spec end_card(map(), number(), keyword()) :: String.t()
  def end_card(brand, duration_s, opts \\ []) do
    brand = Map.merge(Brand.defaults(), brand || %{})
    logo? = Keyword.get(opts, :logo?, false)
    stop = ts(duration_s)
    text = brand["end_card_text"]
    # with a logo the text block moves down to leave the logo its slot
    y0 = if logo?, do: 960, else: 800

    lines =
      [
        {brand["channel_name"], 96, y0},
        {brand["cta"], 60, y0 + 130},
        {brand["handle"], 48, y0 + 215}
      ]
      |> Enum.reject(fn {t, _, _} -> blank?(t) end)

    events =
      Enum.map(lines, fn {t, size, y} ->
        size = fit(t, size, 40)

        "Dialogue: 0,#{ts(0)},#{stop},EndCard,,0,0,0,,{\\an5\\pos(#{div(@width, 2)},#{y})\\fs#{size}}#{escape(t)}"
      end)

    header([style("EndCard", brand, 96, text, 5, 0)]) <> Enum.join(events, "\n") <> "\n"
  end

  @doc "Where the renderer puts the logo on the end card: `%{x, y, max_w, max_h}` (centre)."
  @spec logo_slot() :: map()
  def logo_slot, do: %{x: div(@width, 2), y: 700, max_w: 480, max_h: 280}

  # ── Cards ────────────────────────────────────────────────────────────

  # Each card shows from its first word (t=0 for the first card) until the
  # next card begins (the last until the clip ends), so the frame is never
  # caption-less mid-clip and frame 0 always has one.
  defp cards([], _duration), do: []

  defp cards(words, duration_s) do
    cards = words |> Segmenter.lines() |> Enum.map(&%{lines: &1, words: Enum.concat(&1)})

    starts =
      cards
      |> Enum.with_index()
      |> Enum.map(fn {card, i} -> if i == 0, do: 0.0, else: hd(card.words).start_s end)

    ends = Enum.drop(starts, 1) ++ [duration_s * 1.0]

    [cards, starts, ends]
    |> Enum.zip()
    |> Enum.map(fn {card, s, e} -> Map.merge(card, %{start_s: s, end_s: max(e, s)}) end)
    |> Enum.reject(&(&1.end_s <= &1.start_s))
  end

  # One event per word: the card's text with that word in the highlight.
  defp card_events(card, brand) do
    words = card.words

    size =
      card.lines
      |> Enum.map(&line_text/1)
      |> Enum.map(&fit(&1, @caption_size, @min_caption_size))
      |> Enum.min()

    size_tag = if size == @caption_size, do: "", else: "{\\fs#{size}}"

    starts =
      words
      |> Enum.with_index()
      |> Enum.map(fn {w, i} ->
        if i == 0, do: card.start_s, else: max(w.start_s, card.start_s)
      end)

    ends = Enum.drop(starts, 1) ++ [card.end_s]

    [words, starts, ends]
    |> Enum.zip()
    |> Enum.with_index()
    |> Enum.reject(fn {{_w, s, e}, _i} -> e <= s end)
    |> Enum.map(fn {{_w, s, e}, i} ->
      text = card_text(card.lines, i, brand)
      "Dialogue: 1,#{ts(s)},#{ts(e)},Caption,,0,0,0,,#{size_tag}#{text}"
    end)
  end

  defp card_text(lines, active, brand) do
    highlight = colour(brand["highlight"])
    base = colour(brand["caption_text"])

    {rendered, _} =
      Enum.map_reduce(lines, 0, fn line, offset ->
        text =
          line
          |> Enum.with_index(offset)
          |> Enum.map_join(" ", fn {w, i} ->
            word = escape(w.w)
            if i == active, do: "{\\c#{highlight}}#{word}{\\c#{base}}", else: word
          end)

        {text, offset + length(line)}
      end)

    Enum.join(rendered, "\\N")
  end

  defp line_text(line), do: Enum.map_join(line, " ", & &1.w)

  # ── Speaker labels ───────────────────────────────────────────────────

  # A label on every CHANGE of speaker; the first speaker is labelled only
  # when the clip has more than one, so a single-speaker clip has none.
  defp speaker_events(speakers, duration_s) do
    changes =
      speakers
      |> Enum.reject(&blank?(&1[:name] || &1["name"]))
      |> Enum.map(&%{start_s: &1[:start_s] || &1["start_s"], name: &1[:name] || &1["name"]})
      |> Enum.sort_by(& &1.start_s)
      |> Enum.dedup_by(& &1.name)

    changes = if length(changes) > 1, do: changes, else: []

    Enum.map(changes, fn %{start_s: s, name: name} ->
      s = max(s * 1.0, 0.0)
      e = min(s + @label_s, duration_s * 1.0)
      "Dialogue: 2,#{ts(s)},#{ts(e)},Speaker,,0,0,0,,#{escape(name)}"
    end)
  end

  # The label sits just above a two-line caption block.
  defp label_margin_v,
    do: @height - @caption_baseline + round(2 * @caption_size * @line_height) + 16

  # ── ASS plumbing ─────────────────────────────────────────────────────

  defp header(styles) do
    """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: #{@width}
    PlayResY: #{@height}
    WrapStyle: 2
    ScaledBorderAndShadow: yes

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    #{Enum.join(styles, "\n")}

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """
  end

  defp style(name, brand, size, primary, alignment, margin_v) do
    font = Brand.font_family(brand["font"])
    outline = if name == "EndCard", do: 0, else: brand["outline_px"]

    "Style: #{name},#{font},#{size},#{colour(primary)},#{colour(primary)}," <>
      "#{colour(brand["caption_outline"])},&H00000000,0,0,0,0,100,100,0,0,1,#{outline},0," <>
      "#{alignment},#{@side_margin},#{@side_margin},#{margin_v},1"
  end

  @doc "`#RRGGBB` as an ASS colour, `&H00BBGGRR` (alpha 00 is opaque)."
  @spec colour(String.t()) :: String.t()
  def colour("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>),
    do: "&H00" <> String.upcase(b <> g <> r)

  # Shrinks a size until the estimated line width fits between the margins.
  defp fit(text, size, floor) do
    available = @width - 2 * @side_margin
    est = String.length(text) * size * @char_em

    if est <= available,
      do: size,
      else: max(floor, trunc(available / (String.length(text) * @char_em)))
  end

  @doc false
  def ts(seconds) do
    cs = round(seconds * 100)
    h = div(cs, 360_000)
    m = cs |> rem(360_000) |> div(6000)
    s = cs |> rem(6000) |> div(100)
    c = rem(cs, 100)
    "#{h}:#{pad(m)}:#{pad(s)}.#{pad(c)}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Braces open override blocks and a backslash starts a tag in ASS text.
  defp escape(text),
    do:
      text
      |> to_string()
      |> String.replace("\\", "⧵")
      |> String.replace("{", "(")
      |> String.replace("}", ")")
      |> String.replace("\n", " ")

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
