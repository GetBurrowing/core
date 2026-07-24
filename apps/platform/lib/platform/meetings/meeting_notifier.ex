defmodule Platform.Meetings.MeetingNotifier do
  @moduledoc """
  GenServer that subscribes to every project's meeting lifecycle topic and
  fans out a push notification on `{:meeting_started, meeting}`.

  Sits in the supervision tree (not in a LiveView) because the per-session
  subscriber in `PlatformWeb.MeetingLive` only fires when a meetings page is
  open — drops the broadcast otherwise. Recipients are the human participants
  of the meeting's backing chat space (Option A scope: smallest blast radius,
  structurally cheapest); agents are excluded by `participant_type: "user"`
  and the host is excluded by `:exclude_participant_id`.

  ## Subscription strategy

  Mirrors `Platform.Agents.MeetingHistorianHandler`:

    1. Subscribe to `Platform.Tasks.projects_lifecycle_topic/0` FIRST so
       projects created during the `list_projects/0` call don't slip past.
    2. Subscribe to the project-meetings meta-topic
       (`Platform.Meetings.project_meetings_meta_topic/0`) — covers projects
       whose first meeting is created after boot (legacy/back-compat path).
    3. List every project at boot via `Platform.Tasks.list_projects/0` and
       subscribe to each `Platform.Meetings.project_meetings_topic/1`.

  Both `{:project_created, project}` and `{:project_meetings_topic_added,
  project_id}` prompt a dynamic subscribe so the next `{:meeting_started,
  _}` for that project routes here. Duplicate subscribes on the same topic
  are idempotent in `Phoenix.PubSub`.

  ## Test injection

  The notifications target is resolved at runtime via
  `Application.get_env(:platform, :notifications_module, Platform.Notifications)`
  so tests can swap in a recorder module per-case via
  `Application.put_env/3` to assert the helper was called with the expected
  recipient list. Runtime (not `compile_env`) read is deliberate: tests in
  `async: false` blocks reconfigure per test, and `compile_env` would bake
  the production module into the BEAM image.

  ## Configuration

  Disabled in test env via `config :platform, :start_meeting_notifier, false`.
  Tests that exercise the notifier start their own instance under
  `start_supervised/1` so the Ecto sandbox owns the Repo connection.
  """

  use GenServer

  require Logger

  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Repo
  alias Platform.Tasks

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the set of project_ids the notifier is currently subscribed to."
  @spec subscribed_projects() :: MapSet.t()
  def subscribed_projects do
    GenServer.call(__MODULE__, :subscribed_projects)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # Subscribe to meta-topics FIRST so projects created mid-`list_projects/0`
    # don't slip past. Idempotent re-subscribes are fine.
    :ok = Tasks.subscribe_to_projects_lifecycle()
    :ok = Meetings.subscribe_to_project_meetings_meta()

    subscribed =
      Tasks.list_projects()
      |> Enum.reduce(MapSet.new(), fn project, acc ->
        :ok = Meetings.subscribe_to_project_meetings(project.id)
        MapSet.put(acc, project.id)
      end)

    Logger.info(
      "[MeetingNotifier] started — subscribed to " <>
        "#{MapSet.size(subscribed)} project meeting topic(s) + lifecycle + meta"
    )

    {:ok, %{subscribed: subscribed}}
  end

  @impl GenServer
  def handle_call(:subscribed_projects, _from, state) do
    {:reply, state.subscribed, state}
  end

  @impl GenServer
  def handle_info({:meeting_started, %Meeting{} = meeting}, state) do
    # Compare-and-swap the per-meeting idempotency stamp BEFORE any
    # downstream work. If a concurrent caller already won the race (e.g.
    # the :auto_join path firing for two clients within ms), we silently
    # skip the fan-out — no preload, no recipient query, no broadcast.
    case Meetings.mark_notified(meeting) do
      {:ok, claimed} ->
        fan_out(claimed)

      {:already_notified, _} ->
        Logger.debug(
          "[MeetingNotifier] meeting_started — meeting=#{meeting.id} " <>
            "already notified, skipping fan-out"
        )

        :ok
    end

    {:noreply, state}
  end

  # Cover projects created post-boot: subscribe immediately so the
  # first meeting in that project routes a `{:meeting_started, _}`
  # back here.
  def handle_info({:project_created, %{id: project_id}}, state) do
    {:noreply, maybe_subscribe_project(state, project_id)}
  end

  # Legacy meta-topic from `Meetings.create_meeting/1` — fires when a
  # project's first meeting is created. Belt-and-suspenders with
  # `:project_created`: both routes converge on `maybe_subscribe_project/2`.
  def handle_info({:project_meetings_topic_added, project_id}, state) do
    {:noreply, maybe_subscribe_project(state, project_id)}
  end

  # We share project lifecycle topics with other consumers — ignore
  # everything we don't care about (e.g. :meeting_created, :meeting_ended).
  def handle_info(other, state) do
    Logger.debug("[MeetingNotifier] ignoring #{inspect(other)}")
    {:noreply, state}
  end

  # ── Internal ──────────────────────────────────────────────────────────────

  defp fan_out(%Meeting{} = meeting) do
    meeting = Repo.preload(meeting, :host_participant)

    host_display_name =
      case meeting.host_participant do
        %Participant{display_name: name} when is_binary(name) and name != "" -> name
        _ -> "Someone"
      end

    # Single recipient source for BOTH the #440 push path and the inbox path:
    # the meeting's backing chat space's human participants.
    user_participants = Chat.list_participants(meeting.chat_space_id, participant_type: "user")

    recipients = Enum.map(user_participants, & &1.id)

    payload = %{
      title: "#{host_display_name} started a meeting",
      body: meeting.name,
      url: "/meetings/#{meeting.slug}"
    }

    Logger.info(
      "[MeetingNotifier] meeting_started — meeting=#{meeting.id} " <>
        "project=#{meeting.project_id} recipients=#{length(recipients)}"
    )

    # #440 push fan-out — must stay byte-for-byte identical (no regression).
    notifications_module().fan_out_to_humans(recipients, payload,
      exclude_participant_id: meeting.host_participant_id
    )

    # Parallel, additive inbox fan-out: one durable Inbox row per invited
    # human. Independent of the push path above — a per-recipient failure
    # never aborts the push or the remaining rows.
    fan_out_inbox(meeting, user_participants, host_display_name)
  end

  # Emit one `meeting_starting` inbox row per invited human, skipping the
  # host (no self-row) and anyone already active in the meeting (no attention
  # needed). `invitee_count` is the candidate count (user participants minus
  # host), independent of the already-active skip.
  defp fan_out_inbox(%Meeting{} = meeting, user_participants, host_display_name) do
    active_user_ids =
      meeting.chat_space_id
      |> Meetings.active_participants_for_space()
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    invitees =
      Enum.reject(user_participants, fn p -> p.id == meeting.host_participant_id end)

    invitee_count = length(invitees)

    Enum.each(invitees, fn participant ->
      # For a `participant_type: "user"` chat row, participant_id holds the
      # users.id FK.
      user_id = participant.participant_id

      unless MapSet.member?(active_user_ids, user_id) do
        emit_inbox_row(meeting, user_id, host_display_name, invitee_count)
      end
    end)
  end

  defp emit_inbox_row(%Meeting{} = meeting, user_id, host_display_name, invitee_count) do
    inbox_module().emit(%{
      user_id: user_id,
      kind: "meeting_starting",
      source_type: "meeting",
      source_id: meeting.id,
      title: "Meeting started: #{meeting.name}",
      body: "Host: #{host_display_name} · #{invitee_count} invited",
      url: "/meetings/#{meeting.id}"
    })
  rescue
    error ->
      Logger.warning(
        "[MeetingNotifier] inbox emit failed — meeting=#{meeting.id} " <>
          "user=#{user_id}: #{inspect(error)}"
      )

      :error
  end

  defp notifications_module do
    Application.get_env(:platform, :notifications_module, Platform.Notifications)
  end

  defp inbox_module do
    Application.get_env(:platform, :inbox_module, Platform.Inbox)
  end

  defp maybe_subscribe_project(state, project_id) do
    if MapSet.member?(state.subscribed, project_id) do
      state
    else
      :ok = Meetings.subscribe_to_project_meetings(project_id)

      Logger.info("[MeetingNotifier] dynamically subscribed to project=#{project_id}")

      %{state | subscribed: MapSet.put(state.subscribed, project_id)}
    end
  end
end
