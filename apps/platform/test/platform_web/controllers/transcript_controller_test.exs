defmodule PlatformWeb.TranscriptControllerTest do
  @moduledoc """
  `GET /api/transcripts/:id/download` (task 01a1b288 stage 1): a transcript is
  served only to a viewer who could open its meeting, and every other caller
  gets the SAME 404 body as a nonexistent id.

  Each transcript here belongs to a real meeting (`meeting_id` set,
  `space_id` = the meeting's chat space), inserted straight through the
  changeset so `create_transcript/1`'s covering-meeting lookup cannot leave
  `meeting_id` nil. Every denial test carries a positive control on the same
  fixture, so a route that 404s for everybody fails here.
  """
  use PlatformWeb.ConnCase, async: false

  import Platform.ExternalUserFixtures

  alias Platform.Meetings
  alias Platform.Meetings.Transcript
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  @segments [
    %{
      "speaker_name" => "Sam",
      "text" => "Hello everyone, let's get started",
      "start_time" => 0,
      "end_time" => 3000,
      "final" => true
    },
    %{
      "speaker_name" => "Alex",
      "text" => "Sounds good, what's on the agenda?",
      "start_time" => 3500,
      "end_time" => 6000,
      "final" => true
    },
    %{
      "speaker_name" => "Sam",
      "text" => "We need to review the transcript feature",
      "start_time" => 7000,
      "end_time" => 10000,
      "final" => true
    }
  ]

  # ── Fixtures ──────────────────────────────────────────────────────────────

  defp meeting!(org, attrs) do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Transcript DL #{n}", org_id: org.id})

    {:ok, meeting} =
      Meetings.create_meeting(
        Map.merge(
          %{
            project_id: project.id,
            name: "Transcript DL Meeting #{n}",
            slug: "transcript-dl-#{n}"
          },
          attrs
        )
      )

    meeting
  end

  defp transcript!(meeting_id, space_id, attrs \\ %{}) do
    %Transcript{}
    |> Transcript.changeset(
      Map.merge(
        %{
          room_id: "space-#{space_id}",
          space_id: space_id,
          meeting_id: meeting_id,
          started_at: ~U[2026-04-10 14:00:00.000000Z],
          status: "complete",
          segments: @segments
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp meeting_transcript!(meeting, attrs \\ %{}),
    do: transcript!(meeting.id, meeting.chat_space_id, attrs)

  defp download(conn, user, id) do
    conn |> login(user.id) |> get("/api/transcripts/#{id}/download")
  end

  setup do
    globex = Tenancy.get_org_by_slug!("globex")
    initech = Tenancy.get_org_by_slug!("initech")

    organizer = create_user!()
    plain_member!(organizer, globex)

    outsider = create_user!()
    plain_member!(outsider, initech)
    refute Tenancy.root_admin?(outsider)

    meeting = meeting!(globex, %{created_by_user_id: organizer.id})

    %{globex: globex, organizer: organizer, outsider: outsider, meeting: meeting}
  end

  describe "GET /api/transcripts/:id/download — allowed viewers" do
    test "organizer gets 200 with the formatted transcript", ctx do
      transcript = meeting_transcript!(ctx.meeting)
      assert ctx.meeting.created_by_user_id == ctx.organizer.id

      conn = download(build_conn(), ctx.organizer, transcript.id)

      assert response_content_type(conn, :text) =~ "text/plain"
      assert get_resp_header(conn, "content-disposition") |> List.first() =~ "attachment"
      assert get_resp_header(conn, "content-disposition") |> List.first() =~ ".txt"

      body = response(conn, 200)
      assert body =~ "[00:00:00] Sam: Hello everyone"
      assert body =~ "[00:00:03] Alex: Sounds good"
      assert body =~ "[00:00:07] Sam: We need to review"
    end

    test "invitee gets 200", ctx do
      invitee = create_user!()
      plain_member!(invitee, ctx.globex)
      {:ok, _invite} = Meetings.invite_user(ctx.meeting, invitee.id)
      transcript = meeting_transcript!(ctx.meeting)

      body = download(build_conn(), invitee, transcript.id) |> response(200)
      assert body =~ "[00:00:00] Sam: Hello everyone"
    end

    test "includes date and transcript ID in filename", ctx do
      transcript = meeting_transcript!(ctx.meeting)

      conn = download(build_conn(), ctx.organizer, transcript.id)

      assert conn.status == 200
      disposition = get_resp_header(conn, "content-disposition") |> List.first()
      assert disposition =~ "2026-04-10"
      assert disposition =~ String.slice(transcript.id, 0..7)
    end

    test "returns 422 to a viewer for a transcript still recording", ctx do
      transcript = meeting_transcript!(ctx.meeting, %{status: "recording", segments: []})

      conn = download(build_conn(), ctx.organizer, transcript.id)

      assert json_response(conn, 422)["error"] =~ "still being recorded"
    end

    test "returns empty text to a viewer for a transcript with no segments", ctx do
      transcript = meeting_transcript!(ctx.meeting, %{segments: []})

      conn = download(build_conn(), ctx.organizer, transcript.id)

      assert response(conn, 200) == ""
    end
  end

  describe "GET /api/transcripts/:id/download — denials" do
    test "returns 404 for non-existent transcript", ctx do
      conn = download(build_conn(), ctx.organizer, Ecto.UUID.generate())

      assert json_response(conn, 404)["error"] =~ "not found"
    end

    test "signed-in non-participant gets 404 identical to a nonexistent id", ctx do
      transcript = meeting_transcript!(ctx.meeting)

      # Positive control: the same transcript IS served to a viewer.
      assert download(build_conn(), ctx.organizer, transcript.id).status == 200

      denied = download(build_conn(), ctx.outsider, transcript.id)
      missing = download(build_conn(), ctx.outsider, Ecto.UUID.generate())

      assert denied.status == 404
      assert missing.status == 404
      assert denied.resp_body == missing.resp_body
      refute denied.resp_body =~ "Hello everyone"
    end

    test "non-participant gets 404, not 422, for a recording transcript", ctx do
      transcript = meeting_transcript!(ctx.meeting, %{status: "recording", segments: []})

      # Positive control: a viewer reaches the 422 branch.
      assert download(build_conn(), ctx.organizer, transcript.id).status == 422

      denied = download(build_conn(), ctx.outsider, transcript.id)
      missing = download(build_conn(), ctx.outsider, Ecto.UUID.generate())

      assert denied.status == 404
      assert denied.resp_body == missing.resp_body
    end

    test "external user outside the space is refused with no transcript bytes", ctx do
      external = external_user!(ctx.globex)
      assert Tenancy.external_user?(external)
      transcript = meeting_transcript!(ctx.meeting)

      conn = download(build_conn(), external, transcript.id)

      assert conn.status in [403, 404]
      refute conn.resp_body =~ "Hello everyone"
      refute conn.resp_body =~ "Sounds good"
    end

    test "meeting-less transcript: space participant gets 200, non-participant gets 404", ctx do
      space = channel!(%{org_id: ctx.globex.id})
      add_user!(space.id, ctx.organizer.id)
      transcript = transcript!(nil, space.id)
      assert is_nil(transcript.meeting_id)

      assert download(build_conn(), ctx.organizer, transcript.id) |> response(200) =~
               "[00:00:00] Sam: Hello everyone"

      # Same org, not a participant of the space.
      bystander = create_user!()
      plain_member!(bystander, ctx.globex)

      denied = download(build_conn(), bystander, transcript.id)
      missing = download(build_conn(), bystander, Ecto.UUID.generate())

      assert denied.status == 404
      assert denied.resp_body == missing.resp_body
    end

    test "redirects unauthenticated user", %{conn: conn} do
      conn = get(conn, "/api/transcripts/#{Ecto.UUID.generate()}/download")

      # RequireAuth plug should redirect to login
      assert redirected_to(conn) =~ "/auth/login"
    end
  end
end
