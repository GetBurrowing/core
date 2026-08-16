defmodule Platform.Push do
  @moduledoc """
  Web Push notification context.

  Manages push subscriptions and sends notifications via the Web Push protocol.
  VAPID keys are read from `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` env vars,
  falling back to Vault lookup by slugs `"vapid-public-key"` / `"vapid-private-key"`.
  """

  import Ecto.Query

  require Logger

  alias Platform.Accounts.User
  alias Platform.Chat.Participant
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
  Send a web push notification addressed to one `chat_participants` row.

  Addressing stays per-participant (the archived guard and the external
  redaction both key on `participant_id`), while device resolution goes through
  `subscriptions_for_recipient/1`: a user-typed recipient reaches every device
  that user owns, once per distinct endpoint, whichever conversation the device
  was registered in (task 019ffd19). Agent-typed and unknown recipients keep
  the per-membership device set.
  """
  @spec send_notification(binary(), map()) :: :ok
  def send_notification(participant_id, %{title: _, body: _} = payload) do
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
      subscriptions = subscriptions_for_recipient(participant_id)

      # Redact the payload for external recipients before it leaves the box.
      # The archived guard above still wins — an archived external user is
      # suppressed entirely and never reaches this swap. Internal recipients
      # get the byte-identical payload they get today.
      payload = preview_for_recipient(participant_id, payload)

      json = Jason.encode!(payload)

      Enum.each(subscriptions, fn sub ->
        case do_send_push(sub, json) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Push] failed to send to #{sub.endpoint}: #{inspect(reason)}")
        end
      end)
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

  Inherits `send_notification/2`'s two guards, evaluated once at the user level
  (every resolved row belongs to `user_id`, so the decision is uniform):
  archived users are suppressed with the same telemetry, and external users get
  the redacted `external_safe_preview/1`. 410-expired subscriptions are pruned
  by `do_send_push/2` exactly as in the per-participant path.
  """
  @spec send_to_user(binary(), map()) :: :ok
  def send_to_user(user_id, %{title: _, body: _} = payload) when is_binary(user_id) do
    if archived_user?(user_id) do
      :telemetry.execute(
        [:platform, :push, :suppressed_archived_user],
        %{count: 1},
        %{user_id: user_id}
      )

      :ok
    else
      subscriptions = distinct_endpoint_subscriptions(user_id)

      # Redact once at the user level before the payload leaves the box (all
      # resolved rows belong to `user_id`, so external-ness is uniform).
      payload = preview_for_user(user_id, payload)

      json = Jason.encode!(payload)

      Enum.each(subscriptions, fn sub ->
        case do_send_push(sub, json) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("[Push] failed to send to #{sub.endpoint}: #{inspect(reason)}")
        end
      end)
    end
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
  @spec external_safe_preview(map()) :: map()
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

  @doc "Return the VAPID public key for use in client-side subscription."
  @spec vapid_public_key() :: String.t() | nil
  def vapid_public_key do
    case System.get_env("VAPID_PUBLIC_KEY") do
      nil -> vault_get("vapid-public-key")
      key -> key
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp vapid_private_key do
    case System.get_env("VAPID_PRIVATE_KEY") do
      nil -> vault_get("vapid-private-key")
      key -> key
    end
  end

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

  defp do_send_push(sub, json) do
    vapid = Application.get_env(:web_push_encryption, :vapid_details)

    unless vapid do
      Logger.warning("[Push] VAPID keys not configured, skipping push")
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
            Logger.info("[Push] subscription gone (410): #{sub.endpoint}")
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
    <<r_bytes::binary-size(r_len), 2, s_len, s_bytes::binary-size(s_len), _::binary>> = rest
    pad_to_32(r_bytes) <> pad_to_32(s_bytes)
  end

  defp pad_to_32(bytes) when byte_size(bytes) >= 32,
    do: binary_part(bytes, byte_size(bytes) - 32, 32)

  defp pad_to_32(bytes),
    do: :binary.copy(<<0>>, 32 - byte_size(bytes)) <> bytes

  defp vapid_configured? do
    case Application.get_env(:web_push_encryption, :vapid_details) do
      nil -> false
      details -> details[:public_key] != nil and details[:private_key] != nil
    end
  end
end
