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

  test "feed request logging excludes credentials and nil scopes fail closed" do
    assert PlatformWeb.Endpoint.request_log_level(%Plug.Conn{
             path_info: ["calendar", "feed", "secret"]
           }) == false

    assert Calendar.create_event(nil, attrs()) == {:error, :forbidden}
    assert Calendar.list_events(nil, ~U[2026-10-01 00:00:00Z], ~U[2026-11-01 00:00:00Z]) == []
  end
end
