defmodule PlatformWeb.MeetingPushToTalkPressTest do
  @moduledoc """
  A push-to-talk press through the REAL member mount opens a card
  (task 01a06638 stage 5).

  `meeting_press_card_visibility_test.exs` calls `PressCard.open/3`
  directly and `meeting_push_to_talk_control_test.exs` asserts markup
  only, so nothing drove the `push_to_talk_press` event through a socket
  `PlatformWeb.ShellLive.on_mount/4` had populated. That mount assigns
  `:current_user` as a display STRING and keeps the `%User{}` under
  `:current_user_record`; `press_identity/1` matched `%{id: _}` on the
  string, fell through, and no authenticated press ever reached
  `PressCard.open/3`. This file is the event, end to end: session ->
  `live/2` on `/meetings/:slug` -> `render_hook/3` -> `meeting_candidates`.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PressWindow
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "ptt_press_#{n}@example.com",
        name: "PTT Presser #{n}",
        oidc_sub: "oidc-ptt-press-#{n}"
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
        name: "PTT Press Project #{n}",
        org_id: Platform.TenancyFixtures.acme_org_id()
      })

    {:ok, meeting} =
      Meetings.create_meeting(%{
        project_id: project.id,
        name: "PTT Press Meeting #{n}",
        slug: "ptt-press-meeting-#{n}"
      })

    {:ok, _} =
      Chat.add_participant(meeting.chat_space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    on_exit(fn ->
      IntentQueue.stop(meeting.id)
      PressWindow.clear_meeting(meeting.id)
    end)

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, view, _html} = live(conn, "/meetings/#{meeting.slug}?no_autojoin=true&tab=canvas")

    %{view: view, user: user, meeting: meeting}
  end

  defp card_nodes(html, candidate_id) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[data-role='meeting-candidate-card'][data-candidate-id='#{candidate_id}']")
  end

  # The rail re-renders off an async `:candidate_event` broadcast.
  defp await_card(view, candidate_id, tries \\ 40) do
    html = render(view)

    cond do
      Enum.count(card_nodes(html, candidate_id)) == 1 ->
        html

      tries == 0 ->
        html

      true ->
        Process.sleep(25)
        await_card(view, candidate_id, tries - 1)
    end
  end

  test "pressing through the mounted LiveView opens an unclassified card for THIS user",
       %{view: view, user: user, meeting: meeting} do
    assert Candidates.open_for_meeting(meeting.id) == []

    assert render_hook(view, "push_to_talk_press", %{})

    assert [card] = Candidates.open_for_meeting(meeting.id),
           "expected the press to open exactly one candidate row for the meeting"

    assert card.classified_intent == nil
    assert card.transcript_chunk_id == nil
    assert card.state != :closed

    # The window is keyed on the identity the socket minted — the same
    # `"user:<id>"` the LiveKit token carries — and not on anything the
    # event payload could have named.
    assert %{card_intent_id: intent_id, released_at: nil} =
             PressWindow.get(meeting.id, "user:#{user.id}")

    assert intent_id == card.intent_id

    # And the presser's own rail shows the armed card.
    html = await_card(view, card.id)
    assert Enum.count(card_nodes(html, card.id)) == 1

    # Release closes the window (grace pending); the card is untouched.
    assert render_hook(view, "push_to_talk_release", %{})
    assert %{released_at: %DateTime{}} = PressWindow.get(meeting.id, "user:#{user.id}")
    assert [_still_open] = Candidates.open_for_meeting(meeting.id)
  end

  test "pressing a SPECIFIC agent bylines the card and the window to that agent",
       %{view: view, user: user, meeting: meeting} do
    n = System.unique_integer([:positive])

    agent =
      %Agent{}
      |> Agent.changeset(%{slug: "octavius-#{n}", name: "Octavius #{n}", status: "active"})
      |> Repo.insert!()

    # The human held THIS agent's row.
    assert render_hook(view, "push_to_talk_press", %{"agent_id" => agent.id})

    assert [card] = Candidates.open_for_meeting(meeting.id)
    # Bylined to the pressed agent from the instant the key went down —
    # not the configured default, and not resolved from the (empty) words.
    # (`meeting_candidates` names this `assigned_agent_id`; the intent-queue
    # row it mirrors calls the same value `target_agent_id`.)
    assert card.assigned_agent_id == agent.id
    assert card.assigned_agent_slug == agent.slug

    # And the window carries the same target, so it survives to
    # classification when the utterance arrives.
    assert %{target_agent_id: agent_id, target_agent_slug: slug} =
             PressWindow.get(meeting.id, "user:#{user.id}")

    assert agent_id == agent.id
    assert slug == agent.slug

    assert render_hook(view, "push_to_talk_release", %{})
  end

  test "a crafted agent id that names no active agent falls back rather than bylining a stranger",
       %{view: view, meeting: meeting} do
    assert render_hook(view, "push_to_talk_press", %{"agent_id" => Ecto.UUID.generate()})

    assert [card] = Candidates.open_for_meeting(meeting.id)
    # No default target is configured in this meeting, so the fallback is
    # "nobody" — never the stranger whose id was crafted.
    assert card.assigned_agent_id == nil

    assert render_hook(view, "push_to_talk_release", %{})
  end
end
