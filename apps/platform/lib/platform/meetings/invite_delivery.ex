defmodule Platform.Meetings.InviteDelivery do
  @moduledoc """
  Routes one `Platform.Meetings.Invite` to the surface its invitee can
  actually reach, and records which surface that was.

  Task `019fb955-6577-7fb0-8c97-c70d233bba23`. `019fb954-3ac2` made
  "invited" a declaration; this module makes it a *send*.

  ## Why routing is a module and not an `if`

  The three invite kinds have three disjoint reachable surfaces, and the
  failure mode of getting it wrong is silent in every direction:

    * a **guest** has no account, so an inbox row, a web push and a chat
      message are all addressed at a user id that does not exist;
    * an **external user** has an account but no read access to an internal
      space — an inbox row they cannot open and a push that deep-links them
      into a 403 is a notification that looks BROKEN rather than absent,
      which is strictly worse;
    * an **internal user** is the only audience for whom the inbox and push
      surfaces both resolve.

  `deliver/2` answers `{:ok, carrier}` naming which one ran, so the
  question "what did this person actually get" has an answer that does not
  require reading three tables and guessing.

  ## Order of operations

  1. `Platform.Meetings.Config.enabled?/0` false → `{:ok, :disabled}`
     immediately. No row write, no inbox row, no push, no message, and
     nothing raised. The flag is fail-closed and its "off" state is
     *silence*, not an error the caller has to handle.
  2. Compare-and-swap `delivered_at` BEFORE any downstream work, mirroring
     `Platform.Meetings.mark_notified/1`: a nil-guarded `update_all` where
     `count == 1` claims the send and `count == 0` answers
     `{:ok, :already_delivered}`. This is load-bearing.
     `Meetings.invite_user/3` is idempotent on the partial
     `unique_index(:meeting_invites, [:meeting_id, :user_id])` and returns
     the EXISTING row on a re-invite, so without the CAS a host who
     double-submits fires a second inbox row and a second push at the same
     person.
  3. Route on AUDIENCE — `Invite.kind/1`, then org membership.
  4. Stamp `delivery_carrier` with the carrier that actually ran.

  ## Guests get a link, and there is no email path to build

  A guest's channel is the per-invite URL `Meetings.invite_guest/2` already
  minted and returned to the host; the carrier is `:guest_link`. There is
  **no outbound email capability in this repository** — verified: no
  swoosh, bamboo, gen_smtp or mail dependency in `mix.lock`, no `Mailer`
  module, no SMTP configuration. Recording the carrier and emitting
  telemetry is therefore the honest outcome, and inventing a mail path here
  would be a much larger change wearing this task's name. Do not add one.

  ## The external carrier is a chat message, and the audience picked it

  `PlatformWeb.Plugs.ExternalUserScope.gate_external/2` allowlists exactly
  `[]`, `["chat"]` and `["chat", slug]`; every other path falls through to
  a uniform 403. `/inbox` is not on that list, so an external user's inbox
  row is written and **unreachable**. Push is OS-level and would still
  fire, deep-linking them into that 403 — a notification that looks BROKEN
  rather than absent, which is strictly worse than silence. Chat is the
  only surface they have, so the audience determines the carrier and this
  branch writes NEITHER an inbox row NOR a push.

  ### Not a DM

  `Chat.find_or_create_dm/4` gates on `external_dm_permitted?/3`, which
  returns FALSE unconditionally when the initiator is external and the
  target is an agent. Our sender IS an agent. In the other direction, a
  platform agent opening a DM with an external user is itself a
  DM-creation event and can fail closed for exactly the audience this
  feature serves. `find_or_create_dm/4` is not called anywhere in this
  module, and must not be.

  The `kind: "guest_meeting"` space `Meetings.delivery_space_for_invite/2`
  resolves is what makes posting work at all: `post_message/2`'s
  `ensure_dm_send_allowed/2` guard engages only for `kind in ["dm",
  "group"]` with a `participant_type: "user"` author, so an agent author
  in a guest space falls through to `:ok`.

  ### The URL is the space UUID, never the slug

  `ExternalUserScope.resolve_space/2` resolves `/chat/:slug` via
  `Chat.get_space_by_slug(slug, org_id: <the EXTERNAL user's own org>)`,
  but `create_guest_chat_space/2` stamps `org_id` from the MEETING's
  project org. For an external invitee those differ by definition, so the
  slug lookup returns nil and only the `valid_uuid?(slug) &&
  Chat.get_space(slug)` fallback admits them. A slug-shaped link is a
  403 for the one person it was addressed to.

  ### The message is a deterministic template, not agent-authored prose

  It is rendered from the meeting name, the host display name and the
  space URL. No runtime is started, no model is called, and
  `Platform.Roles.assignee_for/1` / `Roles.agent_id_for_role/1` are
  consulted NOWHERE in this module. The seeded `Platform.Meetings.SenderSeed`
  agent is an authorship identity and nothing more — `chat_messages`
  points at a participant row and there is no `system` participant type,
  so "the platform sent this" needs an agent to be sent as. That is the
  whole reason an invite cannot fail for want of a `meeting_producer`.

  ## A branch that sends nothing RELEASES its claim

  If the external branch cannot deliver — the recorded delivery space was
  deleted, the space is archived, the participant insert fails — the claim
  taken in step 2 is released (`delivered_at` back to NULL) and the error
  is returned. A row that carried nothing must not read as delivered, and
  releasing re-opens no duplicate window: the duplicate the CAS exists to
  prevent is a duplicate *send*, and on that path there was no send.

  ## The internal carrier makes TWO calls, deliberately, every time

  `Platform.Inbox.emit/1` inserts one durable row and broadcasts on the
  user's inbox topic. **It does not push** — that is the documented gap
  from task `019f9251`. `Platform.Notifications` owns the VAPID fan-out
  above `Platform.Push`. So the inbox row and the push are two independent
  surfaces and reaching one is not reaching the other;
  `Platform.Meetings.MeetingNotifier` already does both halves for
  `meeting_starting` and this mirrors it.

  `fan_out_to_user/2` is the correct entry point, not `fan_out_to_humans/3`:
  the latter takes chat-participant ROW ids and so structurally cannot
  address an invitee who is not in the meeting's chat space — which is
  precisely who the invite table exists to reach.

  The inbox emit is wrapped in a `rescue` that logs and continues. The push
  runs whether or not the emit succeeded: one surface failing must never
  suppress the other, because the two exist to cover each other.

  ## Test seams

  Both collaborators resolve at runtime via `Application.get_env/3`, the
  same seam `MeetingNotifier` uses. This is not optional here:
  `Notifications.fan_out_to_user/2` short-circuits ENTIRELY when
  `Application.get_env(:platform, :env) == :test`, so a test that tries to
  observe a real push observes nothing and would pass against code that
  never pushes at all. The push assertion has to go through a recorder.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat
  alias Platform.Meetings
  alias Platform.Meetings.Config
  alias Platform.Meetings.Invite
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.SenderSeed
  alias Platform.Repo

  require Logger

  @type carrier ::
          :disabled
          | :already_delivered
          | :guest_link
          | :internal_inbox_push
          | :external_chat

  @doc """
  Deliver `invite` for `meeting`, returning the carrier that ran.

    * `{:ok, :disabled}` — the meetings flag is off. Nothing happened at
      all, including no row write.
    * `{:ok, :already_delivered}` — somebody else won the `delivered_at`
      compare-and-swap. The caller must not send anything.
    * `{:ok, :guest_link}` — guest invite; their channel is the signed URL
      `Meetings.invite_guest/2` returned.
    * `{:ok, :internal_inbox_push}` — internal user; an inbox row AND a
      user-keyed web push both went out.
    * `{:ok, :external_chat}` — external user; a message was posted into
      the invite's delivery space, which they are a participant of. No
      inbox row and no push, deliberately.
    * `{:error, reason}` — the external carrier could not deliver. The
      claim is released, so a later call can try again.

  Never raises for an expected condition, and never turns a committed
  invite row into a caller-visible failure — see
  `Platform.Meetings.invite_user/3`'s wiring.
  """
  @spec deliver(Invite.t(), Meeting.t()) :: {:ok, carrier()} | {:error, term()}
  def deliver(%Invite{} = invite, %Meeting{} = meeting) do
    if Config.enabled?() do
      case claim(invite) do
        :claimed -> route(invite, meeting)
        :already_delivered -> {:ok, :already_delivered}
      end
    else
      {:ok, :disabled}
    end
  end

  # ── The claim ─────────────────────────────────────────────────────────────

  # Atomic compare-and-swap on `delivered_at`, byte-for-byte the shape of
  # `Meetings.mark_notified/1`. The database guarantees at most one caller's
  # UPDATE affects the row, so concurrent callers race the SQL rather than a
  # lock: exactly one sees `{1, _}` and the rest see `{0, _}`.
  #
  # The struct-level `delivered_at: nil` head is an optimisation, not the
  # guarantee — a re-invite hands us a row loaded from the database with the
  # stamp already on it and short-circuits here, while a genuinely concurrent
  # pair both pass the head and are separated by the WHERE clause.
  defp claim(%Invite{delivered_at: nil} = invite) do
    now = DateTime.utc_now()

    {count, _} =
      from(i in Invite,
        where: i.id == ^invite.id and is_nil(i.delivered_at),
        update: [set: [delivered_at: ^now]]
      )
      |> Repo.update_all([])

    case count do
      1 -> :claimed
      0 -> :already_delivered
    end
  end

  defp claim(%Invite{}), do: :already_delivered

  # Give the claim back. Only the external branch uses this, and only
  # because it sent nothing — see the moduledoc.
  defp release(%Invite{} = invite) do
    from(i in Invite, where: i.id == ^invite.id)
    |> Repo.update_all(set: [delivered_at: nil])

    :ok
  end

  # ── Routing ───────────────────────────────────────────────────────────────

  defp route(%Invite{} = invite, %Meeting{} = meeting) do
    case Invite.kind(invite) do
      :guest -> deliver_guest(invite, meeting)
      :user -> deliver_user(invite, meeting)
    end
  end

  defp deliver_guest(%Invite{} = invite, %Meeting{} = meeting) do
    stamp_carrier(invite, :guest_link)
    emit_telemetry(invite, meeting, :guest_link)
    {:ok, :guest_link}
  end

  defp deliver_user(%Invite{} = invite, %Meeting{} = meeting) do
    if Platform.Tenancy.external_user?(%{id: invite.user_id}) do
      deliver_external(invite, meeting)
    else
      deliver_internal(invite, meeting)
    end
  end

  # ── The external carrier: a chat message, and ONLY a chat message ────────

  defp deliver_external(%Invite{} = invite, %Meeting{} = meeting) do
    with {:ok, space} <- Meetings.delivery_space_for_invite(invite, meeting),
         {:ok, author_participant_id} <- sender_participant_id(space),
         {:ok, _message} <-
           Chat.post_message(%{
             space_id: space.id,
             # The agent's PARTICIPANT ROW id, not the agent id.
             # `chat_messages.participant_id` points at `chat_participants`.
             participant_id: author_participant_id,
             content_type: "text",
             content: external_message(meeting, space)
           }) do
      stamp_delivery(invite, :external_chat, space.id)
      emit_telemetry(invite, meeting, :external_chat)

      {:ok, :external_chat}
    else
      {:error, reason} ->
        # Nothing carried this invite, so it must not read as delivered.
        release(invite)

        Logger.warning(
          "[InviteDelivery] external chat carrier failed — invite=#{invite.id} " <>
            "meeting=#{meeting.id}: #{inspect(reason)}. NOT falling through to " <>
            "the internal carrier: an inbox row they cannot open plus a push " <>
            "into a 403 is worse than silence."
        )

        {:error, reason}
    end
  end

  # The space function has already ensured this row exists; this is a strict
  # read of it, so nothing here can insert a duplicate participant.
  defp sender_participant_id(space) do
    with %Platform.Agents.Agent{} = agent <- SenderSeed.get(),
         %Platform.Chat.Participant{id: id} <- Chat.get_agent_participant(space.id, agent) do
      {:ok, id}
    else
      _ -> {:error, :sender_not_seeded}
    end
  end

  # Deterministic template. Meeting name, host display name, space URL —
  # rendered here, in this call stack, with no model and no role lookup.
  #
  # `/chat/<space.id>`, NEVER `/chat/<space.slug>`: the slug branch of
  # `ExternalUserScope.resolve_space/2` scopes to the EXTERNAL user's own
  # org while the space carries the MEETING's project org, so a slug link
  # is a 403 for its own addressee. See the moduledoc.
  defp external_message(%Meeting{} = meeting, space) do
    host = host_display_name(meeting)

    """
    #{host} invited you to "#{meeting.name}".

    This space is where that invite reaches you: /chat/#{space.id}
    """
  end

  # ── The internal carrier: inbox row AND push, both, every time ───────────

  defp deliver_internal(%Invite{} = invite, %Meeting{} = meeting) do
    host = host_display_name(meeting)

    title = "Meeting invite: #{meeting.name}"
    body = "From #{host}"

    # `meeting.slug`, NOT `meeting.id`. The router declares
    # `live("/meetings/:slug", MeetingLive, :show)`. `MeetingNotifier` is
    # inconsistent about this between its push payload and its inbox url —
    # do not copy the wrong half.
    url = "/meetings/#{meeting.slug}"

    emit_inbox_row(invite, meeting, title, body, url)

    # Unconditional: the push must run whether or not the emit above
    # succeeded. `fan_out_to_user/2` and not `fan_out_to_humans/3` — the
    # latter takes chat-participant row ids and cannot reach an invitee who
    # is not in this meeting's chat space.
    notifications_module().fan_out_to_user(invite.user_id, %{
      title: title,
      body: body,
      url: url
    })

    stamp_carrier(invite, :internal_inbox_push)
    emit_telemetry(invite, meeting, :internal_inbox_push)

    {:ok, :internal_inbox_push}
  end

  defp emit_inbox_row(%Invite{} = invite, %Meeting{} = meeting, title, body, url) do
    inbox_module().emit(%{
      user_id: invite.user_id,
      kind: "meeting_invited",
      source_type: "meeting",
      source_id: meeting.id,
      title: title,
      body: body,
      url: url
    })
  rescue
    error ->
      Logger.warning(
        "[InviteDelivery] inbox emit failed — invite=#{invite.id} " <>
          "meeting=#{meeting.id}: #{inspect(error)}"
      )

      :error
  end

  # ── Receipt + telemetry ───────────────────────────────────────────────────

  defp stamp_carrier(%Invite{} = invite, carrier) when is_atom(carrier) do
    from(i in Invite, where: i.id == ^invite.id)
    |> Repo.update_all(set: [delivery_carrier: Atom.to_string(carrier)])

    :ok
  end

  # The external carrier's receipt names the SPACE as well as the carrier.
  # `delivery_space_for_invite/2` already persisted the id when it minted the
  # space; writing it here too makes the receipt land in one statement on the
  # reuse path as well, so "which space did this go to" is answered by the
  # invite row regardless of which branch resolved it.
  defp stamp_delivery(%Invite{} = invite, carrier, space_id) when is_atom(carrier) do
    from(i in Invite, where: i.id == ^invite.id)
    |> Repo.update_all(
      set: [delivery_carrier: Atom.to_string(carrier), delivery_space_id: space_id]
    )

    :ok
  end

  # Guarded like every other :telemetry.execute in this subsystem so a
  # broken listener cannot tap the delivery path.
  defp emit_telemetry(%Invite{} = invite, %Meeting{} = meeting, carrier) do
    :telemetry.execute(
      [:platform, :meetings, :invite_delivered],
      %{count: 1},
      %{
        invite_id: invite.id,
        meeting_id: meeting.id,
        kind: Invite.kind(invite),
        carrier: carrier
      }
    )
  rescue
    _ -> :ok
  end

  # ── Internal ──────────────────────────────────────────────────────────────

  defp host_display_name(%Meeting{} = meeting) do
    case Repo.preload(meeting, :host_participant).host_participant do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> "Someone"
    end
  end

  defp notifications_module do
    Application.get_env(:platform, :notifications_module, Platform.Notifications)
  end

  defp inbox_module do
    Application.get_env(:platform, :inbox_module, Platform.Inbox)
  end
end
