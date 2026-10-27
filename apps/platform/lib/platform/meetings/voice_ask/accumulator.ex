defmodule Platform.Meetings.VoiceAsk.Accumulator do
  @moduledoc """
  One process per `voice_ask_agent` ask (task 01a17b10 stage 4). It
  subscribes to the space's chat topic (`Platform.Chat.PubSub.subscribe/1`)
  in `init/1`, BEFORE the question is posted, so no part of the answer can
  arrive unseen. It keeps only what the answering agent's participant sends:

    * `{:agent_reply_chunk, %{participant_id, chunk_id, text, done}}`: the
      text is cumulative, so the latest chunk wins. The first chunk id seen
      after start is the answer's; another chunk id from the same agent (a
      reply to something else) is ignored. A `done: true` chunk completes the
      answer.
    * `{:new_message, %Message{}}` from that participant, after the question
      was posted: the posted reply. Its content is the final text and it
      completes the answer.

  Anything from any other participant is ignored.

  Status is `pending` (nothing yet), `streaming` (some text, not done),
  `done`, or `timeout` (nothing complete within `:timeout_ms`, default
  60 seconds). `done` and `timeout` are terminal: `done: true` is reported
  for both, and the process then lingers `:linger_ms` (default 15 seconds) so a
  last poll can read the result, and stops. A posted reply that arrives during
  the linger after a `done` chunk still replaces the text.

  Both durations are read from
  `config :platform, Platform.Meetings.VoiceAsk, timeout_ms: _, linger_ms: _`
  when the ask starts.

  Text length (`since`) is counted in Unicode code points, the same as
  Python's `len/1` on the client side.
  """

  use GenServer, restart: :temporary

  alias Platform.Chat.Message
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Meetings.VoiceAsk.Supervisor, as: VoiceAskSupervisor

  @default_timeout_ms 60_000
  @default_linger_ms 15_000

  # ── API ─────────────────────────────────────────────────────────────────

  @doc "Start an accumulator for one ask under the VoiceAsk DynamicSupervisor."
  @spec start(map()) :: {:ok, pid()} | {:error, term()}
  def start(%{ask_id: _} = ask) do
    DynamicSupervisor.start_child(VoiceAskSupervisor.dynamic_supervisor(), {__MODULE__, ask})
  end

  def start_link(%{ask_id: ask_id} = ask) do
    GenServer.start_link(__MODULE__, ask, name: via(ask_id))
  end

  @doc "Tell the accumulator which message is the question."
  def question_posted(pid, %Message{} = message), do: GenServer.cast(pid, {:question, message})

  @doc "Stop an accumulator whose question never posted."
  def stop(pid), do: GenServer.stop(pid, :normal)

  @doc """
  Poll an ask: `{:ok, snapshot}`, `:unknown` (no such ask on this node, or
  already gone), or `{:error, :forbidden}` (another agent's ask).
  """
  @spec poll(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, map()} | :unknown | {:error, :forbidden}
  def poll(ask_id, agent_id, since, wait_ms) do
    case Registry.lookup(VoiceAskSupervisor.registry(), ask_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:poll, agent_id, since, wait_ms}, wait_ms + 2_000)
        catch
          :exit, _ -> :unknown
        end

      [] ->
        :unknown
    end
  end

  defp via(ask_id), do: {:via, Registry, {VoiceAskSupervisor.registry(), ask_id}}

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(ask) do
    :ok = ChatPubSub.subscribe(ask.space_id)
    config = Application.get_env(:platform, Platform.Meetings.VoiceAsk, [])
    timeout_ms = Keyword.get(config, :timeout_ms, @default_timeout_ms)

    state =
      ask
      |> Map.merge(%{
        text: "",
        status: "pending",
        chunk_id: nil,
        question_id: nil,
        waiters: [],
        linger_ms: Keyword.get(config, :linger_ms, @default_linger_ms),
        timer: Process.send_after(self(), :timeout, timeout_ms)
      })

    {:ok, state}
  end

  @impl true
  def handle_cast({:question, %Message{id: id}}, state),
    do: {:noreply, %{state | question_id: id}}

  @impl true
  def handle_call({:poll, agent_id, _since, _wait}, _from, %{asked_by: owner} = state)
      when agent_id != owner,
      do: {:reply, {:error, :forbidden}, state}

  def handle_call({:poll, _agent_id, since, wait_ms}, from, state) do
    if ready?(state, since) do
      {:reply, {:ok, snapshot(state)}, state}
    else
      ref = make_ref()
      Process.send_after(self(), {:wait_over, ref}, wait_ms)
      {:noreply, %{state | waiters: [{ref, from, since} | state.waiters]}}
    end
  end

  @impl true
  def handle_info({:agent_reply_chunk, %{participant_id: pid} = chunk}, state)
      when pid == state.answer_participant_id do
    cond do
      state.status in ["done", "timeout"] ->
        {:noreply, state}

      state.chunk_id not in [nil, chunk.chunk_id] ->
        {:noreply, state}

      true ->
        text = if is_binary(chunk.text), do: chunk.text, else: state.text
        status = if chunk.done == true, do: "done", else: "streaming"

        state
        |> Map.merge(%{text: text, chunk_id: chunk.chunk_id})
        |> transition(status)
    end
  end

  def handle_info({:new_message, %Message{participant_id: pid} = msg}, state)
      when pid == state.answer_participant_id and not is_nil(state.question_id) and
             msg.id != state.question_id do
    case state.status do
      "timeout" ->
        {:noreply, state}

      # A reply posted after a `done` chunk (during the linger) is the
      # canonical text; nobody is waiting on it, so just replace.
      "done" when state.chunk_id == :message ->
        {:noreply, state}

      _ ->
        state
        |> Map.merge(%{text: msg.content || state.text, chunk_id: :message})
        |> transition("done")
    end
  end

  def handle_info(:timeout, %{status: status} = state) when status in ["done", "timeout"],
    do: {:noreply, state}

  def handle_info(:timeout, state), do: transition(state, "timeout")

  def handle_info({:wait_over, ref}, state) do
    case List.keytake(state.waiters, ref, 0) do
      {{^ref, from, _since}, rest} ->
        GenServer.reply(from, {:ok, snapshot(state)})
        {:noreply, %{state | waiters: rest}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:linger_over, state), do: {:stop, :normal, state}

  def handle_info(_other, state), do: {:noreply, state}

  # ── helpers ─────────────────────────────────────────────────────────────

  defp transition(state, status) do
    was_terminal? = state.status in ["done", "timeout"]
    state = %{state | status: status}

    state =
      if status in ["done", "timeout"] and not was_terminal? do
        Process.cancel_timer(state.timer)
        Process.send_after(self(), :linger_over, state.linger_ms)
        state
      else
        state
      end

    {:noreply, wake_waiters(state)}
  end

  defp wake_waiters(state) do
    {ready, waiting} =
      Enum.split_with(state.waiters, fn {_, _, since} -> ready?(state, since) end)

    Enum.each(ready, fn {_, from, _} -> GenServer.reply(from, {:ok, snapshot(state)}) end)
    %{state | waiters: waiting}
  end

  defp ready?(state, since),
    do: state.status in ["done", "timeout"] or text_length(state.text) > since

  defp text_length(text), do: text |> String.codepoints() |> length()

  defp snapshot(state) do
    %{
      ask_id: state.ask_id,
      text: state.text,
      done: state.status in ["done", "timeout"],
      status: state.status,
      answered_by: state.answered_by,
      variant: state.variant
    }
  end
end
