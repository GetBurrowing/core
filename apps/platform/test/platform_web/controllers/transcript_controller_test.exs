defmodule PlatformWeb.TranscriptControllerTest do
  use PlatformWeb.ConnCase, async: false

  alias Platform.Accounts.User
  alias Platform.Meetings
  alias Platform.Repo

  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "transcript-test-#{System.unique_integer([:positive])}@example.com",
        name: "Transcript Test User",
        oidc_sub: "oidc-transcript-#{System.unique_integer([:positive])}"
      })

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_transcript_with_segments do
    started_at = ~U[2026-04-10 14:00:00.000000Z]

    {:ok, transcript} =
      Meetings.create_transcript(%{
        room_id: Ecto.UUID.generate(),
        space_id: Ecto.UUID.generate(),
        started_at: started_at,
        status: "complete"
      })

    # Append segments via the context function
    segments = [
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

    Enum.each(segments, fn seg ->
      {:ok, _} = Meetings.append_segment(transcript.id, seg)
    end)

    # Reload to get updated segments
    Meetings.get_transcript(transcript.id)
  end

  describe "GET /api/transcripts/:id/download" do
    test "returns formatted plain text transcript for authenticated user", %{conn: conn} do
      transcript = create_transcript_with_segments()
      conn = authenticated_conn(conn)

      conn = get(conn, "/api/transcripts/#{transcript.id}/download")

      assert response_content_type(conn, :text) =~ "text/plain"
      assert get_resp_header(conn, "content-disposition") |> List.first() =~ "attachment"
      assert get_resp_header(conn, "content-disposition") |> List.first() =~ ".txt"

      body = response(conn, 200)
      assert body =~ "[00:00:00] Sam: Hello everyone"
      assert body =~ "[00:00:03] Alex: Sounds good"
      assert body =~ "[00:00:07] Sam: We need to review"
    end

    test "includes date and transcript ID in filename", %{conn: conn} do
      transcript = create_transcript_with_segments()
      conn = authenticated_conn(conn)

      conn = get(conn, "/api/transcripts/#{transcript.id}/download")

      disposition = get_resp_header(conn, "content-disposition") |> List.first()
      assert disposition =~ "2026-04-10"
      assert disposition =~ String.slice(transcript.id, 0..7)
    end

    test "returns 404 for non-existent transcript", %{conn: conn} do
      conn = authenticated_conn(conn)
      fake_id = Ecto.UUID.generate()

      conn = get(conn, "/api/transcripts/#{fake_id}/download")

      assert json_response(conn, 404)["error"] =~ "not found"
    end

    test "returns 422 for transcript still recording", %{conn: conn} do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          started_at: DateTime.utc_now(),
          status: "recording"
        })

      conn = authenticated_conn(conn)

      conn = get(conn, "/api/transcripts/#{transcript.id}/download")

      assert json_response(conn, 422)["error"] =~ "still being recorded"
    end

    test "returns empty text for transcript with no segments", %{conn: conn} do
      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Ecto.UUID.generate(),
          space_id: Ecto.UUID.generate(),
          started_at: DateTime.utc_now(),
          status: "complete"
        })

      conn = authenticated_conn(conn)

      conn = get(conn, "/api/transcripts/#{transcript.id}/download")

      assert response(conn, 200) == ""
    end

    test "redirects unauthenticated user", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn = get(conn, "/api/transcripts/#{fake_id}/download")

      # RequireAuth plug should redirect to login
      assert redirected_to(conn) =~ "/auth/login"
    end
  end
end
