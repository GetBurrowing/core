defmodule PlatformWeb.InboxLive do
  @moduledoc """
  The Inbox surface — the "My Notifications" landing page at `/inbox`.

  It aggregates the things waiting on the viewer across Suite as a live,
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
  place recording that they were outstanding. Harper's report ("I have to click
  each and every message to clear it out") is the same complaint from the other
  side: clicking was the ONLY clear, so clearing meant opening things you did
  not want to open.

  So reading was demoted and bulk dismissal (stages 2 and 3) put in its place.
  `read_at` now feeds the badge (`Inbox.badge_scope/1`).

  Migration `20260817120000_backfill_read_as_dismissed_inbox_items.exs` copied
  `read_at` into `dismissed_at` for every pre-existing row when this shipped,
  so nobody's history came back as a pile of new work on deploy day.
  """

  use PlatformWeb, :live_view

  import Ecto.Query, only: [order_by: 3]
  import PlatformWeb.Components.InboxItem, only: [inbox_item: 1]
  import PlatformWeb.Components.NotificationState, only: [notification_state_row: 1]

  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  @sections [:review, :mentions, :meetings]

  # How long the success toast lingers before it auto-dismisses — RecoveryLive's
  # value (`recovery_live.ex`), unchanged: long enough to read the count and
  # reach for Undo. The timer is nonce-guarded so an older sweep's timer can
  # never clear a newer sweep's toast.
  @toast_ttl_ms 8_000

  @impl true
  def mount(_params, session, socket) do
    user_id = session["current_user_id"] || current_user_id(socket)

    # NOTE: we deliberately do NOT subscribe to the inbox topic here. ShellLive
    # (the `on_mount` hook on every authenticated surface, this LV included)
    # already subscribes the LV process to `inbox:<user_id>` exactly once.
    # Subscribing again here delivered every `{:inbox_item_added}` twice to the
    # one process — the badge jumped +2 on `/inbox`. One subscribe per process;
    # our `handle_info/2` clauses below still receive every event.

    items = if is_binary(user_id), do: load_items(user_id), else: []

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
     |> init_sections(items)
     |> maybe_toast(open_undo_toast(socket, user_id))}
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
    if is_nil(item.dismissed_at) do
      section = section_for(item.kind)

      {:noreply,
       socket
       |> stream_insert(stream_name(section), decorate(item), at: 0)
       |> update_count(section, +1)
       |> track_section(item.id, section)
       |> merge_mention_labels(section, item)}
    else
      {:noreply, socket}
    end
  end

  # Silent-mutation + cross-surface events (a `mark_read`, a `dismiss_by_source`
  # rollup dismissal, a reconcile, or a dismissal originating on another tab)
  # don't map to a single streamed row we can patch, so re-derive the whole
  # list from `unread_scope/1`. `init_sections/2` resets the three streams, so
  # the rendered rows always equal exactly what the badge counts. This is the
  # unified source-of-truth: same scope, same diff.
  def handle_info({:inbox_changed, _user_id}, socket), do: {:noreply, reload_sections(socket)}

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

  # Harper's ask, literally: clear a batch without opening each one.
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
    |> prune_selection()
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

  defp maybe_toast(socket, nil), do: socket

  # Mint a nonce, schedule the auto-dismiss against it, and carry it ON the
  # toast. The handler compares the two, which is the whole guard — see the
  # `{:clear_toast, nonce}` clause. Copied from RecoveryLive's `maybe_toast/2`.
  defp maybe_toast(socket, toast) do
    nonce = System.unique_integer([:positive])
    Process.send_after(self(), {:clear_toast, nonce}, @toast_ttl_ms)
    assign(socket, :toast, Map.put(toast, :nonce, nonce))
  end

  defp pluralize(1, word), do: word
  defp pluralize(_n, word), do: word <> "s"

  @doc """
  How many rows "Clear all" would clear, for the button's label.

  The three section counts are derived from `unread_scope/1` at load, and
  `Inbox.dismiss_all_unread/1` writes over that same scope — so the number on
  the button is the number the button clears. Public so the template can call it.

  Takes the three counts rather than `assigns` so HEEx change-tracking still
  sees which assigns the label depends on.
  """
  def clearable_count(review_count, mention_count, meeting_count) do
    review_count + mention_count + meeting_count
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
    |> Inbox.unread_scope()
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
