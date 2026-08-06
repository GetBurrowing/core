defmodule Platform.Meetings.GuestInvite do
  @moduledoc """
  HMAC sign / verify for meeting guest invite tokens.

  A guest invite URL carries a signed token that identifies a meeting slug,
  the token expiry, and (optionally) a pre-provisioned display name. The
  guest ingress controller/LiveView verifies the token against the
  configured signing key and enforces the payload's expiry before allowing
  a guest to join the LiveKit room.

  Pattern mirrored from `Platform.Chat.AttachmentPresigner`. A separate
  signing key (`:meeting_guest_signing_key`) is used to isolate blast
  radius from the attachment key.

  Payload shape:

      %{
        meeting_slug: "some-meeting",
        expires_at: 1_764_849_600, # unix seconds
        display_name: "Juno Fairbanks", # or nil for self-entry
        guest_space_id: "...",       # or nil when no dedicated guest space
        meeting_id: "...",           # or nil for tokens minted pre-019f9b14
        invite_id: "..."             # or nil for tokens minted pre-019fb954
      }

  `:guest_space_id` was added in stage 4 of task 019f2483 to thread the
  host-provisioned guest chat space through the token so the guest's
  LiveKit identity + subsequent chat writes can be scoped correctly. It
  is optional in the verify path so tokens minted before this stage
  (payload without the key) still verify — they resolve to
  `guest_space_id: nil`.

  `:meeting_id` was added in stage 3 of task 019f9b14 for the same
  reason and by the same mechanism. The token is a legitimate bearer
  capability, but until now it named its target by `meeting_slug`
  alone — and `meetings` only carries `unique_index(:meetings,
  [:project_id, :slug])`, so a slug is unique *per project*, not
  globally. A validly-signed token therefore did not unambiguously
  identify a meeting: two projects (in two different orgs) may both own
  a `standup`. Carrying the id makes the token's subject exact, so the
  resolver never has to guess which row a signature refers to.

  It is optional in the verify path for the same backwards-compatibility
  reason as `:guest_space_id` — tokens minted before this stage verify
  and resolve to `meeting_id: nil`, and `Platform.Meetings`'s resolver
  falls back to a safe-failing unambiguous slug lookup for those. With
  the 24h default expiry, legacy tokens age out within a day.

  `:invite_id` was added in stage 2 of task 019fb954, again by the same
  mechanism. It binds the token to a `meeting_invites` ROW so a single
  guest can be revoked without invalidating the others — an issued HMAC
  cannot be un-issued, so the row (via its `revoked_at`) is the only
  revocation surface a stateless token can have. `verify/2` deliberately
  does NOT perform that check: it stays pure (signature, shape, expiry
  only). Revocation needs a `Platform.Repo` lookup and lives in
  `Platform.Meetings.resolve_guest_invite/2`.

  It is optional in the verify path for the same backwards-compatibility
  reason as the two keys above — every token in the wild today was minted
  without an `invite_id` and must keep verifying.
  """

  @salt "meeting_guest_invite"

  # Default expiry window used by `sign/2` when the caller does not pass an
  # explicit `expires_at`. 24 hours from `sign` time.
  @default_expiry_seconds 24 * 60 * 60

  @type payload :: %{
          required(:meeting_slug) => String.t(),
          required(:expires_at) => integer(),
          required(:display_name) => String.t() | nil,
          required(:guest_space_id) => String.t() | nil,
          required(:meeting_id) => String.t() | nil,
          required(:invite_id) => String.t() | nil
        }

  @doc """
  Sign a guest invite token.

  * `meeting_slug` is the slug of the meeting the guest will join.
  * `expires_at` is a unix timestamp (seconds) at which the token expires.
  * `display_name` is optionally a pre-provisioned name — pass `nil` for
    the self-entry flow where the guest types their own name at ingress.
  * `guest_space_id` (optional, keyword) — id of the dedicated guest
    chat space the host provisioned for this invite. Threaded through
    for the guest-ingress path so ingress can pin writes to the guest
    space. Omit for legacy call sites that never bound a guest space
    (older tests exercise the no-space path).
  * `meeting_id` (optional, keyword) — id of the meeting this token
    admits to. Pass it: `meeting_slug` alone does not uniquely identify
    a meeting (slug is unique per project only), so a token without an
    id can only be resolved by a slug lookup that must refuse ambiguous
    matches. Omit only to simulate a legacy, pre-019f9b14 token.
  * `invite_id` (optional, keyword) — id of the `meeting_invites` row
    this token was issued against. Binding the token to a row is what
    makes a single guest revocable without invalidating the others.
    Omit only to simulate a legacy, pre-019fb954 token.
  """
  @spec sign(String.t(), integer(), String.t() | nil, keyword()) :: String.t()
  def sign(meeting_slug, expires_at, display_name \\ nil, opts \\ [])
      when is_binary(meeting_slug) and is_integer(expires_at) and
             (is_binary(display_name) or is_nil(display_name)) and is_list(opts) do
    guest_space_id = Keyword.get(opts, :guest_space_id)
    meeting_id = Keyword.get(opts, :meeting_id)
    invite_id = Keyword.get(opts, :invite_id)

    unless is_nil(guest_space_id) or is_binary(guest_space_id) do
      raise ArgumentError,
            "guest_space_id must be a binary or nil, got: #{inspect(guest_space_id)}"
    end

    unless is_nil(meeting_id) or is_binary(meeting_id) do
      raise ArgumentError,
            "meeting_id must be a binary or nil, got: #{inspect(meeting_id)}"
    end

    unless is_nil(invite_id) or is_binary(invite_id) do
      raise ArgumentError,
            "invite_id must be a binary or nil, got: #{inspect(invite_id)}"
    end

    payload = %{
      meeting_slug: meeting_slug,
      expires_at: expires_at,
      display_name: display_name,
      guest_space_id: guest_space_id,
      meeting_id: meeting_id,
      invite_id: invite_id
    }

    Plug.Crypto.sign(signing_key(), @salt, payload)
  end

  @doc """
  Sign a guest invite token with the default expiry window (24h from now).
  Convenience wrapper around `sign/3` for callers that want the standard
  expiry policy. `opts` is passed through verbatim, so `:guest_space_id`,
  `:meeting_id` and `:invite_id` behave exactly as they do on `sign/4`.
  """
  @spec sign_with_default_expiry(String.t(), String.t() | nil, keyword()) :: String.t()
  def sign_with_default_expiry(meeting_slug, display_name \\ nil, opts \\ [])
      when is_binary(meeting_slug) and (is_binary(display_name) or is_nil(display_name)) and
             is_list(opts) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.to_unix()
      |> Kernel.+(@default_expiry_seconds)

    sign(meeting_slug, expires_at, display_name, opts)
  end

  @doc """
  Verify a guest invite token.

  Returns `{:ok, payload}` when the HMAC is valid, the payload shape
  matches, and `expires_at` is in the future. Returns `{:error, :expired}`
  when the token has passed its `expires_at`, or `{:error, :invalid}` for
  anything else (wrong signature, tampered payload, wrong shape).

  This function is PURE — signature, shape and expiry only. It does not
  touch `Platform.Repo`, so it does not and cannot check whether the
  bound `:invite_id` row has been revoked. That check lives in
  `Platform.Meetings.resolve_guest_invite/2`.
  """
  @spec verify(String.t(), keyword()) ::
          {:ok, payload} | {:error, :invalid | :expired}
  def verify(token, opts \\ []) when is_binary(token) do
    # `max_age` is an upper bound from issue time. The payload's
    # `expires_at` is checked independently so callers can reject even
    # sooner than the underlying Plug.Crypto max_age.
    max_age = Keyword.get(opts, :max_age_seconds, 30 * 24 * 60 * 60)

    case Plug.Crypto.verify(signing_key(), @salt, token, max_age: max_age) do
      {:ok,
       %{meeting_slug: meeting_slug, expires_at: expires_at, display_name: display_name} =
           payload}
      when is_binary(meeting_slug) and is_integer(expires_at) and
             (is_binary(display_name) or is_nil(display_name)) ->
        guest_space_id = Map.get(payload, :guest_space_id)
        meeting_id = Map.get(payload, :meeting_id)
        invite_id = Map.get(payload, :invite_id)

        cond do
          not (is_nil(guest_space_id) or is_binary(guest_space_id)) ->
            {:error, :invalid}

          not (is_nil(meeting_id) or is_binary(meeting_id)) ->
            {:error, :invalid}

          not (is_nil(invite_id) or is_binary(invite_id)) ->
            {:error, :invalid}

          DateTime.utc_now() |> DateTime.to_unix() > expires_at ->
            {:error, :expired}

          true ->
            # Normalise: always surface `:guest_space_id`, `:meeting_id`
            # and `:invite_id` in the returned payload so callers can
            # pattern-match uniformly across old (pre-stage-4 /
            # pre-019f9b14 / pre-019fb954) and new tokens rather than
            # reaching for `Map.get/2` themselves.
            {:ok,
             payload
             |> Map.put(:guest_space_id, guest_space_id)
             |> Map.put(:meeting_id, meeting_id)
             |> Map.put(:invite_id, invite_id)}
        end

      {:ok, _malformed} ->
        {:error, :invalid}

      {:error, :expired} ->
        {:error, :expired}

      {:error, _} ->
        {:error, :invalid}
    end
  end

  @doc """
  The public hostname guest invite links are minted against.

  Reads `:meeting_guest_host` with NO default. A caller that needs a
  default is a caller that can mint a link pointing at the wrong host,
  which is precisely the failure this two-argument read exists to make
  impossible. Returns `nil` when the key is unset.
  """
  @spec guest_host() :: String.t() | nil
  def guest_host do
    Application.get_env(:platform, :meeting_guest_host)
  end

  @doc """
  Whether a usable guest hostname is configured.

  True only for a binary with non-whitespace content. Unset, `nil`, `""`
  and whitespace-only values all return false, and each means the same
  thing: the guest-invite surface does not exist in this environment.
  Callers MUST fail closed on false — hide or refuse the guest-invite
  action — and must never substitute a default hostname.
  """
  @spec guest_host_configured?() :: boolean()
  def guest_host_configured? do
    case guest_host() do
      host when is_binary(host) -> String.trim(host) != ""
      _ -> false
    end
  end

  defp signing_key do
    Application.get_env(:platform, :meeting_guest_signing_key) ||
      raise """
      :meeting_guest_signing_key not configured.

      Set `config :platform, :meeting_guest_signing_key, "..."` (32+ bytes)
      in config/runtime.exs. Dev and test configs set a stable local
      value. Prod must read from an env var (MEETING_GUEST_SIGNING_KEY).
      """
  end
end
