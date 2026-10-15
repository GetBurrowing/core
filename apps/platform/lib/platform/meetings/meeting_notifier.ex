defmodule Platform.Meetings.MeetingNotifier do
  @moduledoc """
  GenServer that subscribes to every project's meeting lifecycle topic and
  fans out a push notification on `{:meeting_started, meeting}` and on
  `{:meeting_cancelled, meeting}`.

  Sits in the supervision tree (not in a LiveView) because the per-session
  subscriber in `PlatformWeb.MeetingLive` only fires when a meetings page is
  open — drops the broadcast otherwise.

  ## Recipients are resolved by the context, not here

  `Platform.Meetings.recipients_for_meeting/1` answers who gets told, and says
  which rule answered. Two shapes come back and this module fans out
  differently for each:

    * `source: :invites` — the meeting has a declared invitee set
      (`meeting_invites`). Push goes out per invited user via
      `Platform.Notifications.fan_out_to_user/2`, because `fan_out_to_humans/3`
      takes chat-participant ROW ids and therefore structurally cannot reach an
      invitee who is not in the meeting's chat space — the exact gap the invite
      table exists to close. Guests produce no push and no inbox row: they have
      no account, and their delivery channel is the per-invite link.
    * `source: :chat_participants` — no declaration exists, so recipients are
      the human participants of the meeting's backing chat space, exactly as
      before invites existed. Agents are excluded by `participant_type: "user"`
      and the host by `:exclude_participant_id`.

  **The second branch is not a fallback in the "rare" sense.** Every meeting
  that predates `meeting_invites` has zero invite rows, so it is the only path
  production takes until a host declares an invitee. If it breaks, the failure
  is silent — an empty recipient list emits nothing and raises nothing.

  ## Subscription strategy

  Mirrors `Platform.Agents.MeetingHistorianHandler`:

    1. Subscribe to `Platform.Tasks.projects_lifecycle_topic/0` FIRST so
       projects created during the `list_projects_unscoped/1` call don't slip past.
    2. Subscribe to the project-meetings meta-topic
       (`Platform.Meetings.project_meetings_meta_topic/0`) — covers projects
       whose first meeting is created after boot (legacy/back-compat path).
    3. List every project at boot via `Platform.Tasks.list_projects_unscoped/1` and
       subscribe to each `Platform.Meetings.project_meetings_topic/1`.

  Both `{:project_created, project}` and `{:project_meetings_topic_added,
  project_id}` prompt a dynamic subscribe so the next `{:meeting_started,
  _}` for that project routes here.

  The meta-topic subscribes happen BEFORE the boot enumeration on purpose: a
  project missed between the two is unrecoverable, while the overlap costs at
  worst a duplicate subscribe. That duplicate is a REAL duplicate delivery, not
  a no-op — `Phoenix.PubSub` does NOT dedup within a single pid. Its registry is
  started with `keys: :duplicate`
  (deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex) and `subscribe/3` is a
  bare `Registry.register/3` (deps/phoenix_pubsub/lib/phoenix/pubsub.ex), so a
  second subscribe from the same process adds a SECOND registration and every
  later broadcast on the topic arrives twice.

  What actually closes the window is the MapSet guard in
  `maybe_subscribe_project/2`, not `Phoenix.PubSub`: it opens with
  `MapSet.member?(state.subscribed, project_id)` and returns state unchanged on
  a hit, and both dynamic clauses converge on it. Do not delete that check
  believing `Phoenix.PubSub` covers it. Do not pair an unsubscribe with the
  subscribe either — one `Registry.unregister/2` takes this pid's count for the
  key to 0, not n-1, dropping ALL of its entries for that topic.

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
    # Subscribe to meta-topics FIRST so projects created mid-`list_projects_unscoped/1`
    # don't slip past. The ordering is deliberate and asymmetric: a missed
    # project is unrecoverable, while the overlap costs at worst a duplicate
    # subscribe — and that duplicate is a REAL duplicate delivery, not a no-op.
    # `Phoenix.PubSub` does NOT dedup within a single pid: its registry is
    # started with `keys: :duplicate`
    # (deps/phoenix_pubsub/lib/phoenix/pubsub/supervisor.ex) and `subscribe/3`
    # is a bare `Registry.register/3` (deps/phoenix_pubsub/lib/phoenix/pubsub.ex),
    # so a second subscribe from this process adds a SECOND registration and
    # every later broadcast on the topic arrives twice.
    #
    # What makes the ordering safe is the MapSet guard in
    # `maybe_subscribe_project/2` below, not `Phoenix.PubSub`: it returns state
    # unchanged when `state.subscribed` already holds the project, and both
    # `{:project_created, _}` and `{:project_meetings_topic_added, _}` converge
    # on it. Do not delete that check believing PubSub covers it, and do not
    # pair an unsubscribe with the subscribe — one `Registry.unregister/2`
    # takes this pid's count for the key to 0, not n-1.
    :ok = Tasks.subscribe_to_projects_lifecycle()
    :ok = Meetings.subscribe_to_project_meetings_meta()

    subscribed =
      Tasks.list_projects_unscoped()
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
        ring(claimed)

      {:already_notified, _} ->
        Logger.debug(
          "[MeetingNotifier] meeting_started — meeting=#{meeting.id} " <>
            "already notified, skipping fan-out"
        )

        :ok
    end

    {:noreply, state}
  end

  # A cancellation is told to the same people, through the same recipient
  # resolution, as a start (task 019fb954-c848) — which is the reason it is
  # routed here rather than fanned out at the call site: `fan_out/1` already
  # knows how to answer "who was expecting this meeting", invite rows first
  # and chat participants otherwise, and duplicating that query is how the
  # two answers drift apart. Same CAS-before-any-work shape as
  # `:meeting_started`, against the separate `cancellation_notified_at`
  # stamp, so a re-broadcast cannot notify twice.
  def handle_info({:meeting_cancelled, %Meeting{} = meeting}, state) do
    case Meetings.mark_cancellation_notified(meeting) do
      {:ok, claimed} ->
        fan_out(claimed)

      {:already_notified, _} ->
        Logger.debug(
          "[MeetingNotifier] meeting_cancelled — meeting=#{meeting.id} " <>
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

  # Ringing (task 01a10db7 stage 2) runs on START only, after the alert and
  # inbox fan-out above, which it leaves exactly as it was. It is NOT handed
  # `recipients_for_meeting/1`'s answer: that answer falls back to every
  # human of the chat space when nobody was invited, and a ring must never
  # reach that audience. `Ringing.ring_for_start/1` reads the invite rows
  # itself. A raise here must not take the notifier down with it.
  defp ring(%Meeting{} = meeting) do
    ringing_module().ring_for_start(meeting)
  rescue
    error ->
      Logger.warning(
        "[MeetingNotifier] ringing raised — meeting=#{meeting.id}: " <>
          Exception.message(error)
      )

      :error
  end

  defp ringing_module do
    Application.get_env(:platform, :ringing_module, Platform.Meetings.Ringing)
  end

  defp fan_out(%Meeting{} = meeting) do
    meeting = Repo.preload(meeting, :host_participant)

    host_display_name =
      case meeting.host_participant do
        %Participant{display_name: name} when is_binary(name) and name != "" -> name
        _ -> "Someone"
      end

    # Single recipient source for BOTH the #440 push path and the inbox path.
    # Which rule answered is carried on `:source` and drives the push branch
    # below; the inbox branch is the same either way.
    recipients = meeting |> Meetings.recipients_for_meeting() |> readable_recipients(meeting)

    payload = %{
      title: "#{host_display_name} started a meeting",
      body: meeting.name,
      url: "/meetings/#{meeting.slug}"
    }

    Logger.info(
      "[MeetingNotifier] meeting_started — meeting=#{meeting.id} " <>
        "project=#{meeting.project_id} source=#{recipients.source} " <>
        "invitees=#{recipients.invitee_count} recipients=#{length(recipients.user_ids)}"
    )

    fan_out_push(meeting, recipients, payload)

    # Parallel, additive inbox fan-out: one durable Inbox row per invited
    # human. Independent of the push path above — a per-recipient failure
    # never aborts the push or the remaining rows.
    fan_out_inbox(meeting, recipients, host_display_name)
  end

  defp readable_recipients(recipients, %Meeting{chat_space_id: space_id}) do
    allowed? = fn user_id ->
      user = Repo.get(Platform.Accounts.User, user_id)

      is_nil(user) or
        Platform.Access.check(
          Platform.Access.Scope.for_user(user),
          "chat.read",
          {:space, space_id}
        ) == :ok
    end

    candidate_ids =
      recipients.user_ids ++ Enum.map(Map.get(recipients, :chat_participants, []), & &1.participant_id)

    allowed_set = candidate_ids |> Enum.uniq() |> Enum.filter(allowed?) |> MapSet.new()

    recipients
    |> Map.put(:user_ids, Enum.filter(recipients.user_ids, &MapSet.member?(allowed_set, &1)))
    |> Map.update(:chat_participants, [], fn rows ->
      Enum.filter(rows, &MapSet.member?(allowed_set, &1.participant_id))
    end)
  end

  # No declaration: the #440 participant-row push path, unchanged. Passes the
  # FULL participant list (host included) and lets `fan_out_to_humans/3` drop
  # the host via `:exclude_participant_id`, exactly as before invites existed.
  defp fan_out_push(%Meeting{} = meeting, %{source: :chat_participants} = recipients, payload) do
    participant_row_ids = Enum.map(recipients.chat_participants, & &1.id)

    notifications_module().fan_out_to_humans(participant_row_ids, payload,
      exclude_participant_id: meeting.host_participant_id
    )
  end

  # Declared invitees: user-keyed push, one call per invited user.
  # `fan_out_to_humans/3` is NOT usable here — it takes chat-participant row
  # ids, so it cannot address an invitee who has no row in this meeting's chat
  # space, which is precisely who the invite table was added to reach.
  # `fan_out_to_user/2` resolves subscriptions across all of a user's
  # participant rows and dedups by endpoint.
  defp fan_out_push(%Meeting{}, %{source: :invites} = recipients, payload) do
    Enum.each(recipients.user_ids, fn user_id ->
      notifications_module().fan_out_to_user(user_id, payload)
    end)
  end

  # Emit one `meeting_starting` inbox row per invited human, skipping anyone
  # already active in the meeting (no attention needed). The host is already
  # absent from `user_ids` on both branches. `invitee_count` is the declared
  # count, independent of the already-active skip — and on the `:invites`
  # branch it includes guests, who get no row of their own.
  defp fan_out_inbox(%Meeting{} = meeting, recipients, host_display_name) do
    active_user_ids =
      meeting.chat_space_id
      |> Meetings.active_participants_for_space()
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.each(recipients.user_ids, fn user_id ->
      unless MapSet.member?(active_user_ids, user_id) do
        emit_inbox_row(meeting, user_id, host_display_name, recipients.invitee_count)
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
