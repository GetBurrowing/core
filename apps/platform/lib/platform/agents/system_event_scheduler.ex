defmodule Platform.Agents.SystemEventScheduler do
  @moduledoc """
  Periodic scheduler that fires system events to designated agents.

  Two events in v1:
  - `daily_summary` (23:00 UTC) — agent summarizes the day's activity
  - `dreaming` (03:00 UTC) — agent consolidates daily memories into ORG_MEMORY.md

  Each event can only be assigned to a single agent (one-agent-per-event).
  The scheduler posts a synthetic instruction message into a per-agent system
  space and dispatches via `AgentResponder`.

  ## Configuration

      config :platform, Platform.Agents.SystemEventScheduler,
        check_interval_ms: 60_000,
        events: %{"daily_summary" => 23, "dreaming" => 3}
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.AgentResponder
  alias Platform.Repo

  # ── Defaults ─────────────────────────────────────────────────────────────────

  @default_check_interval_ms :timer.seconds(60)

  @default_events %{
    "daily_summary" => 23,
    "dreaming" => 3
  }

  @instruction_templates %{
    "daily_summary" => """
    You are performing your daily summary for {date}. \
    Start by calling `space_list` to see all spaces you participate in. \
    Then call `space_get_messages` on each active space to review today's \
    activity. Write a concise summary of what happened today, including key \
    decisions, progress, blockers, and open questions. Use the \
    `org_memory_append` tool to record this summary as a daily memory entry \
    dated {date}.
    """,
    "dreaming" => """
    You are in dreaming mode. Review recent daily memory entries using \
    org_memory_search. Look for patterns, recurring themes, emerging risks, \
    and strategic insights. Synthesize your observations and update \
    ORG_MEMORY.md with any new patterns, decisions, or lessons learned using \
    the org_context_write tool. Be selective — only add genuinely new insights, \
    and preserve existing content that is still relevant.
    """
  }

  # ── Public API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force-fire a specific event now (for testing/admin)."
  @spec fire_now(String.t()) :: :ok | {:error, term()}
  def fire_now(event_type) do
    GenServer.call(__MODULE__, {:fire_now, event_type}, :timer.minutes(2))
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    config = Application.get_env(:platform, __MODULE__, [])

    state = %{
      check_interval_ms:
        Keyword.get(opts, :check_interval_ms, Keyword.get(config, :check_interval_ms, @default_check_interval_ms)),
      events: Keyword.get(opts, :events, Keyword.get(config, :events, @default_events)),
      next_fires: %{},
      last_fired: %{}
    }

    state = %{state | next_fires: compute_all_next_fires(state.events)}
    schedule_check(state)

    Logger.info(
      "[SystemEventScheduler] started (interval=#{state.check_interval_ms}ms, events=#{inspect(Map.keys(state.events))})"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:check, state) do
    now = DateTime.utc_now()
    {fired, new_next_fires} = check_and_fire(now, state)
    new_last_fired = Map.merge(state.last_fired, fired)
    schedule_check(state)
    {:noreply, %{state | next_fires: new_next_fires, last_fired: new_last_fired}}
  end

  @impl GenServer
  def handle_call({:fire_now, event_type}, _from, state) do
    result = dispatch_event(event_type)
    {:reply, result, state}
  end

  # ── Scheduling ───────────────────────────────────────────────────────────────

  defp schedule_check(%{check_interval_ms: ms}) do
    Process.send_after(self(), :check, ms)
  end

  defp compute_all_next_fires(events) do
    now = DateTime.utc_now()
    Map.new(events, fn {event, hour} -> {event, next_fire_time(now, hour)} end)
  end

  @doc false
  def next_fire_time(%DateTime{} = now, target_hour) when is_integer(target_hour) do
    today_target = %{now | hour: target_hour, minute: 0, second: 0, microsecond: {0, 6}}

    if DateTime.compare(now, today_target) == :lt do
      today_target
    else
      DateTime.add(today_target, 86_400, :second)
    end
  end

  defp check_and_fire(now, state) do
    Enum.reduce(state.next_fires, {%{}, state.next_fires}, fn {event, fire_at}, {fired, nf} ->
      if should_fire?(now, fire_at, event, state.last_fired) do
        Logger.info("[SystemEventScheduler] firing event=#{event}")
        dispatch_event(event)
        new_fire_at = next_fire_time(now, state.events[event])
        {Map.put(fired, event, now), Map.put(nf, event, new_fire_at)}
      else
        {fired, nf}
      end
    end)
  end

  defp should_fire?(now, fire_at, event, last_fired) do
    DateTime.compare(now, fire_at) != :lt and not fired_today?(event, last_fired)
  end

  @doc false
  def fired_today?(event, last_fired) do
    case Map.get(last_fired, event) do
      nil -> false
      %DateTime{} = last -> Date.compare(DateTime.to_date(last), Date.utc_today()) == :eq
    end
  end

  # ── Dispatch ─────────────────────────────────────────────────────────────────

  defp dispatch_event(event_type) do
    case agent_for_event(event_type) do
      %Agent{} = agent ->
        Logger.info("[SystemEventScheduler] dispatching #{event_type} to agent=#{agent.slug}")
        dispatch_to_agent(agent, event_type)

      nil ->
        Logger.info("[SystemEventScheduler] no active agent flagged for #{event_type}, skipping")
        :ok
    end
  end

  defp agent_for_event(event_type) do
    from(a in Agent,
      where: a.status == "active",
      where: fragment("? @> ?", a.system_events, ^[event_type]),
      limit: 1
    )
    |> Repo.one()
  end

  defp dispatch_to_agent(%Agent{} = agent, event_type) do
    with {:ok, space} <- ensure_system_space(agent),
         {:ok, system_participant} <- ensure_system_participant(space),
         {:ok, agent_participant} <-
           Chat.ensure_agent_participant(space.id, agent, display_name: agent.name),
         {:ok, message} <- post_instruction(space, system_participant, event_type) do
      signal = %{
        participant_id: agent_participant.id,
        message_id: message.id,
        space_id: space.id,
        reason: :system_event,
        metadata: %{event_type: event_type}
      }

      AgentResponder.maybe_dispatch(signal)
    else
      {:error, reason} ->
        Logger.error(
          "[SystemEventScheduler] failed to dispatch #{event_type} to #{agent.slug}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # ── Space + participant helpers ──────────────────────────────────────────────

  defp ensure_system_space(%Agent{} = agent) do
    slug = "system-#{agent.slug}"

    case Chat.get_space_by_slug(slug) do
      %Chat.Space{} = space ->
        {:ok, space}

      nil ->
        Chat.create_space(%{
          name: "#{agent.name} — System Events",
          slug: slug,
          kind: "system",
          metadata: %{"system_event_space" => true, "agent_id" => agent.id}
        })
    end
  end

  @system_participant_sentinel "00000000-0000-0000-0000-000000000001"

  defp ensure_system_participant(space) do
    case Repo.get_by(Chat.Participant,
           space_id: space.id,
           participant_type: "user",
           participant_id: @system_participant_sentinel
         ) do
      %Chat.Participant{} = p ->
        {:ok, p}

      nil ->
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: @system_participant_sentinel,
          display_name: "System",
          joined_at: DateTime.utc_now()
        })
    end
  end

  defp post_instruction(space, system_participant, event_type) do
    template = Map.fetch!(@instruction_templates, event_type)
    content = String.replace(template, "{date}", Date.to_iso8601(Date.utc_today()))

    Chat.post_message(%{
      space_id: space.id,
      participant_id: system_participant.id,
      content_type: "text",
      content: content,
      metadata: %{"source" => "system_event", "event_type" => event_type}
    })
  end
end
