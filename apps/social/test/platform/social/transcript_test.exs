defmodule Platform.Social.TranscriptTest do
  @moduledoc """
  `Platform.Social.Transcript` (Social 5/7) on small inline VTT, SRT and JSON
  fixtures, including YouTube's rolling auto-subs.
  """
  use ExUnit.Case, async: true

  alias Platform.Social.Transcript

  # The shape YouTube's auto-generated subtitles actually have: every cue's
  # first text line is a single space, timed lines carry inline word stamps,
  # 10ms "hold" cues repeat the line, and the next cue repeats it again on
  # top of the new timed line.
  @youtube_vtt """
  WEBVTT
  Kind: captions
  Language: en

  00:00:00.160 --> 00:00:01.270 align:start position:0%

  There's<00:00:00.400><c> going</c><00:00:00.640><c> to</c><00:00:00.800><c> be</c>

  00:00:01.270 --> 00:00:01.280 align:start position:0%
  There's going to be


  00:00:01.280 --> 00:00:03.510 align:start position:0%
  There's going to be
  spoiler.<00:00:01.600><c> Spoiler</c><00:00:02.000><c> alert.</c>

  00:00:03.510 --> 00:00:03.520 align:start position:0%
  spoiler. Spoiler alert.

  """

  describe "VTT" do
    test "YouTube auto-subs: inline word times, rolling repeats removed" do
      assert {:ok, [a, b]} = Transcript.parse(@youtube_vtt, :vtt)
      assert a.text == "There's going to be"
      assert b.text == "spoiler. Spoiler alert."

      assert Enum.map(a.words, &{&1.w, &1.start_s}) == [
               {"There's", 0.16},
               {"going", 0.4},
               {"to", 0.64},
               {"be", 0.8}
             ]

      # the last word runs to the cue end; each word ends where the next starts
      assert List.last(a.words).end_s == 1.27
      assert Enum.at(b.words, 1) == %{w: "Spoiler", start_s: 1.6, end_s: 2.0}

      all = Enum.flat_map([a, b], & &1.words) |> Enum.map(& &1.w)
      assert all == ~w(There's going to be spoiler. Spoiler alert.)
    end

    test "plain cues, voice tags, entities and markup" do
      vtt = """
      WEBVTT

      NOTE a comment block

      intro
      00:01.000 --> 00:04.000
      <v Ana Ruiz>Hello &amp; <i>welcome</i> back.

      00:00:04.000 --> 00:00:06.500 line:80%
      <v.loud Ben>Thanks.
      """

      assert {:ok, [a, b]} = Transcript.parse(vtt, :vtt)
      assert %{start_s: 1.0, end_s: 4.0, text: "Hello & welcome back.", speaker: "Ana Ruiz"} = a
      assert %{start_s: 4.0, end_s: 6.5, text: "Thanks.", speaker: "Ben"} = b
    end

    test "plain rolling captions drop the repeated first line" do
      vtt = """
      WEBVTT

      00:00:00.000 --> 00:00:02.000
      first line here

      00:00:02.000 --> 00:00:04.000
      first line here
      second line now
      """

      assert {:ok, [_, b]} = Transcript.parse(vtt, :vtt)
      assert b.text == "second line now"
    end

    test "words without inline times are interpolated by character share" do
      vtt = "WEBVTT\n\n00:00:00.000 --> 00:00:03.000\nab abcd ab\n"
      assert {:ok, [%{words: [w1, w2, w3]}]} = Transcript.parse(vtt, :vtt)
      # weights 3, 5, 3 of 11 over 3.0s
      assert w1.start_s == 0.0
      assert_in_delta w1.end_s, 3 * 3 / 11, 0.001
      assert_in_delta w2.end_s, 3 * 8 / 11, 0.001
      assert w3.end_s == 3.0
    end

    test "refuses a file without the WEBVTT header, or with no cues" do
      assert {:error, "not a VTT transcript" <> _} = Transcript.parse("hello", :vtt)
      assert {:error, msg} = Transcript.parse("WEBVTT\n\n", :vtt)
      assert msg =~ "no timed text"
    end
  end

  describe "SRT" do
    test "numbered cues with comma milliseconds and multi-line text" do
      srt =
        "1\r\n00:00:01,000 --> 00:00:03,500\r\nSo the real\r\nproblem was\r\n\r\n2\r\n00:00:03,500 --> 00:00:05,000\r\nsupply.\r\n"

      assert {:ok, [a, b]} = Transcript.parse(srt, :srt)
      assert %{start_s: 1.0, end_s: 3.5, text: "So the real problem was"} = a
      assert length(a.words) == 5
      assert b.text == "supply."
    end

    test "refuses text with no cue lines" do
      assert {:error, msg} = Transcript.parse("just words", :srt)
      assert msg =~ "not an SRT transcript"
    end
  end

  describe "JSON" do
    test "[{start, end, text, speaker}] (the HTC transcripts shape)" do
      json =
        Jason.encode!([
          %{start: 0.0, end: 2.5, text: "Welcome to the show.", speaker: "Host"},
          %{start: 2.5, end: 4.0, text: "Thanks."}
        ])

      assert {:ok, [a, b]} = Transcript.parse(json, :json)
      assert %{speaker: "Host", end_s: 2.5, text: "Welcome to the show."} = a
      assert %{speaker: nil, start_s: 2.5} = b
    end

    test "youtube-transcript-api's [{text, start, duration}], overlapping, wrapped in segments" do
      json =
        Jason.encode!(%{
          source: "youtube_captions",
          segments: [
            %{start: 0.16, duration: 3.36, text: "There's going to be a little bit of a"},
            %{start: 1.28, duration: 4.479, text: "spoiler. Spoiler alert."}
          ]
        })

      assert {:ok, [a, b]} = Transcript.parse(json, :json)
      # the overlap is clamped: a ends where b starts
      assert a.end_s == 1.28
      assert_in_delta b.end_s, 5.759, 0.0001
    end

    test "YouTube's >> speaker-change marks are dropped from the text" do
      json =
        Jason.encode!(%{
          segments: [
            %{start: 0.0, duration: 1.2, text: ">> I'll spin up some Bill Gates"},
            %{start: 1.2, duration: 1.0, text: "Gates. >> Tech leaders &gt;&gt; agree"}
          ]
        })

      assert {:ok, [a, b]} = Transcript.parse(json, :json)
      assert a.text == "I'll spin up some Bill Gates"
      assert b.text == "Gates. Tech leaders agree"
      refute Enum.any?(a.words ++ b.words, &(&1.w == ">>"))
    end

    test "segment-level word times are kept" do
      json =
        Jason.encode!([
          %{
            start: 0,
            end: 1,
            text: "hi there",
            words: [%{word: "hi", start: 0, end: 0.3}, %{word: "there", start: 0.4, end: 1}]
          }
        ])

      assert {:ok, [%{words: [%{w: "hi", end_s: 0.3}, %{w: "there", start_s: 0.4}]}]} =
               Transcript.parse(json, :json)
    end

    test "readable errors for bad JSON and bad segments" do
      assert {:error, "the JSON transcript is not valid JSON"} = Transcript.parse("{", :json)
      assert {:error, msg} = Transcript.parse(~s([{"start": 1, "text": "x"}]), :json)
      assert msg =~ "segment 1" and msg =~ "end or a duration"
      assert {:error, _} = Transcript.parse(~s({"a": 1}), :json)
    end
  end

  test "format_for/2 by content type or extension" do
    assert {:ok, :vtt} = Transcript.format_for("text/vtt", "x")
    assert {:ok, :srt} = Transcript.format_for("application/octet-stream", "ep.SRT")
    assert {:ok, :json} = Transcript.format_for("application/json; charset=utf-8", nil)
    assert {:error, msg} = Transcript.format_for("text/plain", "notes.txt")
    assert msg =~ "VTT, SRT or JSON"
  end
end
