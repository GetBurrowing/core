defmodule PlatformWeb.InboxLive do
  @moduledoc """
  The Inbox surface — the "My Notifications" landing page at `/inbox`.

  It aggregates the things waiting on the viewer across Burrow as a live,
  sectioned, dismissable list, backed by `Platform.Inbox`:

    * **Awaiting your review** — `review_request_pending`, `task_plan_review`,
      `task_sponsor_assigned` (and any unknown/future kind, which defaults here)
    * **Mentions** — `chat_mention`, grouped by space
    * **Meetings** — `meeting_starting`, `meeting_invited`

  Each section auto-hides when it has no items; when every section is empty the
  surface falls back to the `EmptyState` `:minimal` copy.

  ## Live updates (chat_live pattern)

  `mount/3` subscribes to `Platform.Inbox.topic/1` (`inbox:<user_id>`) and
  loads the initial list via `load_items/1`, which is built on
  `Platform.Inbox.unread_scope/1`. The rail badge counts
  `Platform.Inbox.badge_scope/1`, which composes on that same query and adds
  `is_nil(read_at)`, so every counted row is listed and a listed row is counted
  only until it is opened. (It is emphatically not
  `Inbox.list_unread_for_user/2`; that function has no production caller at
  all. This sentence used to say otherwise, and a ticket was filed off the
  mistake.) Items are held in three streams — one per section — so a live insert/dismiss patches a
  single row without re-rendering its neighbours. A section's visibility is
  driven by an assign COUNT (not the stream), so a broadcast into a
  previously-empty section makes the section appear in the same diff that
  inserts the row.

    * `handle_info({:inbox_item_added, item}, socket)` →
      `stream_insert(stream, item, at: 0)` + bump that section's count.
    * `handle_event("dismiss", %{"id" => id}, socket)` →
      `Inbox.mark_dismissed/2` + `stream_delete_by_dom_id/3` + drop the count.
    * `handle_event("open", %{"id" => id, "url" => url}, socket)` →
      `Inbox.open_item/2` then `push_navigate` to the item's url. Opening an
      action row (`Inbox.action_kinds/0`) marks it read and it STAYS listed;
      opening any other row acknowledges it, which dismisses it. See "Read vs.
      dismissed" below.

  ## Bulk selection (task 01a00108 stage 2)

  Every row carries a checkbox; with ≥1 checked a pinned bar offers "Clear
  selected", which routes to `Inbox.dismiss_many/2` — one write, one broadcast,
  for the whole sweep. The shape is lifted from `PlatformWeb.RecoveryLive`,
  with one forced adaptation:

  Recovery keeps `:selected` as `id => row struct`, because it renders plain
  lists and can read the struct back off the socket. **Streams hold no
  server-side list**, so there is no struct here to hold. `:selected` is
  therefore `id => section` — the section is exactly what the bulk removal
  needs (which stream to `stream_delete_by_dom_id/3` from, which count to
  decrement) and it comes free off the `:item_sections` map that `dismiss`
  already maintains. The ids the sweep needs are the map's keys.

  `prune_selection/1` runs at the end of `init_sections/2` — the single place
  the three streams reset — so a selection held open across an `:inbox_changed`
  re-derive drops ids whose rows are gone rather than counting, and acting on,
  ghosts.

  ## Clear all, and why it ships with undo (task 01a00108 stage 3)

  The header carries a "Clear all (N)" that sweeps the whole unread scope via
  `Inbox.dismiss_all_unread/1` — not the rendered ids, not the selection. N comes
  from the three section counts, which are derived from that same scope, so the
  button names what it will clear.

  **The undo is load-bearing, not polish.** Dismissal is per-ROW and terminal:
  `Inbox`'s moduledoc states re-emitting the same
  `(user_id, source_type, source_id)` triple always inserts a FRESH row, with no
  dedup and no resurrection, and `emit/1` is a bare insert that backs that up. So
  a mis-clicked Clear all destroys the pointer to an unhandled review request and
  nothing in the system brings it back. A bare destructive button on a to-do list
  is the failure mode this guards.

  The idiom is `PlatformWeb.RecoveryLive`'s **act-then-confirm toast**, copied
  rather than reinvented: no pre-action confirm, a success toast afterwards
  carrying an Undo, auto-dismissed after `@toast_ttl_ms`.

  **The nonce is the non-obvious part.** `maybe_toast/2` mints a nonce, schedules
  `{:clear_toast, nonce}`, and stores it on the toast; the handler only clears on
  `%{nonce: ^nonce}`. Without it, two clears in quick succession let the FIRST
  clear's timer fire into the SECOND toast and silently truncate the user's undo
  window — the toast vanishes early and the rows are unrecoverable.

  Undo is `Inbox.restore_many/2` over the ids `dismiss_all_unread/1` reported
  changing. That list is precise by construction (the scope excludes dismissed
  rows, and `RETURNING` reports only rows the statement touched), so undo can
  never resurrect a row the user dismissed earlier and deliberately.

  Two properties worth stating rather than leaving to be discovered:

    * `dismissed_at` is a TIMESTAMP, not a flag, and undo sets it back to `nil` —
      the fact that the row was ever dismissed is destroyed. That is acceptable
      here and matches `mark_read`/`mark_dismissed`, which are equally lossy.
    * The undo lives in a socket assign, so it is PER-TAB and dies with the
      LiveView. Another tab repaints its badge from the DB off the broadcast but
      shows no Undo button. Every existing undo in this codebase behaves this way;
      there is deliberately no journal table and no timestamp-window heuristic.

  `dismiss_selected` raises the same toast — stage 2 stashed its changed ids for
  exactly this.

  ## Read vs. dismissed (task 01a00108 stage 4, then task 01a11703)

  The surface shows every non-dismissed row, read or not. Dismissal is the only
  "gone" verb — per-row (the X), by selection ("Clear selected"), wholesale
  ("Clear all"), and, since task `01a11703`, by OPENING any row whose kind is
  not in `Inbox.action_kinds/0`.

  Opening splits by kind:

    * an action row (`task_plan_review`, `review_request_pending`) is marked
      read. It stays listed, because the thing it asks for is still undone,
      and it leaves the badge, because the user has seen it. It leaves the list
      when its own resolution path dismisses it (the plan settles, the reviews
      resolve, or the reconciler confirms either) or when the user dismisses it.
    * every other row is acknowledged: `read_at` and `dismissed_at` are written
      together, so it leaves the list and the badge in one step.

  The badge therefore counts rows nobody has opened (`Inbox.badge_scope/1`),
  and the list holds what is still outstanding (`Inbox.unread_scope/1`).

  The history below explains why opening stopped being a clear in `01a00108`.
  `01a11703` restores it for the kinds where opening IS the whole job (a
  mention, a meeting notice, a sponsor note, a failed hook) and keeps the
  `01a00108` rule for the kinds that ask for a decision.

  This is a reversal, and the reasoning behind the old behaviour is worth
  keeping because it was not silly. It ran: an inbox that keeps showing things
  you have already opened is noise, and clicking through is a decent proxy for
  having handled it. The proxy is what failed. Once this surface is ruled a
  to-do list, reading and doing are different acts — plenty of items get opened,
  read, and left undone, and under the old rule those vanished from the only
  place recording that they were outstanding. The product lead's report ("I have to click
  each and every message to clear it out") is the same complaint from the other
  side: clicking was the ONLY clear, so clearing meant opening things you did
  not want to open.

  So reading was demoted and bulk dismissal (stages 2 and 3) put in its place.
  `read_at` now feeds the badge (`Inbox.badge_scope/1`).

  Migration `20260817120000_backfill_read_as_dismissed_inbox_items.exs` copied
  `read_at` into `dismissed_at` for every pre-existing row when this shipped,
  so nobody's history came back as a pile of new work on deploy day.

  ## The daily briefing, filter chips and the detail pane (task 01a15ee1 stage 4)

  `briefing` rows are not streamed: each renders through
  `PlatformWeb.Components.BriefingRow` above the sections, newest first,
  with its receipt line recomputed from `Briefings.view/2` counts on every
  load. Every re-derive (`{:inbox_changed, _}` and friends) goes through
  `init_sections/2`, so the counts refresh with the list.

  The chips (All / Briefing / Mentions / Tasks) live in the URL as `?f=`;
  `handle_params/3` reads it and re-derives, because a section that was not
  rendered has no stream rows left to show when it comes back. Briefing
  shows only briefing rows, Mentions the mentions section, Tasks the review
  section, All everything.

  `/inbox/briefing/:date` (`:briefing`) opens the viewer's own briefing for
  that date (`Briefings.for_user_on/2`, never another person's) in the
  detail pane, and marks its row read; the row stays listed. At `lg` and up
  the list is a 380px column beside the pane, which says "Select an item"
  on `/inbox`. Below `lg`, `/inbox` is the list alone and
  `/inbox/briefing/:date` is the detail alone, with a "‹ Inbox" back link.
  Stage 5 mounts the briefing's own component inside the pane.

  ## The briefing detail and its toast (task 01a15ee1 stage 5)

  `PlatformWeb.InboxLive.BriefingComponent` renders the day's briefing in
  the pane and sends every button to `Briefings.handle/5` / `undo/3`. On a
  success it sends `{:briefing_toast, toast}` here, and this LiveView raises
  its OWN toast (`maybe_toast/3`, variant `:briefing`, 5 s instead of 8 s):
  there is one toast mechanism on this page, not two. Its Undo
  (`undo_briefing`) is `Briefings.undo/3` with a Scope rebuilt from the user
  row, then `send_update/3` reloads the component.

  Pausing: the `ToastPause` hook pushes `toast_pause` while the toast is
  hovered or holds focus and `toast_resume` when it no longer does. A paused
  toast ignores its timer; resuming re-arms a fresh nonce for whatever was
  left of the window (at least `@toast_resume_floor_ms`). Every toast on the
  page pauses the same way.

  Every `{:inbox_changed, _}` bumps `:briefing_refresh`, which the
  component reads as "reload": a click on another tab, or a receipt written
  by the Insights tab, repaints the detail as well as the row.

  ## The meeting briefing (task 01a1694a stage 4)

  `meeting_briefing` rows are split out the same way `briefing` rows are,
  render through `PlatformWeb.Components.MeetingBriefingRow` under the
  Briefing chip, and count toward `:briefing_count`. Their briefings are
  read with `MeetingBriefings.list_for_attendee/2`, so a row only ever shows
  a briefing its viewer attended.

  `/inbox/meeting/:meeting_id` (`:meeting_briefing`) mounts
  `PlatformWeb.InboxLive.MeetingBriefingComponent` in the detail pane (full
  screen below lg, with the "‹ Inbox" back link) and marks the row read.
  The component loads only through `MeetingBriefings.get_for_attendee/2`.
  Every `{:inbox_changed, _}` `send_update/3`s it with `reload: true`: that
  is how B's open briefing repaints the item A just resolved.
  """

  use PlatformWeb, :live_view

  import Ecto.Query, only: [order_by: 3]
  import PlatformWeb.Components.BriefingRow, only: [briefing_row: 1]
  import PlatformWeb.Components.InboxItem, only: [inbox_item: 1]
  import PlatformWeb.Components.MeetingBriefingRow, only: [meeting_briefing_row: 1]
  import PlatformWeb.Components.NotificationState, only: [notification_state_row: 1]

  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Memory.Briefing
  alias Platform.Meetings.MeetingBriefings
  alias Platform.Memory.Insights.Briefings
  alias Platform.Repo
  alias PlatformWeb.Components.BriefingRow
  alias PlatformWeb.Components.MeetingBriefingRow
  alias PlatformWeb.MeetingLive.CalendarWindow

  @sections [:review, :mentions, :meetings]

  # The filter chips, in order: `?f=` value, label.
  @filters [
    {"all", "All"},
    {"briefing", "Briefing"},
    {"mentions", "Mentions"},
    {"tasks", "Tasks"}
  ]

  # How long the success toast lingers before it auto-dismisses — RecoveryLive's
  # value (`recovery_live.ex`), unchanged: long enough to read the count and
  # reach for Undo. The timer is nonce-guarded so an older sweep's timer can
  # never clear a newer sweep's toast.
  @toast_ttl_ms 8_000

  # The briefing detail's toast: 5 s, the prototype's window. It is a
  # shortcut, not the only way back: every receipt keeps its inverse for the
  # rest of the day (WCAG 2.2.1, direction canvas 01a15ee2 node states).
  @briefing_toast_ttl_ms 5_000

  # A resumed toast never comes back with less than this left to read.
  @toast_resume_floor_ms 1_500

  @impl true
  def mount(_params, session, socket) do
    user_id = session["current_user_id"] || current_user_id(socket)

    # NOTE: we deliberately do NOT subscribe to the inbox topic here. ShellLive
    # (the `on_mount` hook on every authenticated surface, this LV included)
    # already subscribes the LV process to `inbox:<user_id>` exactly once.
    # Subscribing again here delivered every `{:inbox_item_added}` twice to the
    # one process — the badge jumped +2 on `/inbox`. One subscribe per process;
    # our `handle_info/2` clauses below still receive every event.

    # The list itself is derived in handle_params/3 (it depends on `?f=` and
    # the live action), which always runs before the first render.
    {:ok,
     socket
     |> assign(:page_title, "Inbox")
     |> assign(:current_path, "/inbox")
     |> assign(:current_user_id, user_id)
     # Both must land BEFORE init_sections/2 — it ends in prune_selection/1,
     # which reads :selected.
     |> assign(:selected, %{})
     # The act-then-confirm toast: `nil`, or `%{message:, undo_ids:, nonce:}`,
     # plus `variant: :single` for the open-undo toast `open_undo_toast/2`
     # derives on connected mount.
     # It is the ONLY place the undo ids live — no persistence, no journal table.
     |> assign(:toast, nil)
     |> assign(:filter, "all")
     |> assign(:filters, @filters)
     |> assign(:detail_date, nil)
     |> assign(:meeting_detail_id, nil)
     |> assign(:briefing_refresh, 0)
     |> assign(:time_zone, viewer_time_zone(socket))
     |> maybe_toast(open_undo_toast(socket, user_id))}
  end

  # The viewer's IANA zone from the connect params (app.js sends it), for the
  # briefing row's "Today's" and its time. nil on the dead render, where
  # BriefingRow falls back to America/Chicago, the zone `digest_date` is
  # written in.
  defp viewer_time_zone(socket) do
    if connected?(socket),
      do: CalendarWindow.resolve_time_zone((get_connect_params(socket) || %{})["timezone"]),
      else: nil
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:filter, parse_filter(params["f"]))
      |> assign(:detail_date, detail_date(socket.assigns.live_action, params["date"]))
      |> assign(:meeting_detail_id, meeting_detail_id(socket.assigns.live_action, params))
      |> reload_sections()

    {:noreply, socket |> maybe_open_briefing() |> maybe_open_meeting_briefing()}
  end

  defp parse_filter(f) when f in ["briefing", "mentions", "tasks"], do: f
  defp parse_filter(_f), do: "all"

  defp detail_date(:briefing, iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      _ -> :invalid
    end
  end

  defp detail_date(:briefing, _iso), do: :invalid
  defp detail_date(_action, _iso), do: nil

  # The meeting id on `/inbox/meeting/:meeting_id`, as given: the component
  # answers "There's no briefing here." for anything it cannot load, a
  # malformed id included, so nothing is filtered here.
  defp meeting_detail_id(:meeting_briefing, %{"meeting_id" => id}) when is_binary(id), do: id
  defp meeting_detail_id(:meeting_briefing, _params), do: ""
  defp meeting_detail_id(_action, _params), do: nil

  # Opening a meeting briefing is reading it, exactly as for the daily
  # briefing: mark its row read (it stays listed). Connected only.
  defp maybe_open_meeting_briefing(socket) do
    user_id = socket.assigns.current_user_id
    meeting_id = socket.assigns.meeting_detail_id

    case Enum.find(socket.assigns.meeting_briefing_rows, &(&1.meeting_id == meeting_id)) do
      %{unread?: true, id: id} when is_binary(user_id) and is_binary(meeting_id) ->
        if connected?(socket) do
          Inbox.open_item(id, user_id)
          reload_sections(socket)
        else
          socket
        end

      _ ->
        socket
    end
  end

  # Opening the briefing's detail is reading it: mark its row read (it stays
  # listed, `briefing` being in `Inbox.action_kinds/0`). Connected only, so
  # the dead render of a GET writes nothing, and only while it is unread.
  defp maybe_open_briefing(socket) do
    user_id = socket.assigns.current_user_id

    case socket.assigns.briefing_detail do
      %{row: %{unread?: true, id: id}} when is_binary(user_id) ->
        if connected?(socket) do
          Inbox.open_item(id, user_id)
          reload_sections(socket)
        else
          socket
        end

      _ ->
        socket
    end
  end

  # Opening a non-action row dismisses it and navigates away, so the undo
  # cannot ride a socket assign across the navigation. Derive it from the DB on
  # the next connected mount instead (task `01a11703` stage 3). Accepted wart:
  # it is derived, so returning to /inbox twice inside the window shows it
  # twice — no table or ETS owner was added to suppress that.
  defp open_undo_toast(socket, user_id) when is_binary(user_id) do
    with true <- connected?(socket),
         %Item{} = item <- Inbox.last_dismissed_on_open(user_id) do
      %{message: ~s(Removed "#{item.title}"), undo_ids: [item.id], variant: :single}
    else
      _ -> nil
    end
  end

  defp open_undo_toast(_socket, _user_id), do: nil

  # ── Live inserts ───────────────────────────────────────────────────────

  @impl true
  def handle_info({:inbox_item_added, %Item{} = item}, socket) do
    # Defensive: a dismissed row never belongs in the live list. Every kind maps
    # to a real section (`section_for/1` is total), so there is no "unroutable"
    # case to drop.
    #
    # This test MUST mirror `Inbox.unread_scope/1` exactly — it is the same
    # membership question asked in Elixir instead of SQL, and the two answering
    # differently is precisely the #589/#592 drift. It dropped read rows until
    # stage 4 of task `01a00108` retired read-as-cleared; it no longer does,
    # because the scope no longer does. Move one, move both.
    cond do
      item.kind in ["briefing", "meeting_briefing"] ->
        # Briefing rows are not streamed; their receipt line is derived.
        {:noreply, reload_sections(socket)}

      is_nil(item.dismissed_at) ->
        section = section_for(item.kind)

        {:noreply,
         socket
         |> stream_insert(stream_name(section), decorate(item), at: 0)
         |> update_count(section, +1)
         |> track_section(item.id, section)
         |> merge_mention_labels(section, item)}

      true ->
        {:noreply, socket}
    end
  end

  # Silent-mutation + cross-surface events (a `mark_read`, a `dismiss_by_source`
  # rollup dismissal, a reconcile, or a dismissal originating on another tab)
  # don't map to a single streamed row we can patch, so re-derive the whole
  # list from `unread_scope/1`. `init_sections/2` resets the three streams, so
  # the rendered rows always equal exactly what the badge counts. This is the
  # unified source-of-truth: same scope, same diff.
  def handle_info({:inbox_changed, _user_id}, socket) do
    {:noreply,
     socket
     |> update(:briefing_refresh, &(&1 + 1))
     |> reload_sections()
     |> reload_meeting_briefing()}
  end

  # The briefing component's success toast (it runs in this process). The
  # same toast the list uses, at the briefing's 5 s.
  def handle_info({:briefing_toast, %{message: message} = toast}, socket) do
    {:noreply,
     maybe_toast(
       socket,
       %{
         message: message,
         variant: :briefing,
         undo?: Map.get(toast, :undo?, false),
         briefing: Map.take(toast, [:key, :briefing_id, :component_id])
       },
       @briefing_toast_ttl_ms
     )}
  end

  def handle_info({:inbox_item_dismissed, %Item{}}, socket),
    do: {:noreply, reload_sections(socket)}

  def handle_info({:inbox_item_read, %Item{}}, socket), do: {:noreply, reload_sections(socket)}

  # The toast's auto-dismiss timer. MUST match the nonce: `maybe_toast/2`
  # schedules one of these per sweep and never cancels the old one, so with two
  # clears inside `@toast_ttl_ms` the first sweep's timer is still in flight when
  # the second toast is on screen. An unguarded clause would let it fire into the
  # newer toast and cut the undo window short without a trace. Anything that is
  # not the CURRENT toast's nonce is a stale timer and is dropped.
  # MUST stay above the catch-all below.
  def handle_info({:clear_toast, nonce}, socket) do
    case socket.assigns.toast do
      # Paused (hovered or focused): the timer is spent, resume re-arms.
      %{nonce: ^nonce, paused: true} -> {:noreply, socket}
      %{nonce: ^nonce} -> {:noreply, assign(socket, :toast, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ── Events ─────────────────────────────────────────────────────────────

  @impl true
  def handle_event("dismiss", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user_id

    with true <- is_binary(user_id),
         {section, sections} when not is_nil(section) <-
           Map.pop(socket.assigns.item_sections, id) do
      Inbox.mark_dismissed(id, user_id)

      {:noreply,
       socket
       |> stream_delete_by_dom_id(stream_name(section), dom_id(id))
       |> update_count(section, -1)
       |> assign(:item_sections, sections)}
    else
      _ -> {:noreply, socket}
    end
  end

  # A briefing row's X. Briefing rows are not streamed, so this re-derives
  # rather than deleting a stream row. `mark_dismissed/2` is owner-scoped.
  def handle_event("dismiss_briefing", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user_id

    if is_binary(user_id) and Enum.any?(socket.assigns.briefing_rows, &(&1.id == id)) do
      Inbox.mark_dismissed(id, user_id)
    end

    {:noreply, reload_sections(socket)}
  end

  # A meeting briefing row's X, the same owner-scoped dismissal.
  def handle_event("dismiss_meeting_briefing", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user_id

    if is_binary(user_id) and Enum.any?(socket.assigns.meeting_briefing_rows, &(&1.id == id)) do
      Inbox.mark_dismissed(id, user_id)
    end

    {:noreply, reload_sections(socket)}
  end

  # ── Selection ──────────────────────────────────────────────────────────

  # The value stored is the row's SECTION, not the row — streams keep no
  # server-side list to read a struct from. A row not in `:item_sections` is
  # not on screen and cannot be selected.
  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected = socket.assigns.selected

    selected =
      if Map.has_key?(selected, id) do
        Map.delete(selected, id)
      else
        case Map.get(socket.assigns.item_sections, id) do
          nil -> selected
          section -> Map.put(selected, id, section)
        end
      end

    {:noreply, assign(socket, :selected, selected)}
  end

  # Deselect-all. This one has to RESET THE STREAMS, which the sibling events
  # do not: a streamed row only re-renders when it is re-inserted, so clearing
  # `:selected` alone would hide the bar while leaving every checkbox visibly
  # ticked in the DOM (the browser, not the server, drew those ticks). A
  # re-derive re-renders all three sections with `checked={false}`. Recovery
  # needs no such thing — it renders plain lists, so its checkboxes patch.
  def handle_event("clear_selection", _params, socket) do
    {:noreply, socket |> assign(:selected, %{}) |> reload_sections()}
  end

  # ── Bulk dismiss ───────────────────────────────────────────────────────

  # The product lead's ask, literally: clear a batch without opening each one.
  #
  # `dismiss_many/2` returns the ids it ACTUALLY changed, which is not always
  # every id asked for (a row dismissed on another tab in between is already
  # gone and is excluded). Drive the row removal off that returned list, never
  # off the selection, and stash it — stage 3 turns it into undo.
  def handle_event("dismiss_selected", _params, socket) do
    user_id = socket.assigns.current_user_id
    selected = socket.assigns.selected

    if is_binary(user_id) and selected != %{} do
      {:ok, dismissed_ids} = Inbox.dismiss_many(user_id, Map.keys(selected))

      {:noreply,
       socket
       |> remove_rows(dismissed_ids, selected)
       |> assign(:selected, %{})
       |> maybe_toast(build_toast(dismissed_ids))}
    else
      {:noreply, socket}
    end
  end

  # ── Clear all + undo ───────────────────────────────────────────────────

  # The pile-up path. The sweep is `dismiss_all_unread/1` — the whole unread
  # scope evaluated by Postgres inside the write — so it is neither the rendered
  # ids nor the selection, and a row that lands between the render and the click
  # is still cleared by a button that said "all".
  #
  # Then RE-DERIVE rather than patch rows off streams: `remove_rows/3` needs an
  # id => section map to know which stream and which count each row belongs to,
  # and a sweep of everything has no such map (the selection is empty). The
  # re-derive costs one query and leaves the three streams equal to the DB.
  #
  # The toast is raised from the RETURNED ids, not from the button's count. If
  # the two disagree the returned list is the one that is true, and it is also
  # the one undo has to be built from.
  def handle_event("clear_all", _params, socket) do
    user_id = socket.assigns.current_user_id

    if is_binary(user_id) do
      {:ok, dismissed_ids} = Inbox.dismiss_all_unread(user_id)

      {:noreply,
       socket
       |> assign(:selected, %{})
       |> reload_sections()
       |> maybe_toast(build_toast(dismissed_ids))}
    else
      {:noreply, socket}
    end
  end

  # The inverse, per RecoveryLive's `undo_restore`: apply the inverse over the
  # toast's refs, drop the toast, reload. `restore_many/2` broadcasts
  # `{:inbox_changed, user_id}` on its own, which is what repaints the rail
  # badge, the Dock icon and the document-title prefix on every mounted shell —
  # an undo that skipped the broadcast would leave those three showing 0.
  def handle_event("undo_clear", _params, socket) do
    user_id = socket.assigns.current_user_id
    ids = (socket.assigns.toast || %{}) |> Map.get(:undo_ids, [])

    if is_binary(user_id) and ids != [] do
      {:ok, _restored} = Inbox.restore_many(user_id, ids)
    end

    {:noreply, socket |> assign(:toast, nil) |> reload_sections()}
  end

  def handle_event("dismiss_toast", _params, socket), do: {:noreply, assign(socket, :toast, nil)}

  # The briefing toast's Undo: the receipt's inverse, `Briefings.undo/3`,
  # with the Scope rebuilt from the user row, then the component reloads.
  # The briefing is read by owner AND id, so a stale toast can only ever
  # undo its own person's item.
  def handle_event("undo_briefing", _params, socket) do
    user_id = socket.assigns.current_user_id

    with %{briefing: %{key: key, briefing_id: briefing_id} = ref} <- socket.assigns.toast,
         true <- is_binary(user_id),
         %Briefing{} = briefing <- Briefings.get_for_user(briefing_id, user_id) do
      scope = Platform.Access.Scope.for_user(Platform.Accounts.get_user(user_id))
      _ = Briefings.undo(briefing, key, scope)

      send_update(PlatformWeb.InboxLive.BriefingComponent,
        id: ref[:component_id] || "briefing-#{briefing_id}",
        reload: true
      )
    end

    {:noreply, assign(socket, :toast, nil)}
  end

  # The ToastPause hook: hover or focus inside the toast holds it open.
  def handle_event("toast_pause", _params, socket) do
    case socket.assigns.toast do
      %{paused: true} ->
        {:noreply, socket}

      %{deadline: deadline} = toast ->
        left = max(deadline - System.monotonic_time(:millisecond), 0)
        {:noreply, assign(socket, :toast, Map.merge(toast, %{paused: true, left: left}))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toast_resume", _params, socket) do
    case socket.assigns.toast do
      %{paused: true} = toast ->
        left = max(Map.get(toast, :left, 0), @toast_resume_floor_ms)
        {:noreply, maybe_toast(socket, Map.drop(toast, [:paused, :left, :nonce]), left)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open", %{"id" => id} = params, socket) do
    user_id = socket.assigns.current_user_id
    if is_binary(user_id), do: Inbox.open_item(id, user_id)

    case params["url"] do
      url when is_binary(url) and url != "" ->
        {:noreply, push_navigate(socket, to: url)}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Section wiring ─────────────────────────────────────────────────────

  # Partition the initial list into the three sections, configure a stream per
  # section, seed the per-section counts (which drive section visibility) and
  # the id → section map (which routes a dismiss to the right stream).
  defp init_sections(socket, items) do
    {briefings, items} = Enum.split_with(items, &(&1.kind == "briefing"))
    {meeting_briefings, items} = Enum.split_with(items, &(&1.kind == "meeting_briefing"))
    grouped = Enum.group_by(items, &section_for(&1.kind))
    review = Map.get(grouped, :review, [])
    mentions = grouped |> Map.get(:mentions, []) |> sort_mentions()
    meetings = Map.get(grouped, :meetings, [])

    socket
    |> stream(:review_items, Enum.map(review, &decorate/1), dom_id: &row_dom_id/1, reset: true)
    |> stream(:mention_items, Enum.map(mentions, &decorate/1), dom_id: &row_dom_id/1, reset: true)
    |> stream(:meeting_items, Enum.map(meetings, &decorate/1), dom_id: &row_dom_id/1, reset: true)
    |> assign(:review_count, length(review))
    |> assign(:mention_count, length(mentions))
    |> assign(:meeting_count, length(meetings))
    |> assign(:item_sections, section_map(items))
    |> assign(
      :mention_space_labels,
      resolve_mention_labels(mentions, socket.assigns.current_user_id)
    )
    |> assign_briefings(briefings)
    |> assign_meeting_briefings(meeting_briefings)
    |> prune_selection()
  end

  # ── Briefing rows + the detail pane ────────────────────────────────────

  # One row per undismissed `briefing` item, newest first (the list query's
  # order), each with its receipt line recomputed from the briefing's live
  # `Briefings.view/2` counts. The briefing rows are read by owner AND id,
  # so a row can only ever show its own person's briefing.
  defp assign_briefings(socket, items) do
    user_id = socket.assigns.current_user_id
    zone = socket.assigns[:time_zone]
    today = BriefingRow.today(zone)
    detail_date = socket.assigns[:detail_date]
    briefings = load_briefings(user_id, items)
    scope = is_binary(user_id) && Platform.Access.Scope.for_user(%{id: user_id})

    rows =
      for item <- items do
        briefing = Map.get(briefings, item.source_id)
        date = briefing && briefing.digest_date

        BriefingRow.assigns_for(item,
          counts: briefing && counts(briefing, scope),
          digest_date: date,
          today: today,
          time_zone: zone,
          selected: is_struct(date, Date) and date == detail_date
        )
      end

    socket
    |> assign(:briefing_today, today)
    |> assign(:briefing_rows, rows)
    |> assign(:briefing_count, length(rows))
    |> assign(:briefing_detail, briefing_detail(socket, detail_date, rows, scope, today))
  end

  defp load_briefings(user_id, items) when is_binary(user_id) and items != [] do
    items
    |> Enum.map(& &1.source_id)
    |> Briefings.list_for_user(user_id)
  end

  defp load_briefings(_user_id, _items), do: %{}

  defp counts(%Briefing{} = briefing, %Platform.Access.Scope{} = scope),
    do: Map.take(Briefings.view(briefing, scope).counts, [:total, :open, :calls])

  defp counts(_briefing, _scope), do: nil

  # The pane's content on `/inbox/briefing/:date`: nil on `/inbox`,
  # `:not_found` for a malformed date or a date with no briefing of the
  # viewer's own, else `%{date, row}` where `row` is the list row's slots
  # (built here when the row itself was dismissed or never listed).
  defp briefing_detail(_socket, nil, _rows, _scope, _today), do: nil
  defp briefing_detail(_socket, :invalid, _rows, _scope, _today), do: :not_found

  defp briefing_detail(socket, %Date{} = date, rows, scope, today) do
    user_id = socket.assigns.current_user_id

    case Briefings.for_user_on(user_id, date) do
      %Briefing{} = briefing ->
        row =
          Enum.find(rows, &(&1.date == date)) ||
            %{
              id: nil,
              unread?: false,
              title: BriefingRow.title(date, today),
              summary: BriefingRow.summary(counts(briefing, scope))
            }

        %{date: date, briefing_id: briefing.id, row: row}

      nil ->
        :not_found
    end
  end

  # ── Meeting briefing rows (task 01a1694a stage 4) ───────────────────────

  # One row per undismissed `meeting_briefing` item, each with its receipt
  # line from the briefing's live `MeetingBriefings.view/2` counts. They
  # count toward `:briefing_count` (they sit under the Briefing chip and in
  # Clear all), which `assign_briefings/2` has just set to the daily rows.
  defp assign_meeting_briefings(socket, items) do
    user_id = socket.assigns.current_user_id
    zone = socket.assigns[:time_zone]
    selected = socket.assigns[:meeting_detail_id]
    briefings = load_meeting_briefings(user_id, items)
    scope = is_binary(user_id) && Platform.Access.Scope.for_user(%{id: user_id})

    rows =
      for item <- items do
        briefing = Map.get(briefings, item.source_id)

        MeetingBriefingRow.assigns_for(item,
          counts: briefing && MeetingBriefings.view(briefing, scope).counts,
          ended_at: briefing && briefing.meeting.ended_at,
          time_zone: zone,
          selected: is_binary(selected) and MeetingBriefingRow.meeting_id(item.url) == selected
        )
      end

    socket
    |> assign(:meeting_briefing_rows, rows)
    |> update(:briefing_count, &(&1 + length(rows)))
  end

  defp load_meeting_briefings(user_id, items) when is_binary(user_id) and items != [],
    do: MeetingBriefings.list_for_attendee(Enum.map(items, & &1.source_id), user_id)

  defp load_meeting_briefings(_user_id, _items), do: %{}

  # The open meeting briefing re-reads on every `{:inbox_changed, _}`: a
  # receipt another attendee wrote reaches this viewer here.
  defp reload_meeting_briefing(socket) do
    case socket.assigns.meeting_detail_id do
      id when is_binary(id) ->
        send_update(PlatformWeb.InboxLive.MeetingBriefingComponent,
          id: meeting_briefing_component_id(id),
          reload: true
        )

        socket

      _ ->
        socket
    end
  end

  @doc "The detail component's id for `meeting_id`."
  def meeting_briefing_component_id(meeting_id), do: "meeting-briefing-" <> meeting_id

  @doc """
  The query string a chip, a row or the back link keeps: `""` for All,
  else `"?f=<filter>"`.
  """
  def filter_query("all"), do: ""
  def filter_query(filter) when is_binary(filter), do: "?f=" <> filter
  def filter_query(_filter), do: ""

  @doc "Whether `filter` shows `section` (`:briefing`, `:review`, `:mentions`, `:meetings`)."
  def shows?("all", _section), do: true
  def shows?("briefing", section), do: section == :briefing
  def shows?("mentions", section), do: section == :mentions
  def shows?("tasks", section), do: section == :review
  def shows?(_filter, _section), do: true

  @doc "Rows the current filter shows, for its empty state."
  def filtered_count(filter, counts) do
    Enum.sum(for {section, n} <- counts, shows?(filter, section), do: n)
  end

  # Drop selected ids whose row is no longer on screen. Every stream reset
  # funnels through init_sections/2, so this is the one place it has to run —
  # and it has to run AFTER `:item_sections` is reassigned above, since that
  # map is the definition of "still on screen".
  #
  # Without it a selection held open across an `{:inbox_changed, _}` re-derive
  # keeps counting rows that vanished, and "Clear selected" is aimed at ids
  # that are already gone.
  defp prune_selection(socket) do
    sections = socket.assigns.item_sections

    selected =
      socket.assigns
      |> Map.get(:selected, %{})
      |> Enum.flat_map(fn {id, _section} ->
        case Map.get(sections, id) do
          nil -> []
          section -> [{id, section}]
        end
      end)
      |> Map.new()

    assign(socket, :selected, selected)
  end

  # Take a batch of dismissed rows off their streams. `stream_delete` alone
  # would leave an emptied section's header rendered — visibility is driven by
  # the count assigns — so each removal decrements its section too.
  defp remove_rows(socket, ids, selected) do
    Enum.reduce(ids, socket, fn id, acc ->
      case Map.get(selected, id) do
        nil ->
          acc

        section ->
          acc
          |> stream_delete_by_dom_id(stream_name(section), dom_id(id))
          |> update_count(section, -1)
          |> assign(:item_sections, Map.delete(acc.assigns.item_sections, id))
      end
    end)
  end

  # ── Toast ──────────────────────────────────────────────────────────────

  # A sweep that changed nothing raises no toast — there is nothing to undo and
  # nothing to report.
  defp build_toast([]), do: nil

  defp build_toast(ids) do
    n = length(ids)
    %{message: "#{n} #{pluralize(n, "notification")} cleared", undo_ids: ids}
  end

  defp maybe_toast(socket, toast, ttl_ms \\ @toast_ttl_ms)
  defp maybe_toast(socket, nil, _ttl_ms), do: socket

  # Mint a nonce, schedule the auto-dismiss against it, and carry it ON the
  # toast. The handler compares the two, which is the whole guard — see the
  # `{:clear_toast, nonce}` clause. Copied from RecoveryLive's `maybe_toast/2`.
  # `deadline` (monotonic ms) is what a pause reads the time left from.
  defp maybe_toast(socket, toast, ttl_ms) do
    nonce = System.unique_integer([:positive])
    Process.send_after(self(), {:clear_toast, nonce}, ttl_ms)
    deadline = System.monotonic_time(:millisecond) + ttl_ms
    assign(socket, :toast, Map.merge(toast, %{nonce: nonce, deadline: deadline}))
  end

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  @doc """
  How many rows "Clear all" would clear, for the button's label.

  The three section counts are derived from `unread_scope/1` at load, and
  `Inbox.dismiss_all_unread/1` writes over that same scope — so the number on
  the button is the number the button clears. Public so the template can call it.
  The briefing rows (task 01a15ee1 stage 4) are in that scope too, so their
  count is the fourth argument: the sweep clears them as well.

  Takes the counts rather than `assigns` so HEEx change-tracking still
  sees which assigns the label depends on.
  """
  def clearable_count(review_count, mention_count, meeting_count, briefing_count \\ 0) do
    review_count + mention_count + meeting_count + briefing_count
  end

  # Mentions are sorted by space then recency so same-space rows sit together
  # (the "grouped by space" cue), while the freshest space floats up.
  defp sort_mentions(mentions) do
    Enum.sort_by(
      mentions,
      &{mention_space_key(&1), -DateTime.to_unix(&1.inserted_at, :microsecond)}
    )
  end

  defp section_map(items) do
    for item <- items, into: %{}, do: {item.id, section_for(item.kind)}
  end

  defp track_section(socket, id, section) do
    assign(socket, :item_sections, Map.put(socket.assigns.item_sections, id, section))
  end

  defp update_count(socket, :review, delta),
    do: assign(socket, :review_count, max(socket.assigns.review_count + delta, 0))

  defp update_count(socket, :mentions, delta),
    do: assign(socket, :mention_count, max(socket.assigns.mention_count + delta, 0))

  defp update_count(socket, :meetings, delta),
    do: assign(socket, :meeting_count, max(socket.assigns.meeting_count + delta, 0))

  defp section_for(kind)
       when kind in ~w(review_request_pending task_plan_review task_sponsor_assigned),
       do: :review

  defp section_for("chat_mention"), do: :mentions
  defp section_for("meeting_starting"), do: :meetings
  # MUST sit above the catch-all. Without this clause an invite still renders
  # perfectly well — filed under "Awaiting your review" next to plan reviews —
  # so the typed kind would exist and still not be groupable as an invite.
  defp section_for("meeting_invited"), do: :meetings
  # Unknown/future kinds route to :review — a real, rendered section with a
  # stream, count and template — rather than a nil section that streams into no
  # `phx-update` container and silently vanishes. `InboxItem.kind_label/1` +
  # `kind_icon/1` have generic fallbacks, so any routed kind renders. Adding a
  # new section atom instead would require wiring init_sections + stream setup +
  # stream_name/1 + a count assign + the template, so reuse :review.
  defp section_for(_), do: :review

  defp stream_name(:review), do: :review_items
  defp stream_name(:mentions), do: :mention_items
  defp stream_name(:meetings), do: :meeting_items

  # ── Item decoration + dom ids ──────────────────────────────────────────

  # Identity today — streams carry the raw `Item` struct and the template
  # derives the mention space label from it. `decorate/1` is the seam to attach
  # per-row view state to a streamed item if that need ever grows.
  defp decorate(%Item{} = item), do: item

  defp row_dom_id(%Item{id: id}), do: dom_id(id)
  defp dom_id(id), do: "inbox-item-#{id}"

  @doc """
  The mention grouping/label key — the chat space slug parsed from the item's
  `/chat/<slug>` url. Falls back to the whole url, then to "". Public so the
  template and tests can render/assert the same label.
  """
  def mention_space_key(%Item{url: url}) when is_binary(url) do
    case Regex.run(~r{^/chat/([^/?#]+)}, url) do
      [_, slug] -> slug
      _ -> url
    end
  end

  def mention_space_key(_), do: ""

  @doc """
  Human-facing space label for a mention row, or nil when the row carries no
  usable url.

  Reads a PRE-RESOLVED `segment => label` map (the `:mention_space_labels`
  assign) rather than hitting the DB, so a stream re-render costs no queries
  and the label is resolved exactly once per distinct space per load.

  Falls back to `#<segment>` — today's behaviour byte-for-byte — when the
  segment does not resolve (space deleted, or a legacy row). The fallback is
  why the grouping key stays the raw segment: `sort_mentions/1` groups on
  identity, not on presentation, so a space that loses its label still groups
  with its siblings.

  Task 019fabe8 stage 4: `space_path_segment/1` now emits a UUID for org-scoped
  and slug-less spaces, and `#<uuid>` is not a label a human can read.
  """
  def mention_space_label(%Item{} = item, labels \\ %{}) do
    case mention_space_key(item) do
      "" ->
        nil

      key ->
        case Map.get(labels, key) do
          label when is_binary(label) and label != "" -> label
          _ -> "#" <> key
        end
    end
  end

  # Resolve every distinct space segment in the mention rows to a display name,
  # once. DM/group labels are viewer-relative (the PEER's name), hence the
  # `user_id` — `Chat.display_name_for_space/3` is the same helper the chat
  # sidebar and header already render from, so the inbox row and the
  # destination header agree.
  #
  # Channels keep the `#` prefix the inbox has always shown; DM/group labels do
  # not get one (a person's name is not a channel). Unresolvable segments are
  # simply absent from the map and `mention_space_label/2` falls back.
  defp resolve_mention_labels(mentions, user_id) do
    mentions
    |> Enum.map(&mention_space_key/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn segment, acc ->
      case space_display_label(segment, user_id) do
        nil -> acc
        label -> Map.put(acc, segment, label)
      end
    end)
  end

  defp space_display_label(segment, user_id) do
    case Chat.space_for_path_segment(segment) do
      nil ->
        nil

      space ->
        name = Chat.display_name_for_space(space, Chat.list_participants(space.id), user_id)

        cond do
          not is_binary(name) or name == "" -> nil
          space.kind == "channel" -> "#" <> name
          true -> name
        end
    end
  end

  # A live insert can introduce a space the initial load never saw. Merge just
  # that one segment instead of re-resolving the whole map.
  defp merge_mention_labels(socket, :mentions, %Item{} = item) do
    key = mention_space_key(item)
    labels = socket.assigns[:mention_space_labels] || %{}

    if key == "" or Map.has_key?(labels, key) do
      socket
    else
      case space_display_label(key, socket.assigns.current_user_id) do
        nil -> socket
        label -> assign(socket, :mention_space_labels, Map.put(labels, key, label))
      end
    end
  end

  defp merge_mention_labels(socket, _section, _item), do: socket

  # ── Internals ──────────────────────────────────────────────────────────

  # THE list source of truth: the same `unread_scope/1` the badge COUNT builds
  # on, ordered newest-first. The old `list_unread_for_user + Enum.reject(read)`
  # two-step let the read filter live in Elixir while the badge filtered in SQL
  # — the two drifted (#589/#592). Now both are one query, which is also what
  # let stage 4 move the meaning of "cleared" without reopening that drift. A
  # lazy reconcile runs first so a stale review row (task's reviews all
  # resolved) is dismissed before it's ever selected.
  defp load_items(user_id) do
    Inbox.reconcile_for_user(user_id)

    user_id
    |> Inbox.reachable_unread_scope(
      Platform.Tenancy.external_user?(%{id: user_id}),
      Platform.Access.Scope.for_user(%{id: user_id})
    )
    |> order_by([i], desc: i.inserted_at)
    |> Repo.all()
  end

  # Re-derive all three section streams from the DB (used by the coarse
  # re-derive handle_info clauses above).
  defp reload_sections(socket) do
    user_id = socket.assigns.current_user_id
    items = if is_binary(user_id), do: load_items(user_id), else: []
    init_sections(socket, items)
  end

  defp current_user_id(socket) do
    case socket.assigns[:current_user_record] || socket.assigns[:current_user] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  @doc false
  def sections, do: @sections
end
