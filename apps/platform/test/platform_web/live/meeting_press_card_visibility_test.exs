defmodule PlatformWeb.MeetingPressCardVisibilityTest do
  @moduledoc """
  A push-to-talk press card is visible to EVERY participant, not only to
  the person holding the key (task 01a03f4e, plan v2 stage 3; Harper's
  ruling).

  ## Why this file mounts a second LiveView instead of re-reading the DB

  "Everyone can see it" is a claim about what a different person's
  browser renders. A second `Candidates.list_for_meeting/1` call from
  the same test process would prove only that the row exists, which the
  domain tests next door already prove — it cannot distinguish a card
  that is genuinely public from one the board scopes to its author. So
  the non-presser here is a SEPARATE user, with a separate
  authenticated conn and a separate `live/2` mount on the real route,
  and the assertion is made against the HTML that mount returned.

  ## And why this file renders nothing of its own

  Task 01a03f4e-78b1 owns the card's appearance and shipped it in #872.
  Stage 3 inserts a row and stops. That this test can assert on
  `[data-role='meeting-candidate-card']` — markup this task never
  wrote — IS the serialisation constraint being met: one surface, two
  producers.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PressCard
  alias Platform.Meetings.PressWindow
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership
  alias PlatformWeb.Components.Meetings.CandidateDisplay
  alias PlatformWeb.Components.Meetings.CandidateRail

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "press_card_#{label}_#{n}@example.com",
        name: "Press #{label} #{n}",
        oidc_sub: "oidc-press-card-#{label}-#{n}"
      })

    %OrgMembership{}
    |> OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Platform.TenancyFixtures.fabrikam_org_id(),
      role: "member"
    })
    |> Repo.insert!()

    user
  end

  defp conn_for(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp meeting!(users) do
    n = System.unique_integer([:positive])

    {:ok, project} =
      Platform.Tasks.create_project(%{
        name: "Press Card Project #{n}",
        org_id: Platform.TenancyFixtures.fabrikam_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "Press Card Meeting #{n}",
        slug: "press-card-meeting-#{n}"
      })

    for user <- users do
      {:ok, _} =
        Chat.add_participant(meeting.chat_space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name,
          joined_at: DateTime.utc_now()
        })
    end

    meeting
  end

  defp card_nodes(html, candidate_id) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-role='meeting-candidate-card'][data-candidate-id='#{candidate_id}']")
  end

  test "a participant who did NOT press sees the presser's card", %{conn: conn} do
    presser = user!("presser")
    observer = user!("observer")
    meeting = meeting!([presser, observer])

    on_exit(fn ->
      IntentQueue.stop(meeting.id)
      PressWindow.clear_meeting(meeting.id)
    end)

    # A meeting the observer is also in, whose card must NOT leak onto
    # the first board. Without this a selector that matched every card on
    # the page would pass the assertion below for the wrong reason.
    other_meeting = meeting!([observer])

    on_exit(fn ->
      IntentQueue.stop(other_meeting.id)
      PressWindow.clear_meeting(other_meeting.id)
    end)

    {:ok, _} =
      PressCard.open(meeting.id, "user:#{presser.id}", speaker: presser.name)

    {:ok, _} =
      PressCard.open(other_meeting.id, "user:#{observer.id}", speaker: observer.name)

    assert [card] = Candidates.open_for_meeting(meeting.id)
    assert [other_card] = Candidates.open_for_meeting(other_meeting.id)

    # ── The presser's own session sees it. Establishes that the card is
    # renderable at all, so a miss in the observer's session below is
    # about WHO is looking and not about the card being unrenderable.
    {:ok, _view, presser_html} =
      conn |> conn_for(presser) |> live("/meetings/#{meeting.slug}?no_autojoin=true")

    assert card_nodes(presser_html, card.id) |> Enum.count() == 1

    # ── The observer's session. Separate user, separate conn, separate
    # mount. This is the actual claim.
    {:ok, _view, observer_html} =
      conn |> conn_for(observer) |> live("/meetings/#{meeting.slug}?no_autojoin=true")

    assert card_nodes(observer_html, card.id) |> Enum.count() == 1

    # Negative control: the other meeting's card is NOT on this board,
    # so the match above is this card and not any card.
    assert card_nodes(observer_html, other_card.id) |> Enum.count() == 0
  end

  test "the press card renders as a skeleton — the existing component's own empty state",
       %{conn: conn} do
    presser = user!("presser")
    observer = user!("observer")
    meeting = meeting!([presser, observer])

    on_exit(fn ->
      IntentQueue.stop(meeting.id)
      PressWindow.clear_meeting(meeting.id)
    end)

    {:ok, _} = PressCard.open(meeting.id, "user:#{presser.id}", speaker: presser.name)
    assert [card] = Candidates.open_for_meeting(meeting.id)

    # The card carries no classification yet, which is the condition
    # `CandidateRail.presentation/1` already answers `:skeleton` for.
    # Stage 3 wrote no markup for this; the board's existing empty state
    # is what a pressed-but-not-yet-spoken card looks like.
    assert card.classified_intent == nil

    {:ok, _view, html} =
      conn |> conn_for(observer) |> live("/meetings/#{meeting.slug}?no_autojoin=true")

    nodes = card_nodes(html, card.id)
    assert Enum.count(nodes) == 1

    # Asserted through the component's OWN public predicate rather than
    # against an attribute name this task invented. `presentation/1` is
    # #872's contract for "we do not know what this is yet", and a press
    # card satisfies it without stage 3 having written any markup.
    assert CandidateRail.presentation(card) == :skeleton

    assert nodes |> LazyHTML.attribute("data-stage") |> List.first() ==
             CandidateDisplay.slug(:heard)
  end
end
