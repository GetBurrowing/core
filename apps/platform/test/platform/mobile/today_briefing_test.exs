defmodule Platform.Mobile.TodayBriefingTest do
  @moduledoc """
  Task 01a161f9 stage 1: `Mobile.today_briefing_for_user/2`, the read behind
  `GET /api/app/briefing`. Today is the America/Chicago date the
  disseminator writes `digest_date` in, and only the caller's own row is
  ever read.
  """
  use Platform.DataCase, async: false

  import Platform.InsightFixtures

  alias Platform.Memory.Briefing
  alias Platform.Memory.Insights.BriefingCard
  alias Platform.Memory.Insights.Disseminator
  alias Platform.Mobile
  alias Platform.Repo

  @receipt %{"verb" => "dismiss", "at" => "2026-10-22T08:00:00Z", "undo" => %{}}

  # `calls` needs-call items, `fyi` FYI items and `done` handled items.
  defp briefing!(user, date, calls, fyi, done) do
    needs = for _ <- 1..calls//1, do: insight!(addressee: user, tier: "needs_call")
    fyis = for _ <- 1..fyi//1, do: insight!(addressee: user)
    dones = for _ <- 1..done//1, do: insight!(addressee: user, state: "dismissed")
    key = &BriefingCard.node_key(&1.id)

    Repo.insert!(%Briefing{
      user_id: user.id,
      digest_date: date,
      items: Map.new(needs ++ fyis ++ dones, &{key.(&1), &1.id}),
      receipts: Map.new(dones, &{key.(&1), @receipt})
    })
  end

  defp today, do: Disseminator.local_date(DateTime.utc_now())

  test "today's briefing as counts" do
    user = person!()
    briefing!(user, today(), 3, 0, 9)

    assert Mobile.today_briefing_for_user(user) == %{
             today: today(),
             briefing: %{date: today(), total: 12, open: 3, calls: 3, handled: 9}
           }
  end

  test "only yesterday's briefing reads as nil" do
    user = person!()
    briefing!(user, Date.add(today(), -1), 1, 1, 1)

    assert Mobile.today_briefing_for_user(user) == %{today: today(), briefing: nil}
  end

  test "today is the America/Chicago date: 04:30Z on the 23rd is the 22nd" do
    user = person!()
    briefing!(user, ~D[2026-10-22], 0, 2, 1)
    now = ~U[2026-10-23 04:30:00Z]

    assert %{today: ~D[2026-10-22], briefing: briefing} =
             Mobile.today_briefing_for_user(user, now: now)

    assert briefing == %{date: ~D[2026-10-22], total: 3, open: 2, calls: 0, handled: 1}

    assert %{today: ~D[2026-10-23], briefing: nil} =
             Mobile.today_briefing_for_user(user, now: ~U[2026-10-23 06:00:00Z])
  end

  test "owner scope: another user's briefing is never read" do
    a = person!()
    b = person!()
    briefing!(a, today(), 3, 0, 9)

    assert Mobile.today_briefing_for_user(b).briefing == nil

    briefing!(b, today(), 1, 2, 0)

    assert Mobile.today_briefing_for_user(b).briefing ==
             %{date: today(), total: 3, open: 3, calls: 1, handled: 0}

    assert Mobile.today_briefing_for_user(a).briefing ==
             %{date: today(), total: 12, open: 3, calls: 3, handled: 9}
  end
end
