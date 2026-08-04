defmodule PlatformWeb.Components.Meetings.MeetingDetail do
  @moduledoc """
  The contents of the meeting DETAIL surface — the desktop right-rail
  panel (canvas frame 1) and the mobile bottom sheet (mobile frame 2) —
  as function components shared by both.

  ## Why a shared component rather than two blocks of markup

  The two surfaces are the same information at two widths. Written twice
  in `meeting_live.html.heex` they would drift the first time a field is
  added to one of them, and nothing would fail: a test that reads the
  panel passes while the sheet quietly lacks the row. Rendering both from
  here makes "the sheet shows what the panel shows" structurally true
  instead of a thing someone has to remember.

  ## Two components, not one

  `meeting_detail_body/1` is what SCROLLS; `meeting_detail_actions/1` is
  what stays PINNED. They are separate for a layout reason, not a
  stylistic one — see the geometry section below — and both are used by
  both surfaces, so the no-drift property is unaffected by the split.

  ## Geometry: the panel clips, the body scrolls

  The create sheet shipped as one scroll region (`max-h-[75vh]
  overflow-y-auto` on the panel) and the sponsor rejected it: a long
  staged-invite list carried the footer bar off the bottom of the modal.
  This surface has the same shape and a stronger version of the same
  risk, because the per-invitee rows that will fill
  `meeting_detail_body/1` grow with the meeting's guest list.

  So the panel and the sheet are capped flex COLUMNS that clip
  (`overflow-hidden`), `meeting_detail_body/1`'s host is the single
  scrolling child (`flex-1 min-h-0 overflow-y-auto`), and
  `meeting_detail_actions/1`'s host is a `flex-none` SIBLING of it.
  `min-h-0` is load-bearing: a flex child defaults to
  `min-height: auto` and refuses to shrink below its content,
  so without it the body never scrolls and the footer is pushed out
  again even though the panel is a flex column.

  ## Zone: there is no `nil` clause, deliberately

  `when_label/2` requires a resolved zone and an intended time. Neither
  is a defensive omission:

    * With no zone `MeetingLive` loads NO week meetings, so nothing is
      selectable and this surface never renders. A `nil` clause here
      could only ever render server time labelled as the viewer's, which
      is the confident-wrong-answer the calendar already refuses at
      `data-role="calendar-timezone"`.
    * A meeting with no `scheduled_start_at` is never placed in the grid
      either (`CalendarWindow.place/4` skips it), so it cannot be the
      selection.

  Both are therefore unreachable states, and a `FunctionClauseError`
  naming the shape is a better answer than a rendered guess.

  ## Scope

  The canvas also draws per-invitee rows, an `Add people` row and a red
  `Cancel meeting` action on this surface. None are here: the invitee
  rows and `Add people` belong to `InviteControl`'s `:live` mode and land
  with the create+invite member, and cancellation is the archive member's
  affordance. `meeting_detail_body/1` and `meeting_detail_actions/1` are
  the hosts they will land in.

  ## DOM contract

  Every assertable element carries a `data-role` in the
  `meeting-detail-*` namespace. Tests key on those, never on a Tailwind
  class.
  """

  use PlatformWeb, :html

  alias Platform.Meetings.CalendarLink
  alias Platform.Meetings.Meeting

  @doc """
  The scrolling half of the detail surface: name, local time range,
  status, invited count, and the calendar-subscription link.
  """
  attr(:meeting, Meeting, required: true)
  attr(:time_zone, :string, required: true)
  attr(:invited_count, :integer, required: true)

  def meeting_detail_body(assigns) do
    ~H"""
    <div class="flex flex-col gap-3" data-role="meeting-detail-body-content">
      <h3 class="text-base font-semibold leading-snug" data-role="meeting-detail-name">
        {@meeting.name}
      </h3>

      <div
        class="flex items-center gap-2 text-sm text-base-content/70"
        data-role="meeting-detail-when"
      >
        <span class="hero-clock size-4 flex-shrink-0" aria-hidden="true"></span>
        <span>{when_label(@meeting, @time_zone)}</span>
      </div>

      <div class="flex flex-wrap items-center gap-2">
        <.chip
          tone={status_tone(@meeting.status)}
          class="font-mono text-[10px]"
          data-role="meeting-detail-status"
          data-status={@meeting.status}
        >
          {@meeting.status}
        </.chip>

        <span
          class="inline-flex items-center gap-1.5 text-xs text-base-content/60"
          data-role="meeting-detail-invited-count"
          data-count={@invited_count}
        >
          <span class="hero-user-group size-3.5 flex-shrink-0" aria-hidden="true"></span>
          {invited_label(@invited_count)}
        </span>
      </div>

      <%!-- A LINK, never a download of a snapshot: the endpoint re-renders
         from the row on every fetch, so a moved meeting corrects itself in
         the subscriber's calendar. `show/2` requires BOTH the raw id in the
         path AND a matching signed token, so the bare id is a 404 — the
         token is not decoration. --%>
      <.link
        href={ics_path(@meeting)}
        data-role="meeting-detail-ics"
        class="flex min-h-11 items-center gap-2 rounded-lg border border-base-300 px-3 text-sm hover:border-primary hover:text-primary"
      >
        <span class="hero-calendar-days size-4 flex-shrink-0" aria-hidden="true"></span>
        <span class="flex-1 truncate">Add to calendar</span>
        <span class="hero-arrow-down-tray size-4 flex-shrink-0" aria-hidden="true"></span>
      </.link>
    </div>
    """
  end

  @doc """
  The pinned half: the action row that must stay reachable however long
  the body grows.

  This is the only path from the meetings index to a meeting page at any
  width — the calendar grid and the mobile day view both SELECT rather
  than navigate — so it is exactly the control that must not be able to
  scroll out of view.
  """
  attr(:meeting, Meeting, required: true)

  def meeting_detail_actions(assigns) do
    ~H"""
    <.link
      navigate={~p"/meetings/#{@meeting.slug}"}
      data-role="meeting-detail-open"
      class="btn btn-primary btn-sm min-h-11 w-full gap-1.5"
    >
      <span class="hero-arrow-top-right-on-square size-4 flex-shrink-0" aria-hidden="true"></span>
      <span>Open meeting</span>
    </.link>
    """
  end

  @doc """
  The signed calendar-feed URL for `meeting`.

  Both halves are required by `MeetingCalendarController.show/2` — the
  raw id in the path names the row, the token authorises reading it —
  and a path missing either is a 404.
  """
  @spec ics_path(Meeting.t()) :: String.t()
  def ics_path(%Meeting{id: id}),
    do: ~p"/meetings/#{id}/invite.ics?token=#{CalendarLink.sign(id)}"

  @doc """
  A meeting's local date and time range — `Wed Aug 5 · 2:00–3:00 PM`.

  Rendered SERVER-SIDE in the resolved zone rather than by the
  `LocalTime` hook, so this string and the grid cell the meeting was
  selected from can never disagree about which day it is.

  The meridiem is printed ONCE when both ends share it and twice when
  they do not (`11:30 AM–12:30 PM`), which is the only case where one
  would be ambiguous.

  Punctuation follows the conventions this template already sets rather
  than the stage text's ASCII: `·` joins the date to the range (as in
  `data-role="calendar-day-heading"`) and `–`, the typographic range
  mark, spans it (as in `calendar_week_label/1`). The stage text's
  `Wed Aug 5 - 2:00-3:00 PM` spells two different relationships with the
  same hyphen.
  """
  @spec when_label(Meeting.t(), String.t()) :: String.t()
  def when_label(
        %Meeting{
          scheduled_start_at: %DateTime{} = start_at,
          scheduled_end_at: %DateTime{} = end_at
        },
        time_zone
      )
      when is_binary(time_zone) do
    local_start = DateTime.shift_zone!(start_at, time_zone)
    local_end = DateTime.shift_zone!(end_at, time_zone)

    start_meridiem = Calendar.strftime(local_start, "%p")
    end_meridiem = Calendar.strftime(local_end, "%p")

    start_clock =
      if start_meridiem == end_meridiem,
        do: clock(local_start),
        else: clock(local_start) <> " " <> start_meridiem

    "#{Calendar.strftime(local_start, "%a %b %-d")} · " <>
      "#{start_clock}–#{clock(local_end)} #{end_meridiem}"
  end

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%-I:%M")

  @doc """
  The invited-count line — the set of people who currently hold an
  invite, so a revoked row is not one of them.
  """
  @spec invited_label(non_neg_integer()) :: String.t()
  def invited_label(0), do: "No invites"
  def invited_label(1), do: "1 invited"
  def invited_label(count) when is_integer(count) and count > 1, do: "#{count} invited"

  # `secondary` is absent on purpose: in this theme `--color-secondary` is
  # a grey chromatically indistinguishable from `--chip-neutral`, so a
  # status rendered in it would stop being told apart by colour at all.
  defp status_tone("live"), do: "success"
  defp status_tone("cancelled"), do: "error"
  defp status_tone("ended"), do: "neutral"
  defp status_tone("scheduled"), do: "info"
end
