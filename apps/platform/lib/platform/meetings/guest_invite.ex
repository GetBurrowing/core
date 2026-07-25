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
        meeting_id: "..."            # or nil for tokens minted pre-019f9b14
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
          required(:meeting_id) => String.t() | nil
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
  """
  @spec sign(String.t(), integer(), String.t() | nil, keyword()) :: String.t()
  def sign(meeting_slug, expires_at, display_name \\ nil, opts \\ [])
      when is_binary(meeting_slug) and is_integer(expires_at) and
             (is_binary(display_name) or is_nil(display_name)) and is_list(opts) do
    guest_space_id = Keyword.get(opts, :guest_space_id)
    meeting_id = Keyword.get(opts, :meeting_id)

    unless is_nil(guest_space_id) or is_binary(guest_space_id) do
      raise ArgumentError,
            "guest_space_id must be a binary or nil, got: #{inspect(guest_space_id)}"
    end

    unless is_nil(meeting_id) or is_binary(meeting_id) do
      raise ArgumentError,
            "meeting_id must be a binary or nil, got: #{inspect(meeting_id)}"
    end

    payload = %{
      meeting_slug: meeting_slug,
      expires_at: expires_at,
      display_name: display_name,
      guest_space_id: guest_space_id,
      meeting_id: meeting_id
    }

    Plug.Crypto.sign(signing_key(), @salt, payload)
  end

  @doc """
  Sign a guest invite token with the default expiry window (24h from now).
  Convenience wrapper around `sign/3` for callers that want the standard
  expiry policy. `opts` is passed through verbatim, so `:guest_space_id`
  and `:meeting_id` behave exactly as they do on `sign/4`.
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

        cond do
          not (is_nil(guest_space_id) or is_binary(guest_space_id)) ->
            {:error, :invalid}

          not (is_nil(meeting_id) or is_binary(meeting_id)) ->
            {:error, :invalid}

          DateTime.utc_now() |> DateTime.to_unix() > expires_at ->
            {:error, :expired}

          true ->
            # Normalise: always surface `:guest_space_id` and `:meeting_id`
            # in the returned payload so callers can pattern-match
            # uniformly across old (pre-stage-4 / pre-019f9b14) and new
            # tokens rather than reaching for `Map.get/2` themselves.
            {:ok,
             payload
             |> Map.put(:guest_space_id, guest_space_id)
             |> Map.put(:meeting_id, meeting_id)}
        end

      {:ok, _malformed} ->
        {:error, :invalid}

      {:error, :expired} ->
        {:error, :expired}

      {:error, _} ->
        {:error, :invalid}
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
