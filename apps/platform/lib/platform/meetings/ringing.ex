defmodule Platform.Meetings.Ringing do
  @moduledoc """
  Meeting ringing (task 01a10db7 stage 2): who gets a PushKit VoIP push that
  the iOS app reports to CallKit as an incoming call, and what happens to the
  ring afterwards.

  ## The ringing rule (2026-10-06)

  A ring means "you are invited and it is starting now".

    * **R1, on start** (`ring_for_start/1`, called by
      `Platform.Meetings.MeetingNotifier` on `{:meeting_started, _}` only):
      ring user U iff U is the `user_id` of a NON-REVOKED invite row of the
      meeting, U did not start it, U is not its host, U is not already active
      in it, and `Meetings.join_permitted?/2` holds for U.
    * **R2**: a meeting with no user invite rows rings NOBODY. Its chat-space
      members keep the alert push and inbox row `MeetingNotifier` already
      sends. This module therefore reads `Meetings.list_invites/1` itself and
      never `Meetings.recipients_for_meeting/1`, whose `:chat_participants`
      branch is exactly the audience a ring must not reach.
    * **R3, on an invite** (`ring_for_live_invite/3`, called by
      `Meetings.invite_user/3` when the caller names an inviter): ring iff the
      meeting is `live` AS READ FROM THE DATABASE NOW, not as the caller's
      struct says, and the invitee is not the inviter. An invite to a
      scheduled meeting stays the alert push `InviteDelivery` sends.
    * **R4**: the user who started the meeting is never rung. A decline or a
      missed ring is reported back to the inviter.

  ## Idempotency

  Every ring is a `meeting_rings` row, unique on
  `(meeting_id, user_id, trigger)`. The insert is `on_conflict: :nothing` and
  the push goes out only when a row was actually written, so a re-broadcast
  or a repeated invite cannot ring the same person twice for one reason.

  ## Busy callee

  A callee already active in ANY live room gets no VoIP push (CallKit would
  interrupt the call they are in). They get an ALERT push instead, kind
  `meeting_ring_waiting` (category `SUITE_RING_WAITING`) carrying `ring_id`,
  which the app shows as its in-app "Invites you to join" banner.

  ## Payload

  The VoIP body carries ids and display strings only, never a token:
  `ring_id`, `meeting_id`, `space_id`, `trigger`, `caller_name`,
  `install_host`, `sent_at`.

  ## Seams

  Callers resolve this module through
  `Application.get_env(:platform, :ringing_module, #{inspect(__MODULE__)})`.
  Inside, the VoIP transport is `:voip_push_module` (default
  `Platform.Push.APNs`) and alert pushes go through `:notifications_module`
  (default `Platform.Notifications`), the same seam `MeetingNotifier` uses.
  """

  import Ecto.Query

  require Logger

  alias Platform.Accounts
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant
  alias Platform.Meetings.PubSub, as: MeetingsPubSub
  alias Platform.Meetings.Ring
  alias Platform.Meetings.Room
  alias Platform.Push.Notification
  alias Platform.Repo

  # A ring still `ringing` after this long is over: CallKit has long since
  # given up on it, and the app reports it missed.
  @ring_window_seconds 45

  @doc "Seconds after which a still-ringing ring reads as over."
  def ring_window_seconds, do: @ring_window_seconds

  # ── Ringing ──────────────────────────────────────────────────────────────

  @doc """
  Ring the invitees of `meeting`, which has just started (R1, R2, R4).
  Returns the rings that were sent (VoIP or busy alert).
  """
  @spec ring_for_start(Meeting.t()) :: [Ring.t()]
  def ring_for_start(%Meeting{} = meeting) do
    host_user_id = Meetings.host_user_id(meeting)
    inviter_user_id = meeting.started_by_user_id || host_user_id

    meeting.id
    |> Meetings.list_invites()
    |> Enum.map(& &1.user_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == meeting.started_by_user_id))
    |> Enum.reject(&(not is_nil(host_user_id) and &1 == host_user_id))
    |> Enum.filter(&ringable?(meeting, &1))
    |> Enum.flat_map(fn user_id ->
      ring(meeting, user_id, inviter_user_id, "meeting_started")
    end)
  end

  @doc """
  Ring `invitee_user_id`, just invited into `meeting` by `inviter_user_id`,
  if the meeting is live right now (R3). The meeting's status is re-read from
  the database: the caller's struct may predate the start.
  """
  @spec ring_for_live_invite(Meeting.t(), binary(), binary() | nil) :: [Ring.t()]
  def ring_for_live_invite(%Meeting{id: meeting_id}, invitee_user_id, inviter_user_id)
      when is_binary(invitee_user_id) do
    with false <- invitee_user_id == inviter_user_id,
         %Meeting{status: "live"} = meeting <- Meetings.get_meeting(meeting_id),
         false <- invitee_user_id == meeting.started_by_user_id,
         true <- ringable?(meeting, invitee_user_id) do
      ring(meeting, invitee_user_id, inviter_user_id, "live_invite")
    else
      _ -> []
    end
  end

  def ring_for_live_invite(_meeting, _invitee_user_id, _inviter_user_id), do: []

  # Not already in this meeting, and allowed to join it at all.
  defp ringable?(%Meeting{} = meeting, user_id) do
    is_nil(Meetings.active_participant_for_user_in_space(meeting.chat_space_id, user_id)) and
      Meetings.join_permitted?(meeting.chat_space_id, user_id)
  end

  defp ring(%Meeting{} = meeting, user_id, inviter_user_id, trigger) do
    now = DateTime.utc_now()

    row = %{
      id: Platform.Types.UUIDv7.generate(),
      meeting_id: meeting.id,
      user_id: user_id,
      inviter_user_id: inviter_user_id,
      trigger: trigger,
      state: "ringing",
      inserted_at: now,
      updated_at: now
    }

    # `insert_all` rather than `insert`: the id is generated client-side, so
    # `Repo.insert(on_conflict: :nothing)` would hand back a struct WITH an
    # id even when nothing was written. The row count is the only honest
    # answer to "was this person rung for this reason already?".
    case Repo.insert_all(Ring, [row],
           on_conflict: :nothing,
           conflict_target: [:meeting_id, :user_id, :trigger],
           returning: true
         ) do
      {1, [%Ring{} = ring]} ->
        deliver(meeting, ring)
        [ring]

      {0, _} ->
        []
    end
  end

  defp deliver(%Meeting{} = meeting, %Ring{} = ring) do
    caller_name = caller_name(meeting, ring)

    if busy?(ring.user_id) do
      notifications_module().fan_out_to_user(
        ring.user_id,
        Notification.new(%{
          kind: "meeting_ring_waiting",
          title: caller_name,
          body: "Invites you to join",
          url: "/meetings/#{meeting.slug}",
          meeting_id: meeting.id,
          space_id: meeting.chat_space_id,
          ring_id: ring.id,
          collapse_id: ring.id
        })
      )
    else
      voip_module().deliver_voip_to_user(ring.user_id, %{
        "ring_id" => ring.id,
        "meeting_id" => meeting.id,
        "space_id" => meeting.chat_space_id,
        "trigger" => ring.trigger,
        "caller_name" => caller_name,
        "install_host" => Notification.install_host(),
        "sent_at" => DateTime.to_iso8601(DateTime.utc_now())
      })
    end
  rescue
    error ->
      Logger.warning(
        "[Ringing] delivery raised — ring=#{ring.id} meeting=#{meeting.id}: " <>
          Exception.message(error)
      )

      :error
  end

  # Active in ANY live room: an un-left `meeting_participants` row in a room
  # whose status is `active`.
  defp busy?(user_id) do
    Repo.exists?(
      from(p in Participant,
        join: r in Room,
        on: r.id == p.room_id,
        where: p.user_id == ^user_id and is_nil(p.left_at) and r.status == "active"
      )
    )
  end

  # live_invite                       -> "{Inviter} in {Meeting name}"
  # meeting_started, scheduled        -> "{Meeting name} meeting"
  # meeting_started, unscheduled      -> "{Host} in {Meeting name}"
  defp caller_name(%Meeting{} = meeting, %Ring{trigger: "live_invite"} = ring),
    do: "#{user_name(ring.inviter_user_id) || "Someone"} in #{meeting.name}"

  defp caller_name(%Meeting{scheduled_start_at: %DateTime{}} = meeting, _ring),
    do: "#{meeting.name} meeting"

  defp caller_name(%Meeting{} = meeting, _ring),
    do: "#{host_name(meeting) || "Someone"} in #{meeting.name}"

  defp host_name(%Meeting{} = meeting) do
    user_name(Meetings.host_user_id(meeting)) || user_name(meeting.started_by_user_id)
  end

  defp user_name(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) and email != "" -> email
      _ -> nil
    end
  end

  defp user_name(_), do: nil

  # ── The ring's life after the push ───────────────────────────────────────

  @doc """
  The ring `ring_id` if it belongs to `user_id`, else `{:error, :not_found}`
  (a malformed id and another user's ring included, so ring ids are not
  probeable).
  """
  @spec get_ring_for_user(binary(), term()) :: {:ok, Ring.t()} | {:error, :not_found}
  def get_ring_for_user(user_id, ring_id) when is_binary(user_id) do
    with true <- Platform.UUID.valid?(ring_id),
         %Ring{} = ring <-
           Repo.one(from(r in Ring, where: r.id == ^ring_id and r.user_id == ^user_id)) do
      {:ok, Repo.preload(ring, :meeting)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The state the app should act on: the stored state, except that a ring
  whose meeting is no longer live, or that is still `ringing` after
  #{@ring_window_seconds} s, reads as `"over"`.
  """
  @spec effective_state(Ring.t(), DateTime.t()) :: String.t()
  def effective_state(%Ring{} = ring, now \\ DateTime.utc_now()) do
    ring = Repo.preload(ring, :meeting)

    cond do
      ring.meeting.status != "live" ->
        "over"

      ring.state == "ringing" and
          DateTime.diff(now, ring.inserted_at, :second) > @ring_window_seconds ->
        "over"

      true ->
        ring.state
    end
  end

  @doc "Mark the ring answered. CAS on `state = 'ringing'`."
  @spec answer(Ring.t()) :: {:ok, Ring.t()} | {:error, :not_ringing}
  def answer(%Ring{} = ring), do: transition(ring, "answered", :answered_at)

  @doc """
  Mark the ring declined (CAS on `state = 'ringing'`), report it to the
  inviter on the meeting topic, and leave the callee an alert to join later.
  """
  @spec decline(Ring.t()) :: {:ok, Ring.t()} | {:error, :not_ringing}
  def decline(%Ring{} = ring) do
    with {:ok, ring} <- transition(ring, "declined", :declined_at) do
      report(ring, :ring_declined)
      {:ok, ring}
    end
  end

  @doc "Mark the ring missed. Same reporting as `decline/1`."
  @spec missed(Ring.t()) :: {:ok, Ring.t()} | {:error, :not_ringing}
  def missed(%Ring{} = ring) do
    with {:ok, ring} <- transition(ring, "missed", :missed_at) do
      report(ring, :ring_missed)
      {:ok, ring}
    end
  end

  defp transition(%Ring{id: id}, to, stamp_field) do
    now = DateTime.utc_now()

    from(r in Ring, where: r.id == ^id and r.state == "ringing", select: r)
    |> Repo.update_all(set: [{:state, to}, {stamp_field, now}, {:updated_at, now}])
    |> case do
      {1, [updated]} -> {:ok, Repo.preload(updated, :meeting)}
      {0, _} -> {:error, :not_ringing}
    end
  end

  defp report(%Ring{} = ring, event) do
    meeting = Repo.preload(ring, :meeting).meeting
    display_name = user_name(ring.user_id) || "Someone"

    Phoenix.PubSub.broadcast(
      Platform.PubSub,
      MeetingsPubSub.meeting_topic(meeting.id),
      {event,
       %{
         ring_id: ring.id,
         meeting_id: meeting.id,
         user_id: ring.user_id,
         display_name: display_name,
         inviter_user_id: ring.inviter_user_id
       }}
    )

    notify_callee(meeting, ring)
  end

  # "Missed call in {Meeting name}" /
  # "{Person} invited you at {time}. The meeting is still going. Tap to join."
  defp notify_callee(%Meeting{} = meeting, %Ring{} = ring) do
    meeting = Meetings.get_meeting(meeting.id) || meeting
    person = user_name(ring.inviter_user_id) || "Someone"
    at = Calendar.strftime(ring.inserted_at, "%-I:%M %p UTC")

    tail =
      if meeting.status == "live",
        do: "The meeting is still going. Tap to join.",
        else: "The meeting has ended."

    notifications_module().fan_out_to_user(
      ring.user_id,
      Notification.new(%{
        kind: "meeting_ring_missed",
        title: "Missed call in #{meeting.name}",
        body: "#{person} invited you at #{at}. #{tail}",
        url: "/meetings/#{meeting.slug}",
        meeting_id: meeting.id,
        space_id: meeting.chat_space_id,
        ring_id: ring.id,
        collapse_id: ring.id
      })
    )
  end

  defp voip_module, do: Application.get_env(:platform, :voip_push_module, Platform.Push.APNs)

  defp notifications_module,
    do: Application.get_env(:platform, :notifications_module, Platform.Notifications)
end
