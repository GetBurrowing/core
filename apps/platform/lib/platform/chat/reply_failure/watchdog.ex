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
  (`Platform.Chat.ReplyFailure.remember_delivery/1`). After the window
  (`window_ms/0`) the watch fires:

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
  Watch `context`'s message for a reply from its agent, if the agent is
  native and the watchdog is on. Returns `:armed` or `:ignored`. Never raises.
  """
  @spec arm(map()) :: :armed | :ignored
  def arm(%{agent: %Agent{} = agent, message: %Message{id: message_id}} = context) do
    with window when is_integer(window) <- window_ms(),
         pid when is_pid(pid) <- Process.whereis(__MODULE__),
         true <- NativeAgents.managed?(agent) do
      GenServer.cast(
        pid,
        {:arm,
         %{
           agent_id: agent.id,
           message_id: message_id,
           agent_participant_id: participant_id(context)
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

  @doc "The agent did something that is part of a turn. Cheap; a cast."
  @spec activity(binary() | nil) :: :ok
  def activity(agent_id) when is_binary(agent_id) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:activity, agent_id, now()})
      _ -> :ok
    end

    :ok
  end

  def activity(_agent_id), do: :ok

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
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:arm, watch, window}, state) do
    key = {watch.agent_id, watch.message_id}
    entry = Map.merge(watch, %{armed_at: now(), activity_at: nil})
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

  @impl true
  def handle_call(:watches, _from, state), do: {:reply, Map.values(state), state}

  @impl true
  def handle_info({:check, key}, state) do
    case Map.fetch(state, key) do
      :error ->
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
      try do
        Platform.Chat.ReplyFailure.no_response(entry)
      rescue
        # A test's sandbox owner can be gone by the time a watch fires.
        DBConnection.OwnershipError -> :ok
      end
    end)
  end

  defp participant_id(%{agent_participant: %{id: id}}) when is_binary(id), do: id
  defp participant_id(%{agent_participant_id: id}) when is_binary(id), do: id
  defp participant_id(_), do: nil

  defp now, do: System.monotonic_time(:millisecond)
end
