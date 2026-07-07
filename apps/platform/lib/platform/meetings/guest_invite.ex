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
        guest_space_id: "..."        # or nil when no dedicated guest space
      }

  `:guest_space_id` was added in stage 4 of task 019f2483 to thread the
  host-provisioned guest chat space through the token so the guest's
  LiveKit identity + subsequent chat writes can be scoped correctly. It
  is optional in the verify path so tokens minted before this stage
  (payload without the key) still verify — they resolve to
  `guest_space_id: nil`.
  """

  @salt "meeting_guest_invite"

  # Default expiry window used by `sign/2` when the caller does not pass an
  # explicit `expires_at`. 24 hours from `sign` time.
  @default_expiry_seconds 24 * 60 * 60

  @type payload :: %{
          required(:meeting_slug) => String.t(),
          required(:expires_at) => integer(),
          required(:display_name) => String.t() | nil,
          required(:guest_space_id) => String.t() | nil
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
    space. Omit for legacy call sites (stage 3 GuestMeetingLive tests
    exercise the no-space path).
  """
  @spec sign(String.t(), integer(), String.t() | nil, keyword()) :: String.t()
  def sign(meeting_slug, expires_at, display_name \\ nil, opts \\ [])
      when is_binary(meeting_slug) and is_integer(expires_at) and
             (is_binary(display_name) or is_nil(display_name)) and is_list(opts) do
    guest_space_id = Keyword.get(opts, :guest_space_id)

    unless is_nil(guest_space_id) or is_binary(guest_space_id) do
      raise ArgumentError,
            "guest_space_id must be a binary or nil, got: #{inspect(guest_space_id)}"
    end

    payload = %{
      meeting_slug: meeting_slug,
      expires_at: expires_at,
      display_name: display_name,
      guest_space_id: guest_space_id
    }

    Plug.Crypto.sign(signing_key(), @salt, payload)
  end

  @doc """
  Sign a guest invite token with the default expiry window (24h from now).
  Convenience wrapper around `sign/3` for callers that want the standard
  expiry policy.
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

        if not (is_nil(guest_space_id) or is_binary(guest_space_id)) do
          {:error, :invalid}
        else
          if DateTime.utc_now() |> DateTime.to_unix() > expires_at do
            {:error, :expired}
          else
            # Normalise: always surface `:guest_space_id` in the returned
            # payload so callers can pattern-match uniformly across old
            # (pre-stage-4) and new tokens.
            {:ok, Map.put(payload, :guest_space_id, guest_space_id)}
          end
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
