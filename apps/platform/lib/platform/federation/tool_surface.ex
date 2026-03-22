defmodule Platform.Federation.ToolSurface do
  @moduledoc """
  Write-only tool surface for federated agents.
  Same tools available to built-in and external runtimes.
  """

  alias Platform.Chat
  alias Platform.Tasks
  alias Platform.Tasks.{Task, Project, Epic}

  @doc """
  Returns the tool definitions for inclusion in attention signals.

  Each tool follows the 6-component rubric:
  name, description, parameters, returns, limitations, when_to_use.
  """
  def tool_definitions do
    canvas_tools() ++ task_tools()
  end

  defp canvas_tools do
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
      }
    ]
  end

  defp task_tools do
    [
      %{
        name: "project_list",
        description: "List all projects.",
        parameters: %{},
        returns: "Array of project objects with id, name, description",
        limitations: "Returns all projects; no filtering",
        when_to_use: "When you need to find a project to create tasks or epics in"
      },
      %{
        name: "epic_list",
        description: "List epics, optionally filtered by project.",
        parameters: %{
          project_id: %{
            type: "string",
            required: false,
            description: "Filter epics by project ID. Omit to list all epics."
          }
        },
        returns: "Array of epic objects with id, name, description, project_id, status",
        limitations: "None",
        when_to_use: "When you need to find an epic to assign a task to"
      },
      %{
        name: "task_create",
        description:
          "Create a new task in a project. Tasks track work items on the kanban board.",
        parameters: %{
          project_id: %{
            type: "string",
            required: true,
            description: "The project to create the task in"
          },
          title: %{type: "string", required: true, description: "Task title"},
          description: %{type: "string", required: false, description: "Task description"},
          epic_id: %{
            type: "string",
            required: false,
            description: "Epic to assign the task to"
          },
          status: %{
            type: "string",
            required: false,
            description:
              "Initial status: backlog (default), planning, ready, in_progress, in_review, done, blocked"
          },
          priority: %{
            type: "string",
            required: false,
            description: "Priority: low, medium (default), high, critical"
          },
          assignee_type: %{
            type: "string",
            required: false,
            description: "Assignee type: user or agent"
          },
          assignee_id: %{
            type: "string",
            required: false,
            description: "ID of the user or agent to assign"
          }
        },
        returns: "The created task object with id, title, status, priority",
        limitations: "Requires a valid project_id",
        when_to_use: "When you need to track a work item, feature, bug, or action item"
      },
      %{
        name: "task_get",
        description: "Get a single task by ID with full details.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID"}
        },
        returns: "Task object with id, title, description, status, priority, project_id, epic_id",
        limitations: "Returns nil if task not found",
        when_to_use: "When you need to check the current state of a specific task"
      },
      %{
        name: "task_list",
        description: "List tasks with optional filters.",
        parameters: %{
          project_id: %{
            type: "string",
            required: false,
            description: "Filter by project ID"
          },
          epic_id: %{
            type: "string",
            required: false,
            description: "Filter by epic ID"
          },
          status: %{
            type: "string",
            required: false,
            description: "Filter by status (backlog, in_progress, in_review, done, etc.)"
          }
        },
        returns: "Array of task objects",
        limitations: "Returns all matching tasks; no pagination yet",
        when_to_use:
          "When you need to see what tasks exist, check the backlog, or find tasks in a specific state"
      },
      %{
        name: "task_update",
        description:
          "Update a task's fields (title, description, status, priority, assignee, etc.).",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to update"},
          title: %{type: "string", required: false, description: "New title"},
          description: %{type: "string", required: false, description: "New description"},
          status: %{
            type: "string",
            required: false,
            description: "New status (must be a valid transition)"
          },
          priority: %{type: "string", required: false, description: "New priority"},
          epic_id: %{type: "string", required: false, description: "Move to a different epic"},
          assignee_type: %{type: "string", required: false, description: "Assignee type"},
          assignee_id: %{type: "string", required: false, description: "Assignee ID"}
        },
        returns: "The updated task object",
        limitations: "Status transitions are validated; not all transitions are allowed",
        when_to_use: "When you need to update a task's details or move it between columns"
      }
    ]
  end

  # ── Execute ──────────────────────────────────────────────────────────────

  @doc """
  Execute a tool call.

  context must include :space_id and :agent_participant_id.
  Returns {:ok, result} | {:error, %{error: string, recoverable: boolean, suggestion: string}}
  """

  # ── Canvas tools ─────────────────────────────────────────────────────────

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

  # ── Task tools ───────────────────────────────────────────────────────────

  def execute("project_list", _args, _context) do
    projects =
      Tasks.list_projects()
      |> Enum.map(fn p ->
        %{id: p.id, name: p.name, slug: p.slug, repo_url: p.repo_url}
      end)

    {:ok, projects}
  end

  def execute("epic_list", args, _context) do
    project_id = Map.get(args, "project_id")

    epics =
      Tasks.list_epics_for_project(project_id)
      |> Enum.map(fn e ->
        %{
          id: e.id,
          name: e.name,
          description: e.description,
          project_id: e.project_id,
          status: e.status
        }
      end)

    {:ok, epics}
  end

  def execute("task_create", args, _context) do
    attrs = %{
      project_id: Map.get(args, "project_id"),
      title: Map.get(args, "title", "Untitled Task"),
      description: Map.get(args, "description"),
      epic_id: Map.get(args, "epic_id"),
      status: Map.get(args, "status", "backlog"),
      priority: Map.get(args, "priority", "medium"),
      assignee_type: Map.get(args, "assignee_type"),
      assignee_id: Map.get(args, "assignee_id")
    }

    case Tasks.create_task(attrs) do
      {:ok, task} ->
        Tasks.broadcast_board({:task_created, task})

        {:ok,
         %{
           id: task.id,
           title: task.title,
           status: task.status,
           priority: task.priority,
           project_id: task.project_id,
           epic_id: task.epic_id
         }}

      {:error, changeset} ->
        {:error,
         %{
           error: "Failed to create task: #{inspect_errors(changeset)}",
           recoverable: true,
           suggestion: "Check that project_id is valid and title is provided"
         }}
    end
  end

  def execute("task_get", args, _context) do
    task_id = Map.get(args, "task_id")

    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      task ->
        {:ok, serialize_task(task)}
    end
  end

  def execute("task_list", args, _context) do
    tasks =
      cond do
        project_id = Map.get(args, "project_id") ->
          Tasks.list_tasks_by_project(project_id)

        epic_id = Map.get(args, "epic_id") ->
          Tasks.list_tasks_by_epic(epic_id)

        status = Map.get(args, "status") ->
          Tasks.list_tasks_by_status(status)

        true ->
          Tasks.list_all_tasks()
      end

    {:ok, Enum.map(tasks, &serialize_task/1)}
  end

  def execute("task_update", args, _context) do
    task_id = Map.get(args, "task_id")

    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      task ->
        # Build update attrs from provided fields only
        update_attrs =
          args
          |> Map.take([
            "title",
            "description",
            "status",
            "priority",
            "epic_id",
            "assignee_type",
            "assignee_id"
          ])
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)

        # Use transition_task_status for status changes, regular update for others
        status_change = Map.get(update_attrs, :status)
        other_attrs = Map.delete(update_attrs, :status)

        # Apply non-status updates first
        result =
          if map_size(other_attrs) > 0 do
            Tasks.update_task(task, other_attrs)
          else
            {:ok, task}
          end

        # Then apply status transition if requested
        result =
          case {result, status_change} do
            {{:ok, updated_task}, nil} ->
              {:ok, updated_task}

            {{:ok, updated_task}, new_status} ->
              Tasks.transition_task_status(updated_task, new_status)

            {{:error, _} = err, _} ->
              err
          end

        case result do
          {:ok, updated} ->
            Tasks.broadcast_board({:task_updated, updated})
            {:ok, serialize_task(updated)}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error: "Invalid status transition from '#{task.status}' to '#{status_change}'",
               recoverable: true,
               suggestion: "Check allowed transitions for the current status"
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to update task: #{inspect_errors(changeset)}",
               recoverable: true,
               suggestion: "Check that the provided values are valid"
             }}
        end
    end
  end

  def execute(unknown_tool, _args, _context) do
    tool_names =
      tool_definitions()
      |> Enum.map(& &1.name)
      |> Enum.join(", ")

    {:error,
     %{
       error: "Unknown tool: #{unknown_tool}",
       recoverable: false,
       suggestion: "Available tools: #{tool_names}"
     }}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp serialize_task(task) do
    %{
      id: task.id,
      title: task.title,
      description: task.description,
      status: task.status,
      priority: task.priority,
      project_id: task.project_id,
      epic_id: task.epic_id,
      assignee_type: task.assignee_type,
      assignee_id: task.assignee_id,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp inspect_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end
end
