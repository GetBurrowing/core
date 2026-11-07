defmodule PlatformWeb.MeetingLiveTranscriptionOffTest do
  @moduledoc """
  Meetings ON, transcription OFF (core task 01a1b7ed stage 3): a hosted
  install with no STT key yet renders `MEETING_TRANSCRIPTION=off`, which is
  `config :platform, :meeting_transcription, false`. The meeting still
  connects (LiveKit is configured), but nothing transcribes, so the
  Transcript tab must say captions are unavailable, not "No speech yet.
  Lines appear here as people talk."

  `async: false` for the same reason as
  `meeting_live_captions_unconfigured_test.exs`: it writes process-global
  application env.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    livekit = Application.get_env(:platform, :livekit, [])
    transcription = Application.fetch_env(:platform, :meeting_transcription)

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn ->
      Application.put_env(:platform, :livekit, livekit)

      case transcription do
        {:ok, value} -> Application.put_env(:platform, :meeting_transcription, value)
        :error -> Application.delete_env(:platform, :meeting_transcription)
      end
    end)

    {:ok, conn: authenticated_conn(conn), meeting: create_meeting()}
  end

  # Same shape as `meeting_live_test.exs`'s fixtures: a signed-in member
  # of the root org, and a meeting in a project that org owns, so
  # `Meetings.fetch_meeting_for_user/2` resolves it.
  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "transcription_off_#{System.unique_integer([:positive])}@example.com",
        name: "Transcription Off User",
        oidc_sub: "oidc-transcription-off-#{System.unique_integer([:positive])}"
      })

    org_id = Platform.TenancyFixtures.acme_org_id()

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org_id, role: "member"})
    |> Repo.insert!()

    init_test_session(conn, current_user_id: user.id)
  end

  defp create_meeting do
    n = System.unique_integer([:positive])

    {:ok, project} =
      %Project{}
      |> Project.changeset(%{
        name: "Transcription Off Project #{n}",
        slug: "transcription-off-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Transcription Off Space #{n}",
        slug: "transcription-off-space-#{n}",
        kind: "channel"
      })

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "transcription-off-#{n}",
        name: "Transcription off",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    meeting
  end

  defp count(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> Enum.count()

  defp transcript_pane_text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="meeting-transcript-wrap"]))
    |> LazyHTML.text()
  end

  test "meetings on with transcription off: the Transcript tab says captions are unavailable",
       %{conn: conn, meeting: meeting} do
    Application.put_env(:platform, :meeting_transcription, false)
    # DIRECTION CONTROL: meetings are on, transcription is not.
    assert Platform.Meetings.enabled?()
    refute Platform.Meetings.transcription_available?()

    {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=transcript")

    assert transcript_pane_text(html) =~ "Captions are unavailable for this meeting"
    refute transcript_pane_text(html) =~ "No speech yet."
    assert count(html, ~s([data-role="transcript-empty"])) == 1
  end

  test "meetings on with transcription unset: the pane still waits for speech",
       %{conn: conn, meeting: meeting} do
    Application.delete_env(:platform, :meeting_transcription)
    assert Platform.Meetings.transcription_available?()

    {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=transcript")

    assert transcript_pane_text(html) =~ "No speech yet."
    refute transcript_pane_text(html) =~ "Captions are unavailable"
  end
end
