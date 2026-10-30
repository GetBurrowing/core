defmodule Platform.Calendar.BookingConcurrencyTest do
  use ExUnit.Case, async: false
  alias Platform.{Repo, Calendar}
  alias Platform.Calendar.{BookingLinks, Booking, BookingLink}
  alias Platform.Access.Scope
  alias Ecto.Adapters.SQL.Sandbox
  import Ecto.Query

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
end
