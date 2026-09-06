defmodule Platform.Meetings.AgentActivity.Store do
  @moduledoc """
  Lifecycle owner for the agent-activity ETS tables (task `01a07400`
  stages 1 and 2): the agent-pushed `:thinking`/`:composing` store, and
  core's `:speaking` store.

  All of the store's behaviour — what may be pushed, when a row is live,
  what a sweep deletes — lives in `Platform.Meetings.AgentActivity`, next
  to the resolution it feeds. This module is only the process: it creates
  the tables, and it calls `AgentActivity.sweep_pushed/1` and
  `AgentActivity.sweep_speaking/1` on a timer.

  ## Why the process is not in `AgentActivity` itself

  `agent_activity_test.exs` pins that `AgentActivity` exports no `init/1`
  and no `handle_info/2` — "turning it into a GenServer to sweep the
  ceiling is the change this forbids" — because the 120-second ceiling is
  a pure read-time derivation and must stay provable by handing a value
  and two `DateTime`s to a function with nothing running. That guard is
  correct and this task does not relax it.

  Pushed-state expiry is the same shape: it is decided on every read by a
  pure predicate against the `now` the caller supplies, so a lapsed state
  reads as lapsed whether or not this process exists, is running, or has
  swept recently. The sweep reclaims space; it does not decide anything.
  Splitting the process out is what keeps that difference checkable rather
  than a paragraph asking to be believed — the guard test still runs, and
  it still passes, against the unchanged module.

  ## Shape

  Named public tables, created here, read and written directly by callers —
  no `GenServer.call/2` anywhere on a push or a read path, so a slow or
  wedged sweep can never block a meeting render. Identical to
  `Platform.Meetings.PressWindow`, `Platform.Meetings.SayRegistry` and
  `Platform.Meetings.VoiceSeatCache`.

  The tables die with this process, and that is right: a liveness
  declaration that survived the node that heard it would be a claim
  nothing alive is making, and a `:speaking` window belongs to the node
  that dispatched the audio.
  """

  use GenServer

  alias Platform.Meetings.AgentActivity

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Enum.each([AgentActivity.pushed_table(), AgentActivity.speaking_table()], &ensure_table/1)

    schedule_sweep()
    {:ok, %{}}
  end

  # Two tables, ONE owner (task `01a07400` stage 2 added the second).
  #
  # They are separate tables because the two layers coexist: an agent can
  # be mid-`:composing` by its own declaration and `:speaking` by core's
  # observation at the same instant, and they resolve at different points
  # in `AgentActivity`'s resolution order. Sharing one key per agent would
  # mean either write silently deleting the other.
  #
  # They are NOT separate processes, because there is nothing to separate:
  # both are lifecycle plus a space-reclaiming sweep, both expire on read
  # regardless of whether this process is alive, and a second GenServer
  # would only add a second thing that can be missing from the supervision
  # tree.
  defp ensure_table(table) do
    case :ets.info(table) do
      :undefined ->
        :ets.new(table, [:named_table, :public, :set, read_concurrency: true])

      _ ->
        # A supervisor restart that raced the old owner's exit.
        :ok
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = DateTime.utc_now()
    AgentActivity.sweep_pushed(now)
    AgentActivity.sweep_speaking(now)
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_sweep do
    Process.send_after(self(), :sweep, AgentActivity.pushed_sweep_interval_ms())
  end
end
