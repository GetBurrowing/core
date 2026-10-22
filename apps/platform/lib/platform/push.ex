defmodule Platform.Push do
  @moduledoc """
  Web Push notification context.

  Manages push subscriptions and sends notifications via the Web Push protocol
  and, for users with the native apps, via APNs (`Platform.Push.APNs`, iOS)
  and FCM (`Platform.Push.FCM`, Android).

  ## One notification model, three transports (tasks 01a10882, 01a10d8e)

  `send_to_user/2` and `send_notification/2` accept a legacy
  `%{title, body, url}` map or a `%Platform.Push.Notification{}`. Either way
  they normalise to the struct ONCE, run the archived-user check and the
  external redaction ONCE on it, and only then split: web push encodes
  `Notification.to_web_payload/1`, APNs encodes `Notification.to_apns_payload/1`,
  FCM encodes `Notification.to_fcm_payload/1`. Redaction never runs per
  transport, so they cannot disagree about what a notification says. Only
  USER recipients get APNs or FCM; agent rows have no app.

  ## The notification-level gate (task 01a1557a-e538 stage 1)

  Right after the archived-user check, and BEFORE any subscription read,
  both send functions read the USER recipient's
  `Platform.Accounts.notification_level/1` and ask `permitted?/2`. At
  `"direct"` only a `chat_mention` is sent; everything else returns `:ok`
  having delivered nothing. Each decision emits
  `[:platform, :push, :notification_level]` (`decision: :sent | :suppressed`)
  and a debug log line that names the user, kind, level and decision, never
  the title or body. Agent recipients are never level-gated. The VoIP ring
  does not pass through here and is not gated: a call still rings.

  ## The VAPID resolution invariant

  `vapid_details/0` is the SINGLE source of truth for VAPID credentials, and it
  is all-or-nothing: it returns a complete keyword list or `nil`, never a half.
  Both surfaces that care about VAPID read it — the subscribe surface via
  `vapid_public_key/0` (rendered into the `vapid-public-key` meta tag in
  `root.html.heex`, which `assets/js/hooks/push_subscribe.js` refuses to
  subscribe without) and the send surface via `do_send_push/2`. Therefore:

  > **It is impossible for the subscribe surface to report configured while the
  > send surface reports unconfigured.** They read the same all-or-nothing
  > resolver, so they cannot disagree.

  A future reader can check that invariant by confirming two things: that
  `vapid_details/0` returns `nil` unless BOTH halves resolve, and that no other
  function reads `Application.get_env(:web_push_encryption, :vapid_details)`
  directly. Reintroducing that direct read in the send path is exactly how the
  surfaces drifted apart before (task 01a0108a): `vapid_public_key/0` resolved
  env-then-Vault, while the send path and the configuration probe read only the
  app env that `config/runtime.exs` populates from env vars alone. A host whose
  keys lived in Vault therefore advertised a public key, accepted browser
  subscriptions, and silently delivered nothing.

  Per key, resolution order is: the `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` env
  var, then the matching entry of `Application.get_env(:web_push_encryption,
  :vapid_details)` (an explicit override, and what `runtime.exs` sets), then a
  Vault lookup by slug `"vapid-public-key"` / `"vapid-private-key"`.

  ### Two alternatives that were rejected

  * **Populate `:vapid_details` from Vault at boot.** Cannot work: the section
    of `config/runtime.exs` that would do it evaluates before the Repo starts
    and before Vault decryption is available, so a Vault-held key is simply not
    readable at that point. Vault resolution has to happen at call time.
  * **Make only the subscribe path refuse on a half configuration.** That stops
    the false advertisement but leaves the send path unable to use a Vault-held
    key it legitimately has — it fixes the symptom by making the working half
    stop working, rather than making the two halves agree.
  """

  import Ecto.Query

  require Logger

  alias Platform.Accounts.User
  alias Platform.Chat.Participant
  alias Platform.Push.APNs
  alias Platform.Push.FCM
  alias Platform.Push.Notification
  alias Platform.Push.Relay
  alias Platform.Push.Subscription
  alias Platform.Repo
  alias Platform.Tenancy

  # External-safe preview copy (M13). An external user's push transits an
  # untrusted third-party push service (FCM/APNs/Mozilla autopush), so the
  # internal sender name / message content / channel or meeting name must be
  # redacted server-side. All three strings live here so the safe copy has a
  # single source of truth.
  @external_safe_title "New message"
  @external_safe_body "You have a new message"
  @external_safe_url "/chat"

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Upsert a push subscription for a participant."
  @spec subscribe(binary(), map()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(participant_id, %{endpoint: endpoint, keys: %{p256dh: p256dh, auth: auth}}) do
    attrs = %{
      participant_id: participant_id,
      endpoint: endpoint,
      p256dh: p256dh,
      auth: auth
    }

    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh, :auth]},
      conflict_target: [:participant_id, :endpoint]
    )
  end

  @doc """
  Upsert a push subscription for a USER, off any surface that has no
  participant row to hand.

  `subscribe/2` keys a subscription to a `chat_participants.id`, which is
  per-space. `:current_participant` is assigned by `ChatLive` and `MeetingLive`
  and by nothing else, so a device registered from `/inbox`, `/tasks` or any
  other route had nothing to key to and was dropped: the user was told
  notifications were on, and no row existed (task 019ffe52).

  Nothing in the schema forces that. `distinct_endpoint_subscriptions/1`
  resolves a user's devices across ALL of that user's user-typed participant
  rows, so a subscription filed against any ONE of them is reachable from every
  conversation. This picks such a row and delegates to `subscribe/2`.

  Returns `{:error, :no_participant}` for a user who is in no space at all, and
  for a `user_id` that is not a UUID. There is genuinely nowhere to file the
  device, and the caller has to be able to tell that apart from success.
  """
  @spec subscribe_for_user(binary(), map()) ::
          {:ok, Subscription.t()} | {:error, :no_participant | Ecto.Changeset.t()}
  def subscribe_for_user(user_id, %{endpoint: _, keys: %{p256dh: _, auth: _}} = attrs)
      when is_binary(user_id) do
    case anchor_participant_id(user_id) do
      nil -> {:error, :no_participant}
      participant_id -> subscribe(participant_id, attrs)
    end
  end

  # The user-typed `chat_participants` row a user-level subscription is filed
  # against: the user's earliest membership, ties broken by id.
  #
  # Deterministic on purpose. A bare `Repo.one/1` on an unordered query may
  # return a different row per call, and every distinct row it lands on writes
  # ANOTHER `push_subscriptions` row for the same physical device. Endpoint
  # dedup hides that at delivery time, so the duplication would accumulate
  # silently with nothing to prune it.
  #
  # `chat_participants` carries no `inserted_at`. `joined_at` is the membership
  # creation time, and `id` is a UUIDv7 and therefore time-ordered, which makes
  # it a stable tiebreak for two rows sharing a `joined_at`.
  #
  # `Platform.UUID.valid?/1` guards the query because
  # `chat_participants.participant_id` is a `:binary_id` and
  # `where: p.participant_id == ^user_id` raises the same `Ecto.Query.CastError`
  # as `Repo.get/2` on a malformed binary. `subscribe_for_user/2` is public and
  # takes the id as an argument instead of reading it off a loaded row, so the
  # guard belongs here rather than at one call site. Nil for the same reason
  # `Accounts.get_user/1` returns nil on the same check: an id that cannot be a
  # UUID resolves no row.
  @spec anchor_participant_id(binary()) :: binary() | nil
  defp anchor_participant_id(user_id) do
    if Platform.UUID.valid?(user_id) do
      from(p in Participant,
        where: p.participant_type == "user" and p.participant_id == ^user_id,
        order_by: [asc: p.joined_at, asc: p.id],
        limit: 1,
        select: p.id
      )
      |> Repo.one()
    end
  end

  @doc "Remove a push subscription by participant and endpoint."
  @spec unsubscribe(binary(), String.t()) :: {non_neg_integer(), nil}
  def unsubscribe(participant_id, endpoint) do
    from(s in Subscription,
      where: s.participant_id == ^participant_id and s.endpoint == ^endpoint
    )
    |> Repo.delete_all()
  end

  @doc """
  Forget one browser endpoint for a USER: delete its subscription rows across
  every user-typed `chat_participants` row that user holds (the same join
  `distinct_endpoint_subscriptions/1` resolves devices through). Returns the
  number of rows deleted.

  Settings' "Push on this device" switch calls this when the person turns push
  off (task 01a1557a-e538 stage 4). Only that user's rows go: another user's
  row with the same endpoint (a shared browser) is never touched, because the
  participant join is filtered on this user id.
  """
  @spec unsubscribe_for_user(binary(), String.t()) :: non_neg_integer()
  def unsubscribe_for_user(user_id, endpoint) when is_binary(user_id) and is_binary(endpoint) do
    if Platform.UUID.valid?(user_id) do
      participant_ids =
        from(p in Participant,
          where: p.participant_type == "user" and p.participant_id == ^user_id,
          select: p.id
        )

      {count, _} =
        from(s in Subscription,
          where: s.endpoint == ^endpoint and s.participant_id in subquery(participant_ids)
        )
        |> Repo.delete_all()

      count
    else
      0
    end
  end

  def unsubscribe_for_user(_user_id, _endpoint), do: 0

  @doc """
  Send a web push notification addressed to one `chat_participants` row.

  Addressing stays per-participant (the archived guard and the external
  redaction both key on `participant_id`), while device resolution goes through
  `subscriptions_for_recipient/1`: a user-typed recipient reaches every device
  that user owns, once per distinct endpoint, whichever conversation the device
  was registered in (task 019ffd19). Agent-typed and unknown recipients keep
  the per-membership device set.
  """
  @spec send_notification(binary(), Notification.t() | map()) :: :ok
  def send_notification(participant_id, %{title: _, body: _} = payload) do
    notification = Notification.from_map(payload)

    if archived_user_participant?(participant_id) do
      # Defense-in-depth (task 019f671f Stage 4). `AttentionRouter.route/1`
      # (Stage 3) is the primary chokepoint that keeps `maybe_send_push/3`
      # from firing for archived users, but any future caller — direct push,
      # meeting notifier, batch digest — inherits this guard automatically.
      :telemetry.execute(
        [:platform, :push, :suppressed_archived_user],
        %{count: 1},
        %{participant_id: participant_id}
      )

      :ok
    else
      # Resolved BEFORE any subscription read so the notification-level gate
      # decides with no device registered. `nil` for an agent row (or an id
      # with no `chat_participants` row): agents are never level-gated.
      user_id = apns_user_id(participant_id)

      if is_nil(user_id) or level_permits?(user_id, notification) do
        deliver_to_participant(participant_id, user_id, notification)
      end

      :ok
    end
  end

  defp deliver_to_participant(participant_id, user_id, %Notification{} = notification) do
    subscriptions = subscriptions_for_recipient(participant_id)

    # Redact the notification for external recipients before it leaves the
    # box, ONCE, before the transport split: web push and APNs serialise the
    # same redacted struct. The archived guard above still wins — an
    # archived external user is suppressed entirely and never reaches this
    # swap.
    notification = preview_for_recipient(participant_id, notification)

    send_web_push(subscriptions, notification)

    # Native push only for a USER-typed recipient. An agent row's
    # `participant_id` is an agent id and has no app devices, and no
    # unread count is read for it.
    if user_id do
      notification = stamp_unread(notification, user_id)
      deliver_apns(user_id, notification)
      deliver_fcm(user_id, notification)
    end

    :ok
  end

  @doc """
  Whether a person at notification `level` (`Platform.Accounts.notification_level/1`)
  may be interrupted by `notification`. Pure.

  `"direct"` permits only `kind == "chat_mention"`. `"all"` and `"mentions"`
  permit every kind: the "all" widening happens upstream, in
  `Platform.Chat.AttentionRouter`, which decides who gets a chat decision at
  all. Any other level reads as the default and permits every kind.

  Only alert pushes pass through here. The VoIP ring
  (`Platform.Push.APNs.deliver_voip_to_user/2`) is a call, not an alert, and
  is never level-gated; Inbox rows are written regardless.
  """
  @spec permitted?(String.t() | nil, Notification.t()) :: boolean()
  def permitted?("direct", %Notification{kind: kind}), do: kind == "chat_mention"
  def permitted?(_level, %Notification{}), do: true

  # The notification-level gate for one USER recipient. Emits
  # `[:platform, :push, :notification_level]` on both branches and a debug
  # line naming the decision; never the title or body.
  defp level_permits?(user_id, %Notification{kind: kind} = notification) do
    level = Platform.Accounts.notification_level(user_id)
    decision = if permitted?(level, notification), do: :sent, else: :suppressed

    :telemetry.execute(
      [:platform, :push, :notification_level],
      %{count: 1},
      %{user_id: user_id, kind: kind, level: level, decision: decision}
    )

    Logger.debug(
      "[Push] notification_level user_id=#{user_id} kind=#{kind} level=#{level} decision=#{decision}"
    )

    decision == :sent
  end

  defp send_web_push([], _notification), do: :ok

  defp send_web_push(subscriptions, %Notification{} = notification) do
    json = Jason.encode!(Notification.to_web_payload(notification))

    Enum.each(subscriptions, fn sub ->
      case do_send_push(sub, json) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Push] failed to send to subscription #{sub.id}: #{inspect(reason)}")
      end
    end)
  end

  # Task 01a1261e: stamp the recipient's chat unread total on this install,
  # and when it was read, onto the native-push copy, so the app can keep one
  # count per install and sum the icon badge. USER recipients only (both
  # callers reach this only with a user id), after redaction, before the
  # native transport split; web push never carries it (`to_web_payload/1`
  # has no such key).
  #
  # The number is `Platform.Chat.total_unread_for_viewer/1`, the codebase's
  # single definition of the Chat unread total (the rail badge and the
  # per-channel pills); never a second counting query. It accepts any map
  # with a binary `:id`, so no `users` read is spent loading a struct.
  #
  # A count error must never cost the push: it is rescued to nil, which the
  # serialisers drop, and the notification goes out without a count.
  # `config :platform, Platform.Push, unread_counter: {mod, fun}` is a test
  # seam for that failure; production leaves it unset.
  defp stamp_unread(%Notification{} = notification, user_id) when is_binary(user_id) do
    {mod, fun} =
      Application.get_env(:platform, __MODULE__, [])
      |> Keyword.get(:unread_counter, {Platform.Chat, :total_unread_for_viewer})

    # Read the clock BEFORE the count: the count reflects at least every read
    # up to `as_of`, so a device comparing `unread_as_of` values (newer wins)
    # never lets this number overwrite a later reconcile.
    as_of = DateTime.utc_now()

    count =
      case apply(mod, fun, [%{id: user_id}]) do
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end

    %Notification{
      notification
      | unread_count: count,
        unread_as_of: if(count, do: as_of)
    }
  rescue
    e ->
      Logger.warning("[Push] unread count failed: #{inspect(e.__struct__)}")
      %Notification{notification | unread_count: nil, unread_as_of: nil}
  end

  # APNs is a second transport for the SAME notification. Its failure must
  # never take web push down with it, and it never logs the notification.
  #
  # Transport selection per platform (task 01a1261e stage 2): direct
  # credentials configured -> direct, exactly as before (installs holding
  # their own APNs key keep direct push untouched); else the push relay if
  # configured; else today's not-configured log. Direct is always tried
  # FIRST and the relay is consulted only when the user has devices and
  # direct is unconfigured, so a user with no devices still costs one query
  # and no configuration lookup.
  defp deliver_apns(user_id, %Notification{} = notification) do
    case APNs.deliver_to_user(user_id, notification, quiet_unconfigured: true) do
      {:error, :not_configured} -> via_relay(user_id, notification, :ios)
      _ -> :ok
    end

    :ok
  rescue
    e ->
      Logger.warning("[Push] APNs delivery raised: #{inspect(e.__struct__)}")
      :ok
  end

  # FCM is the Android twin of `deliver_apns/2`: the same redacted struct,
  # and its failure never takes web push or APNs down with it.
  defp deliver_fcm(user_id, %Notification{} = notification) do
    case FCM.deliver_to_user(user_id, notification, quiet_unconfigured: true) do
      {:error, :not_configured} -> via_relay(user_id, notification, :android)
      _ -> :ok
    end

    :ok
  rescue
    e ->
      Logger.warning("[Push] FCM delivery raised: #{inspect(e.__struct__)}")
      :ok
  end

  # The push relay for one platform, or the not-configured log when the
  # relay is absent too. A relay failure is rescued by the caller like any
  # other transport and never takes web push down.
  defp via_relay(user_id, %Notification{} = notification, platform) do
    if Relay.configured?() do
      Relay.deliver_to_user(user_id, notification, platform)
    else
      case platform do
        :ios -> APNs.log_unconfigured()
        :android -> FCM.report_unconfigured()
      end
    end
  end

  defp apns_user_id(participant_id) when is_binary(participant_id) do
    if Platform.UUID.valid?(participant_id) do
      case Repo.get(Participant, participant_id) do
        %Participant{participant_type: "user", participant_id: user_id} when is_binary(user_id) ->
          user_id

        _ ->
          nil
      end
    end
  end

  @doc """
  Resolve the set of devices a chat notification for a recipient should reach.

  Takes either a `%Participant{}` row (callers that already hold one skip the
  lookup) or a `chat_participants.id`.

  A USER-typed recipient resolves to every subscription across ALL of that
  user's user-typed participant rows, collapsed to one row per distinct
  `endpoint` via `distinct_endpoint_subscriptions/1` — the same query
  `send_to_user/2` uses. Turning notifications on registers a device under
  whichever conversation happened to be open at the time, so the old
  per-membership lookup found that device only for messages in that one
  conversation and delivered nothing everywhere else (task 019ffd19). The
  endpoint collapse is load-bearing: a user in N conversations owns N
  membership rows, and resolving them without it would send N copies to one
  device.

  Any other recipient — an AGENT-typed row, or an id with no
  `chat_participants` row — keeps the per-membership lookup. `participant_id`
  on an agent row holds an AGENT id, and `distinct_endpoint_subscriptions/1`
  filters `participant_type == "user"`, so an agent id must never be handed to
  the user-scoped query.

  Distinct from `list_subscriptions/1`, which is a literal "rows stored under
  this participant row" listing and stays per-participant by definition.

  Kept public (not private) so behavioural tests can assert the resolved device
  set directly, the same reason `preview_for_recipient/2` is public: the router
  short-circuits push under the test env and sends inside `Task.start`, so
  delivery itself is not observable from ExUnit.
  """
  @spec subscriptions_for_recipient(Participant.t() | binary()) :: [Subscription.t()]
  def subscriptions_for_recipient(%Participant{participant_type: "user", participant_id: user_id})
      when is_binary(user_id) do
    distinct_endpoint_subscriptions(user_id)
  end

  def subscriptions_for_recipient(%Participant{id: participant_id}) do
    participant_row_subscriptions(participant_id)
  end

  def subscriptions_for_recipient(participant_id) when is_binary(participant_id) do
    case Repo.get(Participant, participant_id) do
      %Participant{} = participant -> subscriptions_for_recipient(participant)
      _ -> participant_row_subscriptions(participant_id)
    end
  end

  @doc """
  Send a web push notification to a *user*, deduplicated by endpoint.

  A user has one `chat_participants` row per space they're in, and the same
  physical device (browser endpoint) is subscribed under each of those rows.
  `send_notification/2` keys on a single participant row, so a user-targeted
  producer that fanned out across every participant row would hit the SAME
  endpoint once per space — the duplicate-push storm (task 019f9251 follow-up:
  one sponsor assignment → hundreds of participant rows → the same ~15 devices
  pinged ~10× each).

  This resolves every subscription across all of the user's user-typed
  participant rows, collapses them to one row per distinct `endpoint`, and
  delivers exactly once per endpoint. Prefer this over `send_notification/2`
  for anything addressed to a *user* rather than a specific participant/space.

  Inherits `send_notification/2`'s guards, evaluated once at the user level
  (every resolved row belongs to `user_id`, so the decision is uniform):
  archived users are suppressed with the same telemetry, the notification
  level gate (`permitted?/2`) runs next, and external users get the redacted
  `external_safe_preview/1`. 410-expired subscriptions are pruned
  by `do_send_push/2` exactly as in the per-participant path.
  """
  @spec send_to_user(binary(), Notification.t() | map()) :: :ok
  def send_to_user(user_id, %{title: _, body: _} = payload) when is_binary(user_id) do
    notification = Notification.from_map(payload)

    if archived_user?(user_id) do
      :telemetry.execute(
        [:platform, :push, :suppressed_archived_user],
        %{count: 1},
        %{user_id: user_id}
      )

      :ok
    else
      if level_permits?(user_id, notification) do
        deliver_to_user(user_id, notification)
      end

      :ok
    end
  end

  defp deliver_to_user(user_id, %Notification{} = notification) do
    subscriptions = distinct_endpoint_subscriptions(user_id)

    # Redact once at the user level before the notification leaves the box
    # (all resolved rows belong to `user_id`, so external-ness is uniform),
    # and BEFORE the transport split: web push and APNs both serialise this
    # one redacted struct, so they cannot disagree about content.
    notification = preview_for_user(user_id, notification)

    send_web_push(subscriptions, notification)

    notification = stamp_unread(notification, user_id)
    deliver_apns(user_id, notification)
    deliver_fcm(user_id, notification)

    :ok
  end

  # One `push_subscriptions` row per distinct endpoint for `user_id`, resolved
  # across ALL of the user's user-typed participant rows. `DISTINCT ON
  # (endpoint)` ordered by `endpoint, inserted_at DESC` keeps the newest row for
  # each endpoint; p256dh/auth are per-endpoint, so any row for an endpoint
  # carries usable keys and newest is simply the most defensible pick.
  @spec distinct_endpoint_subscriptions(binary()) :: [Subscription.t()]
  defp distinct_endpoint_subscriptions(user_id) do
    from(s in Subscription,
      join: p in Participant,
      on: p.id == s.participant_id,
      where: p.participant_type == "user" and p.participant_id == ^user_id,
      distinct: s.endpoint,
      order_by: [asc: s.endpoint, desc: s.inserted_at]
    )
    |> Repo.all()
  end

  # Every `push_subscriptions` row stored under exactly ONE `chat_participants`
  # row. Backs both `list_subscriptions/1` (the literal listing) and the
  # non-user branch of `subscriptions_for_recipient/1`.
  @spec participant_row_subscriptions(binary()) :: [Subscription.t()]
  defp participant_row_subscriptions(participant_id) do
    from(s in Subscription, where: s.participant_id == ^participant_id)
    |> Repo.all()
  end

  # User-level twin of `archived_user_participant?/1`: suppress push to a user
  # whose `users` row carries a non-nil `archived_at`.
  @spec archived_user?(binary()) :: boolean()
  defp archived_user?(user_id) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      %User{archived_at: nil} -> false
      %User{archived_at: _} -> true
      _ -> false
    end
  end

  @doc """
  User-level twin of `preview_for_recipient/2`: external users get the redacted
  generic copy (same telemetry event, emitted once per user notification);
  internal users get the payload unchanged.

  Kept public for the same reason `preview_for_recipient/2` is: this is the
  redaction chokepoint on the user-scoped push path that `AttentionRouter` took
  up in task 019ffd19, and a security test has to be able to assert the
  resolved payload itself, not merely that the telemetry fired. Body unchanged
  from the private version it replaces.
  """
  @spec preview_for_user(binary(), map()) :: map()
  def preview_for_user(user_id, payload) do
    if Tenancy.external_user?(%{id: user_id}) do
      :telemetry.execute(
        [:platform, :push, :external_safe_preview],
        %{count: 1},
        %{user_id: user_id}
      )

      external_safe_preview(payload)
    else
      payload
    end
  end

  # Return true when `participant_id` resolves to a `chat_participants` row
  # whose `participant_type == "user"` AND the referenced `users` row exists
  # with a non-nil `archived_at`. Unknown participant rows and agent
  # participants pass through — the guard only suppresses the case the
  # archival contract cares about.
  @spec archived_user_participant?(binary()) :: boolean()
  defp archived_user_participant?(participant_id) when is_binary(participant_id) do
    case Repo.get(Participant, participant_id) do
      %Participant{participant_type: "user", participant_id: user_id}
      when is_binary(user_id) ->
        case Repo.get(User, user_id) do
          %User{archived_at: nil} -> false
          %User{archived_at: _} -> true
          _ -> false
        end

      _ ->
        false
    end
  end

  defp archived_user_participant?(_), do: false

  @doc """
  Resolve the notification payload for a specific recipient.

  If `participant_id` resolves to an EXTERNAL user, emit a
  `[:platform, :push, :external_safe_preview]` telemetry event and return the
  generic `external_safe_preview/1` (redacting sender name, message/meeting
  body, channel/meeting name, and the deep-link url). Otherwise return the
  payload unchanged.

  Kept public (not private) so callers and behavioral tests can assert the
  redaction deterministically without VAPID keys or a live push endpoint.
  """
  @spec preview_for_recipient(binary(), map()) :: map()
  def preview_for_recipient(participant_id, payload) do
    if external_user_participant?(participant_id) do
      :telemetry.execute(
        [:platform, :push, :external_safe_preview],
        %{count: 1},
        %{participant_id: participant_id}
      )

      external_safe_preview(payload)
    else
      payload
    end
  end

  @doc """
  Build the fixed generic preview shown to external recipients.

  Ignores every sensitive field of the incoming payload and returns the
  redacted copy. The url is rewritten to `/chat` because an internal
  `/meetings/<slug>` deep-link both leaks an internal slug and 403s for an
  external user.
  """
  @spec external_safe_preview(Notification.t() | map()) :: Notification.t() | map()
  def external_safe_preview(%Notification{} = notification) do
    Notification.redact(notification, external_safe_preview(%{}))
  end

  def external_safe_preview(_payload) do
    %{
      title: @external_safe_title,
      body: @external_safe_body,
      url: @external_safe_url
    }
  end

  # Return true when `participant_id` resolves to a `chat_participants` row
  # whose `participant_type == "user"` AND the referenced user is external
  # (holds at least one `external: true` org membership). Agent participants
  # and unknown rows return false — they pass through unchanged. Mirrors the
  # shape of `archived_user_participant?/1`.
  @spec external_user_participant?(binary()) :: boolean()
  defp external_user_participant?(participant_id) when is_binary(participant_id) do
    case Repo.get(Participant, participant_id) do
      %Participant{participant_type: "user", participant_id: user_id}
      when is_binary(user_id) ->
        Tenancy.external_user?(%{id: user_id})

      _ ->
        false
    end
  end

  defp external_user_participant?(_), do: false

  @doc "List all push subscriptions for a participant."
  @spec list_subscriptions(binary()) :: [Subscription.t()]
  def list_subscriptions(participant_id), do: participant_row_subscriptions(participant_id)

  @doc """
  Resolve the complete VAPID credential set, or `nil`.

  The single source of truth for every VAPID reader — see the module doc for the
  invariant this exists to enforce. Returns a keyword list carrying exactly
  `:subject`, `:public_key` and `:private_key` (the three keys
  `build_vapid_jwt/2` reads), or `nil` if EITHER half fails to resolve.

  The all-or-nothing return is the point: it makes agreement between the
  subscribe and send surfaces structural rather than a convention two callers
  have to remember. A half configuration is a misconfiguration, and answering
  `nil` to both surfaces is the loud behaviour — the meta tag renders empty and
  the browser hook declines to subscribe, instead of a client being told
  notifications are on while no send can succeed.

  Vault resolution happens at call time, not at boot, because `runtime.exs`
  evaluates before the Repo and Vault decryption exist. Callers on a per-send
  hot path should therefore resolve ONCE per batch and pass the result down
  rather than calling this per subscription.
  """
  @spec vapid_details() :: keyword() | nil
  def vapid_details do
    app_env = app_env_vapid()

    public_key = resolve_vapid_key("VAPID_PUBLIC_KEY", app_env[:public_key], "vapid-public-key")

    private_key =
      resolve_vapid_key("VAPID_PRIVATE_KEY", app_env[:private_key], "vapid-private-key")

    if public_key && private_key do
      [
        subject: vapid_subject(app_env),
        public_key: public_key,
        private_key: private_key
      ]
    end
  end

  @doc """
  Return the VAPID public key for use in client-side subscription.

  Reads `vapid_details/0`, so this is `nil` on a half configuration even when
  the public half alone resolved. That is deliberate: advertising a public key
  the send path cannot pair with is the defect this module now forbids.
  """
  @spec vapid_public_key() :: String.t() | nil
  def vapid_public_key, do: vapid_details()[:public_key]

  @doc """
  Return the VAPID private key, or `nil`.

  Reads `vapid_details/0` and is subject to the same all-or-nothing rule as
  `vapid_public_key/0`. This is key material: never log it, never include it in
  telemetry metadata, and never pass it as a command-line argument.
  """
  @spec vapid_private_key() :: String.t() | nil
  def vapid_private_key, do: vapid_details()[:private_key]

  @doc """
  Whether VAPID is usable for sending.

  Exactly `vapid_details() != nil`, which is what makes this probe agree with
  the send surface by construction. On the pre-01a0108a code it read the app env
  directly and so agreed with the send path while DISAGREEING with
  `vapid_public_key/0` — a Vault-configured host answered `false` here and still
  handed a public key to the browser.
  """
  @spec vapid_configured?() :: boolean()
  def vapid_configured?, do: vapid_details() != nil

  # ── Private ─────────────────────────────────────────────────────────────────

  # The ONLY reader of `:web_push_encryption, :vapid_details` in this module. It
  # is one input to the resolver — an explicit override that `config/runtime.exs`
  # populates — not the send path's source of truth.
  defp app_env_vapid, do: Application.get_env(:web_push_encryption, :vapid_details) || []

  # Per-key precedence: env var, then the explicit app-env override that
  # `config/runtime.exs` populates, then Vault. Vault is consulted last and
  # lazily, so a configuration that never needs it never pays for it.
  defp resolve_vapid_key(env_var, app_env_value, vault_slug) do
    presence(System.get_env(env_var)) || presence(app_env_value) ||
      presence(vault_get(vault_slug))
  end

  # Mirrors the subject `config/runtime.exs` builds, so moving a deployment
  # between the app-env and Vault paths does not change the JWT audience.
  defp vapid_subject(app_env) do
    presence(app_env[:subject]) || "mailto:push@" <> System.get_env("PHX_HOST", "suite.app")
  end

  # An empty string is an absent credential, not a credential. Env vars set to
  # "" are common in container tooling and must not count as configured.
  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  # VAPID keys are platform-scoped and read from supervised processes that carry
  # no user or agent identity, so the access is attributed to the platform itself
  # via an explicit `{:system, nil}` accessor rather than an omitted option.
  defp vault_get(slug) do
    case Platform.Vault.get(slug, accessor: {:system, nil}) do
      {:ok, value} -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # `vapid_details/0` answers `nil` for two materially different states, and they
  # deserve different volumes. NEITHER half resolving is an unconfigured dev box:
  # a warning, and exactly the historical `"VAPID keys not configured"` line,
  # once per attempt (existing tests count those lines as a delivery-attempt
  # counter). ONE half resolving is a MISCONFIGURATION — somebody set half a
  # credential pair — so it is an error, and it names WHICH half is missing.
  #
  # It names the half and never the value: `vapid_details/0` carries a private
  # key, this repository is public, and the failure mode of making a credential
  # path louder is credentials in logs. No value, not even truncated, goes into
  # the message or the telemetry metadata.
  defp log_vapid_unresolved do
    public_key =
      resolve_vapid_key("VAPID_PUBLIC_KEY", app_env_vapid()[:public_key], "vapid-public-key")

    private_key =
      resolve_vapid_key("VAPID_PRIVATE_KEY", app_env_vapid()[:private_key], "vapid-private-key")

    case {public_key, private_key} do
      {nil, nil} ->
        Logger.warning("[Push] VAPID keys not configured, skipping push")

      {_public, nil} ->
        Logger.error(
          "[Push] VAPID half-configured: public_key resolved, private_key did not; " <>
            "refusing to advertise or send"
        )

        :telemetry.execute(
          [:platform, :push, :vapid_half_configured],
          %{count: 1},
          %{missing: :private_key}
        )

      {nil, _private} ->
        Logger.error(
          "[Push] VAPID half-configured: private_key resolved, public_key did not; " <>
            "refusing to advertise or send"
        )

        :telemetry.execute(
          [:platform, :push, :vapid_half_configured],
          %{count: 1},
          %{missing: :public_key}
        )

      {_public, _private} ->
        # Both halves resolve now but did not a moment ago in `vapid_details/0`:
        # the configuration changed between the two reads. Say that rather than
        # crash the send with a CaseClauseError or mislabel it as unconfigured.
        Logger.error(
          "[Push] VAPID configuration changed mid-send; keys resolve now but did not " <>
            "when this attempt started, so the attempt was skipped"
        )
    end
  end

  # INVARIANT: the subscribe surface (`vapid_public_key/0`, rendered into the
  # `vapid-public-key` meta tag) and the send surface (this function) read the
  # SAME all-or-nothing `vapid_details/0`, so they cannot disagree about whether
  # VAPID is configured. Failure looks like a future edit reintroducing
  # `Application.get_env(:web_push_encryption, :vapid_details)` here — the app
  # env is one INPUT to the resolver, never the send path's source of truth. The
  # agreement test in `test/platform/push_test.exs` is what detonates on it.
  defp do_send_push(sub, json) do
    vapid = vapid_details()

    unless vapid do
      log_vapid_unresolved()
      {:error, :vapid_keys_missing}
    else
      try do
        encrypted =
          WebPushEncryption.Encrypt.encrypt(json, %{
            keys: %{p256dh: sub.p256dh, auth: sub.auth}
          })

        audience = URI.parse(sub.endpoint) |> then(&"#{&1.scheme}://#{&1.host}")
        jwt = build_vapid_jwt(audience, vapid)
        public_key_b64 = Keyword.get(vapid, :public_key)

        salt_b64 = Base.url_encode64(encrypted.salt, padding: false)
        server_key_b64 = Base.url_encode64(encrypted.server_public_key, padding: false)

        headers = [
          {"Content-Encoding", "aesgcm"},
          {"Encryption", "salt=#{salt_b64}"},
          {"Crypto-Key", "dh=#{server_key_b64};p256ecdsa=#{public_key_b64}"},
          {"Authorization", "vapid t=#{jwt}, k=#{public_key_b64}"},
          {"TTL", "86400"}
        ]

        case Req.post(sub.endpoint, body: encrypted.ciphertext, headers: headers) do
          {:ok, %{status: status}} when status in [200, 201, 202] ->
            {:ok, %{status: status}}

          {:ok, %{status: 410}} ->
            Logger.info("[Push] subscription gone (410): #{sub.id}")
            unsubscribe(sub.participant_id, sub.endpoint)
            {:error, :subscription_expired}

          {:ok, %{status: status, body: body}} ->
            Logger.warning("[Push] push returned #{status}: #{inspect(body)}")
            {:error, {:http_error, status}}

          {:error, reason} ->
            Logger.warning("[Push] request failed: #{inspect(reason)}")
            {:error, reason}
        end
      rescue
        e ->
          Logger.warning("[Push] send failed: #{Exception.message(e)}")
          {:error, :send_failed}
      end
    end
  end

  defp build_vapid_jwt(audience, vapid) do
    private_key_raw =
      Base.url_decode64!(Keyword.get(vapid, :private_key), padding: false)

    header =
      Base.url_encode64(Jason.encode!(%{typ: "JWT", alg: "ES256"}), padding: false)

    claims =
      Base.url_encode64(
        Jason.encode!(%{
          aud: audience,
          exp: System.system_time(:second) + 86_400,
          sub: Keyword.get(vapid, :subject)
        }),
        padding: false
      )

    signing_input = "#{header}.#{claims}"

    der_sig =
      :crypto.sign(:ecdsa, :sha256, signing_input, [private_key_raw, :secp256r1])

    raw_sig = der_to_raw_ecdsa(der_sig)
    "#{signing_input}.#{Base.url_encode64(raw_sig, padding: false)}"
  end

  # Convert DER-encoded ECDSA signature to raw r||s (64 bytes)
  defp der_to_raw_ecdsa(<<48, _, 2, r_len, rest::binary>>) do
    <<r_bytes::binary-size(^r_len), 2, s_len, s_bytes::binary-size(s_len), _::binary>> = rest
    pad_to_32(r_bytes) <> pad_to_32(s_bytes)
  end

  defp pad_to_32(bytes) when byte_size(bytes) >= 32,
    do: binary_part(bytes, byte_size(bytes) - 32, 32)

  defp pad_to_32(bytes),
    do: :binary.copy(<<0>>, 32 - byte_size(bytes)) <> bytes
end
