defmodule PlatformWeb.ChatLive.CanvasHooks do
  @moduledoc """
  Lifecycle hook module for canvases in `PlatformWeb.ChatLive` (ADR 0036).

  Owns:

    * Assigns: `:canvases`, `:canvases_by_id`, `:active_canvas`,
      `:show_canvases`, `:new_canvas_form`
    * Events:  `"canvas_panel_toggle"`, `"canvas_close"`,
      `"canvas_open_mobile"`, `"canvas_patch"`, `"canvas_action_click"`,
      `"canvas_form_submit"`
    * Info:    `{:canvas_created, canvas}`, `{:canvas_updated, canvas}`

  Per-type LiveView event handlers (canvas_save_form, canvas_save_code,
  canvas_save_diagram, canvas_refresh_dashboard, canvas_sort) are removed.
  UI mutations flow through the generic `canvas_patch` event which applies a
  list of `CanvasPatch` operations.
  """

  require Logger

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.Presence
  alias Platform.Chat.PubSub, as: ChatPubSub

  @doc "Attach canvas handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:canvases, [])
    |> assign(:canvases_by_id, %{})
    |> assign(:active_canvas, nil)
    |> assign(:show_canvases, false)
    |> assign(:recent_canvas_events, [])
    |> assign_new_form()
    |> attach_hook(:canvas_events, :handle_event, &handle_event/3)
    |> attach_hook(:canvas_info, :handle_info, &handle_info/2)
  end

  @doc "Load canvases for a space."
  @spec load_for_space(Phoenix.LiveView.Socket.t(), binary()) :: Phoenix.LiveView.Socket.t()
  def load_for_space(socket, space_id) do
    canvases = Chat.list_canvases(space_id)

    unsubscribe_all_canvases(socket)
    Enum.each(canvases, fn c -> ChatPubSub.subscribe_canvas(c.id) end)

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_id, build_map(canvases))
    |> assign(:active_canvas, nil)
    |> assign(:show_canvases, false)
    |> assign_new_form()
  end

  defp unsubscribe_all_canvases(socket) do
    Enum.each(Map.get(socket.assigns, :canvases, []), fn c ->
      ChatPubSub.unsubscribe_canvas(c.id)
    end)
  end

  @doc "Merge a canvas into hook state."
  @spec put(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def put(socket, canvas) do
    canvases =
      socket.assigns.canvases
      |> Enum.reject(&(&1.id == canvas.id))
      |> Kernel.++([canvas])
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    # Subscribe to the canvas topic if this is a first-sight canvas for this
    # LiveView. Phoenix.PubSub dedups within a single pid, so re-subscribing
    # on an already-known canvas is a no-op.
    ChatPubSub.subscribe_canvas(canvas.id)

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_id, build_map(canvases))
    |> maybe_update_active(canvas)
  end

  @doc "Remove a canvas from the socket's local list (paired with `{:canvas_deleted, canvas}` broadcasts)."
  @spec remove(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def remove(socket, canvas) do
    # Use safe assigns access — a {:canvas_deleted, _} broadcast can race with
    # mount and arrive before :canvases / :canvases_by_id are initialized.
    canvases =
      socket.assigns
      |> Map.get(:canvases, [])
      |> Enum.reject(&(&1.id == canvas.id))

    active =
      case socket.assigns[:active_canvas] do
        %{id: id} when id == canvas.id -> nil
        other -> other
      end

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_id, build_map(canvases))
    |> assign(:active_canvas, active)
  end

  @doc "Set the active canvas."
  @spec set_active(Phoenix.LiveView.Socket.t(), map() | nil) :: Phoenix.LiveView.Socket.t()
  def set_active(socket, canvas), do: assign(socket, :active_canvas, canvas)

  @doc "Show the canvases panel."
  @spec show_panel(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def show_panel(socket), do: assign(socket, :show_canvases, true)

  @doc "Reset the new-canvas form."
  @spec reset_new_form(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def reset_new_form(socket, attrs \\ %{}), do: assign_new_form(socket, attrs)

  @doc "Find a canvas by id — DB first, then cached list."
  @spec find(Phoenix.LiveView.Socket.t(), binary()) :: map() | nil
  def find(socket, canvas_id) do
    Chat.get_canvas(canvas_id) || Enum.find(socket.assigns.canvases, &(&1.id == canvas_id))
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("canvas_panel_toggle", _params, socket) do
    {:halt, assign(socket, :show_canvases, !socket.assigns.show_canvases)}
  end

  defp handle_event("canvas_close", _params, socket) do
    if canvas = socket.assigns.active_canvas do
      clear_canvas_engagement(socket, canvas)
    end

    {:halt, assign(socket, :active_canvas, nil)}
  end

  defp handle_event("canvas_open_mobile", params, socket) do
    canvas_id =
      Map.get(params, "canvas-id") ||
        case Map.get(params, "message-id") do
          nil ->
            nil

          mid ->
            case Chat.get_message(mid) do
              %{canvas_id: cid} when is_binary(cid) -> cid
              _ -> nil
            end
        end

    case canvas_id && find(socket, canvas_id) do
      nil ->
        {:halt, socket}

      %{} = canvas ->
        register_canvas_engagement(socket, canvas, :viewing)
        {:halt, assign(socket, :active_canvas, canvas)}

      _ ->
        {:halt, socket}
    end
  end

  defp handle_event(
         "canvas_action_click",
         %{"node-id" => node_id, "value" => value} = params,
         socket
       ) do
    canvas_id =
      params["canvas-id"] || (socket.assigns.active_canvas && socket.assigns.active_canvas.id)

    with %{} = canvas <- find(socket, canvas_id) do
      CanvasServer.emit_event(canvas.id, %{
        "name" => "action",
        "node_id" => node_id,
        "value" => value
      })
    end

    {:halt, socket}
  end

  defp handle_event(
         "canvas_form_submit",
         %{"node-id" => node_id, "form" => values} = params,
         socket
       ) do
    canvas_id =
      params["canvas-id"] || (socket.assigns.active_canvas && socket.assigns.active_canvas.id)

    with %{} = canvas <- find(socket, canvas_id) do
      CanvasServer.emit_event(canvas.id, %{
        "name" => "submitted",
        "node_id" => node_id,
        "values" => values
      })
    end

    {:halt, socket}
  end

  defp handle_event("canvas_node_focus", %{"node-id" => node_id} = params, socket) do
    canvas_id =
      params["canvas-id"] || (socket.assigns.active_canvas && socket.assigns.active_canvas.id)

    with %{} = canvas <- find(socket, canvas_id),
         %{current_participant: %{id: participant_id}} <- socket.assigns do
      Presence.set_canvas_engagement(self(), canvas.space_id, participant_id, %{
        canvas_id: canvas.id,
        engagement: :editing,
        focus_node_id: node_id
      })
    end

    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:canvas_created, canvas}, socket), do: {:halt, put(socket, canvas)}
  defp handle_info({:canvas_updated, canvas}, socket), do: {:halt, put(socket, canvas)}
  defp handle_info({:canvas_deleted, canvas}, socket), do: {:halt, remove(socket, canvas)}

  # Canvas kind emissions (action-row click, form submit, checklist toggle, …)
  # arrive here via `ChatPubSub.broadcast_canvas/2`. Events are signals — they
  # don't mutate the document. For user-visible feedback we flash a short
  # description + log; agent-runtime forwarding is a separate subscriber.
  defp handle_info({:canvas_event, canvas_id, event}, socket) when is_map(event) do
    Logger.debug("[canvas_event] canvas=#{canvas_id} #{inspect(event)}")

    {:halt,
     socket
     |> assign(:recent_canvas_events, prepend_event(socket, canvas_id, event))
     |> put_flash(:info, flash_for(event))}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  @recent_events_cap 20

  defp prepend_event(socket, canvas_id, event) do
    prior = Map.get(socket.assigns, :recent_canvas_events, [])

    entry = %{
      canvas_id: canvas_id,
      event: event,
      at: DateTime.utc_now()
    }

    [entry | prior] |> Enum.take(@recent_events_cap)
  end

  defp flash_for(%{"name" => "action", "node_id" => id, "value" => v}),
    do: "Canvas action: #{id} → #{inspect(v)}"

  defp flash_for(%{"name" => "submitted", "node_id" => id}),
    do: "Canvas form submitted: #{id}"

  defp flash_for(%{"name" => name}), do: "Canvas event: #{name}"
  defp flash_for(_), do: "Canvas event received"

  @doc "Human-readable summary of the canvas's root document kind."
  def humanize_kind(%{document: %{"root" => %{"type" => t}}}) when is_binary(t) do
    humanize_string(t)
  end

  def humanize_kind(_), do: "Canvas"

  @doc "Title for a canvas attached to a message (fallbacks through structured_content)."
  def message_canvas_title(message, canvases_by_id) do
    case Map.get(canvases_by_id, message.canvas_id) do
      %{title: title} when is_binary(title) and title != "" ->
        title

      _ ->
        get_in(message.structured_content || %{}, ["title"]) ||
          "Untitled Canvas"
    end
  end

  defp humanize_string(type) when is_binary(type) do
    type
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_string(_), do: "Canvas"

  @doc "Summarize a canvas creation changeset for a flash message."
  def changeset_error_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      replacements = Map.new(opts, fn {key, value} -> {to_string(key), value} end)

      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        replacements |> Map.get(key, key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  rescue
    _ -> "Please check the canvas fields and try again."
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp assign_new_form(socket, attrs \\ %{}) do
    params = %{
      "title" => Map.get(attrs, "title", "")
    }

    assign(socket, :new_canvas_form, to_form(params, as: :canvas))
  end

  # Keyed by canvas.id so templates can look up via `msg.canvas_id`.
  # Replaces the old `canvases_by_message_id` (pre-ADR-0036) that used the
  # now-removed `chat_canvases.message_id` column.
  defp build_map(canvases) do
    Map.new(canvases, fn canvas -> {canvas.id, canvas} end)
  end

  defp register_canvas_engagement(socket, canvas, engagement) do
    case socket.assigns do
      %{current_participant: %{id: participant_id}} ->
        Presence.set_canvas_engagement(self(), canvas.space_id, participant_id, %{
          canvas_id: canvas.id,
          engagement: engagement
        })

      _ ->
        :ok
    end
  end

  defp clear_canvas_engagement(socket, canvas) do
    case socket.assigns do
      %{current_participant: %{id: participant_id}} ->
        Presence.clear_canvas_engagement(self(), canvas.space_id, participant_id)

      _ ->
        :ok
    end
  end

  defp maybe_update_active(socket, canvas) do
    case socket.assigns.active_canvas do
      %{id: id} when id == canvas.id -> assign(socket, :active_canvas, canvas)
      _ -> socket
    end
  end
end
