defmodule PlatformWeb.MeetingCalendarController do
  @moduledoc """
  `GET /meetings/:id/invite.ics` — the calendar **feed** for one meeting.

  ## A link, never an attachment

  Nothing in this module writes the rendered document into
  `Platform.Chat.Attachment`, `Platform.Chat.AttachmentStorage`, or a
  message body, and nothing on the invite-message path calls it. An
  `.ics` attachment is a *snapshot*: the moment the meeting moves, every
  imported copy is silently wrong and there is no channel left to
  correct it. This endpoint exists precisely so the client re-fetches,
  and `Platform.Meetings.CalendarFeed.render/1` is a pure function of
  the row so that a re-fetch of an unchanged meeting is a byte-identical
  no-op.

  ## No session, by design

  The route runs through the `:calendar_feed` pipeline: no
  `:fetch_session`, no `:require_auth`, no `ExternalUserScope`. The
  clients this exists for — Google Calendar's "From URL", Apple
  Calendar's subscription, Outlook's Internet Calendar — fetch from
  *their* servers, carrying no cookie of ours. A session-scoped feed is
  un-subscribable by them, which collapses the endpoint back into the
  one-shot snapshot it was built to replace. The signed token in the
  query string is therefore the only auth there is; see
  `Platform.Meetings.CalendarLink` for the leak posture that buys.

  ## Never cached

  The response is emitted `no-cache, no-store, must-revalidate`. A
  cached response *is* a stale snapshot — the exact failure this
  endpoint exists to avoid — so a `max-age` here would be a defect, not
  an optimisation.

  ## Uniform 404

  Every failure mode — absent token, bad signature, a valid token for a
  *different* meeting, an unknown id, a meeting with no intended time —
  returns the same bare 404 with no body. Distinguishing them would turn
  the endpoint into an existence oracle over meeting ids for anyone
  holding any one valid token.

  A 404 is safe *here* specifically because nothing was ever published
  for those rows: no client holds an event to be corrected, so there is
  nothing to strand.

  ## A cancelled meeting is 200, not 404

  That reasoning does **not** extend to cancellation, and the two cases
  must not be conflated:

    * *Never scheduled* — no client ever received an event. A 404 strands
      nobody, and answering anything else would be inventing an event.
    * *Cancelled* — every invitee's calendar is holding a real event
      right now. The only way to remove it is to serve a document that
      says so. A 404 here leaves that event in place forever, with the
      link that could have corrected it now permanently dead: the precise
      failure this endpoint exists to prevent, and strictly worse than
      having sent nothing at all.

  So a cancelled meeting keeps returning **200**, with
  `Platform.Meetings.CalendarFeed.render/1` supplying `METHOD:CANCEL`,
  `STATUS:CANCELLED` and an advanced `SEQUENCE` on the *same* `UID`.
  Cancellation likewise does not invalidate the token — an invalidated
  link is a 404 by another name.

  The one exception is the intersection: a cancelled meeting that never
  had an intended time is still a 404, because it was never on anyone's
  calendar. `render/1` decides that, on the row, for the same reason as
  above.
  """

  use PlatformWeb, :controller

  alias Platform.Meetings
  alias Platform.Meetings.CalendarFeed
  alias Platform.Meetings.CalendarLink
  alias Platform.Meetings.Meeting

  @content_type "text/calendar"
  # A cached copy is a stale snapshot. See the moduledoc.
  @cache_control "no-cache, no-store, must-revalidate"
  @content_disposition ~s(inline; filename="invite.ics")

  def show(conn, %{"id" => id} = params) do
    with {:ok, token} <- fetch_token(params),
         {:ok, payload} <- CalendarLink.verify(token),
         :ok <- authorize_payload(payload, id),
         %Meeting{} = meeting <- Meetings.get_meeting(id),
         {:ok, body} <- CalendarFeed.render(meeting) do
      conn
      |> put_resp_content_type(@content_type)
      |> put_resp_header("cache-control", @cache_control)
      |> put_resp_header("pragma", "no-cache")
      # The document is served with an authoritative content type; without
      # this a browser may re-interpret the bytes as something else.
      # Mirrors `PlatformWeb.ChatAttachmentController`.
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", @content_disposition)
      |> send_resp(:ok, body)
    else
      _anything -> not_found(conn)
    end
  end

  defp fetch_token(%{"token" => token}) when is_binary(token), do: {:ok, token}
  defp fetch_token(_params), do: :error

  # LOAD-BEARING. The URL is what was shared; the payload has to agree
  # with it. Without this check a single valid token reads *every*
  # meeting, because `verify/1` only proves the token was minted by us —
  # not that it was minted for the row being requested. Same posture as
  # the URL-vs-payload slug guard in
  # `Platform.Meetings.resolve_guest_invite/2`: trust the path, require
  # the payload to match it.
  defp authorize_payload(%{meeting_id: meeting_id}, meeting_id), do: :ok
  defp authorize_payload(_payload, _id), do: :error

  # One shape for every failure. See the moduledoc on why the branches
  # must stay indistinguishable.
  defp not_found(conn), do: send_resp(conn, :not_found, "")
end
