defmodule Platform.Meetings.SegmentsSpokenByTest do
  @moduledoc """
  Task 01a1aa47 stage 3 — `Platform.Meetings.segments_spoken_by/2` returns
  the subject's own segments and nothing else: not the summary, not another
  speaker's words, however the subject is identified.
  """
  use Platform.DataCase, async: true

  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Repo

  @others_line "I think Marisol is slow playing us"
  @summary "Fixture Founder voiced doubts about Marisol's pace; Marisol proposed smaller PRs."

  defp transcript! do
    %Transcript{}
    |> Transcript.changeset(%{
      room_id: "room-#{System.unique_integer([:positive])}",
      status: "complete",
      completed_at: ~U[2026-10-20 10:30:00.000000Z],
      summary: @summary,
      segments: [
        %{
          "id" => "seg-1",
          "participant_identity" => "user:founder",
          "speaker_name" => "Fixture Founder",
          "text" => @others_line,
          "spoken_at" => "2026-10-20T10:01:00Z"
        },
        %{
          "id" => "seg-2",
          "participant_identity" => "user:marisol",
          "speaker_name" => "Dr. Marisol Tennebrook",
          "text" => "I prefer small PRs so review stays quick",
          "spoken_at" => "2026-10-20T10:02:00Z"
        },
        %{
          "id" => "seg-3",
          "participant_identity" => "marisol tennebrook",
          "text" => "and I will own the deploy pipeline this quarter",
          "spoken_at" => "2026-10-20T10:03:00Z"
        }
      ]
    })
    |> Repo.insert!()
  end

  test "returns only the subject's segments and never the summary" do
    transcript = transcript!()

    result = Meetings.segments_spoken_by(transcript.id, ["@[Marisol Tennebrook]"])

    assert [
             %{
               segment_id: "seg-2",
               text: "I prefer small PRs so review stays quick",
               spoken_at: "2026-10-20T10:02:00Z"
             },
             %{segment_id: "seg-3", text: "and I will own the deploy pipeline this quarter"}
           ] = result

    refute inspect(result) =~ "slow playing"
    refute inspect(result) =~ "voiced doubts"
    assert Enum.all?(result, &(Map.keys(&1) |> Enum.sort() == [:segment_id, :spoken_at, :text]))
  end

  test "matches on participant_identity when the speaker name is missing, and nothing on no identities" do
    transcript = transcript!()

    assert [%{segment_id: "seg-1"}] = Meetings.segments_spoken_by(transcript.id, ["user:founder"])
    assert Meetings.segments_spoken_by(transcript.id, []) == []
    assert Meetings.segments_spoken_by(transcript.id, ["Oskar Vellinghausen"]) == []
    assert Meetings.segments_spoken_by("not-a-uuid", ["Fixture Founder"]) == []
    assert Meetings.segments_spoken_by(nil, ["Fixture Founder"]) == []
  end
end
