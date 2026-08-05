defmodule Platform.Meetings.SearchVectorTest do
  @moduledoc """
  Tests for the weighted search vectors the meeting archive ranks on
  (task `019fb954-c848`): `meetings.search_vector` (weight `A`),
  `chat_canvases.title_search_vector` (weight `B`) and
  `meeting_transcripts.search_vector` (summary at `C`, segment text at `D`).

  All three are STORED GENERATED columns, so these tests never write a
  vector — they write the source text and assert on what Postgres computed.

  The segment-text test is load-bearing beyond "a vector exists": it is the
  only assertion that proves the `jsonb_path_query_array(segments,
  '$[*].text')` extraction reaches the words a speaker actually said. Cast
  the whole `segments` array to text instead and the vector fills up with
  JSON punctuation and key names, which still produces a non-empty
  `tsvector` — so a presence assertion alone cannot tell the two apart.

  The weight assertion compares two `ts_rank_cd/2` floats with `>`. It is
  the only test here that fails if the `setweight` letters are wrong; the
  presence assertions pass under any weighting.
  """

  use Platform.DataCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Tasks

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp create_meeting(name) do
    {:ok, project} = Tasks.create_project(%{name: "#{name} Project"})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: name})
    meeting
  end

  defp add_participant(meeting) do
    {:ok, participant} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        joined_at: DateTime.utc_now(),
        display_name: "Author"
      })

    participant
  end

  defp create_transcript(attrs) do
    {:ok, transcript} =
      %Transcript{}
      |> Transcript.changeset(Map.merge(%{room_id: "room-#{Ecto.UUID.generate()}"}, attrs))
      |> Repo.insert()

    Repo.get!(Transcript, transcript.id)
  end

  # Ranks a stored vector against a query, in SQL, so `ts_rank_cd/2` reads
  # the weights Postgres actually stored rather than anything recomputed here.
  defp meeting_rank(meeting_id, query) do
    Repo.one!(
      from(m in Meeting,
        where: m.id == ^meeting_id,
        select:
          fragment(
            "ts_rank_cd(?, websearch_to_tsquery('english', ?))",
            field(m, :search_vector),
            ^query
          )
      )
    )
  end

  defp transcript_rank(transcript_id, query) do
    Repo.one!(
      from(t in Transcript,
        where: t.id == ^transcript_id,
        select:
          fragment(
            "ts_rank_cd(?, websearch_to_tsquery('english', ?))",
            field(t, :search_vector),
            ^query
          )
      )
    )
  end

  defp meeting_matches?(meeting_id, query) do
    Repo.one!(
      from(m in Meeting,
        where: m.id == ^meeting_id,
        select:
          fragment("? @@ websearch_to_tsquery('english', ?)", field(m, :search_vector), ^query)
      )
    )
  end

  defp transcript_matches?(transcript_id, query) do
    Repo.one!(
      from(t in Transcript,
        where: t.id == ^transcript_id,
        select:
          fragment("? @@ websearch_to_tsquery('english', ?)", field(t, :search_vector), ^query)
      )
    )
  end

  defp canvas_matches?(canvas_id, query) do
    Repo.one!(
      from(c in Chat.Canvas,
        where: c.id == ^canvas_id,
        select:
          fragment(
            "? @@ websearch_to_tsquery('english', ?)",
            field(c, :title_search_vector),
            ^query
          )
      )
    )
  end

  # ── meetings.search_vector ─────────────────────────────────────────────────

  describe "meetings.search_vector" do
    test "is populated from the meeting name and matches a websearch query" do
      meeting = create_meeting("Assignment policy spike")

      reloaded = Repo.get!(Meeting, meeting.id)

      refute is_nil(reloaded.search_vector)
      refute reloaded.search_vector == []

      assert meeting_matches?(meeting.id, "assignment policy")
    end

    test "tracks a rename, because Postgres owns the column" do
      meeting = create_meeting("Assignment policy spike")

      {:ok, renamed} =
        meeting
        |> Meeting.changeset(%{name: "Retention window review"})
        |> Repo.update()

      refute meeting_matches?(renamed.id, "assignment policy")
      assert meeting_matches?(renamed.id, "retention window")
    end
  end

  # ── chat_canvases.title_search_vector ──────────────────────────────────────

  describe "chat_canvases.title_search_vector" do
    test "is populated from the canvas title" do
      meeting = create_meeting("Canvas Title Vector")

      {:ok, canvas} =
        Chat.create_canvas(%{
          space_id: meeting.chat_space_id,
          created_by: add_participant(meeting).id,
          title: "Bucket policy canvas"
        })

      reloaded = Repo.get!(Chat.Canvas, canvas.id)

      refute is_nil(reloaded.title_search_vector)
      refute reloaded.title_search_vector == []

      assert canvas_matches?(canvas.id, "bucket policy")
    end
  end

  # ── meeting_transcripts.search_vector ──────────────────────────────────────

  describe "meeting_transcripts.search_vector" do
    test "indexes the text inside segments, not the JSON around it" do
      meeting = create_meeting("Segment Extraction")

      transcript =
        create_transcript(%{
          space_id: meeting.chat_space_id,
          segments: [%{"text" => "we should revisit the bucket policy"}]
        })

      refute is_nil(transcript.search_vector)

      assert transcript_matches?(transcript.id, "bucket policy"),
             "segment text did not reach the vector — check the " <>
               "jsonb_path_query_array($[*].text) extraction"
    end

    test "indexes the summary" do
      meeting = create_meeting("Summary Extraction")

      transcript =
        create_transcript(%{
          space_id: meeting.chat_space_id,
          summary: "The team agreed to raise the retention window."
        })

      assert transcript_matches?(transcript.id, "retention window")
    end
  end

  # ── Weighting ──────────────────────────────────────────────────────────────

  describe "weighting" do
    test "a meeting name outranks the same term buried in transcript segments" do
      meeting = create_meeting("Bucket policy review")

      transcript =
        create_transcript(%{
          space_id: meeting.chat_space_id,
          segments: [%{"text" => "we should revisit the bucket policy"}]
        })

      name_rank = meeting_rank(meeting.id, "bucket policy")
      segment_rank = transcript_rank(transcript.id, "bucket policy")

      # Both must actually match, or the comparison below is vacuous: two
      # zero ranks would satisfy neither `>` nor a reader.
      assert name_rank > 0.0
      assert segment_rank > 0.0

      assert name_rank > segment_rank,
             "meeting name (weight A) ranked #{name_rank}, transcript segments " <>
               "(weight D) ranked #{segment_rank} — the name must outrank the " <>
               "segments, or the archive has no weight signal to sort on"
    end
  end
end
