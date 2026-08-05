defmodule Platform.Meetings.CalendarLink do
  @moduledoc """
  HMAC sign / verify for the per-meeting calendar link token.

  `GET /meetings/:id/invite.ics` is **unauthenticated but unguessable**: a
  signed bearer token in the query string is the only auth. There is no
  session and no cookie, because the clients this endpoint exists for —
  Google Calendar ("From URL"), Apple Calendar (subscription), Outlook
  (Internet Calendar) — fetch the URL *from their own servers*. A
  session-scoped `.ics` is literally un-subscribable by them, which would
  collapse the endpoint back into a one-shot snapshot.

  ## Leak posture

  The URL is a bearer capability over calendar **metadata**. Anyone who
  receives a forwarded calendar entry can re-fetch it and learn that the
  meeting exists, its name and its time. They cannot join: the rendered
  document carries no LiveKit token, no guest-invite token, and no `URL:`
  property. Metadata leak is accepted; room admission is not.

  ## Per-meeting, not per-invite

  The token names one meeting and nothing else. Contrast
  `Platform.Meetings.GuestInvite`, whose token is per-INVITE (it carries
  `:invite_id` so a single guest is revocable) and whose payload admits to
  a LiveKit room. One meeting, one calendar link, one UID.

  Payload shape:

      %{meeting_id: "..."}

  Nothing else. No slug, no name, no invitee — a calendar client needs
  none of it, and every extra field is another thing a forwarded link
  discloses.

  ## No expiry — deliberately

  `verify/1` passes `max_age: :infinity` and the payload carries no
  `expires_at`. A calendar subscription is long-lived: the client refetches
  the URL on its own schedule, potentially for months. An expired token
  makes that refetch fail, which leaves the event frozen at whatever it
  last was — the same ghost-event failure a 404 causes, and the exact
  failure mode this endpoint exists to avoid.

  Expiry is the wrong lever here. **Key rotation is the revocation
  lever**: rotating `:meeting_calendar_signing_key` invalidates every
  calendar link at once. That is why this module has its own key rather
  than borrowing `:meeting_guest_signing_key` — a link that survives
  forever and a link that admits to a room must be independently
  rotatable, so their blast radii must not overlap. (`GuestInvite` names
  the same blast-radius reasoning for isolating itself from the
  attachment key.)
  """

  @salt "meeting_calendar_link"

  @type payload :: %{required(:meeting_id) => String.t()}

  @doc """
  Sign a calendar link token for `meeting_id`.

  The payload is `%{meeting_id: meeting_id}` and nothing else.
  """
  @spec sign(String.t()) :: String.t()
  def sign(meeting_id) when is_binary(meeting_id) do
    Plug.Crypto.sign(signing_key(), @salt, %{meeting_id: meeting_id})
  end

  @doc """
  Verify a calendar link token.

  Returns `{:ok, %{meeting_id: meeting_id}}` when the HMAC is valid and
  the payload shape matches, `{:error, :invalid}` otherwise.

  There is no `{:error, :expired}` clause and there never should be: the
  verification runs with `max_age: :infinity` on purpose (see the
  moduledoc). Age is not a rejection reason for a calendar subscription.
  """
  @spec verify(String.t()) :: {:ok, payload} | {:error, :invalid}
  def verify(token) when is_binary(token) do
    case Plug.Crypto.verify(signing_key(), @salt, token, max_age: :infinity) do
      {:ok, %{meeting_id: meeting_id}} when is_binary(meeting_id) ->
        {:ok, %{meeting_id: meeting_id}}

      {:ok, _malformed} ->
        {:error, :invalid}

      {:error, _} ->
        {:error, :invalid}
    end
  end

  defp signing_key do
    Application.get_env(:platform, :meeting_calendar_signing_key) ||
      raise """
      :meeting_calendar_signing_key not configured.

      Set `config :platform, :meeting_calendar_signing_key, "..."` (32+
      bytes) in config/runtime.exs. Dev and test configs set a stable
      local value. Prod must read from an env var
      (MEETING_CALENDAR_SIGNING_KEY).

      This key is deliberately NOT `:meeting_guest_signing_key` — a
      calendar link never expires and is revoked only by rotating this
      key, so it must be rotatable without invalidating guest invites.
      """
  end
end
