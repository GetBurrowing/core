defmodule PlatformWeb.MeetingLiveCaptionsUnconfiguredTest do
  @moduledoc """
  NEGATIVE CONTROL for the transcript pane's empty state on `/meetings`
  (task 01a0693d).

  `captions_available` on `/meetings` is `@meetings_enabled`, i.e.
  `Platform.Meetings.enabled?/0` read at mount — the same value the
  quickmeet passes. The positive case (LiveKit triple present → "No
  speech yet…") lives in `meeting_live_test.exs` under "LiveKit wiring
  (stage 2)". This module pins the other branch: with NO LiveKit triple
  the pane must say captions are unavailable, not "none yet".

  Why a separate `async: false` module. `Meetings.enabled?/0` reads
  process-global application env, and the only way to make it false is
  to REMOVE the triple. Every other test that touches `:livekit` only
  ever SETS the same fake triple, so concurrent async modules agree with
  each other; a test that unsets it from an `async: true` module would
  race every meeting join running at the same moment. ExUnit runs sync
  modules after the async ones and one at a time, so this module holds
  the unconfigured env alone.

  History: the "right rail" describe in `meeting_live_test.exs` carried
  this assertion with a comment claiming the env was unconfigured, while
  its own setup stashed a fake triple. It was green anyway, because the
  value came from `@livekit_url`, which the signed-in path never assigns
  — the defect 01a0693d fixed. Moving the assertion here is what makes it
  a control rather than a coincidence.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])
    Application.put_env(:platform, :livekit, [])
    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    # DIRECTION CONTROL: the predicate the page reads is false here.
    refute Platform.Meetings.enabled?()

    {:ok, conn: authenticated_conn(conn), meeting: create_meeting()}
  end

  # Same shape as `meeting_live_test.exs`'s fixtures: a signed-in member
  # of the root org, and a meeting in a project that org owns, so
  # `Meetings.fetch_meeting_for_user/2` resolves it.
  defp authenticated_conn(conn) do
    user =
      Repo.insert!(%User{
        email: "captions_off_#{System.unique_integer([:positive])}@example.com",
        name: "Captions Off User",
        oidc_sub: "oidc-captions-off-#{System.unique_integer([:positive])}"
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
        name: "Captions Off Project #{n}",
        slug: "captions-off-project-#{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })
      |> Repo.insert()

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Captions Off Space #{n}",
        slug: "captions-off-space-#{n}",
        kind: "channel"
      })

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "captions-off-#{n}",
        name: "Captions off",
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

  test "with no LiveKit triple the Transcript tab says captions are unavailable, outside the host",
       %{conn: conn, meeting: meeting} do
    # NAMED MUTATION: `captions_available={true}` in `meeting_live.html.heex`
    # turns the first assertion red while the configured-env test stays
    # green; restoring `(assigns[:livekit_url] || "") != ""` keeps THIS
    # green and turns that one red — the pair is what proves the value is
    # the mount-time flag and not a constant.
    {:ok, _view, html} = live(conn, ~p"/meetings/#{meeting.slug}?tab=transcript")

    assert html =~ "Captions are unavailable for this meeting"
    refute html =~ "No speech yet."

    # Scoped to the TRANSCRIPT PANE's own subtree, not the whole page —
    # task 01a0fa7e-afd7 added a floating "Listening while you hold"
    # status line to the left rail's Ask-floor overlay (an unrelated
    # surface, canvas 01a0fa80-da74's own "Must keep" wording), and a
    # whole-page regex here would false-positive on that unrelated copy.
    # The negative control this guards — captions-unavailable copy must
    # never imply active listening — is still enforced, just at the
    # pane this test is actually about.
    refute transcript_pane_text(html) =~ ~r/listening/i

    assert count(html, ~s([data-role="transcript-empty"])) == 1

    assert count(html, ~s([data-role="meeting-transcript-wrap"] > [data-role="transcript-empty"])) ==
             1

    assert count(html, ~s([data-role="meeting-transcript"] [data-role="transcript-empty"])) == 0
  end
end
