defmodule PlatformWeb.Components.Meetings.TranscriptPaneTest do
  @moduledoc """
  The transcript pane's HOST (task 01a06524 stage 1).

  What `mix test` can and cannot prove about this pane, said plainly:
  the buffer, grouping, interim/final and follow-live behaviour are JS —
  `meeting:caption` is a client-side DOM CustomEvent that never reaches
  the server — and are covered by `assets/test/hooks/meeting_transcript.test.js`
  against a stubbed element, and by the e2e stage in a real DOM under
  morphdom patches. This file proves the contract the server side owns:
  the host's id, hook name, `phx-update="ignore"`, its `data-role`, and
  the empty-state wording. Nothing here pretends to see a line.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PlatformWeb.Components.Meetings.TranscriptPane

  defp pane(overrides \\ []) do
    render_component(
      &TranscriptPane.transcript_pane/1,
      Keyword.merge([id: "rail-transcript"], overrides)
    )
  end

  defp count(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  describe "the hook host" do
    test "renders exactly one host with the given id, the hook, phx-update=ignore and its role" do
      html = pane()

      assert count(html, ~s(#rail-transcript)) == 1
      assert count(html, ~s([data-role="meeting-transcript"])) == 1

      # `phx-update="ignore"` is the whole reason the pane survives a
      # LiveView patch: every line is DOM the hook wrote and morphdom
      # would otherwise erase them mid-call. NAMED MUTATION for this
      # assertion: delete the attribute from `transcript_pane.ex` and this
      # test goes red on the selector below.
      assert count(
               html,
               ~s(#rail-transcript[phx-hook="MeetingTranscript"][phx-update="ignore"][data-role="meeting-transcript"])
             ) == 1
    end

    test "the id is the caller's, not a baked-in one" do
      assert count(pane(id: "quickmeet-rail-transcript"), ~s(#quickmeet-rail-transcript)) == 1
      assert count(pane(id: "quickmeet-rail-transcript"), ~s(#rail-transcript)) == 0
    end
  end

  describe "the empty state" do
    test "with captions available it says lines will appear as people talk" do
      html = pane(captions_available: true)

      assert html =~ "No speech yet. Lines appear here as people talk."
      refute html =~ "Captions are unavailable for this meeting"
      assert count(html, ~s([data-role="transcript-empty"])) == 1
    end

    test "with captions unavailable it says so outright, not 'none yet'" do
      html = pane(captions_available: false)

      assert html =~ "Captions are unavailable for this meeting"
      refute html =~ "No speech yet."
      assert count(html, ~s([data-role="transcript-empty"])) == 1
    end

    test "never uses the word listening, in either branch" do
      # Two reasons, both binding. A "listening" line would imply a
      # transcriber is attached when none may be (the `Listening` refusal
      # on the rail). And on `/meetings` the word is already spoken for by
      # the intents bar — one screen, two subjects for one word (Saru's
      # canvas 01a068fc; the collision closed on 01a064fd).
      for available <- [true, false] do
        html = pane(captions_available: available)
        refute html =~ ~r/listening/i
        refute html =~ ~r/transcribing/i
      end
    end
  end
end
