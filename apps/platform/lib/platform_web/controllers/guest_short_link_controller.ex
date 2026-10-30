defmodule PlatformWeb.GuestShortLinkController do
  @moduledoc """
  The short guest link, `GET /g/:code` on the `meet.` host (task
  01a18d0a-ec37-7000-8a47-108834f2efe2).

  This controller admits nobody. It asks
  `Platform.Meetings.resolve_guest_short_code/1` for the meeting and a guest
  token freshly re-minted from the invite row, then 302s to
  `/<slug>/<token>` on the same host: the existing shellless guest ingress,
  where `PlatformWeb.MeetingLive` verifies the token again on mount. There is
  one guest admission path, and this is not a second one.

  ## Headers

    * `cache-control: no-store` — the redirect carries a bearer token in its
      `location`; no cache may keep it.
    * `referrer-policy: no-referrer` — overrides the pipeline's default so the
      code is not sent onward as a referrer.

  ## One refusal

  Malformed, unknown, expired, revoked, deleted meeting and mismatched row all
  get the SAME response: same status, same body, same headers, naming no
  meeting, slug or guest. A response that told an expired code from an unknown
  one would let anyone probing codes learn which ones once existed.
  """
  use PlatformWeb, :controller

  alias Platform.Meetings

  @refusal_status 404
  @refusal_body "This invite link is not valid. Ask the person who invited you for a new one."

  @doc false
  def refusal_status, do: @refusal_status

  @doc false
  def refusal_body, do: @refusal_body

  def show(conn, %{"code" => code}) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("referrer-policy", "no-referrer")

    case Meetings.resolve_guest_short_code(code) do
      {:ok, %{meeting: meeting, token: token}} ->
        redirect(conn, to: "/" <> encode_segment(meeting.slug) <> "/" <> encode_segment(token))

      {:error, _reason} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(@refusal_status, @refusal_body)
    end
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
