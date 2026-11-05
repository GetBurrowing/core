defmodule Platform.People.SweepState do
  @moduledoc """
  Is the HR daily sweep in flight right now? Task 01a1aa47 stage 4.

  The ONE question HR answers for anyone else, read from PERSISTED org
  journal rows and nothing else: no ETS, no GenServer, no process state, so
  a node restart between the HR fire and the dreaming fire changes nothing.

  `Platform.Responsibilities.Handlers.Hr` appends one journal row when its
  daily sweep's context is gathered (`"phase" => "started"`) and one when the
  output or refusal is handled (`"phase" => "finished"`), both with
  `"source" => "#{"responsibility:hr.daily_sweep"}"`. `status/2` is pure
  over the rows `Platform.Org.Wiki.list_journal_entries_since/2` returns for
  the UTC day of `now`:

    * `:not_started` — no started row today;
    * `{:in_flight, started_at}` — a started row, no finished row after it,
      and fewer than `timeout_minutes` (default #{55}) elapsed;
    * `{:finished, at}` — the latest row is a finished row;
    * `{:timed_out, started_at}` — a started row with no finished row after
      it, `timeout_minutes` or more ago.

  `maybe_wait_for_hr/2` is the single call `Handlers.Dreaming.gather_context/2`
  makes. HR is an INPUT to dreaming, never a gate on it: the function never
  returns an error, never schedules anything, and on a `:fallback` trigger
  returns at once without reading a row. `Platform.Memory.DreamingPasses`
  (task 01a1a2db) is the sole authority on dreaming's run state; this module
  holds no `dreaming_ran_at` and defines no predicate about dreaming.
  """

  alias Platform.Org.Wiki

  @source "responsibility:hr.daily_sweep"
  @default_timeout_minutes 55
  @default_wait_minutes 10
  @default_poll_ms 30_000
  @telemetry_event [:platform, :memory, :dreaming, :hr_wait]

  @type status ::
          :not_started
          | {:in_flight, DateTime.t()}
          | {:finished, DateTime.t()}
          | {:timed_out, DateTime.t()}

  @type wait_outcome ::
          :skipped_fallback
          | :proceeded_not_in_flight
          | :proceeded_after_finish
          | :proceeded_after_wait_budget

  @doc "The `metadata.source` HR stamps on its sweep rows."
  @spec source() :: String.t()
  def source, do: @source

  @doc "The telemetry event `maybe_wait_for_hr/2` emits."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Today's sweep status at `now`.

  Options:

    * `:workspace_id` — the journal scope (default `nil`, org-wide);
    * `:timeout_minutes` — how long a started row counts as in flight
      (default #{@default_timeout_minutes});
    * `:rows` — journal rows to evaluate instead of reading them (a list, or
      a one-arity function of `now`), for the pure path.
  """
  @spec status(DateTime.t(), keyword()) :: status()
  def status(%DateTime{} = now, opts \\ []) do
    rows =
      case Keyword.get(opts, :rows) do
        nil -> rows_for_day(now, opts)
        rows_fun when is_function(rows_fun, 1) -> rows_fun.(now)
        rows when is_list(rows) -> rows
      end

    status_from_rows(rows, now, opts)
  end

  @doc "`status/2` over rows already in hand. Pure."
  @spec status_from_rows([map()], DateTime.t(), keyword()) :: status()
  def status_from_rows(rows, %DateTime{} = now, opts \\ []) when is_list(rows) do
    timeout_minutes = Keyword.get(opts, :timeout_minutes, @default_timeout_minutes)

    rows
    |> Enum.filter(&sweep_row?/1)
    |> Enum.map(&phase_at/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_phase, at, inserted_at} -> {inserted_at, at} end, fn a, b ->
      compare_pair(a, b) != :gt
    end)
    |> List.last()
    |> case do
      nil ->
        :not_started

      {:finished, at, _} ->
        {:finished, at}

      {:started, at, _} ->
        if DateTime.diff(now, at, :minute) >= timeout_minutes,
          do: {:timed_out, at},
          else: {:in_flight, at}
    end
  end

  @doc """
  Consult HR once, with a bounded wait, before a dreaming run gathers its
  context. Returns the outcome; NEVER an error.

  Options: `:poll_ms` (default #{@default_poll_ms}), `:wait_minutes` (default
  `Application.get_env(:platform, :dreaming_hr_wait_minutes, #{@default_wait_minutes})`),
  `:now` (a zero-arity clock), plus `status/2`'s `:workspace_id` and
  `:timeout_minutes`.
  """
  @spec maybe_wait_for_hr(map(), keyword()) :: wait_outcome()
  def maybe_wait_for_hr(trigger_meta, opts \\ []) do
    kind = Map.get(trigger_meta, :kind) || Map.get(trigger_meta, "kind")

    if kind in [:fallback, "fallback"] do
      emit(0, :skipped_fallback)
    else
      poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)

      wait_minutes =
        Keyword.get_lazy(opts, :wait_minutes, fn ->
          Application.get_env(:platform, :dreaming_hr_wait_minutes, @default_wait_minutes)
        end)

      budget_ms = max(wait_minutes, 0) * 60_000
      now_fun = Keyword.get(opts, :now, &DateTime.utc_now/0)
      status_opts = Keyword.take(opts, [:workspace_id, :timeout_minutes, :rows])

      case safe_status(now_fun, status_opts) do
        {:in_flight, _} ->
          wait_loop(now_fun, status_opts, poll_ms, budget_ms, 0)

        _ ->
          emit(0, :proceeded_not_in_flight)
      end
    end
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp wait_loop(now_fun, status_opts, poll_ms, budget_ms, waited_ms) do
    if waited_ms >= budget_ms do
      emit(waited_ms, :proceeded_after_wait_budget)
    else
      sleep_ms = poll_ms |> max(0) |> min(budget_ms - waited_ms)
      if sleep_ms > 0, do: Process.sleep(sleep_ms)
      waited_ms = waited_ms + sleep_ms

      case safe_status(now_fun, status_opts) do
        {:in_flight, _} -> wait_loop(now_fun, status_opts, poll_ms, budget_ms, waited_ms)
        {:finished, _} -> emit(waited_ms, :proceeded_after_finish)
        _ -> emit(waited_ms, :proceeded_not_in_flight)
      end
    end
  end

  defp safe_status(now_fun, status_opts) do
    status(now_fun.(), status_opts)
  rescue
    _ -> :not_started
  catch
    :exit, _ -> :not_started
  end

  defp emit(waited_ms, outcome) do
    :telemetry.execute(@telemetry_event, %{waited_ms: waited_ms}, %{outcome: outcome})
    outcome
  end

  defp rows_for_day(now, opts) do
    day_start = now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Wiki.list_journal_entries_since(day_start,
      workspace_id: Keyword.get(opts, :workspace_id),
      window_end: DateTime.add(now, 1, :second)
    )
  end

  defp sweep_row?(row), do: meta(row, "source") == @source

  defp phase_at(row) do
    inserted_at = Map.get(row, :inserted_at)

    case meta(row, "phase") do
      "started" -> {:started, parse_at(meta(row, "started_at")) || inserted_at, inserted_at}
      "finished" -> {:finished, parse_at(meta(row, "finished_at")) || inserted_at, inserted_at}
      _ -> nil
    end
  end

  defp meta(row, key) do
    case Map.get(row, :metadata) || Map.get(row, "metadata") do
      %{} = metadata -> Map.get(metadata, key)
      _ -> nil
    end
  end

  defp parse_at(%DateTime{} = at), do: at

  defp parse_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp parse_at(_), do: nil

  defp compare_pair({a1, a2}, {b1, b2}) do
    case compare_dt(a1, b1) do
      :eq -> compare_dt(a2, b2)
      other -> other
    end
  end

  defp compare_dt(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare_dt(nil, nil), do: :eq
  defp compare_dt(nil, _), do: :lt
  defp compare_dt(_, nil), do: :gt
end
