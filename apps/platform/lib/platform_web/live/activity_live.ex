defmodule PlatformWeb.ActivityLive do
  @moduledoc """
  Activity panel — chronological view of AI-agent-driven actions across all
  accessible (non-archived) spaces. Supports time-range filtering, pagination
  (10 items per page, "Load more" appends), and one-click undo per item.

  Polls on mount/refresh/load-more; no live streaming.

  See `Platform.Chat.list_recent_agent_actions/1` for the underlying query.
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
    # Defensive fallback: any unexpected range string resets to the default.
    # Avoids crashing on stale clients sending old/invalid range values.
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

  def handle_event("undo", %{"kind" => "message", "id" => id}, socket) when is_binary(id) do
    # Defensive shape: the resource must be agent-authored AND its space must
    # be accessible (not archived). Drops the prior participant-membership
    # gate to match the broadened "all accessible spaces" scope.
    with %Message{deleted_at: nil, author_participant_type: "agent"} = msg <-
           Chat.get_message(id) || :not_found,
         true <- Chat.space_accessible?(msg.space_id),
         {:ok, _} <- Chat.delete_message(msg) do
      {actions, has_more} = load_actions(socket.assigns.range, socket.assigns.page)

      {:noreply,
       socket
       |> put_flash(:info, "Message undone")
       |> assign(:actions, actions)
       |> assign(:has_more, has_more)}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Message not found")}

      %Message{} ->
        # Either already-soft-deleted, or not agent-authored. Refresh the list
        # in either case so the stale item drops out of view.
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
    # `Chat.get_canvas/1` already filters out soft-deleted canvases, so a stale
    # double-undo simply lands here as `nil`.
    with %Canvas{created_by_participant_type: "agent"} = canvas <-
           Chat.get_canvas(id) || :not_found,
         true <- Chat.space_accessible?(canvas.space_id),
         {:ok, _} <- Chat.delete_canvas(canvas) do
      {actions, has_more} = load_actions(socket.assigns.range, socket.assigns.page)

      {:noreply,
       socket
       |> put_flash(:info, "Canvas undone")
       |> assign(:actions, actions)
       |> assign(:has_more, has_more)}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Canvas not found")}

      %Canvas{} ->
        # Canvas exists but was not agent-authored — refuse the undo.
        {:noreply, put_flash(socket, :error, "Not an agent-created canvas")}

      false ->
        {:noreply, put_flash(socket, :error, "Space no longer accessible")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to undo canvas")}
    end
  end

  # Catch-all for malformed undo payloads (unknown kind, missing id, etc.) so
  # the LiveView doesn't crash on a crafted/bad event.
  def handle_event("undo", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unknown undo target")}
  end

  # ── Loader ─────────────────────────────────────────────────────────────────

  defp load_actions(range, page) do
    target = page * @page_size

    # Over-fetch by 1 so we can detect "is there a next page?" without an
    # extra count query. Trim to `target` for display.
    opts = [limit: target + 1]
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
  # Fallback: stale clients (e.g. cached "1h" from before this PR retired it)
  # resolve to the new default range rather than crashing the LiveView.
  defp since_for_range(_), do: DateTime.add(DateTime.utc_now(), -86_400, :second)

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
