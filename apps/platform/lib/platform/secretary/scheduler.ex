defmodule Platform.Secretary.Scheduler do
  @moduledoc """
  Turns arrivals into per-person batches (task 01a1b721 stage 3 item 2).
  Deterministic: routing, debounce and caps are code, not a model.

  ## Arrivals

    * `Platform.Secretary.note_arrival/1` — `Platform.Inbox.emit/1` after its
      broadcast, and meeting briefing delivery for each attendee;
    * `[:platform, :chat, :message_posted]` — the handler runs inside the
      POSTER's process, so it does nothing but cast `{space_id, message_id,
      participant_id}` here, and rescues everything (a raising handler is
      detached VM-wide). Recipients are resolved in this process: the space's
      user MEMBERS and the people the message drew attention to, in
      channel, dm and group spaces only, never the author. A post in an open
      channel the person is not in is NOT an arrival for them; it is read
      only as an input when something else batches them. A message written
      by the secretary's own agent, or carrying a `secretary_nudge` marker in
      its metadata, is not an arrival either, so a nudge cannot loop.

  ## Debounce and caps

  The first arrival for a person starts a `debounce_ms` window; arrivals
  inside it add nothing. When it closes the person is queued. At most one
  batch per person is in flight (an arrival during it marks them dirty and
  opens a new window when it ends) and at most `max_in_flight` across the
  install. Each batch is `Platform.Secretary.Pass.run/2` in a task under
  `Platform.TaskSupervisor` (`async_nolink`), so a crash in one never takes
  this process down.

  `debounce_ms` and `max_in_flight` come from the install's policy payload
  (`Platform.Secretary.Policy.install/0`) unless given as options.

  Boot flag `:start_secretary` (default true; false in config/test.exs, where
  tests `start_supervised!/1` their own).
  """

  use GenServer

  import Ecto.Query

  alias Platform.Chat.{Message, MessageAttention, Participant, Space}
  alias Platform.Repo
  alias Platform.Secretary.{Pass, Policy}
  alias Platform.Secretary.Model.Host

  @handler_id "platform-secretary-arrivals"
  @event [:platform, :chat, :message_posted]
  @space_kinds ~w(channel dm group)
  @nudge_marker "secretary_nudge"

  @doc "The metadata key that marks a secretary nudge message."
  @spec nudge_marker() :: String.t()
  def nudge_marker, do: @nudge_marker

  @doc """
  Options: `:debounce_ms`, `:max_in_flight`, `:pass_opts` (passed to
  `Platform.Secretary.Pass.run/2`). Registered under this module's name,
  which the arrival casts and the telemetry handler address.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The telemetry handler: one cast, everything rescued."
  def handle_message_posted(_event, _measurements, metadata, _config) do
    case metadata do
      %{space_id: space_id, message_id: message_id} when is_binary(message_id) ->
        GenServer.cast(__MODULE__, {:message, space_id, message_id, metadata[:participant_id]})

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "The people a posted message is an arrival for (pure read, used by the scheduler)."
  @spec recipients(Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def recipients(message_id) do
    with true <- is_binary(message_id) and Platform.UUID.valid?(message_id),
         [{%Message{} = message, kind}] <-
           Repo.all(
             from(m in Message,
               join: s in Space,
               on: s.id == m.space_id,
               where: m.id == ^message_id and is_nil(m.deleted_at),
               select: {m, s.kind}
             )
           ),
         true <- kind in @space_kinds,
         false <- secretary_authored?(message) do
      members =
        from(p in Participant,
          where: p.space_id == ^message.space_id and p.participant_type == "user",
          select: p.participant_id
        )
        |> Repo.all()

      mentioned =
        from(a in MessageAttention,
          join: p in Participant,
          on: p.id == a.participant_id,
          where: a.message_id == ^message.id and p.participant_type == "user",
          select: p.participant_id
        )
        |> Repo.all()

      (members ++ mentioned)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == message.author_user_id))
    else
      _ -> []
    end
  end

  defp secretary_authored?(%Message{} = message) do
    marked? = Map.get(message.metadata || %{}, @nudge_marker) not in [nil, false]

    marked? or
      (is_binary(message.author_agent_id) and
         match?(%{id: id} when id == message.author_agent_id, secretary_agent()))
  end

  defp secretary_agent do
    Platform.Roles.assignee_for(Host.responsibility())
  rescue
    _ -> nil
  end

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    install = if opts[:debounce_ms] && opts[:max_in_flight], do: %{}, else: Policy.install()

    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach(@handler_id, @event, &__MODULE__.handle_message_posted/4, nil)

    {:ok,
     %{
       debounce_ms: Keyword.get(opts, :debounce_ms) || install["debounce_ms"],
       max_in_flight: Keyword.get(opts, :max_in_flight) || install["max_in_flight"],
       pass_opts: Keyword.get(opts, :pass_opts, []),
       timers: %{},
       queue: [],
       running: %{},
       dirty: MapSet.new()
     }}
  end

  @impl true
  def handle_cast({:arrival, user_id}, state) when is_binary(user_id),
    do: {:noreply, arrive(state, user_id)}

  def handle_cast({:message, _space_id, message_id, _participant_id}, state) do
    recipients =
      try do
        recipients(message_id)
      rescue
        _ -> []
      end

    {:noreply, Enum.reduce(recipients, state, &arrive(&2, &1))}
  end

  def handle_cast(_msg, state), do: {:noreply, state}

  @impl true
  def handle_info({:due, user_id}, state) do
    state = %{state | timers: Map.delete(state.timers, user_id)}

    state =
      if user_id in state.queue, do: state, else: %{state | queue: state.queue ++ [user_id]}

    {:noreply, drain(state)}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finished(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, finished(state, ref)}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
    :ok
  end

  defp arrive(state, user_id) do
    cond do
      Map.has_key?(state.timers, user_id) or user_id in state.queue ->
        state

      running?(state, user_id) ->
        %{state | dirty: MapSet.put(state.dirty, user_id)}

      true ->
        timer = Process.send_after(self(), {:due, user_id}, state.debounce_ms)
        %{state | timers: Map.put(state.timers, user_id, timer)}
    end
  end

  defp drain(%{queue: [user_id | rest]} = state) do
    cond do
      map_size(state.running) >= state.max_in_flight ->
        state

      running?(state, user_id) ->
        drain(%{state | queue: rest, dirty: MapSet.put(state.dirty, user_id)})

      true ->
        drain(%{
          state
          | queue: rest,
            running: Map.put(state.running, start(state, user_id), user_id)
        })
    end
  end

  defp drain(state), do: state

  defp start(state, user_id) do
    pass_opts = state.pass_opts

    %Task{ref: ref} =
      Task.Supervisor.async_nolink(Platform.TaskSupervisor, fn ->
        try do
          Pass.run(user_id, pass_opts)
        rescue
          DBConnection.OwnershipError -> {:error, :sandbox}
          error -> {:error, error.__struct__}
        end
      end)

    ref
  end

  defp finished(state, ref) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        state

      {user_id, running} ->
        state = %{state | running: running}

        state =
          if MapSet.member?(state.dirty, user_id),
            do: arrive(%{state | dirty: MapSet.delete(state.dirty, user_id)}, user_id),
            else: state

        drain(state)
    end
  end

  defp running?(state, user_id), do: user_id in Map.values(state.running)
end
