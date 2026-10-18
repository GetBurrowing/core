defmodule Platform.Social.CaptionsTest do
  @moduledoc """
  The caption and end-card ASS scripts (Social 5/7) against design canvas
  01a140fc-14a9: safe zone, two-line cap, highlight, frame-0 caption,
  speaker label on change only, brand overrides, no Burrow token colour.
  Reads the script text, not pixels.
  """
  use ExUnit.Case, async: true

  import Platform.SocialFixtures, only: [suite_token_colours: 0]

  alias Platform.Social.{Brand, Captions}

  defp words(text, at \\ 0.4, step \\ 0.4) do
    text
    |> String.split()
    |> Enum.with_index()
    |> Enum.map(fn {w, i} -> %{w: w, start_s: at + i * step, end_s: at + (i + 1) * step} end)
  end

  defp brand(overrides \\ %{}), do: Map.merge(Brand.defaults(), overrides)

  defp dialogues(ass, style) do
    ass
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "Dialogue:"))
    |> Enum.map(&String.split(&1, ",", parts: 10))
    |> Enum.filter(fn parts -> Enum.at(parts, 3) == style end)
  end

  defp style_line(ass, name) do
    ass |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Style: #{name},"))
  end

  defp style_fields(ass, name), do: ass |> style_line(name) |> String.split(",")

  @sentence "So the real problem was the supply chain and nobody saw it coming."

  test "the frame is 1080x1920 and the caption style keeps the safe zone" do
    ass = Captions.captions(words(@sentence), [], brand(), 6.0)
    assert ass =~ "PlayResX: 1080"
    assert ass =~ "PlayResY: 1920"

    # Format: Name, Fontname, Fontsize, Primary, Secondary, Outline, Back, Bold,
    # Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle,
    # BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    f = style_fields(ass, "Caption")
    assert Enum.at(f, 1) == "Public Sans Black"
    size = String.to_integer(Enum.at(f, 2))
    assert size in 64..72
    # outlined text, no box, no shadow
    assert Enum.at(f, 15) == "1"
    assert Enum.at(f, 16) == "3"
    assert Enum.at(f, 17) == "0"
    # bottom-centred: the block's bottom edge sits at 1920 - MarginV
    assert Enum.at(f, 18) == "2"
    margin_r = String.to_integer(Enum.at(f, 20))
    margin_v = String.to_integer(Enum.at(f, 21))
    assert margin_r >= 140

    baseline = 1920 - margin_v
    top_of_two_lines = baseline - round(2 * size * 1.2)
    zone = Captions.safe_zone()
    assert baseline <= zone.bottom
    assert top_of_two_lines >= zone.top
    # centred roughly 60-65% down the frame
    centre = (baseline + top_of_two_lines) / 2 / 1920
    assert centre >= 0.58 and centre <= 0.66

    # the speaker label also stays inside the zone, above the captions
    lf = style_fields(ass, "Speaker")
    label_bottom = 1920 - String.to_integer(Enum.at(lf, 21))
    assert label_bottom < top_of_two_lines
    assert label_bottom - String.to_integer(Enum.at(lf, 2)) >= zone.top
  end

  test "every caption state is at most 2 lines with exactly one highlighted word" do
    ass = Captions.captions(words(@sentence), [], brand(), 6.0)
    events = dialogues(ass, "Caption")
    assert length(events) == length(String.split(@sentence))

    hl = Captions.colour("#FFD400")

    for parts <- events do
      text = List.last(parts)
      assert length(String.split(text, "\\N")) <= 2
      assert length(Regex.scan(~r/\\c#{Regex.escape(hl)}/, text)) == 1
    end
  end

  test "the first caption starts at t=0 so frame 0 has a caption" do
    ass = Captions.captions(words(@sentence, 1.3), [], brand(), 6.0)
    [first | _] = dialogues(ass, "Caption")
    assert Enum.at(first, 1) == "0:00:00.00"
  end

  test "a speaker label shows for 1.5s on each change, never on every line" do
    ws = words(@sentence)

    speakers = [
      %{start_s: 0.0, name: "Ana"},
      %{start_s: 1.0, name: "Ana"},
      %{start_s: 2.0, name: "Ben"}
    ]

    labels = Captions.captions(ws, speakers, brand(), 6.0) |> dialogues("Speaker")

    assert Enum.map(labels, &{Enum.at(&1, 1), Enum.at(&1, 2), List.last(&1)}) == [
             {"0:00:00.00", "0:00:01.50", "Ana"},
             {"0:00:02.00", "0:00:03.50", "Ben"}
           ]

    # one speaker throughout: no label at all
    one = Captions.captions(ws, [%{start_s: 0.0, name: "Ana"}], brand(), 6.0)
    assert dialogues(one, "Speaker") == []
  end

  test "a brand override changes the colours; defaults carry no Suite token colour" do
    custom =
      brand(%{
        "caption_text" => "#F0F0F0",
        "highlight" => "#00FF88",
        "caption_outline" => "#202020"
      })

    ass = Captions.captions(words(@sentence), [], custom, 6.0)
    f = style_fields(ass, "Caption")
    assert Enum.at(f, 3) == Captions.colour("#F0F0F0")
    assert Enum.at(f, 5) == Captions.colour("#202020")
    assert ass =~ "\\c#{Captions.colour("#00FF88")}"
    refute ass =~ Captions.colour("#FFD400")

    default_ass = Captions.captions(words(@sentence), [], brand(), 6.0)
    card = Captions.end_card(brand(%{"handle" => "@htc"}), 2.0)

    for token <- suite_token_colours() do
      refute default_ass =~ Captions.colour(token)
      refute card =~ Captions.colour(token)
    end
  end

  test "colour/1 is ASS's &H00BBGGRR" do
    assert Captions.colour("#FFD400") == "&H0000D4FF"
    assert Captions.colour("#112233") == "&H00332211"
  end

  test "the end card: name, call to action on one line, handle, decreasing sizes, in the zone" do
    card = Captions.end_card(brand(%{"channel_name" => "HTC", "handle" => "@htc"}), 2.0)
    assert card =~ "WrapStyle: 2"
    lines = dialogues(card, "EndCard")
    assert Enum.map(lines, &Enum.at(&1, 2)) |> Enum.uniq() == ["0:00:02.00"]

    parsed =
      Enum.map(lines, fn parts ->
        text = List.last(parts)
        [_, y] = Regex.run(~r/\\pos\(540,(\d+)\)/, text)
        [_, fs] = Regex.run(~r/\\fs(\d+)/, text)
        {Regex.replace(~r/\{[^}]*\}/, text, ""), String.to_integer(y), String.to_integer(fs)}
      end)

    assert [{"HTC", y1, s1}, {"Full episode on YouTube", y2, s2}, {"@htc", y3, s3}] = parsed
    assert s1 in 90..100 and s3 in 44..52
    assert s1 > s2 and s2 > s3
    assert y1 < y2 and y2 < y3
    zone = Captions.safe_zone()
    assert y1 - s1 >= zone.top and y3 + s3 <= zone.bottom

    # end-card text colour is the brand's, with no outline
    f = style_fields(card, "EndCard")
    assert Enum.at(f, 3) == Captions.colour("#FFFFFF")
    assert Enum.at(f, 16) == "0"

    # no handle: that line is simply absent
    assert card
           |> then(fn _ -> Captions.end_card(brand(), 2.0) end)
           |> dialogues("EndCard")
           |> length() == 2
  end

  test "ASS control characters in transcript text cannot inject tags" do
    ass = Captions.captions(words("a {\\pos(0,0)} b c"), [], brand(), 3.0)
    refute ass =~ "{\\pos(0,0)}"
  end

  test "no words gives a valid script with no caption events" do
    ass = Captions.captions([], [], brand(), 3.0)
    assert ass =~ "[Events]"
    assert dialogues(ass, "Caption") == []
  end
end
