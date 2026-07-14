defmodule Platform.Agents.MeetingHistorianHandler do
  @moduledoc """
  GenServer that subscribes to every project's `meeting_ended` PubSub
  topic and dispatches the Historian on `:meeting_ended` (ADR-0041 / T6).

  Sibling fire path to `Platform.Agents.SystemEventScheduler` — both
  delegate the actual dispatch pipeline to
  `Platform.Agents.HistorianDispatcher` so the (template_slug, metadata)
  pair is the only thing each call site picks.

  ## Subscription strategy

  On `init/1` the handler:

    1. Lists every project via `Platform.Tasks.list_projects/0` and
       subscribes to `Platform.Meetings.project_meetings_topic(project.id)`
       for each — covers projects that existed at boot.
    2. Subscribes to the meta-topic
       `Platform.Meetings.project_meetings_meta_topic/0`
       — covers projects whose first meeting is created after boot.
       `Platform.Meetings.create_meeting/1` broadcasts
       `{:project_meetings_topic_added, project_id}` on that topic, and
       the handler subscribes to the new project topic in response.

  ## Dispatch metadata

  On `{:meeting_ended, %Meeting{}}` the handler dispatches via
  `HistorianDispatcher.dispatch("historian", "historian.meeting_ended",
  %{trigger: "meeting_ended", meeting_id: m.id, project_id: m.project_id,
  chat_space_id: m.chat_space_id})` — the Historian's prompt template
  interpolates the scope IDs so the agent's `memory_search` calls filter
  to that meeting / project / space namespace.

  ## Failure isolation

  Dispatch failures are logged but do not crash the handler. A project
  that has no Historian-flagged agent yields `:ok` from the dispatcher
  (the "no eligible agent" path) — the handler stays subscribed.

  ## Per-meeting debounce

  Because the same meeting can emit `{:meeting_ended, %Meeting{}}` more than
  once (webhook re-delivery, replay, an operator manually re-ending a stuck
  meeting), the handler tracks a last-fired timestamp per `meeting_id` and
  refuses to re-dispatch inside the debounce window. The window defaults to
  15 minutes and is configurable via
  `Application.get_env(:platform, :meeting_historian_debounce_ms, 900_000)`.
  When a fire is skipped the handler emits the
  `[:platform, :agents, :historian, :dispatch_debounced]` telemetry event
  (audit handler wired in stage 5) with `%{meeting_id, project_id,
  elapsed_ms}` metadata. Stale meeting IDs (last-fired > 2× the debounce
  window ago) are pruned on every fire so the map does not grow without
  bound over a long-lived BEAM.

  ## Configuration

  Disabled in test env via `config :platform, :start_meeting_historian_handler, false`.
  Tests start their own instance under `start_supervised/1`.
  """

  use GenServer

  require Logger

  alias Platform.Agents.HistorianDispatcher
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Tasks

  @historian_event "historian"
  @meeting_ended_template "historian.meeting_ended"

  # 15 minutes — the same meeting_id firing more than once inside this
  # window is treated as a duplicate delivery and the Historian dispatch
  # is skipped. Override via
  # `config :platform, :meeting_historian_debounce_ms, <ms>`.
  @default_debounce_ms 15 * 60 * 1_000

  @dispatch_debounced_event [:platform, :agents, :historian, :dispatch_debounced]

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the set of project_ids the handler is currently subscribed to."
  @spec subscribed_projects() :: MapSet.t()
  def subscribed_projects do
    GenServer.call(__MODULE__, :subscribed_projects)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Subscribe to the meta-topic FIRST so projects created during the
    # `list_projects/0` call (or just after) don't slip past — the worst
    # case is a duplicate subscribe on a topic, which is idempotent for
    # Phoenix.PubSub.
    :ok = Meetings.subscribe_to_project_meetings_meta()

    subscribed =
      Tasks.list_projects()
      |> Enum.reduce(MapSet.new(), fn project, acc ->
        :ok = Meetings.subscribe_to_project_meetings(project.id)
        MapSet.put(acc, project.id)
      end)

    Logger.info(
      "[MeetingHistorianHandler] started — subscribed to " <>
        "#{MapSet.size(subscribed)} project meeting topic(s) + meta-topic"
    )

    {:ok, %{subscribed: subscribed, last_dispatched_at: %{}}}
  end

  @impl GenServer
  def handle_call(:subscribed_projects, _from, state) do
    {:reply, state.subscribed, state}
  end

  @impl GenServer
  def handle_info({:meeting_ended, %Meeting{} = meeting}, state) do
    now = DateTime.utc_now()
    debounce = debounce_ms()

    case Map.get(state.last_dispatched_at, meeting.id) do
      %DateTime{} = last ->
        elapsed_ms = DateTime.diff(now, last, :millisecond)

        if elapsed_ms >= debounce do
          fire_dispatch(meeting, now, debounce, state)
        else
          skip_dispatch(meeting, elapsed_ms, debounce, state)
        end

      nil ->
        fire_dispatch(meeting, now, debounce, state)
    end
  end

  # Cover projects created after boot: the `Meetings.create_meeting/1`
  # broadcast on the meta-topic prompts a dynamic subscribe so the next
  # `{:meeting_ended, _}` for that project routes here.
  def handle_info({:project_meetings_topic_added, project_id}, state) do
    if MapSet.member?(state.subscribed, project_id) do
      {:noreply, state}
    else
      :ok = Meetings.subscribe_to_project_meetings(project_id)

      Logger.info("[MeetingHistorianHandler] dynamically subscribed to project=#{project_id}")

      {:noreply, %{state | subscribed: MapSet.put(state.subscribed, project_id)}}
    end
  end

  # We share the project lifecycle topic with other consumers — ignore
  # everything we don't care about (e.g. :meeting_created, :meeting_started).
  def handle_info(other, state) do
    Logger.debug("[MeetingHistorianHandler] ignoring #{inspect(other)}")
    {:noreply, state}
  end

  # ── Dispatch + debounce internals ─────────────────────────────────────────

  defp fire_dispatch(%Meeting{} = meeting, %DateTime{} = now, debounce, state) do
    metadata = %{
      trigger: "meeting_ended",
      meeting_id: meeting.id,
      project_id: meeting.project_id,
      chat_space_id: meeting.chat_space_id
    }

    Logger.info(
      "[MeetingHistorianHandler] meeting_ended — meeting=#{meeting.id} " <>
        "project=#{meeting.project_id} space=#{meeting.chat_space_id}"
    )

    case HistorianDispatcher.dispatch(@historian_event, @meeting_ended_template, metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[MeetingHistorianHandler] historian dispatch failed for meeting " <>
            "#{meeting.id}: #{inspect(reason)}"
        )
    end

    new_last =
      state.last_dispatched_at
      |> Map.put(meeting.id, now)
      |> prune_stale(now, debounce)

    {:noreply, %{state | last_dispatched_at: new_last}}
  end

  defp skip_dispatch(%Meeting{} = meeting, elapsed_ms, debounce, state) do
    Logger.info(
      "[MeetingHistorianHandler] debounced meeting_ended — meeting=#{meeting.id} " <>
        "elapsed=#{elapsed_ms}ms < window=#{debounce}ms"
    )

    :telemetry.execute(
      @dispatch_debounced_event,
      %{elapsed_ms: elapsed_ms, debounce_ms: debounce},
      %{meeting_id: meeting.id, project_id: meeting.project_id}
    )

    {:noreply, state}
  end

  # Prune entries whose last-fired timestamp is older than 2× the debounce
  # window — safely past the point where the same meeting_id could still
  # be debounced. Keeps the map from growing across a long-lived BEAM.
  defp prune_stale(last_dispatched_at, %DateTime{} = now, debounce) do
    cutoff_ms = debounce * 2

    Enum.reduce(last_dispatched_at, %{}, fn {meeting_id, ts}, acc ->
      if DateTime.diff(now, ts, :millisecond) < cutoff_ms do
        Map.put(acc, meeting_id, ts)
      else
        acc
      end
    end)
  end

  defp debounce_ms do
    Application.get_env(:platform, :meeting_historian_debounce_ms, @default_debounce_ms)
  end
end
