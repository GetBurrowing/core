defmodule Platform.People.SweepStateTest do
  @moduledoc """
  Task 01a1aa47 stage 4 — `Platform.People.SweepState` answers "is the HR
  daily sweep in flight" from persisted journal rows, and
  `maybe_wait_for_hr/2` never returns an error.
  """
  use Platform.DataCase, async: false

  alias Platform.Org.Context, as: OrgContext
  alias Platform.Org.WikiJournalEntry
  alias Platform.People.SweepState
  alias Platform.Repo

  @source "responsibility:hr.daily_sweep"

  setup do
    Repo.delete_all(WikiJournalEntry)
    :ok
  end

  defp row!(phase, at) do
    iso = DateTime.to_iso8601(at)
    at_key = if phase == "started", do: "started_at", else: "finished_at"

    {:ok, entry} =
      OrgContext.append_memory_entry(%{
        content: "HR daily sweep #{phase} #{iso}",
        date: DateTime.to_date(at),
        metadata: %{"source" => @source, "phase" => phase, at_key => iso}
      })

    entry
  end

  defp pure_row(phase, at, inserted_at) do
    at_key = if phase == "started", do: "started_at", else: "finished_at"

    %{
      inserted_at: inserted_at,
      metadata: %{"source" => @source, "phase" => phase, at_key => DateTime.to_iso8601(at)}
    }
  end

  defp attach_telemetry do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      "sweep-state-#{inspect(ref)}",
      SweepState.telemetry_event(),
      fn _event, measurements, meta, _ -> send(parent, {:hr_wait, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("sweep-state-#{inspect(ref)}") end)
  end

  test "status is in_flight after a started row and finished after a finished row" do
    now = DateTime.utc_now()
    assert SweepState.status(now) == :not_started

    started = DateTime.add(now, -5, :minute)
    row!("started", started)
    assert {:in_flight, at} = SweepState.status(DateTime.utc_now())

    assert DateTime.compare(DateTime.truncate(at, :second), DateTime.truncate(started, :second)) ==
             :eq

    finished = DateTime.add(now, -1, :minute)
    row!("finished", finished)
    assert {:finished, at} = SweepState.status(DateTime.utc_now())

    assert DateTime.compare(DateTime.truncate(at, :second), DateTime.truncate(finished, :second)) ==
             :eq

    # A row from another source is not HR's.
    {:ok, _} =
      OrgContext.append_memory_entry(%{
        content: "unrelated",
        date: Date.utc_today(),
        metadata: %{"source" => "responsibility:memory.daily_summary", "phase" => "started"}
      })

    assert {:finished, _} = SweepState.status(DateTime.utc_now())
  end

  test "status is timed_out once timeout_minutes have passed" do
    started = ~U[2026-10-20 09:00:00Z]
    rows = [pure_row("started", started, started)]

    assert {:in_flight, ^started} =
             SweepState.status(DateTime.add(started, 54, :minute), rows: rows)

    assert {:timed_out, ^started} =
             SweepState.status(DateTime.add(started, 55, :minute), rows: rows)

    assert {:timed_out, ^started} =
             SweepState.status(DateTime.add(started, 10, :minute),
               rows: rows,
               timeout_minutes: 10
             )

    # A finished row after the started row wins regardless of elapsed time.
    finished = DateTime.add(started, 30, :minute)
    rows = rows ++ [pure_row("finished", finished, finished)]

    assert {:finished, ^finished} =
             SweepState.status(DateTime.add(started, 300, :minute), rows: rows)
  end

  test "maybe_wait_for_hr skips the wait for a :fallback trigger" do
    attach_telemetry()
    row!("started", DateTime.utc_now())
    assert {:in_flight, _} = SweepState.status(DateTime.utc_now())

    # poll_ms 0 and a zero budget would also return at once; the outcome is
    # what proves the fallback branch was taken rather than the budget.
    assert SweepState.maybe_wait_for_hr(%{kind: :fallback}, poll_ms: 0, wait_minutes: 10) ==
             :skipped_fallback

    assert_receive {:hr_wait, %{waited_ms: 0}, %{outcome: :skipped_fallback}}
  end

  test "maybe_wait_for_hr returns proceeded_after_wait_budget and never an error when HR stays in flight" do
    attach_telemetry()
    row!("started", DateTime.utc_now())

    assert SweepState.maybe_wait_for_hr(%{kind: :cron}, poll_ms: 0, wait_minutes: 0) ==
             :proceeded_after_wait_budget

    assert_receive {:hr_wait, %{waited_ms: 0}, %{outcome: :proceeded_after_wait_budget}}

    # Not in flight at all: no wait, a different outcome, still never an error.
    Repo.delete_all(WikiJournalEntry)

    assert SweepState.maybe_wait_for_hr(%{kind: :cron}, poll_ms: 0, wait_minutes: 0) ==
             :proceeded_not_in_flight

    assert_receive {:hr_wait, _, %{outcome: :proceeded_not_in_flight}}
  end

  test "maybe_wait_for_hr proceeds after the sweep finishes within the budget" do
    attach_telemetry()
    started = ~U[2026-10-20 09:00:00Z]
    finished = DateTime.add(started, 2, :minute)
    {:ok, ticks} = Agent.start_link(fn -> 0 end)

    # The injected clock advances one minute per read: in flight at 09:00,
    # in flight at 09:01, finished at 09:02 (the finished row dates 09:02).
    now_fun = fn ->
      n = Agent.get_and_update(ticks, &{&1, &1 + 1})
      DateTime.add(started, n, :minute)
    end

    rows = [pure_row("started", started, started), pure_row("finished", finished, finished)]
    rows_at = fn now -> Enum.filter(rows, &(DateTime.compare(&1.inserted_at, now) != :gt)) end

    assert SweepState.maybe_wait_for_hr(%{kind: :cron},
             poll_ms: 1,
             wait_minutes: 10,
             now: now_fun,
             rows: rows_at
           ) == :proceeded_after_finish

    assert_receive {:hr_wait, %{waited_ms: 2}, %{outcome: :proceeded_after_finish}}
  end

  test "state survives a restart because it is read from journal rows" do
    row!("started", DateTime.utc_now())
    assert {:in_flight, _} = SweepState.status(DateTime.utc_now())

    # Nothing about the first read is held anywhere: a brand-new caller with
    # no process, ETS table or cache sees the same answer from the rows.
    task = Task.async(fn -> SweepState.status(DateTime.utc_now()) end)
    assert {:in_flight, _} = Task.await(task)

    refute Enum.any?(:ets.all(), fn table ->
             :ets.info(table, :name) |> to_string() |> String.contains?("sweep")
           end)
  end
end
