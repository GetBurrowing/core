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

  The invitee rows and the `Add people` row landed in stage 5 of task
  019fb955-1d7b — they are `InviteControl`'s `:live` mode, hosted inside
  `meeting_detail_body/1` because they are precisely the content that
  grows. The red `Cancel meeting` action the canvas draws in the footer is
  still absent: `Meetings.cancel_meeting/2` and the `"cancelled"` status
  belong to the archive member, and rendering its control from here would
  collide.

  There is deliberately no REVOKE control on any row. See
  `PlatformWeb.Components.Meetings.InviteControl`'s moduledoc for why —
  short version, `recipients_for_meeting/1` falls back to chat
  participants when the live invite list is empty, so revoking the last
  invitee WIDENS the notified audience. The canvas draws none either.

  ## The invited count is the list's own header

  There is one count on this surface and it is `invite_list/1`'s
  `Invited · N`, which counts the rows the reader can see. The chip that
  used to sit beside the status tag counted `list_invites/2` instead, and
  the two numbers legitimately differ — the producer agent is a rendered
  row and is not a `meeting_invites` row. Two numbers a reader cannot
  reconcile is worse than one, and the canvas draws one.

  ## DOM contract

  Every assertable element carries a `data-role` in the
  `meeting-detail-*` namespace. Tests key on those, never on a Tailwind
  class.
  """

  use PlatformWeb, :html

  import PlatformWeb.Components.Meetings.InviteControl,
    only: [invite_control: 1, invite_list: 1]

  alias Platform.Meetings.CalendarLink
  alias Platform.Meetings.Meeting

  @doc """
  The scrolling half of the detail surface: name, local time range,
  status, the invitee list with its `Add people` row, and the
  calendar-subscription link.

  `@id_prefix` is what keeps the panel and the sheet from colliding. Both
  render this component in the same document, and the copy control carries
  a `phx-hook` — which LiveView keys by DOM id — so the two surfaces have
  to namespace theirs. It is required rather than defaulted for exactly
  that reason: a caller that forgets it would silently ship one working
  copy button and one dead one.

  `@invite_open` gates the search box the `Add people` row expands. It is
  the CALLER's assign rather than component state because both surfaces
  read it, and a component owning it would have to be told which of the
  two it was standing in for.
  """
  attr(:meeting, Meeting, required: true)
  attr(:time_zone, :string, required: true)
  attr(:invite_entries, :list, required: true)
  attr(:id_prefix, :string, required: true)
  attr(:invite_open, :boolean, required: true)
  attr(:invite_query, :string, required: true)
  attr(:invite_candidates, :list, required: true)
  attr(:invite_email_option, :string, default: nil)

  def meeting_detail_body(assigns) do
    ~H"""
    <div class="flex flex-col gap-3" data-role="meeting-detail-body-content">
      <h3 class="text-base font-semibold leading-snug" data-role="meeting-detail-name">
        {@meeting.name}
      </h3>

      <div
        class="flex items-center gap-2 text-sm text-subtle"
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
      </div>

      <%!-- The invitee list, and the reason this whole surface is a
         cap-and-clip flex column: it is the one region that grows with
         the meeting rather than with the schema. It sits INSIDE the
         scrolling body — never between the body and the action row —
         so however many people are invited, `Open meeting` stays put.

         `Add people` is the last row of the list and there is no invite
         control in any toolbar, deliberately: a meeting-wide invite
         affordance is how a forwardable link gets minted, and a
         forwardable link destroys transcript attribution. Every invite
         here is minted per person. --%>
      <.invite_list mode={:live} entries={@invite_entries} id_prefix={@id_prefix} />

      <%!-- `dropdown={:inline}` is load-bearing here, not stylistic. This
         body is the surface's single scroll region and this control is at
         the end of it, so a FLOATING dropdown is clipped by the panel's
         `overflow-hidden` cap with its second option unreachable at any
         scroll position — measured at 1440x900. In flow it lengthens the
         body and the body scrolls to it. --%>
      <div :if={@invite_open} data-role="meeting-detail-invite-expansion">
        <.invite_control
          mode={:live}
          id={"#{@id_prefix}-control"}
          query={@invite_query}
          candidates={@invite_candidates}
          email_option={@invite_email_option}
          dropdown={:inline}
        />
      </div>

      <%!-- A LINK, never a download of a snapshot: the endpoint re-renders
         from the row on every fetch, so a moved meeting corrects itself in
         the subscriber's calendar. `show/2` requires BOTH the raw id in the
         path AND a matching signed token, so the bare id is a 404 — the
         token is not decoration. --%>
      <.link
        href={ics_path(@meeting)}
        data-role="meeting-detail-ics"
        class="flex min-h-11 items-center gap-2 rounded-lg border border-edge px-3 text-sm hover:border-primary hover:text-primary"
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

  # `invited_label/1` lived here until task 019fb955-1d7b stage 5. It
  # rendered the count chip this surface no longer draws — the invitee
  # list's own `Invited · N` header is the single count now — so it had no
  # caller left. Deleted rather than kept "in case": a helper nothing calls
  # is a claim nothing checks.

  # `secondary` is absent on purpose: in this theme `--color-secondary` is
  # a grey chromatically indistinguishable from `--chip-neutral`, so a
  # status rendered in it would stop being told apart by colour at all.
  defp status_tone("live"), do: "success"
  defp status_tone("cancelled"), do: "error"
  defp status_tone("ended"), do: "neutral"
  defp status_tone("scheduled"), do: "info"
end
