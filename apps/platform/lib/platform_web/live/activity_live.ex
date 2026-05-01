defmodule PlatformWeb.ActivityLive do
  @moduledoc """
  Activity panel — chronological view of AI-agent-driven actions across all
  accessible (non-archived) spaces.

  Each row carries a `:state` of `:active` or `:undone`. Active rows render
  unmarked with an [Undo] button; Undone rows render with an "Undone" pill
  and a [Restore] button. Per the architect's recommendation:

    * Sort is always `inserted_at desc` (regardless of state) for cursor
      stability — pagination cannot skip or duplicate rows.
    * Pill renders only on Undone rows; Active is the unmarked default.
    * On Undo / Restore, the row stays visible in place — state flips,
      button swaps. Hard refresh (Refresh button / page navigation /
      range change) re-applies sort and the row may shift.

  Pagination is **numbered pages** (10 per page). Total page count comes
  from `Chat.count_recent_agent_actions/1`. Each page navigation fetches
  only that page's slice (over-fetch + slice on the server side).

  Polling-only; no live streaming. See `Platform.Chat.list_recent_agent_actions/1`.
  """

  use PlatformWeb, :live_view

  alias Platform.Chat
  alias Platform.Chat.{Canvas, Message}

  @ranges ~w(24h 7d 30d all)
  @default_range "24h"
  @page_size 10

  @impl true
  def mount(_params, _session, socket) do
    {actions, page, total_pages} = load_page(@default_range, 1)

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:current_path, "/activity")
     |> assign(:range, @default_range)
     |> assign(:ranges, @ranges)
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:page_size, @page_size)
     |> assign(:actions, actions)}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    range = if range in @ranges, do: range, else: @default_range
    {actions, page, total_pages} = load_page(range, 1)

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:actions, actions)}
  end

  def handle_event("refresh", _params, socket) do
    {actions, page, total_pages} = load_page(socket.assigns.range, socket.assigns.page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:actions, actions)
     |> put_flash(:info, "Refreshed")}
  end

  def handle_event("goto_page", %{"page" => page_str}, socket) do
    page = parse_page(page_str)
    {actions, page, total_pages} = load_page(socket.assigns.range, page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:actions, actions)}
  end

  # ── Undo / Restore handlers ────────────────────────────────────────────────
  #
  # Defensive shape for both: the resource must be agent-authored AND its
  # space must be accessible (not archived). Optimistic in-place flip on
  # success — the row stays visible, state + button swap. Errors put_flash
  # without mutating state.

  def handle_event("undo", %{"kind" => "message", "id" => id}, socket) when is_binary(id) do
    with %Message{deleted_at: nil, author_participant_type: "agent"} = msg <-
           Chat.get_message(id) || :not_found,
         true <- Chat.space_accessible?(msg.space_id),
         {:ok, _} <- Chat.delete_message(msg) do
      {:noreply,
       socket
       |> put_flash(:info, "Message undone")
       |> assign(:actions, flip_state(socket.assigns.actions, :message, id, :undone))}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Message not found")}

      %Message{} ->
        # Already soft-deleted or not agent-authored. Reload current page so
        # the stale row drops out of view.
        reload_current_page(socket, "Already undone", :info)

      false ->
        {:noreply, put_flash(socket, :error, "Space no longer accessible")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to undo message")}
    end
  end

  def handle_event("undo", %{"kind" => "canvas", "id" => id}, socket) when is_binary(id) do
    with %Canvas{created_by_participant_type: "agent"} = canvas <-
           Chat.get_canvas(id) || :not_found,
         true <- Chat.space_accessible?(canvas.space_id),
         {:ok, _} <- Chat.delete_canvas(canvas) do
      {:noreply,
       socket
       |> put_flash(:info, "Canvas undone")
       |> assign(:actions, flip_state(socket.assigns.actions, :canvas, id, :undone))}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Canvas not found")}

      %Canvas{} ->
        {:noreply, put_flash(socket, :error, "Not an agent-created canvas")}

      false ->
        {:noreply, put_flash(socket, :error, "Space no longer accessible")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to undo canvas")}
    end
  end

  def handle_event("undo", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unknown undo target")}
  end

  def handle_event("restore", %{"kind" => "message", "id" => id}, socket) when is_binary(id) do
    with %Message{author_participant_type: "agent"} = msg <-
           Chat.get_message(id) || :not_found,
         true <- not is_nil(msg.deleted_at) || :already_active,
         true <- Chat.space_accessible?(msg.space_id),
         {:ok, _} <- Chat.restore_message(msg) do
      {:noreply,
       socket
       |> put_flash(:info, "Message restored")
       |> assign(:actions, flip_state(socket.assigns.actions, :message, id, :active))}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Message not found")}

      :already_active ->
        reload_current_page(socket, "Already active", :info)

      %Message{} ->
        {:noreply, put_flash(socket, :error, "Not an agent message")}

      false ->
        {:noreply, put_flash(socket, :error, "Space no longer accessible")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore message")}
    end
  end

  def handle_event("restore", %{"kind" => "canvas", "id" => id}, socket) when is_binary(id) do
    with %Canvas{created_by_participant_type: "agent"} = canvas <-
           Chat.get_canvas_with_deleted(id) || :not_found,
         true <- not is_nil(canvas.deleted_at) || :already_active,
         true <- Chat.space_accessible?(canvas.space_id),
         {:ok, _} <- Chat.restore_canvas(canvas) do
      {:noreply,
       socket
       |> put_flash(:info, "Canvas restored")
       |> assign(:actions, flip_state(socket.assigns.actions, :canvas, id, :active))}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Canvas not found")}

      :already_active ->
        reload_current_page(socket, "Already active", :info)

      %Canvas{} ->
        {:noreply, put_flash(socket, :error, "Not an agent-created canvas")}

      false ->
        {:noreply, put_flash(socket, :error, "Space no longer accessible")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore canvas")}
    end
  end

  def handle_event("restore", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unknown restore target")}
  end

  # ── Page loader ────────────────────────────────────────────────────────────

  defp load_page(range, page) do
    since = since_for_range(range)

    count_opts = [include_deleted: true]
    count_opts = put_since(count_opts, since)
    total = Chat.count_recent_agent_actions(count_opts)

    total_pages = max(1, ceil_div(total, @page_size))
    page = clamp(page, 1, total_pages)

    # Over-fetch up to (page * @page_size) items so we can slice the page's
    # window. The list call's dual-stream merge means we need at least
    # `page * @page_size` items in the merged-and-sorted result.
    list_opts = [limit: page * @page_size, include_deleted: true]
    list_opts = put_since(list_opts, since)

    all = Chat.list_recent_agent_actions(list_opts)
    actions = Enum.slice(all, (page - 1) * @page_size, @page_size)

    {actions, page, total_pages}
  end

  defp reload_current_page(socket, msg, kind) do
    {actions, page, total_pages} = load_page(socket.assigns.range, socket.assigns.page)

    {:noreply,
     socket
     |> put_flash(kind, msg)
     |> assign(:page, page)
     |> assign(:total_pages, total_pages)
     |> assign(:actions, actions)}
  end

  defp parse_page(page_str) do
    case Integer.parse(to_string(page_str)) do
      {n, _} when n >= 1 -> n
      _ -> 1
    end
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  defp ceil_div(0, _denom), do: 0
  defp ceil_div(num, denom) when num > 0, do: div(num + denom - 1, denom)

  defp put_since(opts, nil), do: opts
  defp put_since(opts, %DateTime{} = since), do: Keyword.put(opts, :since, since)

  defp since_for_range("24h"), do: DateTime.add(DateTime.utc_now(), -86_400, :second)
  defp since_for_range("7d"), do: DateTime.add(DateTime.utc_now(), -604_800, :second)
  defp since_for_range("30d"), do: DateTime.add(DateTime.utc_now(), -2_592_000, :second)
  defp since_for_range("all"), do: nil
  defp since_for_range(_), do: DateTime.add(DateTime.utc_now(), -86_400, :second)

  # ── Optimistic in-place state flip ─────────────────────────────────────────
  #
  # Updates a single action's `:state` (and the embedded item's `:deleted_at`
  # to keep the map self-consistent for downstream readers) without triggering
  # a full list reload. The row stays in its current sort position so the
  # user sees an immediate, stable response to their click.

  defp flip_state(actions, kind, id, new_state) do
    now = DateTime.utc_now()

    Enum.map(actions, fn
      %{kind: ^kind, item: %{id: ^id} = item} = action ->
        deleted_at = if new_state == :undone, do: now, else: nil
        %{action | state: new_state, item: %{item | deleted_at: deleted_at}}

      action ->
        action
    end)
  end

  # ── Template helpers ──────────────────────────────────────────────────────

  def range_label("24h"), do: "Last 24 hours"
  def range_label("7d"), do: "Last 7 days"
  def range_label("30d"), do: "Last 30 days"
  def range_label("all"), do: "All time"
  def range_label(other), do: other

  def avatar_initial(nil), do: "?"
  def avatar_initial(""), do: "?"

  def avatar_initial(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.first()
    |> Kernel.||("?")
    |> String.upcase()
  end

  def kind_label(:message), do: "Message"
  def kind_label(:canvas), do: "Canvas"
  def kind_label(other), do: to_string(other)

  def action_preview(%{kind: :message, item: %Message{content: content}})
      when is_binary(content) do
    String.slice(content, 0, 200)
  end

  def action_preview(%{kind: :canvas, item: %Canvas{title: title}}) do
    case title do
      t when is_binary(t) and t != "" -> t
      _ -> "(untitled canvas)"
    end
  end

  def action_preview(_), do: ""

  def time_ago(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3_600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3_600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %-d")
    end
  end

  def time_ago(_), do: ""

  @doc """
  Visible page numbers for a numbered-pagination nav. Returns a list of
  integers and `:ellipsis` markers. For ≤7 total pages, shows them all;
  otherwise shows 1, neighbors of current, and last with ellipses.
  """
  @spec visible_pages(integer(), integer()) :: [integer() | :ellipsis]
  def visible_pages(_current, total) when total <= 7, do: Enum.to_list(1..total)

  def visible_pages(current, total) when current <= 4 do
    Enum.to_list(1..5) ++ [:ellipsis, total]
  end

  def visible_pages(current, total) when current >= total - 3 do
    [1, :ellipsis] ++ Enum.to_list((total - 4)..total)
  end

  def visible_pages(current, total) do
    [1, :ellipsis, current - 1, current, current + 1, :ellipsis, total]
  end
end
