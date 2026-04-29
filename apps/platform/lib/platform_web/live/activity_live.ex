defmodule PlatformWeb.ActivityLive do
  @moduledoc """
  Activity panel — chronological view of AI-agent-driven actions in spaces the
  current user participates in. Supports time-range filtering and one-click
  undo (soft-delete) per item. Polls on mount/refresh; no live streaming.

  See `Platform.Chat.list_recent_agent_actions/2` for the underlying query.
  """

  use PlatformWeb, :live_view

  alias Platform.Chat
  alias Platform.Chat.{Canvas, Message}

  @ranges [
    {"1h", 3600},
    {"24h", 86_400},
    {"7d", 604_800},
    {"30d", 2_592_000},
    {"all", nil}
  ]

  @default_range "1h"

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user_id

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:current_path, "/activity")
     |> assign(:range, @default_range)
     |> assign(:ranges, @ranges)
     |> assign(:actions, load_actions(user_id, @default_range))}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("change_range", %{"range" => range}, socket)
      when range in ~w(1h 24h 7d 30d all) do
    user_id = socket.assigns.current_user_id

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:actions, load_actions(user_id, range))}
  end

  def handle_event("refresh", _params, socket) do
    user_id = socket.assigns.current_user_id

    {:noreply,
     socket
     |> assign(:actions, load_actions(user_id, socket.assigns.range))
     |> put_flash(:info, "Refreshed")}
  end

  def handle_event("undo", %{"kind" => "message", "id" => id}, socket) when is_binary(id) do
    user_id = socket.assigns.current_user_id

    with %Message{deleted_at: nil} = msg <- Chat.get_message(id) || :not_found,
         true <- Chat.user_in_space?(user_id, msg.space_id),
         {:ok, _} <- Chat.delete_message(msg) do
      {:noreply,
       socket
       |> put_flash(:info, "Message undone")
       |> assign(:actions, load_actions(user_id, socket.assigns.range))}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Message not found")}

      %Message{} ->
        # already soft-deleted; refresh so the stale row drops out of view
        {:noreply,
         socket
         |> put_flash(:info, "Already undone")
         |> assign(:actions, load_actions(user_id, socket.assigns.range))}

      false ->
        {:noreply, put_flash(socket, :error, "Not authorized")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to undo message")}
    end
  end

  def handle_event("undo", %{"kind" => "canvas", "id" => id}, socket) when is_binary(id) do
    user_id = socket.assigns.current_user_id

    # `Chat.get_canvas/1` already filters out soft-deleted canvases, so a stale
    # double-undo simply lands here as `nil`.
    with %Canvas{} = canvas <- Chat.get_canvas(id) || :not_found,
         true <- Chat.user_in_space?(user_id, canvas.space_id),
         {:ok, _} <- Chat.delete_canvas(canvas) do
      {:noreply,
       socket
       |> put_flash(:info, "Canvas undone")
       |> assign(:actions, load_actions(user_id, socket.assigns.range))}
    else
      :not_found ->
        {:noreply, put_flash(socket, :error, "Canvas not found")}

      false ->
        {:noreply, put_flash(socket, :error, "Not authorized")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to undo canvas")}
    end
  end

  # Catch-all for malformed undo payloads (unknown kind, missing id, etc.) so
  # the LiveView doesn't crash on a crafted/bad event.
  def handle_event("undo", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unknown undo target")}
  end

  defp load_actions(user_id, range) do
    opts =
      case Enum.find(@ranges, fn {r, _} -> r == range end) do
        {_, nil} -> []
        {_, seconds} -> [since: DateTime.add(DateTime.utc_now(), -seconds, :second)]
        _ -> [since: DateTime.add(DateTime.utc_now(), -3600, :second)]
      end

    Chat.list_recent_agent_actions(user_id, opts)
  end

  # ── Template helpers ──────────────────────────────────────────────────────

  def range_label("1h"), do: "Last hour"
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
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 2_592_000 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %-d")
    end
  end

  def time_ago(_), do: ""
end
