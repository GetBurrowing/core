defmodule PlatformWeb.ChatLive.CanvasHooks do
  @moduledoc """
  Lifecycle hook module for the Canvases feature in `PlatformWeb.ChatLive`.

  See ADR 0035. Canvases has distributed UI (sidebar list + inline canvas
  on messages + panel overlay + creation form) so it lives as a
  LifecycleHook. Owns:

    * Assigns: `:canvases`, `:canvases_by_message_id`, `:active_canvas`,
      `:show_canvases`, `:new_canvas_form`, `:canvas_types`
    * Events:  `"canvas_panel_toggle"`, `"canvas_close"`,
      `"canvas_open_mobile"`, `"canvas_action"`, `"canvas_sort"`,
      `"canvas_save_form"`, `"canvas_save_code"`,
      `"canvas_save_diagram"`, `"canvas_refresh_dashboard"`
    * Info:    `{:canvas_created, canvas}`, `{:canvas_updated, canvas}`,
               `{:canvas_action, canvas, value}`

  ## Cross-feature events (stay on parent)

    * `canvas_open` — writes Thread assigns (`active_thread`,
      `thread_messages`, `thread_attachments_map`) alongside
      `active_canvas`. Stays on parent until Threads extracts.
    * `canvas_create` — creates a message (stream_insert, attachments
      map). Stays on parent until MessageList extracts.

  The parent uses `put/2` to merge a newly-created canvas into hook
  state, and `reset_active/1` or `set_active/2` for panel coordination.

  ## Usage

      # In ChatLive.mount/3:
      socket = PlatformWeb.ChatLive.CanvasHooks.attach(socket)

      # In ChatLive.handle_params/3 on space change:
      socket = PlatformWeb.ChatLive.CanvasHooks.load_for_space(socket, space.id)
  """

  require Logger

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub

  @canvas_types ~w(table form code diagram dashboard custom)

  @doc "The supported canvas types. Exposed for render."
  def canvas_types, do: @canvas_types

  @doc "Attach Canvas handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:canvases, [])
    |> assign(:canvases_by_message_id, %{})
    |> assign(:active_canvas, nil)
    |> assign(:show_canvases, false)
    |> assign(:canvas_types, @canvas_types)
    |> assign_new_form()
    |> attach_hook(:canvas_events, :handle_event, &handle_event/3)
    |> attach_hook(:canvas_info, :handle_info, &handle_info/2)
  end

  @doc "Load canvases for a space. Call from `ChatLive.handle_params/3`."
  @spec load_for_space(Phoenix.LiveView.Socket.t(), binary()) :: Phoenix.LiveView.Socket.t()
  def load_for_space(socket, space_id) do
    canvases = Chat.list_canvases(space_id)

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_message_id, build_map(canvases))
    |> assign(:active_canvas, nil)
    |> assign(:show_canvases, false)
    |> assign_new_form()
  end

  @doc """
  Merge a newly-created or -updated canvas into hook state. Called by the
  parent's `canvas_create` coordinator after `Chat.create_canvas_with_message/3`.
  """
  @spec put(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def put(socket, canvas) do
    canvases =
      socket.assigns.canvases
      |> Enum.reject(&(&1.id == canvas.id))
      |> Kernel.++([canvas])
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    socket
    |> assign(:canvases, canvases)
    |> assign(:canvases_by_message_id, build_map(canvases))
    |> maybe_update_active(canvas)
  end

  @doc "Set the active canvas (called by parent's canvas_open coordinator)."
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

  @doc "Default state for a canvas of the given type."
  @spec default_state(String.t() | nil) :: map()
  def default_state(type), do: do_default_state(type)

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("canvas_panel_toggle", _params, socket) do
    {:halt, assign(socket, :show_canvases, !socket.assigns.show_canvases)}
  end

  defp handle_event("canvas_close", _params, socket) do
    {:halt, assign(socket, :active_canvas, nil)}
  end

  defp handle_event("canvas_open_mobile", %{"message-id" => message_id}, socket) do
    case Map.get(socket.assigns.canvases_by_message_id, message_id) do
      nil ->
        {:halt, socket}

      canvas ->
        {:halt, assign(socket, :active_canvas, find(socket, canvas.id) || canvas)}
    end
  end

  defp handle_event("canvas_action", %{"value" => value, "canvas-id" => canvas_id}, socket) do
    case find(socket, canvas_id) do
      nil ->
        Logger.warning("canvas_action: canvas not found (canvas_id=#{inspect(canvas_id)})")
        {:halt, socket}

      canvas ->
        Logger.info(
          "canvas_action: canvas=#{canvas.id} value=#{inspect(value)} space=#{canvas.space_id}"
        )

        ChatPubSub.broadcast(canvas.space_id, {:canvas_action, canvas, value})
        dispatch_to_agent(canvas, value)
        {:halt, socket}
    end
  end

  defp handle_event("canvas_sort", %{"id" => canvas_id, "column" => column}, socket) do
    with %{} = canvas <- find(socket, canvas_id) do
      sort_by = Map.get(canvas.state || %{}, "sort_by")
      sort_dir = Map.get(canvas.state || %{}, "sort_dir", "asc")
      next_dir = if sort_by == column and sort_dir == "asc", do: "desc", else: "asc"

      Chat.update_canvas_state(canvas, %{"sort_by" => column, "sort_dir" => next_dir})
    end

    {:halt, socket}
  end

  defp handle_event("canvas_save_form", %{"canvas_id" => canvas_id, "values" => values}, socket) do
    with %{} = canvas <- find(socket, canvas_id) do
      Chat.update_canvas_state(canvas, %{
        "values" => values,
        "submitted_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    end

    {:halt, socket}
  end

  defp handle_event(
         "canvas_save_code",
         %{"canvas_id" => canvas_id, "code_canvas" => params},
         socket
       ) do
    with %{} = canvas <- find(socket, canvas_id) do
      Chat.update_canvas_state(canvas, %{
        "language" => params["language"],
        "content" => params["content"],
        "saved_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    end

    {:halt, socket}
  end

  defp handle_event(
         "canvas_save_diagram",
         %{"canvas_id" => canvas_id, "diagram_canvas" => params},
         socket
       ) do
    with %{} = canvas <- find(socket, canvas_id) do
      Chat.update_canvas_state(canvas, %{
        "diagram_title" => params["diagram_title"],
        "source" => params["source"],
        "saved_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    end

    {:halt, socket}
  end

  defp handle_event("canvas_refresh_dashboard", %{"id" => canvas_id}, socket) do
    with %{} = canvas <- find(socket, canvas_id) do
      Chat.update_canvas_state(canvas, %{
        "metrics" => refresh_dashboard_metrics(canvas.state || %{}),
        "refreshed_at" =>
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })
    end

    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({:canvas_created, canvas}, socket), do: {:halt, put(socket, canvas)}
  defp handle_info({:canvas_updated, canvas}, socket), do: {:halt, put(socket, canvas)}

  defp handle_info({:canvas_action, _canvas, _value}, socket) do
    # Broadcast echo: other clients ignore it; originator already handled.
    {:halt, socket}
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # ── Render-layer helpers (used by parent template) ──────────────────

  @doc "Capitalize a canvas type for display."
  def humanize_type(type) when is_binary(type) do
    type
    |> String.replace(["_", "-"], " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def humanize_type(_type), do: "Canvas"

  @doc "Title for a canvas attached to a message (fallbacks through structured_content)."
  def message_canvas_title(message, canvases_by_message_id) do
    case Map.get(canvases_by_message_id, message.id) do
      %{title: title} when is_binary(title) and title != "" ->
        title

      _ ->
        get_in(message.structured_content || %{}, ["title"]) ||
          "Untitled Canvas"
    end
  end

  @doc "Human-readable canvas type label for a message-bound canvas."
  def message_canvas_type(message, canvases_by_message_id) do
    type =
      case Map.get(canvases_by_message_id, message.id) do
        %{canvas_type: type} when is_binary(type) -> type
        _ -> get_in(message.structured_content || %{}, ["canvas_type"]) || "custom"
      end

    humanize_type(type)
  end

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
      "title" => Map.get(attrs, "title", ""),
      "canvas_type" => Map.get(attrs, "canvas_type", "table")
    }

    assign(socket, :new_canvas_form, to_form(params, as: :canvas))
  end

  defp build_map(canvases) do
    canvases
    |> Map.new(fn canvas -> {canvas.message_id, canvas} end)
    |> Map.delete(nil)
  end

  defp maybe_update_active(socket, canvas) do
    case socket.assigns.active_canvas do
      %{id: id} when id == canvas.id -> assign(socket, :active_canvas, canvas)
      _ -> socket
    end
  end

  defp dispatch_to_agent(canvas, value) do
    with %{participant_type: "agent", participant_id: agent_id} <-
           Chat.get_participant(canvas.created_by),
         %Platform.Agents.Agent{} = agent <- Platform.Agents.get_agent(agent_id),
         runtime_id when is_binary(runtime_id) <- agent.runtime_id,
         topic = "runtime:#{runtime_id}",
         bundle = Platform.Chat.ContextPlane.build_context_bundle(canvas.space_id),
         tools = PlatformWeb.Channels.ToolSurface.tool_definitions() do
      payload = %{
        signal: %{
          reason: :canvas_action,
          space_id: canvas.space_id,
          canvas_id: canvas.id,
          canvas_title: canvas.title,
          action_value: value
        },
        message: %{
          content: "Action button pressed on canvas \"#{canvas.title || canvas.id}\": #{value}",
          author: "system"
        },
        history: [],
        context: bundle,
        tools: tools
      }

      case PlatformWeb.Endpoint.broadcast(topic, "attention", payload) do
        :ok ->
          Logger.info(
            "canvas_action dispatched to agent #{agent_id} (runtime: #{runtime_id}) value=#{value}"
          )

        {:error, reason} ->
          Logger.warning("canvas_action dispatch failed: #{inspect(reason)}")
      end
    else
      _ ->
        Logger.debug(
          "canvas_action: creator is not an agent or runtime not found, skipping dispatch"
        )
    end
  end

  # ── Default canvas state shapes ─────────────────────────────────────

  defp do_default_state("table") do
    %{
      "columns" => ["Task", "Owner", "Status"],
      "rows" => [
        %{"Task" => "Plan", "Owner" => "Rowan", "Status" => "Ready"},
        %{"Task" => "Build", "Owner" => "Zip", "Status" => "In Progress"},
        %{"Task" => "Ship", "Owner" => "Team", "Status" => "Queued"}
      ],
      "sort_dir" => "asc"
    }
  end

  defp do_default_state("form") do
    %{
      "fields" => [
        %{
          "name" => "goal",
          "label" => "Goal",
          "type" => "text",
          "placeholder" => "What are we aligning on?"
        },
        %{
          "name" => "owner",
          "label" => "Owner",
          "type" => "text",
          "placeholder" => "Who is driving it?"
        },
        %{
          "name" => "notes",
          "label" => "Notes",
          "type" => "textarea",
          "placeholder" => "Shared notes"
        }
      ],
      "values" => %{},
      "submit_label" => "Save"
    }
  end

  defp do_default_state("code") do
    %{
      "language" => "elixir",
      "content" => "# Shared canvas\n# Add notes or code here\n"
    }
  end

  defp do_default_state("diagram") do
    %{
      "diagram_title" => "Workflow",
      "source" => "graph TD\n  Idea --> Build\n  Build --> Review\n  Review --> Ship"
    }
  end

  defp do_default_state("dashboard") do
    %{"metrics" => refresh_dashboard_metrics(%{})}
  end

  defp do_default_state(_type) do
    %{"notes" => "Custom canvas ready for shared state."}
  end

  defp refresh_dashboard_metrics(state) do
    now = DateTime.utc_now()
    tick = System.system_time(:second)
    existing = Map.get(state, "metrics", [])

    labels =
      existing
      |> Enum.map(&Map.get(&1, "label"))
      |> Enum.filter(&is_binary/1)
      |> case do
        [] -> ["Open items", "People here", "Fresh edits"]
        labels -> labels
      end

    [
      %{
        "label" => Enum.at(labels, 0, "Open items"),
        "value" => Integer.to_string(rem(tick, 9) + 3),
        "trend" => "Updated #{format_timestamp(now)}"
      },
      %{
        "label" => Enum.at(labels, 1, "People here"),
        "value" => Integer.to_string(rem(tick, 4) + 1),
        "trend" => "Live presence"
      },
      %{
        "label" => Enum.at(labels, 2, "Fresh edits"),
        "value" => Integer.to_string(rem(tick, 7) + 1),
        "trend" => "Rolling 15 min"
      }
    ]
  end

  defp format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%I:%M %p")
end
