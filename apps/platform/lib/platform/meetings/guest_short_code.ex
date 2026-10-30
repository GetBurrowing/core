defmodule Platform.Meetings.GuestShortCode do
  @moduledoc """
  The opaque code behind a short guest link, `https://<guest host>/g/<code>`
  (task 01a18d0a-ec37-7000-8a47-108834f2efe2).

  A guest link used to be `https://<guest host>/<slug>/<signed token>`. The
  token is a `Platform.Meetings.GuestInvite` `Plug.Crypto` signature over the
  slug, expiry, display name, meeting id and invite id, so the URL ran to 150+
  characters: too long to read aloud, and long enough that chat clients and
  mail wrap or truncate it.

  The code is stored on the `meeting_invites` row (`short_code`). The signed
  token is NOT stored anywhere: a signed token is a live bearer credential, and
  the row is already enough to re-mint it (`Platform.Meetings.guest_invite_link/2`
  has done that for the detail panel since task 019fb954). On every short-link
  hit `Platform.Meetings.resolve_guest_short_code/1` looks the row up by code,
  re-mints the token from it and passes that token unchanged through
  `Platform.Meetings.resolve_guest_invite/2`, so expiry still comes from the
  row's `expires_at` and revocation from its `revoked_at`.

  ## Why 22 characters, not 8

  16 bytes from `:crypto.strong_rand_bytes/1`, base64url without padding, is
  22 characters carrying 128 bits. The design canvas showed an 8-character
  `7kq2-mxpd` as an illustration. That is about 40 bits, and the short link is
  an online-guessable bearer alias: anyone who guesses a live code is admitted
  to a meeting as a named guest, with no other check. 128 bits puts guessing
  out of reach at any request rate, and the code is still a fraction of the
  token's length.

  ## Resulting URL length

  `https://` (8) + guest host + `/g/` (3) + code (22) = 33 + the host's length.
  The two production installs' `:meeting_guest_host` values, read 2026-10-30,
  are 16 and 24 characters long, giving 49- and 57-character links against
  150+ for the long form. (The host names themselves are install identity and
  stay out of this repository.)
  """

  @byte_size 16
  @length 22
  @format ~r/\A[A-Za-z0-9_-]{22}\z/

  @doc "A fresh code: 16 CSPRNG bytes, base64url without padding (22 chars)."
  @spec generate() :: String.t()
  def generate do
    @byte_size |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  @doc "The fixed length of every code."
  @spec code_length() :: pos_integer()
  def code_length, do: @length

  @doc """
  Whether `value` has the shape of a code: exactly 22 url-safe base64
  characters. Checked before any query, so a malformed path segment never
  reaches the database.
  """
  @spec valid_format?(term()) :: boolean()
  def valid_format?(value) when is_binary(value), do: Regex.match?(@format, value)
  def valid_format?(_value), do: false
end
