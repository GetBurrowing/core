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
      button swaps. Hard refresh (Refresh button / Load more) re-applies
      sort and the row may shift.

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
    {actions, has_more} = load_actions(@default_range, 1)

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:current_path, "/activity")
     |> assign(:range, @default_range)
     |> assign(:ranges, @ranges)
     |> assign(:page, 1)
     |> assign(:page_size, @page_size)
     |> assign(:actions, actions)
     |> assign(:has_more, has_more)}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_range", %{"range" => range}, socket) do
    range = if range in @ranges, do: range, else: @default_range
    {actions, has_more} = load_actions(range, 1)

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:page, 1)
     |> assign(:actions, actions)
     |> assign(:has_more, has_more)}
  end

  def handle_event("refresh", _params, socket) do
    {actions, has_more} = load_actions(socket.assigns.range, 1)

    {:noreply,
     socket
     |> assign(:page, 1)
     |> assign(:actions, actions)
     |> assign(:has_more, has_more)
     |> put_flash(:info, "Refreshed")}
  end

  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1
    {actions, has_more} = load_actions(socket.assigns.range, next_page)

    {:noreply,
     socket
     |> assign(:page, next_page)
     |> assign(:actions, actions)
     |> assign(:has_more, has_more)}
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
        # Already soft-deleted, or not agent-authored. Refresh so the stale
        # row drops out of the list.
        {actions, has_more} = load_actions(socket.assigns.range, socket.assigns.page)

        {:noreply,
         socket
         |> put_flash(:info, "Already undone")
         |> assign(:actions, actions)
         |> assign(:has_more, has_more)}

      false ->
        {:noreply, put_flash(socket, :error, "Space no longer accessible")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to undo message")}
    end
  end

  def handle_event("undo", %{"kind" => "canvas", "id" => id}, socket) when is_binary(id) do
    # `Chat.get_canvas/1` already filters out soft-deleted canvases.
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
    # `Chat.get_message/1` does NOT filter soft-deleted, so it works for
    # restore. We do require the message currently HAS a deleted_at, otherwise
    # this is a no-op (already active).
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
        # Already active, refresh to sync.
        {actions, has_more} = load_actions(socket.assigns.range, socket.assigns.page)

        {:noreply,
         socket
         |> put_flash(:info, "Already active")
         |> assign(:actions, actions)
         |> assign(:has_more, has_more)}

      %Message{} ->
        # Not agent-authored — refuse.
        {:noreply, put_flash(socket, :error, "Not an agent message")}

      false ->
        {:noreply, put_flash(socket, :error, "Space no longer accessible")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restore message")}
    end
  end

  def handle_event("restore", %{"kind" => "canvas", "id" => id}, socket) when is_binary(id) do
    # Use the soft-delete-aware fetch — `Chat.get_canvas/1` filters those out.
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
        {actions, has_more} = load_actions(socket.assigns.range, socket.assigns.page)

        {:noreply,
         socket
         |> put_flash(:info, "Already active")
         |> assign(:actions, actions)
         |> assign(:has_more, has_more)}

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

  # ── Loader ─────────────────────────────────────────────────────────────────

  defp load_actions(range, page) do
    target = page * @page_size

    # Always include soft-deleted rows; the LV renders state via the pill.
    # Over-fetch by 1 so we can detect "is there a next page?" without an
    # extra count query. Trim to `target` for display.
    opts = [limit: target + 1, include_deleted: true]
    opts = put_since(opts, since_for_range(range))

    all = Chat.list_recent_agent_actions(opts)
    has_more = length(all) > target
    actions = Enum.take(all, target)

    {actions, has_more}
  end

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
  # user sees an immediate, stable response to their click. On the next hard
  # refresh / pagination, normal sort rules re-apply.

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
end
