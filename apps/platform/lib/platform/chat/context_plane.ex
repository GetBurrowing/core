defmodule Platform.Chat.ContextPlane do
  @moduledoc """
  GenServer that owns an ETS table for shared context.

  Attaches telemetry handlers to automatically update context when
  events fire (message_posted, canvas_created, canvas_updated,
  participant_added). Provides a `build_context_bundle/1` for
  inclusion in attention signals to external runtimes.
  """
  use GenServer
  require Logger

  @table :suite_context_plane
  @activity_limit 50

  # ── Public API ──────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the full space context map for a space."
  def get_space_context(space_id) do
    case :ets.lookup(@table, {:space, space_id}) do
      [{_, context}] -> context
      [] -> %{}
    end
  end

  @doc "Return the agent state map for all agents in a space."
  def get_agent_states(space_id) do
    case :ets.lookup(@table, {:agents, space_id}) do
      [{_, states}] -> states
      [] -> %{}
    end
  end

  @doc "Return the canvas summaries for a space."
  def get_canvas_summaries(space_id) do
    case :ets.lookup(@table, {:canvases, space_id}) do
      [{_, summaries}] -> summaries
      [] -> []
    end
  end

  @doc "Return the recent activity ring buffer for a space."
  def get_recent_activity(space_id, limit \\ 20) do
    case :ets.lookup(@table, {:activity, space_id}) do
      [{_, activity}] -> Enum.take(activity, limit)
      [] -> []
    end
  end

  @doc "Update the state of a specific agent in a space."
  def update_agent_state(space_id, agent_participant_id, state) do
    GenServer.cast(__MODULE__, {:update_agent_state, space_id, agent_participant_id, state})
  end

  @doc """
  Build a context bundle for an attention signal.

  Returns a map containing space info, active canvases, active tasks,
  other agents, and a recent activity summary.
  """
  def build_context_bundle(space_id) do
    space_context = get_space_context(space_id)
    canvases = get_canvas_summaries(space_id)
    agents = get_agent_states(space_id)
    activity = get_recent_activity(space_id, 20)

    summary =
      activity
      |> Enum.map(fn entry ->
        "#{entry.author}: #{entry.preview}"
      end)
      |> Enum.join("\n")

    %{
      space: space_context,
      active_canvases: canvases,
      active_tasks: [],
      other_agents:
        Enum.map(agents, fn {_id, agent} ->
          %{name: agent[:name], state: agent[:state], capabilities: agent[:capabilities] || []}
        end),
      recent_activity_summary: summary
    }
  end

  # ── GenServer callbacks ─────────────────────────────────────────────

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    attach_telemetry()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:update_agent_state, space_id, agent_participant_id, state}, s) do
    current = get_agent_states(space_id)
    updated = Map.put(current, agent_participant_id, state)
    :ets.insert(@table, {{:agents, space_id}, updated})
    {:noreply, s}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Synchronous drain for test cleanup
  @impl true
  def handle_call(:__drain__, _from, state), do: {:reply, :ok, state}

  # ── Telemetry handlers ─────────────────────────────────────────────

  defp attach_telemetry do
    events = [
      [:platform, :chat, :message_posted],
      [:platform, :chat, :canvas_created],
      [:platform, :chat, :canvas_updated],
      [:platform, :chat, :participant_added]
    ]

    :telemetry.attach_many(
      "context-plane-handlers",
      events,
      &__MODULE__.handle_telemetry_event/4,
      nil
    )
  end

  def handle_telemetry_event(
        [:platform, :chat, :message_posted],
        _measurements,
        metadata,
        _config
      ) do
    %{space_id: space_id, message_id: message_id, participant_id: participant_id} = metadata

    entry = %{
      message_id: message_id,
      author: participant_id,
      preview: fetch_message_preview(message_id),
      timestamp: DateTime.utc_now()
    }

    current =
      case :ets.lookup(@table, {:activity, space_id}) do
        [{_, activity}] -> activity
        [] -> []
      end

    updated = [entry | current] |> Enum.take(@activity_limit)
    :ets.insert(@table, {{:activity, space_id}, updated})
  end

  def handle_telemetry_event(
        [:platform, :chat, :canvas_created],
        _measurements,
        metadata,
        _config
      ) do
    update_canvas_summary(metadata)
  end

  def handle_telemetry_event(
        [:platform, :chat, :canvas_updated],
        _measurements,
        metadata,
        _config
      ) do
    update_canvas_summary(metadata)
  end

  def handle_telemetry_event(
        [:platform, :chat, :participant_added],
        _measurements,
        metadata,
        _config
      ) do
    %{space_id: space_id, participant_id: participant_id, participant_type: participant_type} =
      metadata

    # Update space context with participant count hint
    current =
      case :ets.lookup(@table, {:space, space_id}) do
        [{_, ctx}] -> ctx
        [] -> %{}
      end

    count = Map.get(current, :participant_count, 0) + 1
    updated = Map.put(current, :participant_count, count)
    :ets.insert(@table, {{:space, space_id}, updated})

    # If it's an agent participant, add to agent states
    if participant_type == "agent" do
      agents = get_agent_states(space_id)

      updated_agents =
        Map.put_new(agents, participant_id, %{state: "idle", name: nil, capabilities: []})

      :ets.insert(@table, {{:agents, space_id}, updated_agents})
    end
  end

  defp update_canvas_summary(
         %{canvas_id: canvas_id, space_id: space_id, canvas_type: canvas_type} = meta
       ) do
    current = get_canvas_summaries(space_id)

    entry = %{
      id: canvas_id,
      title: Map.get(meta, :title),
      type: canvas_type
    }

    updated =
      current
      |> Enum.reject(fn c -> c.id == canvas_id end)
      |> then(fn list -> [entry | list] end)

    :ets.insert(@table, {{:canvases, space_id}, updated})
  end

  defp fetch_message_preview(message_id) do
    case Platform.Chat.get_message(message_id) do
      %{content: content} when is_binary(content) ->
        String.slice(content, 0, 100)

      _ ->
        ""
    end
  end
end
