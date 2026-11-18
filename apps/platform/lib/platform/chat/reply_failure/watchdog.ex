defmodule Platform.Chat.ReplyFailure.Watchdog do
  @moduledoc """
  No message to a NATIVE agent ends silently (task 01a10322 stage 7, round 2).

  Every other reply-failure path needs a failure someone observes: a dispatch
  that errors, or the agent host reporting `needs_login` / `crashed`. The
  behavioural gate found two mentions that failed with nothing observable:

    * case 7008: the agent ran a turn and answered in its own terminal,
      never calling `suite_reply`;
    * case 7009: the agent's key went bad after it had worked; Claude Code
      resumed its session, the pane read ready, and the dev channel dropped
      the message. No turn ran at all.

  Both looked the same from Burrow: "<Name> is thinking…" forever, no reply,
  no notice. This is the one mechanism for both.

  ## What it does

  `arm/1` is called when a message is delivered to a native agent's runtime
  (`Platform.Chat.ReplyFailure.remember_delivery/1`), and arms a watch only
  when the message was addressed to the agent (`context.reason` in
  `Platform.Chat.ReplyFailure.addressed_reasons/0`): a message routed to the
  channel's active agent that nobody addressed to it may rightly get no
  reply, and watching it posted "Something went wrong" under "Bingo"
  (legacy-pie, 2026-11-16..18). After the window (`window_ms/0`) the watch
  fires:

    * the agent has posted in the space since the message: nothing;
    * the agent showed TURN ACTIVITY since it was armed (`activity/1`: a
      typing frame, a reply chunk, a tool call over its runtime socket or the
      MCP endpoint): the watch waits another window, never past `max_ms/0`
      from delivery;
    * otherwise: `Platform.Chat.ReplyFailure.no_response/1`, which asks the
      agent host whether the agent's key still works, posts ONE notice with
      the cause it can name (`needs_login` for a rejected key, otherwise what
      the host observes, otherwise `unknown`), and clears "thinking".

  The notice goes through `ReplyFailure.notify/2`, so the per-message and
  per-agent dedupe hold, and `AttentionRouter` never routes it.

  ## Busy is not a failure

  A Claude Code agent in the middle of a multi-minute tool call shows no turn
  activity core can see, and Claude Code holds a channel message until that
  turn ends. Before, the watch read that as "no response" after one window
  and posted "Something went wrong" with a Restart button, and a Restart
  killed the work in progress. Now `ReplyFailure.no_response/1` first asks
  whether the runtime still has a heartbeat; when it does, the message is
  waiting on a busy agent: the space is told "<Agent> is busy" (with what it
  was last seen doing, `current_activity/1`), the watch re-checks every
  window, and only after `busy_max_ms/0` with still no answer is a notice
  posted. A runtime that loses its heartbeat meanwhile gets the notice at the
  next check.

  Turn activity is recorded with what it was (`activity/2`), so the busy line
  can name it: a Burrow tool (and the task it was about), or a reply in
  another space.

  ## The bound, stated as scope

  It watches deliveries to install-managed (native) agents made on THIS node
  while this process has been up, and nothing else. Federated agents are not
  watched: their turns are their operators'. A restart forgets every watch,
  which can cost one notice, never add one.

  Disabled when `:native_reply_watchdog_ms` is `false` (the test env, so a
  watch armed by an unrelated test never fires into a later one).
  """

  use GenServer

  alias Platform.Agents.{Agent, NativeAgents}
  alias Platform.Chat.Message

  @default_window_ms 45_000
  @default_max_ms 600_000
  @default_busy_max_ms 30 * 60_000
  # Activity older than this says nothing about what the agent is doing now.
  @activity_fresh_ms 30 * 60_000
  # A gap longer than this between two activities starts a new run, so
  # "since" is the start of the current run of work, not of the session.
  @activity_run_gap_ms 5 * 60_000
  @activity_table :chat_agent_activity

  @type entry :: %{
          agent_id: binary(),
          message_id: binary(),
          agent_participant_id: binary() | nil,
          armed_at: integer(),
          activity_at: integer() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The window, in ms, read per call from `config :platform,
  :native_reply_watchdog_ms` (`NATIVE_REPLY_WATCHDOG_S`, default 45 s), or
  `false` when the watchdog is off.
  """
  @spec window_ms() :: pos_integer() | false
  def window_ms do
    case Application.get_env(:platform, :native_reply_watchdog_ms, @default_window_ms) do
      false -> false
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_window_ms
    end
  end

  @doc """
  The longest a watch keeps waiting on turn activity, in ms from delivery
  (`NATIVE_REPLY_WATCHDOG_MAX_S`, default 600 s).
  """
  @spec max_ms() :: pos_integer()
  def max_ms do
    case Application.get_env(:platform, :native_reply_watchdog_max_ms, @default_max_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_max_ms
    end
  end

  @doc """
  How long a message may wait on a BUSY agent (runtime connected, no reply)
  before the notice is posted anyway, in ms from delivery
  (`NATIVE_REPLY_BUSY_MAX_S`, default 30 min).
  """
  @spec busy_max_ms() :: pos_integer()
  def busy_max_ms do
    case Application.get_env(:platform, :native_reply_busy_max_ms, @default_busy_max_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_busy_max_ms
    end
  end

  @doc """
  Watch `context`'s message for a reply from its agent, if the agent is
  native and the watchdog is on. Returns `:armed` or `:ignored`. Never raises.
  """
  @spec arm(map()) :: :armed | :ignored
  def arm(%{agent: %Agent{} = agent, message: %Message{id: message_id}} = context) do
    with true <- Platform.Chat.ReplyFailure.addressed_reason?(context[:reason]),
         window when is_integer(window) <- window_ms(),
         pid when is_pid(pid) <- Process.whereis(__MODULE__),
         true <- NativeAgents.managed?(agent) do
      GenServer.cast(
        pid,
        {:arm,
         %{
           agent_id: agent.id,
           message_id: message_id,
           space_id: context.message.space_id,
           agent_participant_id: participant_id(context),
           delivered_at: DateTime.utc_now()
         }, window}
      )

      :armed
    else
      _ -> :ignored
    end
  rescue
    _ -> :ignored
  end

  def arm(_context), do: :ignored

  @doc """
  The agent did something that is part of a turn. Cheap; a cast and an ETS
  write.

  `detail` says what, for the busy line: `{:tool, name, args}` for a Burrow
  tool call, `{:space, space_id}` for typing or a reply chunk, or nil.
  """
  @spec activity(binary() | nil, term()) :: :ok
  def activity(agent_id, detail \\ nil)

  def activity(agent_id, detail) when is_binary(agent_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:activity, agent_id, now()})
      _ -> :ok
    end

    record_activity(agent_id, detail)
    :ok
  end

  def activity(_agent_id, _detail), do: :ok

  @doc """
  What `agent_id` was last seen doing, if within the last 30 minutes:
  `%{at, since, tool, task_id, space_id}`, `since` being the start of the
  current run of activity. Nil when nothing recent is known.
  """
  @spec current_activity(binary()) :: map() | nil
  def current_activity(agent_id) when is_binary(agent_id) do
    case :ets.lookup(@activity_table, agent_id) do
      [{_, %{at: at} = activity}] ->
        if DateTime.diff(DateTime.utc_now(), at, :millisecond) <= @activity_fresh_ms,
          do: activity

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  def current_activity(_agent_id), do: nil

  @doc """
  The watches in `space_id` currently shown as busy, as
  `%{agent_participant_id => busy}` (`Platform.Chat.PubSub.broadcast_agent_busy/3`).
  """
  @spec busy_in_space(binary()) :: %{binary() => map()}
  def busy_in_space(space_id) when is_binary(space_id) do
    for %{space_id: ^space_id, busy: %{} = busy, agent_participant_id: pid} <- watches(),
        is_binary(pid),
        into: %{},
        do: {pid, busy}
  end

  defp record_activity(agent_id, detail) do
    now = DateTime.utc_now()

    since =
      case :ets.lookup(@activity_table, agent_id) do
        [{_, %{at: at, since: since}}] ->
          if DateTime.diff(now, at, :millisecond) <= @activity_run_gap_ms, do: since, else: now

        _ ->
          now
      end

    entry =
      Map.merge(
        %{at: now, since: since, tool: nil, task_id: nil, space_id: nil},
        describe(detail)
      )

    :ets.insert(@activity_table, {agent_id, entry})
  rescue
    ArgumentError -> :ok
  end

  defp describe({:tool, name, args}) when is_binary(name) do
    task_id =
      case args do
        %{"task_id" => id} when is_binary(id) -> id
        _ -> nil
      end

    %{tool: name, task_id: task_id}
  end

  defp describe({:space, space_id}) when is_binary(space_id), do: %{space_id: space_id}
  defp describe(_detail), do: %{}

  @doc false
  # Drop every watch of `agent_id`. For tests, whose busy watches would
  # otherwise keep re-checking after their sandbox is gone.
  @spec disarm(binary()) :: :ok
  def disarm(agent_id) when is_binary(agent_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, {:disarm, agent_id})
      _ -> :ok
    end
  end

  @doc "The live watches. For tests and the console."
  @spec watches() :: [entry()]
  def watches do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.call(pid, :watches)
      _ -> []
    end
  end

  @doc """
  The decision for one watch at `now_ms`, given the window and the cap. Pure.

    * `{:wait, ms}`: turn activity since it was armed and the cap not
      reached; check again in `ms`;
    * `:verdict`: no activity, or the cap reached.
  """
  @spec decide(entry(), integer(), pos_integer(), pos_integer()) ::
          {:wait, pos_integer()} | :verdict
  def decide(%{armed_at: armed_at, activity_at: activity_at}, now_ms, window, cap) do
    deadline = armed_at + cap

    cond do
      is_nil(activity_at) -> :verdict
      now_ms >= deadline -> :verdict
      true -> {:wait, max(1, min(activity_at + window, deadline) - now_ms)}
    end
  end

  # ── Server ─────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    if :ets.whereis(@activity_table) == :undefined do
      :ets.new(@activity_table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:arm, watch, window}, state) do
    key = {watch.agent_id, watch.message_id}
    entry = Map.merge(watch, %{armed_at: now(), activity_at: nil, busy: nil})
    Process.send_after(self(), {:check, key}, window)
    {:noreply, Map.put(state, key, entry)}
  end

  def handle_cast({:activity, agent_id, at}, state) do
    state =
      Map.new(state, fn
        {{^agent_id, _} = key, entry} -> {key, %{entry | activity_at: at}}
        other -> other
      end)

    {:noreply, state}
  end

  # `ReplyFailure.no_response/1` found the agent busy: keep watching, a
  # window at a time, until it answers, loses its heartbeat, or the busy cap.
  def handle_cast({:busy, entry, busy}, state) do
    key = {entry.agent_id, entry.message_id}
    window = window_ms() || @default_window_ms
    Process.send_after(self(), {:check, key}, window)
    {:noreply, Map.put(state, key, %{entry | busy: busy, activity_at: nil})}
  end

  # Only the watch the verdict was about: a re-arm meanwhile (a redelivery)
  # is a new watch and stays.
  def handle_cast({:settled, key, armed_at}, state) do
    case Map.get(state, key) do
      %{armed_at: ^armed_at} -> {:noreply, Map.delete(state, key)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_call(:watches, _from, state), do: {:reply, Map.values(state), state}

  def handle_call({:disarm, agent_id}, _from, state) do
    {:reply, :ok, Map.reject(state, fn {{id, _}, _} -> id == agent_id end)}
  end

  @impl true
  def handle_info({:check, key}, state) do
    case Map.fetch(state, key) do
      :error ->
        {:noreply, state}

      {:ok, %{busy: %{}} = entry} ->
        # A busy watch is re-judged every window; past the busy cap the
        # verdict is final and posts the notice whatever the heartbeat says.
        # The entry stays while the verdict runs, so a page entering the
        # space meanwhile still sees the agent busy; the verdict re-arms it
        # (`{:busy, ...}`) or settles it.
        final? = now() - entry.armed_at >= busy_max_ms()
        verdict(Map.put(entry, :final, final?))
        {:noreply, state}

      {:ok, entry} ->
        case decide(entry, now(), window_ms() || @default_window_ms, max_ms()) do
          {:wait, ms} ->
            Process.send_after(self(), {:check, key}, ms)
            # The next check asks for activity SINCE this one.
            {:noreply, Map.put(state, key, %{entry | activity_at: nil})}

          :verdict ->
            verdict(entry)
            {:noreply, Map.delete(state, key)}
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The verdict reads and writes the DB and may wait on the agent host for up
  # to 10 s, so it never runs in this server.
  defp verdict(entry) do
    Task.Supervisor.start_child(Platform.TaskSupervisor, fn ->
      result =
        try do
          Platform.Chat.ReplyFailure.no_response(entry)
        rescue
          # A test's sandbox owner can be gone by the time a watch fires.
          DBConnection.OwnershipError -> :ok
        end

      case result do
        {:busy, busy} ->
          GenServer.cast(__MODULE__, {:busy, entry, busy})

        _ ->
          GenServer.cast(
            __MODULE__,
            {:settled, {entry.agent_id, entry.message_id}, entry.armed_at}
          )
      end
    end)
  end

  defp participant_id(%{agent_participant: %{id: id}}) when is_binary(id), do: id
  defp participant_id(%{agent_participant_id: id}) when is_binary(id), do: id
  defp participant_id(_), do: nil

  defp now, do: System.monotonic_time(:millisecond)
end
