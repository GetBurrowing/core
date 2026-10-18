defmodule Platform.Memory.Insights.PurgerTest do
  @moduledoc "Task 01a13867 stage 1: the hourly hard-delete of expired insights."

  use Platform.DataCase, async: false

  alias Platform.Memory.Insight
  alias Platform.Memory.Insights.Purger
  alias Platform.Memory.InsightVerdict
  alias Platform.Repo

  @now ~U[2026-10-18 12:00:00.000000Z]

  defp insight!(state, expires_at) do
    %Insight{}
    |> Insight.changeset(%{
      journal_path: "org/journal/2026-10-18.md",
      block_hash: "hash-#{System.unique_integer([:positive])}",
      run_id: Ecto.UUID.generate(),
      action_type: "briefing",
      confidence: "high",
      body: "body #{state}",
      state: state,
      expires_at: expires_at
    })
    |> Repo.insert!()
  end

  test "deletes every expired row whatever its state, and keeps the live ones" do
    past = DateTime.add(@now, -1, :second)
    future = DateTime.add(@now, 1, :hour)

    for state <- ~w(open done dismissed), do: insight!(state, past)
    live = insight!("open", future)

    assert {:ok, 3} = Purger.sweep(now: @now)
    assert [%Insight{id: id}] = Repo.all(Insight)
    assert id == live.id
  end

  test "never touches verdicts, however old" do
    Repo.insert!(%InsightVerdict{
      block_hash: "old",
      kind: "rejected",
      reason: "r",
      inserted_at: ~U[2020-01-01 00:00:00.000000Z]
    })

    insight!("open", DateTime.add(@now, -1, :day))

    assert {:ok, 1} = Purger.sweep(now: @now)
    assert Repo.aggregate(InsightVerdict, :count) == 1
  end

  test "a row expiring exactly now is kept until it is past" do
    insight!("open", @now)
    assert {:ok, 0} = Purger.sweep(now: @now)
    assert {:ok, 1} = Purger.sweep(now: DateTime.add(@now, 1, :microsecond))
  end

  test "a tick sweeps and reschedules" do
    insight!("done", DateTime.add(DateTime.utc_now(), -1, :second))
    {:ok, pid} = GenServer.start_link(Purger, [])
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    send(pid, :tick)
    _ = :sys.get_state(pid)
    assert Repo.aggregate(Insight, :count) == 0
    GenServer.stop(pid)
  end
end
