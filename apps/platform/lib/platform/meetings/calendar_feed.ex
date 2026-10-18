defmodule Platform.Meetings.CalendarFeed do
  @moduledoc """
  Renders one `Platform.Meetings.Meeting` as a single-`VEVENT` iCalendar
  document (RFC 5545), served by `GET /meetings/:id/invite.ics`.

  `render/1` is a **pure function of the row**. It reads no `Repo`, calls
  no `DateTime.utc_now/0`, and knows nothing about the request. Two
  fetches of an unchanged meeting therefore produce byte-identical
  documents, which is what lets a subscribing client treat a re-fetch as
  a no-op instead of a change.

  ## UID — one meeting, one UID

  `"meeting-" <> meeting.id`. The meeting id is a UUIDv7, which RFC 7986
  §5.3 endorses directly as a UID value, so there is no `@domain` suffix
  — that also keeps a hostname out of this repo.

  The UID is derived from the meeting id and **nothing else**: not an
  invite id, not the bearer token, not the slug, not the request. Two
  invitees who fetch two different links for the same meeting must see
  the same UID or they end up with two events on one calendar and a
  later cancel only clears one of them.

  (The string happens to coincide with the `livekit_room_name`
  convention. That is a coincidence, not a dependency — do not source
  the UID from that column, it is free to change.)

  ## Timezone — UTC with the `Z` suffix, not `TZID`

  Times are rendered in RFC 5545 §3.3.5 form 2, e.g.
  `DTSTART:20260815T140000Z`.

  A `TZID` parameter is only legal alongside a `VTIMEZONE` component
  carrying correct `STANDARD`/`DAYLIGHT` sub-components. Ship a `TZID` a
  client cannot resolve and Outlook renders the event at the wrong hour
  or rejects the document outright. The source columns are
  `:utc_datetime_usec`, so there is no author-intended local zone to
  preserve, and with no `RRULE` in v1 there is no DST-spanning
  recurrence — the one case where `TZID` earns its cost.

  Fractional seconds are **illegal** in an iCalendar DATE-TIME and
  `:utc_datetime_usec` carries them, hence the `DateTime.truncate/2`
  before formatting.

  ## DTSTAMP is `updated_at`, not "now"

  Using `DateTime.utc_now/0` would make every fetch a different document
  and defeat the purity above. `updated_at` advances on any real change
  — including the cancellation stage 4 adds, which bumps the row — so
  the stamp still moves when, and only when, something moved.

  ## SEQUENCE is always emitted

  `SEQUENCE:0` on the live path, `SEQUENCE:1` on the cancelled one. RFC
  5545 §3.8.7.4 defaults an absent SEQUENCE to 0, so omitting it from
  *both* states would give a cancellation the same effective sequence as
  the original — and Google and Outlook discard an update whose sequence
  does not exceed the stored one. That is precisely the "cancel the
  client ignores" failure. Both values are derived from the row; there
  is no counter column and none should be added.

  ## Cancellation — a different document, never a different event

  `status == "cancelled"` (read through the single `cancelled?/1`
  predicate) swaps three properties together:

    * calendar-level `METHOD:CANCEL` for `METHOD:PUBLISH`
    * `STATUS:CANCELLED` for `STATUS:CONFIRMED` inside the `VEVENT`
    * `SEQUENCE:1` for `SEQUENCE:0`

  All three, because clients disagree about which one they honour: a
  document that says only `METHOD:CANCEL` is ignored by a client keying
  on `STATUS`, and one that advances neither `SEQUENCE` is discarded as
  a stale replay by clients that key on that.

  **The `UID` does not change.** It is still `uid/1` of the meeting id,
  with no cancellation-specific branch anywhere near it. A cancel is not
  a new event; it is a correction addressed to an event a client already
  holds, and the UID is the only handle it has for finding it. Mint a
  fresh UID on this path and the client files the cancellation as a
  second, already-cancelled entry while the original sits on the
  calendar forever — the exact ghost this endpoint exists to clear.

  `DTSTART`/`DTEND` likewise keep the original scheduled times. Blanking
  them would leave the client nothing to match, and RFC 5545 requires a
  `DTSTART` regardless.

  ## METHOD:PUBLISH, and the properties deliberately absent

  RFC 5546 §3.2.1 PUBLISH requires no `ATTENDEE` list where REQUEST
  does. Emitting `ATTENDEE` rows would disclose the entire invitee list
  to anyone holding the bearer URL — strictly worse than disclosing the
  meeting's existence, which is the accepted ceiling
  (`Platform.Meetings.CalendarLink` states the leak posture).

  No `ORGANIZER`, no `ATTENDEE`, no `URL`, no `DESCRIPTION`, no
  `LOCATION`. `URL` is omitted on purpose: the only hosts available are
  the authenticated app (useless to someone without an account) or the
  guest ingress, which would turn a forwarded calendar entry into room
  admission.

  **Known deviation:** RFC 5546 §3.2.5 wants an `ORGANIZER` on a CANCEL.
  We knowingly omit it and compensate in the cancelled path with
  `STATUS:CANCELLED` plus an advanced `SEQUENCE`, which is what Google
  and Apple key on for a fetched (non-iTIP) feed.

  ## Line mechanics

  Content lines are joined with CRLF and the document ends with a
  trailing CRLF (RFC 5545 §3.1). Lines are folded at 75 **octets** with
  a CRLF plus a single leading space; the fold never splits a multi-byte
  UTF-8 sequence. `SUMMARY` is escaped per §3.3.11.
  """

  alias Platform.Meetings.Meeting

  @prodid "-//Burrow//Meetings//EN"
  @uid_prefix "meeting-"

  # RFC 5545 §3.1: octets, excluding the line break. A continuation line
  # spends one of its 75 on the leading space.
  @fold_limit 75

  @doc """
  The iCalendar UID for `meeting`.

  Derived from the meeting id alone — see the moduledoc on why nothing
  request-scoped may leak into it.
  """
  @spec uid(%Meeting{}) :: binary()
  def uid(%Meeting{id: id}) when is_binary(id), do: @uid_prefix <> id

  @doc """
  Render `meeting` as a single-`VEVENT` iCalendar document.

  Returns `{:error, :unscheduled}` when the intended-time pair is not
  fully present:

    * both nil — an ad-hoc meeting that was started but never scheduled.
      There is no intended time, so there is no event to publish, and
      synthesising one from `started_at` would put a *wrong* event on
      someone's calendar. This is not the cancellation case: nothing was
      ever published, so there is nothing to ghost.

    * start present, end nil — `Meeting.changeset/2` rejects this pair,
      but that is changeset-level only and not a DB check constraint, so
      direct SQL can still produce the row. Refusing it explicitly beats
      emitting a `DTSTART` with no `DTEND` (legal RFC, renders as a
      zero-length blip) or inventing a `DURATION` the author never chose.
  """
  @spec render(%Meeting{}) :: {:ok, binary()} | {:error, :unscheduled}
  def render(%Meeting{scheduled_start_at: nil}), do: {:error, :unscheduled}
  def render(%Meeting{scheduled_end_at: nil}), do: {:error, :unscheduled}

  def render(%Meeting{} = meeting) do
    # The three cancellation-sensitive properties are chosen together,
    # from one predicate, in one place. Scattering three separate
    # `if cancelled?` branches through the list is how a document ends up
    # saying CANCEL at the calendar level and CONFIRMED inside the event.
    #
    # UID is deliberately NOT in this tuple, and must never join it.
    {method, status, sequence} =
      if cancelled?(meeting) do
        {"CANCEL", "CANCELLED", "1"}
      else
        {"PUBLISH", "CONFIRMED", "0"}
      end

    document =
      [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:" <> @prodid,
        "CALSCALE:GREGORIAN",
        "METHOD:" <> method,
        "BEGIN:VEVENT",
        "UID:" <> uid(meeting),
        "DTSTAMP:" <> utc_stamp(meeting.updated_at),
        "DTSTART:" <> utc_stamp(meeting.scheduled_start_at),
        "DTEND:" <> utc_stamp(meeting.scheduled_end_at),
        "SUMMARY:" <> escape(meeting.name),
        "STATUS:" <> status,
        "SEQUENCE:" <> sequence,
        "TRANSP:OPAQUE",
        "END:VEVENT",
        "END:VCALENDAR"
      ]
      |> Enum.map(&[fold(&1), "\r\n"])
      |> IO.iodata_to_binary()

    {:ok, document}
  end

  # The ONE place the cancelled state is read. `status` is authoritative,
  # not `cancelled_at`: the two are the same statement (see the
  # cancellation migration), and keying on the timestamp would make a
  # row with a stamp and a non-cancelled status render a cancel.
  defp cancelled?(%Meeting{status: "cancelled"}), do: true
  defp cancelled?(%Meeting{}), do: false

  # RFC 5545 §3.3.5 form 2. An iCalendar DATE-TIME has no
  # fractional-second field at all, and `:utc_datetime_usec` carries
  # microseconds.
  #
  # MEASURED, not assumed: `DateTime.truncate/2` is **currently
  # unobservable** here. `%S` in the format string below renders the
  # second and nothing finer, so deleting the truncate leaves every
  # rendered byte identical — a mutation run for stage 2 removed it and
  # all 27 tests stayed green. It is kept as defence for the day someone
  # swaps this formatter for `DateTime.to_iso8601/1`, which *would* emit
  # `20260815T140000.123456Z`. Do not read its presence as something the
  # suite protects; what the suite pins is the rendered value.
  defp utc_stamp(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  # RFC 5545 §3.3.11 TEXT escaping. Backslash FIRST — escaping it after
  # the others would double-escape the backslashes this function itself
  # introduced.
  defp escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace(["\r\n", "\r", "\n"], "\\n")
  end

  # RFC 5545 §3.1 folding. The limit counts OCTETS, not characters and
  # not graphemes: a client unfolds by deleting the CRLF and the single
  # following space, so a fold that lands inside a multi-byte UTF-8
  # sequence yields a byte string that is no longer valid UTF-8 once
  # rejoined.
  defp fold(line) do
    case take_octets(line, @fold_limit) do
      {head, ""} -> head
      {head, rest} -> [head, "\r\n", fold_continuation(rest)]
    end
  end

  defp fold_continuation(rest) do
    case take_octets(rest, @fold_limit - 1) do
      {head, ""} -> [" ", head]
      {head, more} -> [" ", head, "\r\n", fold_continuation(more)]
    end
  end

  # Longest prefix of `binary` that fits in `limit` octets without
  # splitting a codepoint, plus the remainder.
  defp take_octets(binary, limit) when byte_size(binary) <= limit, do: {binary, ""}
  defp take_octets(binary, limit), do: take_octets(binary, limit, 0, [])

  defp take_octets(rest, limit, taken, acc) do
    case String.next_codepoint(rest) do
      nil ->
        {IO.iodata_to_binary(acc), ""}

      {codepoint, tail} ->
        size = byte_size(codepoint)

        if taken + size > limit do
          {IO.iodata_to_binary(acc), rest}
        else
          take_octets(tail, limit, taken + size, [acc, codepoint])
        end
    end
  end
end
