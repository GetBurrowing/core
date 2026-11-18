defmodule Platform.Calendar.BookingConcurrencyTest do
  use ExUnit.Case, async: false
  alias Platform.{Repo, Calendar}
  alias Platform.Calendar.{BookingHosts, BookingLinks, Booking, BookingLink}
  alias Platform.Access.Scope
  alias Ecto.Adapters.SQL.Sandbox
  import Ecto.Query
  alias Platform.Tenancy.{Org, OrgMembership}

  test "independent database connections contend on owner and one conflicting booking wins" do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%Platform.Accounts.User{
        email: "race-book#{n}@example.com",
        oidc_sub: "race-book#{n}",
        name: "Race owner"
      })

    scope = Scope.for_user(owner)
    date = Date.add(Date.utc_today(), 7)

    {:ok, link} =
      BookingLinks.create(scope, %{
        title: "Concurrent",
        start_date: date,
        end_date: date,
        time_zone: "Etc/UTC",
        duration_minutes: 30,
        windows: [%{"weekday" => Date.day_of_week(date), "start" => "10:00", "end" => "11:00"}]
      })

    {:ok, [slot | _]} = BookingLinks.slots(link.token, date)

    try do
      parent = self()

      tasks =
        for number <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go ->
                BookingLinks.book(
                  link.token,
                  %{
                    "name" => "Guest #{number}",
                    "starts_at" => DateTime.to_iso8601(slot.starts_at)
                  },
                  "race-idempotency-#{number}"
                )
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _}, 2000)
      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 15_000))
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :slot_unavailable}, &1)) == 1
      assert Repo.aggregate(from(b in Booking, where: b.owner_id == ^owner.id), :count) == 1
    after
      Repo.delete_all(from(b in Booking, where: b.owner_id == ^owner.id))
      Repo.delete_all(from(l in BookingLink, where: l.owner_id == ^owner.id))
      Repo.delete_all(from(e in Calendar.Event, where: e.owner_id == ^owner.id))
      Repo.delete!(owner)
      Sandbox.mode(Repo, :manual)
    end
  end

  # ── Shared links (task 01a1eff0-6880 stage 2) ──────────────────────────
  # Outside the sandbox, so everything is created here and deleted in
  # `after`. The org is a fresh tenant under the install's root; the root
  # is created (and dropped) only when the test DB has none.

  defp race_user!(tag, n) do
    Repo.insert!(%Platform.Accounts.User{
      email: "race-shared-#{tag}-#{n}@example.com",
      oidc_sub: "race-shared-#{tag}-#{n}",
      name: "Race #{tag}"
    })
  end

  defp race_link!(owner, date) do
    {:ok, link} =
      BookingLinks.create(Scope.for_user(owner), %{
        title: "Shared race",
        start_date: date,
        end_date: date,
        time_zone: "Etc/UTC",
        duration_minutes: 30,
        windows: [%{"weekday" => Date.day_of_week(date), "start" => "10:00", "end" => "10:30"}]
      })

    link
  end

  defp race_cohost!(owner, link, cohost) do
    {:ok, host} = BookingHosts.invite(Scope.for_user(owner), link.id, cohost.id)
    {:ok, _} = BookingHosts.accept(Scope.for_user(cohost), host.id)
  end

  defp with_shared_world(tags, fun) do
    Sandbox.mode(Repo, :auto)
    n = System.unique_integer([:positive])

    created_root =
      case Platform.Tenancy.get_root_org() do
        nil -> Repo.insert!(%Org{name: "Race root #{n}", slug: "race-root-#{n}"})
        _ -> nil
      end

    root = created_root || Platform.Tenancy.get_root_org()

    org =
      Repo.insert!(%Org{name: "Race org #{n}", slug: "race-org-#{n}", parent_org_id: root.id})

    users = Map.new(tags, &{&1, race_user!(&1, n)})
    ids = Enum.map(users, fn {_, u} -> u.id end)

    for {_, u} <- users,
        do: Repo.insert!(%OrgMembership{user_id: u.id, org_id: org.id, role: "member"})

    try do
      fun.(users)
    after
      Repo.delete_all(
        from(b in Booking,
          where:
            b.owner_id in ^ids or
              fragment("? && ?", b.host_user_ids, type(^ids, {:array, Ecto.UUID}))
        )
      )

      Repo.delete_all(from(l in BookingLink, where: l.owner_id in ^ids))
      Repo.delete_all(from(e in Calendar.Event, where: e.owner_id in ^ids))
      Repo.delete_all(from(i in Platform.Inbox.Item, where: i.user_id in ^ids))
      Repo.delete_all(from(m in OrgMembership, where: m.user_id in ^ids))
      Repo.delete_all(from(u in Platform.Accounts.User, where: u.id in ^ids))
      Repo.delete!(org)
      if created_root, do: Repo.delete!(created_root)
      Sandbox.mode(Repo, :manual)
    end
  end

  defp race(bookings) do
    parent = self()

    tasks =
      for {token, slot, number} <- bookings do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              BookingLinks.book(
                token,
                %{
                  "name" => "Guest #{number}",
                  "starts_at" => DateTime.to_iso8601(slot.starts_at)
                },
                "shared-race-key-#{number}-#{System.unique_integer([:positive])}"
              )
          end
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 2000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  test "two links sharing a co-host race for one slot and exactly one books" do
    with_shared_world([:a, :b, :c], fn %{a: a, b: b, c: c} ->
      date = Date.add(Date.utc_today(), 7)
      l1 = race_link!(a, date)
      l2 = race_link!(c, date)
      race_cohost!(a, l1, b)
      race_cohost!(c, l2, b)
      {:ok, [slot]} = BookingLinks.slots(l1.token, date)
      {:ok, [^slot]} = BookingLinks.slots(l2.token, date)

      results = race([{l1.token, slot, 1}, {l2.token, slot, 2}])
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
      assert Enum.count(results, &match?({:error, :slot_unavailable}, &1)) == 1, inspect(results)

      holding_b =
        Repo.aggregate(
          from(r in Booking,
            where: fragment("? = ANY(?)", type(^b.id, Ecto.UUID), r.host_user_ids)
          ),
          :count
        )

      assert holding_b == 1
    end)
  end

  test "links whose hosts lock in opposite list orders do not deadlock" do
    with_shared_world([:a, :b], fn %{a: a, b: b} ->
      date = Date.add(Date.utc_today(), 8)
      # L1 lists A then B; L3 lists B then A. Sorted locking takes them in
      # one order whichever link is booked.
      l1 = race_link!(a, date)
      l3 = race_link!(b, date)
      race_cohost!(a, l1, b)
      race_cohost!(b, l3, a)
      {:ok, [slot]} = BookingLinks.slots(l1.token, date)

      started = System.monotonic_time(:millisecond)
      results = race([{l1.token, slot, 3}, {l3.token, slot, 4}])
      assert System.monotonic_time(:millisecond) - started < 15_000
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)
      assert Enum.count(results, &match?({:error, :slot_unavailable}, &1)) == 1, inspect(results)
    end)
  end
end
