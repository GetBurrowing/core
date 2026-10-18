defmodule Platform.Meetings.CandidateSweeper do
  @moduledoc """
  The server-side countdown: tick, claim every candidate whose deadline
  has passed, graduate it (task 01a03fba stage 3).

  This exists because the countdown cannot live in the browser. The
  acceptance criterion is the product lead's: *a closed tab must not stop the card
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

  ## Reaping the orphan (task 01a06638)

  `Candidates.claim_due/2` passes over a card nothing has classified, so
  a slow answer is not graduated unvetted. The tail of that rule is a
  card whose answer NEVER comes: it stays armed and overdue for the life
  of the row, never firing and never closing. After the claim/fire
  pipeline each sweep therefore calls `Candidates.reap_unclassified/2`,
  which closes every armed unclassified card past `acts_at + grace`
  with reason `:unclassified` and disposition `:timed_out`, and this
  module logs one line and emits `reap_telemetry_event/0` per row.
  Operator-visible only — no toast, no banner.

  ### WHY 300s

  The grace must exceed the slowest GENUINE answer, or the reaper is the
  P1 regression in a new coat: a real classification arriving inside
  the provider's timeout would find its card already closed. The
  classifier's default provider is `Platform.Agents.Providers.Ollama`
  (`Platform.Meetings.IntentClassifier.init/1`, and `Platform.Application`
  starts it with no override), whose receive timeout is 300_000 ms — the
  Anthropic, OpenAI and Codex adapters allow 60_000. The bound is
  therefore pinned to the maximum provider timeout, 300_000 ms after
  the deadline. The classifier holds a chunk at most `max_hold_ms`
  (4 s) before the call and does not retry, so the latest genuine answer
  lands well inside `acts_at + 300s`.

  The pin is a TEST, not a compile-time assertion: Ollama's timeout is
  read from `Application.get_env/3` at runtime, so it is not a constant
  this module could compare against at compile time.
  `CandidateSweeperTest` asserts `default_unclassified_grace_ms/0` is at
  or above `receive_timeout_ms/0` for every provider module, so a new or
  slower provider reds that test rather than silently reaping answers.

  ## Configuration

      config :platform, #{__MODULE__},
        tick_interval_ms: 1_000,
        batch_size: 100,
        unclassified_grace_ms: 300_000

  Boot gated on `:start_candidate_sweeper` (defaults to `true`; set to
  `false` in `config/test.exs` so DataCase-scoped tests start their own
  per-case instance and no ambient sweeper races the sandbox).

  ## Test seam

  Every `start_link/1` option is forwarded to `init/1`, so a test can
  pass `tick_interval_ms: 50` and a `:name`, and `sweep/1` is public and
  synchronous — the timing assertions call it directly rather than
  sleeping past a cadence. `sweep/1` also takes `:now` and `:grace_ms`
  for the same reason.
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
