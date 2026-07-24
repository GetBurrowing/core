defmodule PlatformWeb.InboxLive do
  @moduledoc """
  The Inbox surface — the "My Notifications" landing page at `/inbox`.

  It aggregates the things waiting on the viewer across Suite as a live,
  sectioned, dismissable list, backed by `Platform.Inbox`:

    * **Awaiting your review** — `review_request_pending` + `task_plan_review`
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

  import PlatformWeb.Components.InboxItem, only: [inbox_item: 1]

  alias Platform.Inbox
  alias Platform.Inbox.Item

  @sections [:review, :mentions, :meetings]

  @impl true
  def mount(_params, session, socket) do
    user_id = session["current_user_id"] || current_user_id(socket)

    if connected?(socket) and is_binary(user_id) do
      Inbox.subscribe(user_id)
    end

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
    cond do
      # Defensive: a read/dismissed row never belongs in the live list.
      not is_nil(item.dismissed_at) or not is_nil(item.read_at) ->
        {:noreply, socket}

      section = section_for(item.kind) ->
        {:noreply,
         socket
         |> stream_insert(stream_name(section), decorate(item), at: 0)
         |> update_count(section, +1)
         |> track_section(item.id, section)}

      true ->
        {:noreply, socket}
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
    for item <- items, section = section_for(item.kind), not is_nil(section), into: %{} do
      {item.id, section}
    end
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

  defp section_for(kind) when kind in ~w(review_request_pending task_plan_review), do: :review
  defp section_for("chat_mention"), do: :mentions
  defp section_for("meeting_starting"), do: :meetings
  defp section_for(_), do: nil

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

  @doc "Human-facing space label for a mention row (`#<slug>`), or nil if unknown."
  def mention_space_label(%Item{} = item) do
    case mention_space_key(item) do
      "" -> nil
      key -> "#" <> key
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────

  defp load_items(user_id) do
    user_id
    |> Inbox.list_unread_for_user()
    |> Enum.reject(&(not is_nil(&1.read_at)))
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
