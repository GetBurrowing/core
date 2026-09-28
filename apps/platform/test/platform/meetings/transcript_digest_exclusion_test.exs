defmodule Platform.Meetings.TranscriptDigestExclusionTest do
  @moduledoc """
  Task 01a0a12e, clause 9 — meeting transcripts are NOT eligible for the
  Historian indexing digest by default.

  The exclusion lives in the ONE eligibility seam,
  `Platform.Meetings.digest_eligible_transcripts_query/1`, so the rendered
  digest (`list_transcripts_since/2` → `ActivityDigest`) and the byte signal
  (`Historian.pending_windows_input/1`) agree by construction.

  The fixture summary is ~200 bytes, far under the 120000-byte digest
  window, so the size cap cannot be what keeps it out. That is the point:
  the harm of indexing a call is uncorrelated with its byte volume, and the
  budget is not a control.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.ActivityDigest
  alias Platform.Agents.Historian
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Repo

  @line "Priya to deliver list of demands to Marcus by end of week"

  # ~200 bytes: the synthesised line plus neutral filler.
  @summary @line <> ". " <> String.duplicate("sprint planning notes. ", 6)

  setup do
    {:ok, space} =
      Chat.create_space(%{
        name: "exclusion-#{System.unique_integer([:positive])}",
        slug: "excl-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    transcript =
      %Transcript{}
      |> Transcript.changeset(%{
        room_id: "room-#{System.unique_integer([:positive])}",
        space_id: space.id,
        status: "complete",
        summary: @summary,
        started_at: DateTime.add(now, -600, :second),
        completed_at: now
      })
      |> Repo.insert!()

    ws = DateTime.add(now, -3600, :second)
    we = DateTime.add(now, 3600, :second)

    %{transcript: transcript, ws: ws, we: we}
  end

  test "fixture summary is small, so the byte budget is irrelevant" do
    assert byte_size(@summary) in 150..300
  end

  test "1. list_transcripts_since/2 returns nothing by default", %{ws: ws, we: we} do
    assert Meetings.list_transcripts_since(ws, window_end: we) == []
  end

  test "2. the windowed transcripts digest renders an empty window", %{ws: ws, we: we} do
    {:ok, body, meta} =
      ActivityDigest.build_windowed_result(%{
        corpus: :transcripts,
        window_start: ws,
        window_end: we
      })

    assert body =~ "_No activity in this window._"
    refute body =~ @line
    assert meta.item_count == 0
  end

  test "3. the 24h scheduled digest does not contain the summary", %{ws: ws, we: we} do
    refute ActivityDigest.build(ws, we) =~ @line
  end

  test "4. the byte signal inherits the exclusion (zero transcript bytes)" do
    {_last_at, bytes} = Historian.pending_windows_input(nil)[:transcripts]
    assert bytes == 0
  end

  test "5. positive control: :included admits the fixture", %{
    ws: ws,
    we: we,
    transcript: transcript
  } do
    ids =
      ws
      |> Meetings.list_transcripts_since(window_end: we, meeting_transcripts: :included)
      |> Enum.map(& &1.id)

    assert ids == [transcript.id]
  end

  test "an unrecognised :meeting_transcripts value fails closed", %{ws: ws, we: we} do
    assert Meetings.list_transcripts_since(ws, window_end: we, meeting_transcripts: true) == []
    assert Meetings.list_transcripts_since(ws, window_end: we, meeting_transcripts: nil) == []
  end

  test "6. no production module outside meetings.ex opts in to :included" do
    lib = Path.expand("../../../lib", __DIR__)
    needle = "meeting_transcripts: " <> ":included"

    offenders =
      Path.wildcard(Path.join(lib, "**/*.{ex,exs,heex,eex}"))
      |> Enum.reject(&(Path.basename(&1) == "meetings.ex"))
      |> Enum.filter(&(File.read!(&1) =~ needle))
      |> Enum.map(&Path.relative_to(&1, lib))

    assert File.dir?(lib)
    assert Path.wildcard(Path.join(lib, "platform/meetings.ex")) != []
    assert offenders == []
  end
end
