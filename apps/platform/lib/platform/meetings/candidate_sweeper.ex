defmodule Platform.Meetings.CandidateSweeper do
  @moduledoc """
  The server-side countdown: tick, claim every candidate whose deadline
  has passed, graduate it (task 01a03fba stage 3).

  This exists because the countdown cannot live in the browser. The
  acceptance criterion is Harper's: *a closed tab must not stop the card
  firing with nobody watching*. A `setInterval` in a LiveView hook, or
  even a `Process.send_after/3` in the LiveView process, both die with
  the last connected participant — so the meeting whose members all
  closed their laptops is exactly the meeting where the countdown must
  still run, and exactly the one where those two mechanisms do not.

  ## Why a polled column and not a timer

  See `Platform.Meetings.Countdown` for the full argument. In short: the
  intent queue's `ack_timer` holds one deadline, on a `restart: :temporary`
  GenServer whose ETS dies with it, gating a rail
  (`Candidates.graduate/2`) that does not use the queue at all. The
  deadline is therefore `meeting_candidates.acts_at`, and this module is
  the poller.

  The shape is `Platform.Tenancy.ContainerPurger` /
  `Platform.Files.Purger` / `Platform.Chat.SpacePurger`: a GenServer,
  boot-gated on an application flag, that ticks and scans a due-by
  `*_at` column. There is no Oban and no Quantum in this project.

  ## Firing exactly once

  There is no advisory lock, leader election or `:global` registration
  anywhere in `lib/`. Every sweeper here is node-local and pushes its
  idempotence down into the data, and this one has to as well:
  `Candidates.graduate/2` has no guard of its own, so two sweepers that
  both cleared a `SELECT` would both reach `mint/1` and produce two
  tasks for one sentence.

  So this module never selects and then acts. `Candidates.claim_due/2`
  is a conditional `UPDATE ... WHERE acts_at IS NOT NULL AND acts_at <= now
  AND state NOT IN ('closed','acting')` with `RETURNING`, and only the
  rows it returns are fired. The stop button races the same predicate on
  the same row and Postgres row locking picks a winner. Nothing about
  correctness depends on there being one sweeper.

  ## The tick is short on purpose

  One second. The countdown is 30 seconds and the visible artefact is a
  ring, so a minute-scale cadence — right for a daily purge — would make
  a card fire up to a minute after its ring reached zero, and a ring
  that sits at zero is exactly the "timer that lies" this ticket is
  about. The cost is one indexed query per second against a partial
  index on the armed minority (`meeting_candidates_armed_acts_at_index`).

  ## Configuration

      config :platform, #{__MODULE__},
        tick_interval_ms: 1_000,
        batch_size: 100

  Boot gated on `:start_candidate_sweeper` (defaults to `true`; set to
  `false` in `config/test.exs` so DataCase-scoped tests start their own
  per-case instance and no ambient sweeper races the sandbox).

  ## Test seam

  Every `start_link/1` option is forwarded to `init/1`, so a test can
  pass `tick_interval_ms: 50` and a `:name`, and `sweep/1` is public and
  synchronous — the timing assertions call it directly rather than
  sleeping past a cadence.
  """

  use GenServer

  require Logger

  alias Platform.Meetings.Candidates

  @default_tick_interval_ms 1_000
  @default_batch_size 100

  @telemetry_event [:platform, :meetings, :candidate_countdown_fired]

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
  """
  @spec sweep(keyword()) :: [Platform.Meetings.MeetingCandidate.t()]
  def sweep(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    now
    |> Candidates.claim_due(limit: batch_size)
    |> Enum.flat_map(fn candidate ->
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

  @doc "The telemetry event emitted once per candidate that fires."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @impl GenServer
  def init(opts) do
    config = Application.get_env(:platform, __MODULE__, [])

    state = %{
      tick_interval_ms:
        Keyword.get(opts, :tick_interval_ms) ||
          Keyword.get(config, :tick_interval_ms, @default_tick_interval_ms),
      batch_size:
        Keyword.get(opts, :batch_size) ||
          Keyword.get(config, :batch_size, @default_batch_size)
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
      sweep(batch_size: state.batch_size)
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
