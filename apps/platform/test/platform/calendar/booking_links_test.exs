defmodule Platform.Calendar.BookingLinksTest do
  use Platform.DataCase, async: false
  alias Platform.{Calendar, Repo}
  alias Platform.Calendar.{BookingLinks, Booking, Subscription}
  alias Platform.Access.Scope
  alias Platform.Accounts.User
  defp scope do
    n = System.unique_integer([:positive])
    Scope.for_user(Repo.insert!(%User{email: "booking#{n}@example.com", oidc_sub: "booking#{n}", name: "Owner"}))
  end
  defp attrs(extra \\ %{}) do
    date = Date.add(Date.utc_today(), 7)
    Map.merge(%{title: "Office hours", time_zone: "Etc/UTC", duration_minutes: 30,
      start_date: date, end_date: Date.add(date, 30),
      windows: [%{"weekday" => Date.day_of_week(date), "start" => "09:00", "end" => "12:00"}]}, extra)
  end
  defp create(owner, extra \\ %{}) do
    {:ok, link} = BookingLinks.create(owner, attrs(extra))
    link
  end
  defp guest(slot, extra \\ %{}), do: Map.merge(%{"name" => "Booker", "email" => "guest@example.com", "starts_at" => DateTime.to_iso8601(slot.starts_at)}, extra)

  test "owner policy validation, private settings, revocation and malformed input" do
    owner = scope()
    other = scope()
    link = create(owner)
    assert [] == BookingLinks.list(other)
    assert {:error, :not_found} = BookingLinks.revoke(other, link.id)
    assert {:error, _} = BookingLinks.create(owner, attrs(%{time_zone: "fake/zone"}))
    assert {:error, _} = BookingLinks.create(owner, attrs(%{duration_minutes: 0}))
    assert {:error, _} = BookingLinks.create(owner, attrs(%{end_date: Date.add(Date.utc_today(), 800)}))
    assert {:error, _} = BookingLinks.create(owner, attrs(%{windows: [%{"weekday" => 8, "start" => "09:00", "end" => "10:00"}]}))
    assert {:error, :not_found} = BookingLinks.slots("invalid", link.start_date)
    assert {:ok, []} = BookingLinks.slots(link.token, Date.add(link.end_date, 1))
    assert {:ok, _} = BookingLinks.revoke(owner, link.id)
    assert {:error, :not_found} = BookingLinks.slots(link.token, link.start_date)
  end

  test "only offered slots book, native conflicts and both buffers block, replay does not duplicate" do
    owner = scope()
    link = create(owner, %{buffer_before_minutes: 15, buffer_after_minutes: 15})
    {:ok, [first | _]} = BookingLinks.slots(link.token, link.start_date)
    {:ok, booked} = BookingLinks.book(link.token, guest(first, %{"create_meeting" => "true", "project_id" => "forged"}), "first-key-00000000")
    assert booked.event_id
    refute booked.meeting_id
    assert {:ok, replay} = BookingLinks.book(link.token, guest(first), "first-key-00000000")
    assert replay.id == booked.id
    assert Repo.aggregate(Booking, :count) == 1
    assert {:error, :idempotency_conflict} = BookingLinks.book(link.token, guest(first, %{"name" => "Other"}), "first-key-00000000")
    assert {:error, :slot_unavailable} = BookingLinks.book(link.token, guest(first), "second-key-0000000")
    {:ok, slots} = BookingLinks.slots(link.token, link.start_date)
    refute Enum.any?(slots, &(DateTime.diff(&1.starts_at, first.starts_at) in [0, 1800]))
    assert {:ok, event} = Calendar.create_event(owner, %{title: "Secret", starts_at: DateTime.add(first.starts_at, 7200), ends_at: DateTime.add(first.starts_at, 9000)})
    {:ok, slots} = BookingLinks.slots(link.token, link.start_date)
    refute Enum.any?(slots, &(&1.starts_at == event.starts_at))
    off_grid = %{first | starts_at: DateTime.add(first.starts_at, 7)}
    assert {:error, :slot_unavailable} = BookingLinks.book(link.token, guest(off_grid), "off-grid-key-00000")
    assert {:error, :invalid_guest} = BookingLinks.book(link.token, guest(first, %{"email" => "not-email"}), "invalid-guest-key")
  end

  test "reservations conflict across separate links and stale external feeds fail closed" do
    owner = scope()
    first_link = create(owner)
    second_link = create(owner)
    {:ok, [slot | _]} = BookingLinks.slots(first_link.token, first_link.start_date)
    assert {:ok, _} = BookingLinks.book(first_link.token, guest(slot), "cross-link-key-000")
    assert {:error, :slot_unavailable} = BookingLinks.book(second_link.token, guest(slot), "cross-link-key-001")
    Repo.insert!(%Subscription{owner_id: owner.actor.id, name: "Not refreshed", url: "https://example.com/feed.ics"})
    assert {:error, :external_coverage_unknown} = BookingLinks.slots(second_link.token, second_link.start_date)
  end

  test "DST gap and repeated wall times are omitted; actual duration is fixed" do
    owner = scope()
    for date <- [~D[2027-03-14], ~D[2027-11-07]] do
      link = create(owner, %{start_date: date, end_date: date, time_zone: "America/Chicago",
        windows: [%{"weekday" => 7, "start" => "00:00", "end" => "05:00"}]})
      {:ok, slots} = BookingLinks.slots(link.token, date)
      assert slots != []
      assert Enum.all?(slots, &(DateTime.diff(&1.ends_at, &1.starts_at) == 1800))
      local = Enum.map(slots, &DateTime.shift_zone!(&1.starts_at, "America/Chicago"))
      refute Enum.any?(local, &(&1.hour == if(date.month == 3, do: 2, else: 1)))
    end
  end

  test "Meetings disabled refuses owner policy and rechecks persisted policy" do
    old = Application.get_env(:platform, :meetings_enabled)
    Application.put_env(:platform, :meetings_enabled, false)
    on_exit(fn -> Application.put_env(:platform, :meetings_enabled, old) end)
    owner = scope()
    assert {:error, :meetings_unavailable} = BookingLinks.create(owner, attrs(%{create_meeting: true}))
    link = create(owner)
    Repo.update!(Ecto.Changeset.change(link, create_meeting: true))
    assert {:error, :meetings_unavailable} = BookingLinks.slots(link.token, link.start_date)
  end

  test "hourly booking limit is counted under the owner lock across links" do
    owner = scope()
    link = create(owner)
    {:ok, [slot | _]} = BookingLinks.slots(link.token, link.start_date)
    for n <- 1..20 do
      Repo.insert!(%Booking{link_id: link.id, owner_id: owner.actor.id, idempotency_key: "existing-#{n}", name: "Existing",
        starts_at: DateTime.add(slot.starts_at, -86400), ends_at: DateTime.add(slot.ends_at, -86400),
        reserved_start: DateTime.add(slot.starts_at, -86400), reserved_end: DateTime.add(slot.ends_at, -86400)})
    end
    assert {:error, :rate_limited} = BookingLinks.book(link.token, guest(slot), "over-limit-key-000")
  end
end
