defmodule Platform.CalendarTest do
  use Platform.DataCase, async: true
  alias Platform.{Calendar, Repo}
  alias Platform.Access.Scope
  alias Platform.Accounts.User

  defp user do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "calendar-#{n}@example.com",
      name: "Calendar #{n}",
      oidc_sub: "calendar-#{n}"
    })
  end

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        title: "Private interview",
        starts_at: ~U[2026-10-30 19:00:00.000000Z],
        ends_at: ~U[2026-10-30 20:00:00.000000Z],
        time_zone: "America/Chicago"
      },
      extra
    )
  end

  test "private events stay private and mutations recheck owner" do
    owner = Scope.for_user(user())
    other = Scope.for_user(user())
    assert {:ok, event} = Calendar.create_event(owner, attrs())
    assert {:error, :not_found} = Calendar.get_event(other, event.id)
    assert {:error, :not_found} = Calendar.update_event(other, event.id, %{title: "Forged"})
    assert {:error, :not_found} = Calendar.delete_event(other, event.id)
    assert [] == Calendar.list_events(other, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z])
    assert {:ok, updated} = Calendar.update_event(owner, event.id, %{title: "Confirmed"})
    assert updated.sequence == 1
    assert {:ok, cancelled} = Calendar.delete_event(owner, event.id)
    assert cancelled.sequence == 2
    assert Calendar.list_events(owner, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z]) == []

    assert ICalendar.from_ics(Calendar.Feed.render(owner)) |> hd() |> Map.fetch!(:status) ==
             "cancelled"
  end

  test "feed credentials are hashed, rotated and revoked" do
    owner = Scope.for_user(user())
    assert {:ok, token} = Calendar.rotate_feed(owner)
    row = Repo.get_by!(Calendar.FeedToken, owner_id: owner.actor.id)
    refute row.token_hash == token
    assert row.token_hash == :crypto.hash(:sha256, token)
    assert {:ok, scope} = Calendar.feed_scope(token)
    assert scope.actor.id == owner.actor.id
    assert {:ok, next} = Calendar.rotate_feed(owner)
    assert {:error, :not_found} = Calendar.feed_scope(token)
    assert {:ok, _} = Calendar.feed_scope(next)
    assert :ok = Calendar.revoke_feed(owner)
    assert {:error, :not_found} = Calendar.feed_scope(next)
    assert {:error, :not_found} = Calendar.feed_scope("malformed")
  end

  test "project events keep the membership boundary for root-org members" do
    root_member = user()
    tenant_member = user()
    root_id = Platform.TenancyFixtures.acme_org_id()
    tenant_id = Platform.TenancyFixtures.tenant_org_id("initech")

    for {member, org_id} <- [{root_member, root_id}, {tenant_member, tenant_id}] do
      Repo.insert!(%Platform.Tenancy.OrgMembership{
        user_id: member.id,
        org_id: org_id,
        role: "member"
      })
    end

    n = System.unique_integer([:positive])

    root_project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Root calendar",
        slug: "root-calendar-#{n}",
        org_id: root_id
      })

    tenant_project =
      Repo.insert!(%Platform.Tasks.Project{
        name: "Tenant calendar",
        slug: "tenant-calendar-#{n}",
        org_id: tenant_id
      })

    root_scope = Scope.for_user(root_member)
    tenant_scope = Scope.for_user(tenant_member)
    assert {:ok, own} = Calendar.create_event(root_scope, attrs(%{project_id: root_project.id}))

    assert {:ok, foreign} =
             Calendar.create_event(tenant_scope, attrs(%{project_id: tenant_project.id}))

    assert {:error, :forbidden} =
             Calendar.create_event(root_scope, attrs(%{project_id: tenant_project.id}))

    ids =
      Calendar.list_events(root_scope, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z])
      |> Enum.map(& &1.id)

    assert own.id in ids
    refute foreign.id in ids
  end

  test "a private space event is visible to its members and absent from another member's feed" do
    owner = user()
    member = user()
    outsider = user()
    org_id = Platform.TenancyFixtures.acme_org_id()

    for actor <- [owner, member, outsider] do
      Repo.insert!(%Platform.Tenancy.OrgMembership{
        user_id: actor.id,
        org_id: org_id,
        role: "member"
      })
    end

    n = System.unique_integer([:positive])

    {:ok, space} =
      Platform.Chat.create_space(%{
        name: "Private calendar conversation",
        slug: "calendar-private-#{n}",
        kind: "dm",
        org_id: org_id
      })

    for actor <- [owner, member] do
      {:ok, _} =
        Platform.Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: actor.id,
          joined_at: DateTime.utc_now()
        })
    end

    {:ok, event} =
      Calendar.create_event(
        Scope.for_user(owner),
        attrs(%{title: "Private DM appointment", space_id: space.id})
      )

    member_scope = Scope.for_user(member)
    assert {:ok, _} = Calendar.get_event(member_scope, event.id)
    assert Calendar.Feed.render(member_scope) =~ "Private DM appointment"
    assert Enum.any?(Calendar.list_spaces(member_scope), &(&1.id == space.id))
    refute Enum.any?(Calendar.list_spaces(Scope.for_user(outsider)), &(&1.id == space.id))
    assert {:error, :not_found} = Calendar.get_event(Scope.for_user(outsider), event.id)
    refute Calendar.Feed.render(Scope.for_user(outsider)) =~ "Private DM appointment"

    participant =
      Repo.get_by!(Platform.Chat.Participant, space_id: space.id, participant_id: member.id)

    assert {:ok, _} = Platform.Chat.remove_participant(participant)
    assert {:error, :not_found} = Calendar.get_event(member_scope, event.id)
    refute Calendar.Feed.render(member_scope) =~ "Private DM appointment"
    refute Enum.any?(Calendar.list_spaces(member_scope), &(&1.id == space.id))
  end

  test "all-day dates preserve exclusive end across DST" do
    owner = Scope.for_user(user())

    assert {:ok, event} =
             Calendar.create_event(owner, %{
               title: "Away",
               all_day: true,
               start_date: ~D[2026-11-01],
               end_date: ~D[2026-11-02],
               time_zone: "America/Chicago"
             })

    assert DateTime.diff(event.ends_at, event.starts_at, :hour) == 25
    [parsed] = ICalendar.from_ics(Calendar.Feed.render(owner))
    assert parsed.summary == "Away"

    assert {:error, changeset} =
             Calendar.create_event(owner, %{
               title: "Invalid",
               all_day: true,
               start_date: ~D[2026-11-01],
               end_date: ~D[2026-11-01]
             })

    refute changeset.valid?
  end

  test "recurrence preserves local wall clock and exceptions across DST" do
    owner = Scope.for_user(user())

    assert {:ok, _} =
             Calendar.create_event(
               owner,
               attrs(%{recurrence: "FREQ=WEEKLY;COUNT=3", exception_dates: [~D[2026-11-06]]})
             )

    occurrences = Calendar.list_events(owner, ~U[2026-10-29 00:00:00Z], ~U[2026-11-15 00:00:00Z])

    assert Enum.map(occurrences, & &1.starts_at) == [
             ~U[2026-10-30 19:00:00.000000Z],
             ~U[2026-11-13 20:00:00.000000Z]
           ]

    assert {:error, _} = Calendar.create_event(owner, attrs(%{recurrence: "FREQ=SECONDLY"}))
  end

  test "shared busy event redacts title and description for other readers" do
    owner = Scope.for_user(user())
    other = Scope.for_user(user())
    space = Repo.insert!(%Platform.Chat.Space{kind: "group", name: "Shared"})

    for actor <- [owner.actor, other.actor] do
      Repo.insert!(%Platform.Chat.Participant{
        space_id: space.id,
        participant_type: "user",
        participant_id: actor.id,
        joined_at: DateTime.utc_now()
      })
    end

    owner = Scope.for_user(owner.actor)
    other = Scope.for_user(other.actor)

    assert {:ok, event} =
             Calendar.create_event(
               owner,
               attrs(%{space_id: space.id, visibility: "busy", description: "Secret"})
             )

    assert {:ok, %{title: "Busy", description: nil}} = Calendar.get_event(other, event.id)
    assert {:ok, %{title: "Private interview"}} = Calendar.get_event(owner, event.id)
    [parsed] = ICalendar.from_ics(Calendar.Feed.render(other))
    assert parsed.summary == "Busy"
  end

  # Task 01a18d9f fix round: the editor promises the iCal feed shows "Busy"
  # for a busy-only event, and the feed is a bearer URL that leaves Burrow,
  # so the owner's own feed is redacted too; in-app reads are not.
  test "the owner's own feed shows a busy-only event as Busy, with no notes" do
    owner = Scope.for_user(user())

    assert {:ok, event} =
             Calendar.create_event(owner, attrs(%{visibility: "busy", description: "Secret"}))

    assert {:ok, %{title: "Private interview", description: "Secret"}} =
             Calendar.get_event(owner, event.id)

    feed = Calendar.Feed.render(owner)
    [parsed] = ICalendar.from_ics(feed)
    assert parsed.summary == "Busy"
    refute feed =~ "Private interview"
    refute feed =~ "Secret"

    # Positive control: a full-details event keeps its title in the same feed.
    assert {:ok, _} = Calendar.update_event(owner, event.id, %{visibility: "details"})
    assert Calendar.Feed.render(owner) =~ "Private interview"
  end

  test "feed request logging excludes credentials and nil scopes fail closed" do
    assert PlatformWeb.Endpoint.request_log_level(%Plug.Conn{
             path_info: ["calendar", "feed", "secret"]
           }) == false

    assert Calendar.create_event(nil, attrs()) == {:error, :forbidden}
    assert Calendar.list_events(nil, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z]) == []
  end
end
