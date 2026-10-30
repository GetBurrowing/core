defmodule PlatformWeb.MeetingRejoinAskTest do
  @moduledoc """
  Task 01a1265f stage 2: Ask in a REJOINED ended meeting.

  The room empties, `room_finished` ends the meeting and stamps `ended_at`.
  Someone explicitly joins the call again from the meeting's page. The new transcript
  starts after `ended_at`, so #902's bound in `Meetings.meeting_id_for_space/2`
  resolves it to nil. `MeetingLive`'s transcript clause matches on
  `^meeting_id`, so nothing reaches the ask veil, and the press closes as
  nothing heard.

  The fix resumes the meeting from `maybe_start_meeting/1`, the helper both
  join sites on the meeting page already go through. These tests drive the
  real path: a connected mount of an ENDED meeting, an explicit Join, a real press, and a
  segment persisted through `Meetings.append_segment/2` on a transcript that
  began after the original end, so the `meeting_id` on the broadcast comes
  from production code, not from the test.

  The scope controls pin #902's guarantee from the other side: a mount that
  does not join, and a join that does not come from the meeting page, both
  leave the meeting ended.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.PressWindow
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "rejoin_ask_#{n}@example.com",
        name: "Rejoin Ask #{n}",
        oidc_sub: "oidc-rejoin-ask-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.acme_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Rejoin Ask Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Rejoin Ask Meeting #{n}",
        slug: "rejoin-ask-meeting-#{n}"
      })

    {:ok, _} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    # The meeting happened and is over: started two hours ago, ended an hour
    # ago. Stamped directly so the times are unambiguous relative to the
    # rejoin transcript below.
    now = DateTime.utc_now()
    started_at = DateTime.add(now, -2 * 3600, :second)
    ended_at = DateTime.add(now, -3600, :second)

    {1, _} =
      Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id),
        set: [status: "ended", started_at: started_at, ended_at: ended_at]
      )

    on_exit(fn ->
      IntentQueue.stop(meeting.id)
      PressWindow.clear_meeting(meeting.id)
    end)

    conn = init_test_session(conn, current_user_id: user.id)

    %{
      conn: conn,
      user: user,
      meeting: Repo.get!(Meeting, meeting.id),
      started_at: started_at,
      ended_at: ended_at
    }
  end

  defp room_name(meeting), do: Meetings.room_name_for_space(meeting.chat_space_id)

  # A transcript for this meeting's room that began AFTER the meeting ended:
  # the rejoin case. Same `ensure_transcript/1` the transcriber calls.
  defp rejoin_transcript!(meeting, ended_at) do
    {:ok, transcript} =
      Meetings.ensure_transcript(%{
        room_id: room_name(meeting),
        space_id: meeting.chat_space_id,
        started_at: DateTime.add(ended_at, 30 * 60, :second)
      })

    assert DateTime.compare(transcript.started_at, ended_at) == :gt
    transcript
  end

  describe "rejoining an ended meeting from its own page" do
    test "explicit Join resumes it; Ask hears the rejoined call, attributed to this meeting",
         %{conn: conn, user: user, meeting: meeting, started_at: started_at, ended_at: ended_at} do
      assert meeting.status == "ended"

      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?tab=canvas")
      # A normal connected page view is read-only for an ended meeting.
      _ = render(view)
      assert Repo.get!(Meeting, meeting.id).status == "ended"
      view |> element(~s([data-role="meeting-join"])) |> render_click()

      resumed = Repo.get!(Meeting, meeting.id)
      assert resumed.status == "live"
      assert resumed.ended_at == nil
      assert resumed.started_at == started_at

      transcript = rejoin_transcript!(meeting, ended_at)
      :ok = MeetingsPubSub.subscribe_transcript_chunk(room_name(meeting))

      assert render_hook(view, "push_to_talk_press", %{})

      assert {:ok, _} =
               Meetings.append_segment(transcript.id, %{
                 "participant_identity" => "user:#{user.id}",
                 "text" => "can you hear me after the rejoin",
                 "final" => true
               })

      meeting_id = meeting.id

      assert_receive {:transcript_chunk,
                      %{transcript_id: transcript_id, meeting_id: ^meeting_id} = _payload},
                     1_000

      assert transcript_id == transcript.id

      _ = render(view)

      assert_push_event(view, "meeting_ask_transcript_chunk", %{
        "text" => "can you hear me after the rejoin"
      })

      assert render_hook(view, "push_to_talk_release", %{})
    end
  end

  describe "the meetings index" do
    # The index re-renders on `{:meeting_resumed, _}`, the distinct tag
    # `Meetings.resume_meeting/2` broadcasts so `MeetingNotifier` never sees a
    # resume as a start. Placed at 11:00-12:00 UTC today so it is on the
    # calendar the index renders.
    test "a resume re-renders the meeting as live without a reload",
         %{conn: conn, meeting: meeting} do
      today = PlatformWeb.MeetingLive.calendar_today_date("Etc/UTC")
      {:ok, start_at} = DateTime.new(today, ~T[11:00:00.000000], "Etc/UTC")
      {:ok, end_at} = DateTime.new(today, ~T[12:00:00.000000], "Etc/UTC")

      {1, _} =
        Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id),
          set: [scheduled_start_at: start_at, scheduled_end_at: end_at]
        )

      conn = put_connect_params(conn, %{"timezone" => "Etc/UTC"})
      {:ok, view, html} = live(conn, "/meetings")

      selector = ~s([data-role="calendar-event"][data-meeting-id="#{meeting.id}"])
      assert statuses(html, selector) != []
      assert Enum.uniq(statuses(html, selector)) == ["ended"]

      assert {:ok, _} = Meetings.resume_meeting(Repo.get!(Meeting, meeting.id))

      assert Enum.uniq(statuses(render(view), selector)) == ["live"]
    end
  end

  describe "#902's guarantee: every other way in leaves it ended" do
    test "a mount that does not join (?no_autojoin=true) leaves it ended",
         %{conn: conn, meeting: meeting, ended_at: ended_at} do
      {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true")
      _ = render(view)

      still = Repo.get!(Meeting, meeting.id)
      assert still.status == "ended"
      assert still.ended_at == ended_at
    end

    test "joining the call through Meetings.join_for_user/3 (chat Meet, native) leaves it ended",
         %{user: user, meeting: meeting, ended_at: ended_at} do
      # The test env has no LiveKit credentials, so the join ends at token
      # minting with `{:error, :livekit_not_configured}`. Everything before
      # that ran: the viewer is seated in the room, which is what the
      # assertion on the roster below proves. A join that failed earlier
      # would make the "still ended" assertions vacuous.
      result = Meetings.join_for_user(meeting.chat_space_id, user.id, user.name)
      assert match?({:ok, %{token: _}}, result) or result == {:error, :livekit_not_configured}
      assert Meetings.active_participants_for_space(meeting.chat_space_id) != []

      still = Repo.get!(Meeting, meeting.id)
      assert still.status == "ended"
      assert still.ended_at == ended_at

      transcript = rejoin_transcript!(meeting, ended_at)
      assert Meetings.meeting_id_for_space(meeting.chat_space_id, transcript.started_at) == nil
    end
  end

  defp statuses(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-meeting-status")
  end
end
