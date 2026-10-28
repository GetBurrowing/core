defmodule Platform.Meetings.CandidateSweeper do
  @moduledoc """
  Server-side artifact countdowns. Each tick claims due, classified artifact
  candidates atomically, then creates their canvases. Task candidates never
  fire: task filing belongs to end-of-meeting triage.

  Unclassified armed artifact orphans are closed after the provider timeout
  grace (`default_unclassified_grace_ms/0`), with an audit event and telemetry.
  """

  use GenServer

  require Logger

  alias Platform.Meetings.Candidates

  @default_tick_interval_ms 1_000
  @default_batch_size 100
  @default_unclassified_grace_ms 300_000

  @telemetry_event [:platform, :meetings, :candidate_countdown_fired]
  @reap_telemetry_event [:platform, :meetings, :candidate_reaped]

  @doc """
  Start the sweeper. Options override the application config, and are
  the test seam — see the moduledoc.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Run one sweep and return the candidates that fired.

  Public and synchronous so a test can assert the timing with a number
  rather than sleeping past a cadence and hoping. `now` is injectable
  for the same reason: "fires at the deadline and not before" is a claim
  about a specific instant, and a test that has to wait 30 real seconds
  to make it is a test nobody runs.

  Returns the FIRED candidates only. The reaped ones (see the moduledoc)
  are closed and narrated as a side effect of the same sweep; use
  `sweep_all/1` to see both.
  """
  @spec sweep(keyword()) :: [Platform.Meetings.MeetingCandidate.t()]
  def sweep(opts \\ []) do
    sweep_all(opts).fired
  end

  @doc """
  Run one sweep and return `%{fired: [...], reaped: [...]}`: the
  candidates that graduated and the unclassified orphans that were
  closed. `sweep/1` is this with only the first half.
  """
  @spec sweep_all(keyword()) :: %{
          fired: [Platform.Meetings.MeetingCandidate.t()],
          reaped: [Platform.Meetings.MeetingCandidate.t()]
        }
  def sweep_all(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    grace_ms = Keyword.get(opts, :grace_ms, @default_unclassified_grace_ms)

    fired = fire_due(now, batch_size)
    reaped = reap_orphans(now, grace_ms, batch_size)

    %{fired: fired, reaped: reaped}
  end

  defp fire_due(now, batch_size) do
    now
    |> Candidates.claim_due(limit: batch_size)
    |> Enum.flat_map(fn candidate ->
      # claim_due/2 selects artifact candidates only; graduate/2 also
      # refuses task candidates, including stale pre-cutover rows.
      case Candidates.fire(candidate) do
        {:ok, fired} ->
          :telemetry.execute(
            @telemetry_event,
            %{count: 1},
            %{
              meeting_id: fired.meeting_id,
              candidate_id: fired.id,
              outcome_kind: fired.outcome_kind,
              task_id: fired.task_id,
              canvas_id: fired.canvas_id
            }
          )

          [fired]

        {:error, _reason} ->
          # Already logged by `Candidates.fire/1`. The row stays
          # `:acting` and disarmed rather than being re-armed — see that
          # function's docs for why a retry loop would be worse.
          []
      end
    end)
  end

  defp reap_orphans(now, grace_ms, batch_size) do
    reaped = Candidates.reap_unclassified(now, grace_ms: grace_ms, limit: batch_size)

    Enum.each(reaped, fn candidate ->
      # `close/2` does not touch `acts_at`, so the closed row still
      # carries the deadline it was reaped against.
      age_ms = DateTime.diff(now, candidate.acts_at, :millisecond)

      :telemetry.execute(
        @reap_telemetry_event,
        %{count: 1, age_ms: age_ms},
        %{
          meeting_id: candidate.meeting_id,
          candidate_id: candidate.id,
          outcome_kind: candidate.outcome_kind
        }
      )

      Logger.info(
        "[CandidateSweeper] reaped unclassified candidate id=#{candidate.id} " <>
          "meeting_id=#{candidate.meeting_id} age_ms=#{age_ms} outcome_kind=#{candidate.outcome_kind}"
      )
    end)

    reaped
  end

  @doc "The telemetry event emitted once per candidate that fires."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc "The telemetry event emitted once per unclassified candidate that is reaped."
  @spec reap_telemetry_event() :: [atom()]
  def reap_telemetry_event, do: @reap_telemetry_event

  @doc """
  How long past its deadline an unclassified card is left alone before
  it is reaped, in milliseconds. See "WHY 300s" in the moduledoc; the
  sweeper's tests pin this at or above every provider's receive timeout.
  """
  @spec default_unclassified_grace_ms() :: pos_integer()
  def default_unclassified_grace_ms, do: @default_unclassified_grace_ms

  @impl GenServer
  def init(opts) do
    config = Application.get_env(:platform, __MODULE__, [])

    state = %{
      tick_interval_ms:
        Keyword.get(opts, :tick_interval_ms) ||
          Keyword.get(config, :tick_interval_ms, @default_tick_interval_ms),
      batch_size:
        Keyword.get(opts, :batch_size) ||
          Keyword.get(config, :batch_size, @default_batch_size),
      unclassified_grace_ms:
        Keyword.get(opts, :unclassified_grace_ms) ||
          Keyword.get(config, :unclassified_grace_ms, @default_unclassified_grace_ms)
    }

    schedule_tick(state.tick_interval_ms)

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    # Wrapped rather than left to crash the sweeper. A single bad
    # candidate — an archived project, a canvas whose space is gone —
    # must not take down the countdown for every other meeting on the
    # node, and `restart: :permanent` would simply retry the same row.
    try do
      sweep_all(batch_size: state.batch_size, grace_ms: state.unclassified_grace_ms)
    rescue
      error ->
        Logger.error(
          "meeting candidate sweep raised: #{Exception.format(:error, error, __STACKTRACE__)}"
        )
    end

    schedule_tick(state.tick_interval_ms)

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_tick(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
