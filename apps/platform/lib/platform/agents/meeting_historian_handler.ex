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

    {:ok, %{subscribed: subscribed}}
  end

  @impl GenServer
  def handle_call(:subscribed_projects, _from, state) do
    {:reply, state.subscribed, state}
  end

  @impl GenServer
  def handle_info({:meeting_ended, %Meeting{} = meeting}, state) do
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

    {:noreply, state}
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
end
