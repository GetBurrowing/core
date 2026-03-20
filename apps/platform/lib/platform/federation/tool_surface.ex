defmodule Platform.Federation.ToolSurface do
  @moduledoc """
  Write-only tool surface for federated agents.
  Same tools available to built-in and external runtimes.
  """

  alias Platform.Chat

  @doc """
  Returns the tool definitions for inclusion in attention signals.

  Each tool follows the 6-component rubric:
  name, description, parameters, returns, limitations, when_to_use.
  """
  def tool_definitions do
    [
      %{
        name: "canvas_create",
        description:
          "Create a new live canvas in a space. Canvases are collaborative visual artifacts (tables, forms, code blocks, diagrams, dashboards).",
        parameters: %{
          space_id: %{
            type: "string",
            required: true,
            description: "The space to create the canvas in"
          },
          canvas_type: %{
            type: "string",
            required: true,
            description: "One of: table, form, code, diagram, dashboard, custom"
          },
          title: %{
            type: "string",
            required: false,
            description: "Human-readable title for the canvas"
          },
          initial_state: %{
            type: "object",
            required: false,
            description: "Initial state map for the canvas"
          }
        },
        returns: "The created canvas object with id, title, type",
        limitations: "Cannot create canvases in spaces the agent is not a participant of",
        when_to_use: "When you need to present structured, interactive, or visual data to users"
      },
      %{
        name: "canvas_update",
        description: "Update an existing canvas by merging new keys into its state.",
        parameters: %{
          canvas_id: %{type: "string", required: true, description: "The canvas to update"},
          patches: %{
            type: "object",
            required: true,
            description: "Map of keys to merge into canvas state"
          }
        },
        returns: "The updated canvas object",
        limitations:
          "Cannot update canvases in spaces the agent is not a participant of. Patches are merged, not replaced.",
        when_to_use: "When you need to modify the content or state of an existing canvas"
      },
      %{
        name: "task_create",
        description: "Create a new task in a space.",
        parameters: %{
          space_id: %{
            type: "string",
            required: true,
            description: "The space to create the task in"
          },
          title: %{type: "string", required: true, description: "Task title"},
          description: %{type: "string", required: false, description: "Task description"}
        },
        returns: "The created task object with id and title",
        limitations:
          "Task system is a placeholder — tasks are stored as canvas artifacts for now",
        when_to_use: "When you need to track a work item or action item"
      },
      %{
        name: "task_complete",
        description: "Mark an existing task as complete.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to complete"}
        },
        returns: "The updated task object",
        limitations: "Task system is a placeholder — completion updates canvas state",
        when_to_use: "When a tracked work item is finished"
      }
    ]
  end

  @doc """
  Execute a tool call.

  context must include :space_id and :agent_participant_id.
  Returns {:ok, result} | {:error, %{error: string, recoverable: boolean, suggestion: string}}
  """
  def execute("canvas_create", args, context) do
    space_id = Map.get(args, "space_id") || Map.get(context, :space_id)
    participant_id = Map.get(context, :agent_participant_id)

    canvas_attrs = %{
      "canvas_type" => Map.get(args, "canvas_type", "custom"),
      "title" => Map.get(args, "title"),
      "state" => Map.get(args, "initial_state", %{})
    }

    try do
      case Chat.create_canvas_with_message(space_id, participant_id, canvas_attrs) do
        {:ok, canvas, _message} ->
          {:ok, %{id: canvas.id, title: canvas.title, type: canvas.canvas_type}}

        {:error, reason} ->
          {:error,
           %{
             error: "Failed to create canvas: #{inspect(reason)}",
             recoverable: true,
             suggestion: "Verify the space_id is valid and the agent is a participant"
           }}
      end
    rescue
      e ->
        {:error,
         %{
           error: "Failed to create canvas: #{Exception.message(e)}",
           recoverable: true,
           suggestion: "Verify the space_id is valid and the agent is a participant"
         }}
    end
  end

  def execute("canvas_update", args, _context) do
    canvas_id = Map.get(args, "canvas_id")
    patches = Map.get(args, "patches", %{})

    case Chat.get_canvas(canvas_id) do
      nil ->
        {:error,
         %{
           error: "Canvas not found: #{canvas_id}",
           recoverable: false,
           suggestion: "Use canvas_create to create a new canvas instead"
         }}

      canvas ->
        case Chat.update_canvas_state(canvas, patches) do
          {:ok, updated} ->
            {:ok, %{id: updated.id, title: updated.title, type: updated.canvas_type}}

          {:error, reason} ->
            {:error,
             %{
               error: "Failed to update canvas: #{inspect(reason)}",
               recoverable: true,
               suggestion: "Check that the patches are valid JSON-compatible maps"
             }}
        end
    end
  end

  def execute("task_create", args, context) do
    space_id = Map.get(args, "space_id") || Map.get(context, :space_id)
    participant_id = Map.get(context, :agent_participant_id)
    title = Map.get(args, "title", "Untitled Task")
    description = Map.get(args, "description", "")

    canvas_attrs = %{
      "canvas_type" => "custom",
      "title" => title,
      "state" => %{"type" => "task", "description" => description, "status" => "open"}
    }

    case Chat.create_canvas_with_message(space_id, participant_id, canvas_attrs) do
      {:ok, canvas, _message} ->
        {:ok, %{id: canvas.id, title: canvas.title}}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to create task: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Verify the space_id is valid and the agent is a participant"
         }}
    end
  end

  def execute("task_complete", args, _context) do
    task_id = Map.get(args, "task_id")

    case Chat.get_canvas(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Verify the task_id is correct"
         }}

      canvas ->
        case Chat.update_canvas_state(canvas, %{"status" => "completed"}) do
          {:ok, updated} ->
            {:ok, %{id: updated.id, title: updated.title}}

          {:error, reason} ->
            {:error,
             %{
               error: "Failed to complete task: #{inspect(reason)}",
               recoverable: true,
               suggestion: "Try again or check that the task exists"
             }}
        end
    end
  end

  def execute(unknown_tool, _args, _context) do
    {:error,
     %{
       error: "Unknown tool: #{unknown_tool}",
       recoverable: false,
       suggestion: "Available tools: canvas_create, canvas_update, task_create, task_complete"
     }}
  end
end
