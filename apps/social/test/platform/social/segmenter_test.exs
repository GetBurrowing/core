defmodule Platform.Social.SegmenterTest do
  @moduledoc """
  `Platform.Social.Segmenter` (Social 5/7): sentence splitting, clip-boundary
  snapping and caption line breaking. Pure, so every fixture is inline with
  known word times.
  """
  use ExUnit.Case, async: true

  alias Platform.Social.Segmenter

  # Each word lasts `step` seconds from `at`, back to back.
  defp words(text, at, step \\ 0.5) do
    text
    |> String.split()
    |> Enum.with_index()
    |> Enum.map(fn {w, i} ->
      %{w: w, start_s: Float.round(at + i * step, 3), end_s: Float.round(at + (i + 1) * step, 3)}
    end)
  end

  defp segment(text, at, speaker \\ nil, step \\ 0.5) do
    ws = words(text, at, step)
    %{start_s: at, end_s: List.last(ws).end_s, text: text, speaker: speaker, words: ws}
  end

  # The e2e fixture: sentences start at 0.0, 2.0, 4.5 and 5.0; the last run has no
  # punctuation at all.
  #   "It cost $3.5 million."          0.0 - 2.0  (4 words)
  #   "Dr. Smith joined at 10:30."     2.0 - 4.5  (5 words)
  #   "Really?"                        4.5 - 5.0
  #   "and then the long run ..."      5.0 - 12.5 (15 words)
  defp fixture do
    [
      segment("It cost $3.5 million. Dr. Smith joined at 10:30.", 0.0),
      segment("Really?", 4.5),
      segment("and then the long run of words just keeps going with no stop at all", 5.0)
    ]
  end

  describe "sentences/1" do
    test "does not split at a decimal, an abbreviation or a time" do
      texts = fixture() |> Segmenter.sentences() |> Enum.map(& &1.text)

      assert texts == [
               "It cost $3.5 million.",
               "Dr. Smith joined at 10:30.",
               "Really?",
               "and then the long run of words just keeps going with no stop at all"
             ]
    end

    test "carries word times: a sentence runs from its first word's start to its last's end" do
      [s1, s2, s3, s4] = Segmenter.sentences(fixture())
      assert {s1.start_s, s1.end_s} == {0.0, 2.0}
      assert {s2.start_s, s2.end_s} == {2.0, 4.5}
      assert {s3.start_s, s3.end_s} == {4.5, 5.0}
      assert {s4.start_s, s4.end_s} == {5.0, 12.5}
      assert length(s2.words) == 5
    end

    test "splits on question marks, exclamations and ellipses" do
      seg = segment("Is it real? Yes! Well... maybe so.", 0.0)
      texts = [seg] |> Segmenter.sentences() |> Enum.map(& &1.text)
      assert texts == ["Is it real?", "Yes!", "Well...", "maybe so."]

      unicode = segment("Wait… what now.", 0.0)
      assert [unicode] |> Segmenter.sentences() |> length() == 2
    end

    test "keeps U.S., e.g., Mr., Mrs. and single initials inside a sentence" do
      seg = segment("The U.S. team, e.g. Mr. Jones and Mrs. J. Lee, won.", 0.0)

      assert [%{text: "The U.S. team, e.g. Mr. Jones and Mrs. J. Lee, won."}] =
               Segmenter.sentences([seg])
    end

    test "a closing quote after the stop still ends the sentence" do
      seg = segment(~s(He said "stop." Then left.), 0.0)
      assert [seg] |> Segmenter.sentences() |> length() == 2
    end

    test "a change of speaker ends a sentence and the sentence keeps its speaker" do
      segs = [segment("so I think that", 0.0, "Ana"), segment("No way.", 2.0, "Ben")]

      assert [%{speaker: "Ana", text: "so I think that"}, %{speaker: "Ben"}] =
               Segmenter.sentences(segs)
    end

    test "no words gives no sentences" do
      assert Segmenter.sentences([]) == []
    end
  end

  describe "snap/4" do
    setup do: %{s: Segmenter.sentences(fixture())}

    test "a mid-sentence start and end move to the sentence start and end", %{s: s} do
      # 1.2s after the 2.0 sentence start, 0.8s before the 12.5 sentence end
      assert {:ok, %{start_s: 2.0, end_s: 12.5, snapped: :sentence}} =
               Segmenter.snap(s, 3.2, 11.7)
    end

    test "a start already on a boundary is unchanged", %{s: s} do
      assert {:ok, %{start_s: 2.0, end_s: 12.5}} = Segmenter.snap(s, 2.0, 11.5)
    end

    test "an end past the source duration is clamped to it", %{s: s} do
      assert {:ok, %{start_s: +0.0, end_s: 10.0}} =
               Segmenter.snap(s, 0.0, 30.0, duration_s: 10.0, tolerance_s: 1.0)
    end

    test "a snapped end never passes the source duration", %{s: s} do
      # nearest sentence end to 9.5 within 3s is 12.5, past the 10.0 source
      assert {:ok, %{end_s: end_s}} = Segmenter.snap(s, 0.0, 9.5, duration_s: 10.0)
      assert end_s <= 10.0
    end

    test "the tolerance edge is inclusive: exactly 3.0s away still snaps", %{s: s} do
      # one sentence 0.0 - 8.0 with 1s words: its start sits exactly 3.0s
      # before a requested 3.0
      long =
        Segmenter.sentences([segment("One two three four five six seven eight.", 0.0, nil, 1.0)])

      assert {:ok, %{start_s: +0.0, end_s: 8.0, snapped: :sentence}} =
               Segmenter.snap(long, 3.0, 9.0)

      # 3.001s away is outside: falls back to the nearest word start (3.0)
      assert {:ok, %{start_s: 3.0, end_s: 8.0, snapped: :word}} =
               Segmenter.snap(long, 3.001, 9.0)

      assert is_list(s)
    end

    test "with no sentence boundary in tolerance it falls back to word boundaries" do
      # one 20s sentence with no punctuation at all: no boundary near 7.3 / 13.6
      s = Segmenter.sentences([segment(Enum.map_join(1..20, " ", &"w#{&1}"), 0.0, nil, 1.0)])

      assert {:ok, %{start_s: 7.0, end_s: 14.0, snapped: :word}} =
               Segmenter.snap(s, 7.3, 13.6)
    end

    test "a snap that would invert the range is refused", %{s: s} do
      # 4.8 snaps to the 5.0 start of the last sentence; 4.9 snaps to the
      # 5.0 end of "Really?": end <= start.
      assert {:error, :invalid_range} = Segmenter.snap(s, 4.8, 4.9, min_s: 0)
    end

    test "a request outside min_s..max_s, or inverted, is refused", %{s: s} do
      assert {:error, :invalid_range} = Segmenter.snap(s, 2.0, 4.0)
      assert {:error, :invalid_range} = Segmenter.snap(s, 0.0, 12.0, max_s: 5)
      assert {:error, :invalid_range} = Segmenter.snap(s, 8.0, 3.0)
      assert {:error, :invalid_range} = Segmenter.snap(s, "a", 3.0)
    end

    test "never returns end <= start or a length outside the bounds", %{s: s} do
      for start <- [0.0, 1.0, 2.5, 4.0, 6.0], stop <- [5.5, 7.0, 9.0, 12.0, 15.0], stop > start do
        case Segmenter.snap(s, start, stop, min_s: 1, max_s: 10, duration_s: 12.0) do
          {:ok, r} ->
            assert r.end_s > r.start_s
            assert r.end_s - r.start_s >= 1 and r.end_s - r.start_s <= 10
            assert r.end_s <= 12.0

          {:error, :invalid_range} ->
            :ok
        end
      end
    end
  end

  describe "lines/2" do
    test "the e2e sentence: at most 2 lines of 3-5 words, names and numbers kept whole" do
      words = String.split("Dr. Smith joined at 10:30 and paid $3.5 million")
      assert [card] = Segmenter.lines(words)
      assert length(card) <= 2
      assert Enum.all?(card, &(length(&1) in 3..5))
      joined = Enum.map(card, &Enum.join(&1, " "))
      assert Enum.any?(joined, &String.contains?(&1, "Dr. Smith"))
      assert Enum.any?(joined, &String.contains?(&1, "10:30"))
      assert Enum.any?(joined, &String.contains?(&1, "$3.5 million"))
    end

    test "a name run is never split, even at the line boundary" do
      # without the rule the 5-word break would fall between Mary and Jane
      words = String.split("we met with Anna Mary Jane Watson at the shop today")

      for card <- Segmenter.lines(words), line <- card do
        refute List.last(line) in ["Anna", "Mary", "Jane"]
      end
    end

    test "a number group (\"2 000\", \"$3.5 million\") is never split" do
      words = String.split("they sold one two 2 000 units for $3.5 million dollars")
      lines = words |> Segmenter.lines() |> Enum.concat()
      refute Enum.any?(lines, &(List.last(&1) == "2"))
      refute Enum.any?(lines, &(List.last(&1) == "$3.5"))
    end

    test "a card never spans two sentences" do
      words = String.split("Go now. Then we wait for the others to arrive here.")
      [first | _] = Segmenter.lines(words)
      assert first == [["Go", "now."]]
    end

    test "long sentences become several cards of at most two lines" do
      words = Enum.map(1..23, &"w#{&1}")
      cards = Segmenter.lines(words)
      assert Enum.all?(cards, &(length(&1) <= 2))
      assert cards |> Enum.concat() |> Enum.all?(&(length(&1) in 3..5))
      assert cards |> Enum.concat() |> Enum.concat() == words
    end

    test "word maps come back as given" do
      ws = words("Hello there my old friend.", 0.0)
      assert [[line]] = Segmenter.lines(ws)
      assert line == ws
    end
  end
end
