defmodule Platform.Meetings.HumanAttendeeIdsTest do
  @moduledoc """
  `Platform.Meetings.human_attendee_ids/1` (task 01a1694a stage 1): the
  users whose presence in the meeting's room overlapped the meeting's actual
  window, minus agents, anonymous guests and external members.

  Every exclusion is asserted as an exact list in the same pass as the
  people who ARE included, so no exclusion can pass on an empty answer.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant
  alias Platform.Meetings.Room
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  defp user!(opts \\ []) do
    n = System.unique_integer([:positive])

    user =
      %User{}
      |> User.changeset(%{
        email: "attendee-#{n}@example.com",
        name: "Attendee #{n}",
        oidc_sub: "oidc-attendee-#{n}"
      })
      |> Repo.insert!()

    if Keyword.get(opts, :external, false) do
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: user.id, org_id: acme_org_id()})
    else
      %OrgMembership{}
      |> OrgMembership.changeset(%{user_id: user.id, org_id: acme_org_id(), role: "member"})
      |> Repo.insert!()
    end

    user
  end

  defp agent! do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "attendee-agent-#{n}",
      name: "Attendee Agent #{n}",
      status: "active"
    })
  end

  defp meeting_with_room! do
    n = System.unique_integer([:positive])
    {:ok, project} = Tasks.create_project(%{name: "Attendee Project #{n}", org_id: acme_org_id()})
    {:ok, meeting} = Meetings.create_meeting(%{project_id: project.id, name: "Attendance #{n}"})

    room =
      %Room{}
      |> Room.changeset(%{
        space_id: meeting.chat_space_id,
        livekit_room_name: "space-#{meeting.chat_space_id}"
      })
      |> Repo.insert!()

    {meeting, room}
  end

  defp present!(%Room{} = room, attrs) do
    %Participant{}
    |> Participant.changeset(Map.merge(%{room_id: room.id, display_name: "Someone"}, attrs))
    |> Repo.insert!()
  end

  defp ago(minutes), do: DateTime.add(DateTime.utc_now(), -minutes * 60, :second)

  # The meeting ran from 120 to 60 minutes ago.
  defp run!(%Meeting{} = meeting) do
    {:ok, live} =
      meeting |> Meeting.status_changeset("live", %{started_at: ago(120)}) |> Repo.update()

    {:ok, ended} =
      live |> Meeting.status_changeset("ended", %{ended_at: ago(60)}) |> Repo.update()

    ended
  end

  test "in-window humans are attendees; rejoiners, agents, guests and external members are not" do
    {meeting, room} = meeting_with_room!()

    in_window = user!()
    before_start_still_in = user!()
    left_before_start = user!()
    rejoined_after_end = user!()
    external = user!(external: true)
    agent_owner = user!()
    agent = agent!()

    # Joined and left inside the window.
    present!(room, %{user_id: in_window.id, joined_at: ago(110), left_at: ago(70)})
    # Joined before the start and never left.
    present!(room, %{user_id: before_start_still_in.id, joined_at: ago(150)})
    # Came and went before the meeting began.
    present!(room, %{user_id: left_before_start.id, joined_at: ago(200), left_at: ago(130)})
    # A rejoin of the room after the meeting ended.
    present!(room, %{user_id: rejoined_after_end.id, joined_at: ago(30)})
    # An external member, present the whole time.
    present!(room, %{user_id: external.id, joined_at: ago(115)})
    # An agent row. It carries a user id too, so the `agent_id IS NULL`
    # clause is the only thing keeping it out.
    present!(room, %{agent_id: agent.id, user_id: agent_owner.id, joined_at: ago(115)})
    # An anonymous guest: no user, no agent.
    present!(room, %{display_name: "Guest", joined_at: ago(115)})

    meeting = run!(meeting)

    assert Meetings.human_attendee_ids(meeting) ==
             Enum.sort([in_window.id, before_start_still_in.id])
  end

  # The orchestrator's ruling on task 01a1694a: guest status is judged against
  # the meeting's OWN org (its chat space's org), never against any org the
  # person happens to be external in. Both directions in one pass, so neither
  # verdict can hold on an empty answer.
  test "guest status is judged against the meeting's org only" do
    {meeting, room} = meeting_with_room!()
    other_org = tenant_org_id("globex")

    # A member here, and a guest in another org: an attendee.
    member_here_guest_elsewhere = user!()

    {:ok, _} =
      Tenancy.mark_membership_external(%{
        user_id: member_here_guest_elsewhere.id,
        org_id: other_org
      })

    # A guest in THIS org: not an attendee.
    guest_here = user!(external: true)

    present!(room, %{user_id: member_here_guest_elsewhere.id, joined_at: ago(110)})
    present!(room, %{user_id: guest_here.id, joined_at: ago(110)})

    assert Meetings.human_attendee_ids(run!(meeting)) == [member_here_guest_elsewhere.id]
  end

  test "a user present twice in the window is listed once" do
    {meeting, room} = meeting_with_room!()
    user = user!()

    present!(room, %{user_id: user.id, joined_at: ago(110), left_at: ago(100)})
    present!(room, %{user_id: user.id, joined_at: ago(90), left_at: ago(80)})

    assert Meetings.human_attendee_ids(run!(meeting)) == [user.id]
  end

  test "a meeting that never started has no attendees" do
    {meeting, room} = meeting_with_room!()
    user = user!()
    present!(room, %{user_id: user.id, joined_at: ago(10)})

    assert %Meeting{started_at: nil} = meeting
    assert Meetings.human_attendee_ids(meeting) == []
  end
end
