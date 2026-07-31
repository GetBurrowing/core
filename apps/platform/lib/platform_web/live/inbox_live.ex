defmodule PlatformWeb.InboxLive do
  @moduledoc """
  The Inbox surface — the "My Notifications" landing page at `/inbox`.

  It aggregates the things waiting on the viewer across Suite as a live,
  sectioned, dismissable list, backed by `Platform.Inbox`:

    * **Awaiting your review** — `review_request_pending`, `task_plan_review`,
      `task_sponsor_assigned` (and any unknown/future kind, which defaults here)
    * **Mentions** — `chat_mention`, grouped by space
    * **Meetings** — `meeting_starting`

  Each section auto-hides when it has no items; when every section is empty the
  surface falls back to the `EmptyState` `:minimal` copy.

  ## Live updates (chat_live pattern)

  `mount/3` subscribes to `Platform.Inbox.topic/1` (`inbox:<user_id>`) and
  loads the initial list via `Platform.Inbox.list_unread_for_user/2`. Items are
  held in three streams — one per section — so a live insert/dismiss patches a
  single row without re-rendering its neighbours. A section's visibility is
  driven by an assign COUNT (not the stream), so a broadcast into a
  previously-empty section makes the section appear in the same diff that
  inserts the row.

    * `handle_info({:inbox_item_added, item}, socket)` →
      `stream_insert(stream, item, at: 0)` + bump that section's count.
    * `handle_event("dismiss", %{"id" => id}, socket)` →
      `Inbox.mark_dismissed/2` + `stream_delete_by_dom_id/3` + drop the count.
    * `handle_event("open", %{"id" => id, "url" => url}, socket)` →
      `Inbox.mark_read/2` then `push_navigate` to the item's url.

  ## Read vs. dismissed

  The surface shows only UNREAD, non-dismissed rows. `list_unread_for_user/2`
  returns read-but-not-dismissed rows too (read is orthogonal to dismissal at
  the context layer), but an inbox that keeps showing notifications you have
  already opened is noise — clicking through to an item is the signal that it is
  handled, so a read item drops off the inbox on the next load. Dismissal is the
  explicit per-row "gone" verb; there is no bulk "mark all read" in v1.
  """

  use PlatformWeb, :live_view

  import Ecto.Query, only: [order_by: 3]
  import PlatformWeb.Components.InboxItem, only: [inbox_item: 1]

  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Repo

  @sections [:review, :mentions, :meetings]

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
     |> init_sections(items)}
  end

  # ── Live inserts ───────────────────────────────────────────────────────

  @impl true
  def handle_info({:inbox_item_added, %Item{} = item}, socket) do
    # Defensive: a read/dismissed row never belongs in the live list. Every
    # kind maps to a real section (`section_for/1` is total), so there is no
    # "unroutable" case to drop.
    if is_nil(item.dismissed_at) and is_nil(item.read_at) do
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

  def handle_event("open", %{"id" => id} = params, socket) do
    user_id = socket.assigns.current_user_id
    if is_binary(user_id), do: Inbox.mark_read(id, user_id)

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
  # — the two drifted (#589/#592). Now both are one query. A lazy reconcile
  # runs first so a stale review row (task's reviews all resolved) is dismissed
  # before it's ever selected.
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
