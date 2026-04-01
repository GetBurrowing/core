defmodule Platform.Federation.ToolSurface do
  @moduledoc """
  Tool surface for federated agents.
  Same tools available to built-in and external runtimes.
  Includes both write tools and bounded read tools for space context.
  """

  alias Platform.Chat
  alias Platform.Chat.ContextPlane
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, PlanEngine, Stage, Validation}
  alias Platform.Repo

  @doc """
  Returns the tool definitions for inclusion in attention signals.

  Each tool follows the 6-component rubric:
  name, description, parameters, returns, limitations, when_to_use.
  """
  def tool_definitions do
    canvas_tools() ++
      messaging_tools() ++
      task_tools() ++
      plan_tools() ++
      review_tools() ++
      space_tools() ++ context_read_tools() ++ federation_tools()
  end

  defp federation_tools do
    [
      %{
        name: "federation_status",
        description:
          "Check the connection status of all registered agent runtimes. Shows which runtimes are online, when they connected, and when they last sent a message.",
        parameters: %{},
        returns:
          "Array of runtime status objects with runtime_id, agent_name, online, connected_at, last_seen_at, last_connected_at",
        limitations:
          "Only shows active runtimes. Presence data is in-memory and resets on restart.",
        when_to_use:
          "When you need to diagnose connectivity issues or verify which agent runtimes are currently reachable"
      }
    ]
  end

  defp messaging_tools do
    [
      %{
        name: "send_media",
        description: "Send a message with one or more file attachments to a Suite space.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"},
          file_paths: %{
            type: "array",
            required: false,
            description: "Absolute local file paths to attach"
          },
          file_path: %{
            type: "string",
            required: false,
            description: "Back-compat single absolute local path to the file"
          },
          content: %{
            type: "string",
            required: false,
            description: "Optional message text"
          },
          filename: %{
            type: "string",
            required: false,
            description: "Optional display filename for single-file uploads"
          }
        },
        returns: "The message ID, space ID, and attachment count",
        limitations:
          "Files must exist on the local filesystem. Agent must be a participant in the space.",
        when_to_use: "When you need to share files (images, documents, etc.) in a space"
      }
    ]
  end

  defp review_tools do
    [
      %{
        name: "review_request_create",
        description:
          "Submit evidence for a manual_approval validation gate. Creates a review request with labelled items for human review. Each item is independently approvable. Use this instead of validation_evaluate for manual_approval validations.",
        parameters: %{
          validation_id: %{
            type: "string",
            required: true,
            description: "The manual_approval validation ID to submit evidence for"
          },
          items: %{
            type: "array",
            required: true,
            description:
              "Array of review items: {label: string, canvas_id?: string, content?: string}. Each item is independently reviewed by a human."
          }
        },
        returns: "The created review request object with id, status, and items list",
        limitations: "Only for manual_approval validations. Items cannot be empty.",
        when_to_use:
          "When you reach a manual_approval validation gate and need to submit evidence (screenshots, canvases, text) for human review"
      }
    ]
  end

  defp space_tools do
    [
      %{
        name: "space_list",
        description: "List Suite spaces the agent is a member of.",
        parameters: %{
          kind: %{
            type: "string",
            required: false,
            description: "Filter by kind: channel, dm (optional)"
          }
        },
        returns: "Array of space objects with id, name, kind, description",
        limitations: "Only returns spaces the agent is a participant in",
        when_to_use:
          "When you need to discover available spaces or find a space ID for proactive messaging"
      }
    ]
  end

  defp context_read_tools do
    [
      %{
        name: "space_get_context",
        description:
          "Get the current context bundle for a space: recent activity summary, active canvases, other agents, and space metadata. Useful for orienting yourself in a space before acting.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"}
        },
        returns:
          "Context bundle with space metadata, active_canvases, other_agents, and recent_activity_summary",
        limitations:
          "Only works for spaces the agent is an active participant in. Activity data is in-memory and may be incomplete after restarts.",
        when_to_use:
          "When you join a space or need to understand what has been happening before you act"
      },
      %{
        name: "space_search_messages",
        description:
          "Full-text search messages in a space. Returns up to 10 results ranked by relevance with highlighted excerpts.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"},
          query: %{
            type: "string",
            required: true,
            description: "Search query (supports natural language)"
          },
          limit: %{
            type: "integer",
            required: false,
            description: "Max results to return (default 10, max 10)"
          }
        },
        returns:
          "Array of message objects with id, participant_id, content, search_headline, inserted_at",
        limitations:
          "Only searches spaces the agent is a participant in. Max 10 results. Uses PostgreSQL full-text search.",
        when_to_use: "When you need to find specific messages or topics discussed in a space"
      },
      %{
        name: "space_get_messages",
        description:
          "Get recent messages from a space, newest first. Supports cursor-based pagination.",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"},
          limit: %{
            type: "integer",
            required: false,
            description: "Number of messages to return (default 20, max 20)"
          },
          before_id: %{
            type: "string",
            required: false,
            description: "Cursor: only return messages older than this message ID"
          }
        },
        returns:
          "Array of message objects with id, participant_id, content_type, content, inserted_at",
        limitations:
          "Only works for spaces the agent is a participant in. Max 20 messages per call.",
        when_to_use: "When you need to read the recent conversation history in a space"
      },
      %{
        name: "canvas_list",
        description:
          "List all canvases in a space with summary information (id, title, type, timestamps).",
        parameters: %{
          space_id: %{type: "string", required: true, description: "UUID of the Suite space"}
        },
        returns: "Array of canvas summary objects with id, title, type, inserted_at, updated_at",
        limitations: "Only works for spaces the agent is a participant in.",
        when_to_use:
          "When you need to discover what canvases exist in a space before reading or updating one"
      },
      %{
        name: "canvas_get",
        description:
          "Get a canvas by ID. Returns summary by default, or full document state with mode=full.",
        parameters: %{
          canvas_id: %{type: "string", required: true, description: "UUID of the canvas"},
          mode: %{
            type: "string",
            required: false,
            description:
              "\"summary\" (default) or \"full\" — full includes the complete state map"
          }
        },
        returns:
          "Canvas object with id, title, type, space_id, and optionally the full state document",
        limitations:
          "Only works for canvases in spaces the agent is a participant in. Full mode may return large payloads for complex canvases.",
        when_to_use:
          "When you need to inspect a canvas's content before updating it, or to present canvas data to a user"
      }
    ]
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
        name: "epic_update",
        description: "Update an epic's fields including target_branch and deploy_target.",
        parameters: %{
          epic_id: %{type: "string", required: true, description: "The epic to update"},
          name: %{type: "string", required: false, description: "New epic name"},
          description: %{type: "string", required: false, description: "New description"},
          status: %{type: "string", required: false, description: "New status"},
          target_branch: %{
            type: "string",
            required: false,
            description: "Git branch for task worktrees in this epic (e.g. feat/reskin)"
          },
          deploy_target: %{
            type: "string",
            required: false,
            description: "Deploy target for tasks in this epic (e.g. exp, prod)"
          }
        },
        returns: "The updated epic object",
        limitations: "Epic must exist",
        when_to_use: "When you need to configure an epic's target branch or deploy target"
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
              "Initial status: backlog (default), planning, ready, in_progress, in_review, deploying, done, blocked"
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
        name: "task_complete",
        description: "Mark a task as done.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID to complete"}
        },
        returns: "The updated task object with id and status",
        limitations: "Task must exist and allow transition to done status",
        when_to_use: "When you need to mark a task as complete/done"
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
      },
      %{
        name: "task_start",
        description:
          "Start a task — sets assignee (optional), transitions to in_progress, kicks off TaskRouter. Use instead of task_update when ready to begin work.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to start"},
          assignee_id: %{
            type: "string",
            required: false,
            description: "Agent ID to assign. Defaults to current assignee."
          },
          assignee_type: %{
            type: "string",
            required: false,
            description: "Assignee type: agent or user. Defaults to agent."
          }
        },
        returns: "Updated task object with status in_progress",
        limitations: "Task must be in backlog, planning, or ready status",
        when_to_use: "When task is fully specced and ready to begin"
      }
    ]
  end

  defp plan_tools do
    [
      %{
        name: "plan_create",
        description:
          "Create a new execution plan for a task with stages and validations, all in a single transaction.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task to create a plan for"},
          stages: %{
            type: "array",
            required: true,
            description:
              "Array of stage objects: {name, description, position, validations: [{kind}]}. Valid validation kinds: ci_check, lint_pass, type_check, test_pass, code_review, manual_approval"
          }
        },
        returns: "The created plan with stages and validations preloaded",
        limitations: "Requires a valid task_id. Stages must have unique positions.",
        when_to_use: "When you need to define a multi-stage execution plan for a task"
      },
      %{
        name: "plan_get",
        description: "Get the current approved plan for a task with full stage/validation tree.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID"}
        },
        returns: "Plan object with stages and validations preloaded",
        limitations: "Returns error if no approved plan exists for the task",
        when_to_use: "When you need to check the current execution plan for a task"
      },
      %{
        name: "plan_submit",
        description: "Submit a draft plan for review (draft → pending_review).",
        parameters: %{
          plan_id: %{type: "string", required: true, description: "The plan ID to submit"}
        },
        returns: "The updated plan object",
        limitations: "Plan must be in draft status",
        when_to_use: "When a plan is ready to be reviewed and approved"
      },
      %{
        name: "plan_approve",
        description:
          "Approve a plan that is in pending_review status. Transitions the plan to approved and auto-advances the task to in_progress if it was in planning/ready/backlog.",
        parameters: %{
          plan_id: %{type: "string", required: true, description: "The plan ID to approve"},
          approved_by: %{
            type: "string",
            required: false,
            description: "Who is approving (agent slug or user ID). Defaults to system."
          }
        },
        returns: "The approved plan object",
        limitations: "Plan must be in pending_review status",
        when_to_use:
          "After plan_submit, when you want to approve a plan and kick off task execution without waiting for human review"
      },
      %{
        name: "stage_start",
        description: "Start a pending stage (pending → running).",
        parameters: %{
          stage_id: %{type: "string", required: true, description: "The stage ID to start"}
        },
        returns: "The updated stage object",
        limitations: "Stage must be in pending status",
        when_to_use: "When you are ready to begin executing a stage"
      },
      %{
        name: "stage_list",
        description:
          "List all stages for a plan, ordered by position, with validations preloaded.",
        parameters: %{
          plan_id: %{type: "string", required: true, description: "The plan ID"}
        },
        returns: "Array of stage objects with validations",
        limitations: "None",
        when_to_use: "When you need to see all stages and their validation status for a plan"
      },
      %{
        name: "validation_evaluate",
        description:
          "Record a validation result (passed/failed). Auto-advances the stage if all validations are resolved.",
        parameters: %{
          validation_id: %{
            type: "string",
            required: true,
            description: "The validation ID to evaluate"
          },
          status: %{
            type: "string",
            required: true,
            description: "Result: \"passed\" or \"failed\""
          },
          evidence: %{
            type: "object",
            required: false,
            description: "Optional evidence map (e.g. CI output, test results)"
          },
          evaluated_by: %{
            type: "string",
            required: false,
            description: "Who evaluated this (user ID or \"system\")"
          }
        },
        returns: "The updated validation object",
        limitations: "Status must be \"passed\" or \"failed\"",
        when_to_use: "When a validation check has completed and you need to record the result"
      },
      %{
        name: "validation_pass",
        description:
          "Convenience alias for marking a validation as passed. Mirrors validation_evaluate with status=passed.",
        parameters: %{
          validation_id: %{
            type: "string",
            required: true,
            description: "The validation ID to mark passed"
          },
          evidence: %{
            type: "object",
            required: false,
            description: "Optional evidence payload"
          },
          evaluated_by: %{
            type: "string",
            required: false,
            description: "Who evaluated this (user ID or \"system\")"
          }
        },
        returns: "The updated validation object",
        limitations: "Equivalent to validation_evaluate with status=passed",
        when_to_use:
          "When prompt contracts refer to validation_pass and you need to mark a validation successful"
      },
      %{
        name: "stage_complete",
        description:
          "Attempt to advance a running stage once its validations are satisfied. Useful for stages with no validations or for prompt contracts that refer to stage_complete.",
        parameters: %{
          stage_id: %{type: "string", required: true, description: "The running stage ID"}
        },
        returns: "Structured result describing the completed stage and updated plan state",
        limitations: "Fails if the stage is not running or still has pending/failed validations.",
        when_to_use: "When you have completed a running stage and need the plan engine to advance"
      },
      %{
        name: "report_blocker",
        description:
          "Report a blocker for the current task stage. Records a structured execution.blocked event so the router can stop treating silence as liveness.",
        parameters: %{
          task_id: %{type: "string", required: true, description: "The task ID"},
          stage_id: %{type: "string", required: true, description: "The current stage ID"},
          description: %{
            type: "string",
            required: true,
            description: "What is blocked and why"
          },
          needs_human: %{
            type: "boolean",
            required: false,
            description: "Whether the blocker requires human intervention"
          }
        },
        returns: "Structured blocker acknowledgement with event ID and escalation hint",
        limitations: "Requires task_id and stage_id from the current execution context.",
        when_to_use:
          "When you cannot proceed and need the orchestrator to pause silence-based escalation"
      },
      %{
        name: "validation_list",
        description: "List all validations for a stage.",
        parameters: %{
          stage_id: %{type: "string", required: true, description: "The stage ID"}
        },
        returns: "Array of validation objects",
        limitations: "None",
        when_to_use: "When you need to see the validation status for a specific stage"
      },
      %{
        name: "prompt_template_list",
        description:
          "List all prompt templates (dispatch and heartbeat prompts used by the orchestrator).",
        parameters: %{},
        returns: "Array of prompt template objects with slug, name, description, variables",
        limitations: "None",
        when_to_use:
          "When you need to see or audit the current dispatch/heartbeat prompt templates"
      },
      %{
        name: "prompt_template_update",
        description:
          "Update the content of a prompt template by slug. " <>
            "Use {{variable_name}} placeholders for dynamic values. " <>
            "Sets updated_by to \"agent\".",
        parameters: %{
          slug: %{
            type: "string",
            required: true,
            description:
              "Template slug (e.g. dispatch.planning, dispatch.in_progress, dispatch.in_review, dispatch.fallback, heartbeat)"
          },
          content: %{
            type: "string",
            required: true,
            description:
              "New template content with {{variable_name}} placeholders for interpolation"
          }
        },
        returns: "The updated prompt template object",
        limitations: "Template must exist. Use prompt_template_list to see available slugs.",
        when_to_use: "When you need to improve or customize a dispatch or heartbeat prompt"
      }
    ]
  end

  # ── Execute ──────────────────────────────────────────────────────────────

  @doc """
  Execute a tool call.

  context must include :space_id and :agent_participant_id.
  Returns {:ok, result} | {:error, %{error: string, recoverable: boolean, suggestion: string}}
  """

  # ── Messaging tools ──────────────────────────────────────────────────────

  def execute("send_media", args, context) do
    space_id = Map.get(args, "space_id")
    content = Map.get(args, "content", "")

    participant_id =
      Map.get(context, :agent_participant_id) ||
        get_agent_participant_id_for_space(space_id, context)

    case normalize_send_media_attachments(args) do
      {:ok, attachment_specs} ->
        with {:ok, attachment_attrs} <- persist_send_media_attachments(attachment_specs),
             {:ok, message, attachments} <-
               Chat.post_message_with_attachments(
                 %{
                   space_id: space_id,
                   participant_id: participant_id,
                   content_type: "text",
                   content: content
                 },
                 attachment_attrs
               ) do
          {:ok,
           %{
             message_id: message.id,
             space_id: space_id,
             attachment_count: length(attachments)
           }}
        else
          {:error, reason} ->
            {:error,
             %{
               error: "Failed to send media: #{inspect(reason)}",
               recoverable: true,
               suggestion:
                 "Check that the files exist and the agent is a participant in the space"
             }}
        end

      {:error, message} ->
        {:error,
         %{
           error: message,
           recoverable: true,
           suggestion:
             "Pass file_paths as a non-empty array, or file_path for a single attachment"
         }}
    end
  end

  defp normalize_send_media_attachments(args) do
    file_paths =
      case Map.get(args, "file_paths") do
        paths when is_list(paths) -> Enum.filter(paths, &is_binary/1)
        _ -> []
      end

    attachment_specs =
      cond do
        file_paths != [] ->
          Enum.map(file_paths, fn path ->
            %{path: path, filename: Path.basename(path)}
          end)

        is_binary(Map.get(args, "file_path")) and Map.get(args, "file_path") != "" ->
          file_path = Map.get(args, "file_path")
          filename = Map.get(args, "filename") || Path.basename(file_path)
          [%{path: file_path, filename: filename}]

        true ->
          []
      end

    case attachment_specs do
      [] -> {:error, "Failed to send media: no file path provided"}
      specs -> {:ok, specs}
    end
  end

  defp persist_send_media_attachments(attachment_specs) do
    attachment_specs
    |> Enum.reduce_while({:ok, []}, fn %{path: path, filename: filename}, {:ok, acc} ->
      case Chat.AttachmentStorage.persist_upload(path, filename) do
        {:ok, file_meta} -> {:cont, {:ok, [Map.put(file_meta, :message_id, nil) | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attachment_attrs} -> {:ok, Enum.reverse(attachment_attrs)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Review tools ────────────────────────────────────────────────────────

  def execute("review_request_create", args, context) do
    validation_id = Map.get(args, "validation_id")
    items = Map.get(args, "items", [])

    with validation when not is_nil(validation) <- Repo.get(Validation, validation_id),
         stage when not is_nil(stage) <- Repo.get(Stage, validation.stage_id),
         plan when not is_nil(plan) <- Repo.get(Plan, stage.plan_id) do
      # Find or create the execution space for the task
      execution_space_id =
        case Platform.Orchestration.ExecutionSpace.find_or_create(plan.task_id) do
          {:ok, space} -> space.id
          _ -> nil
        end

      attrs = %{
        validation_id: validation_id,
        task_id: plan.task_id,
        execution_space_id: execution_space_id,
        submitted_by: Map.get(context, :agent_id) || "agent",
        items: items
      }

      case Platform.Tasks.ReviewRequests.create_review_request(attrs) do
        {:ok, request} ->
          {:ok, serialize_review_request(request)}

        {:error, reason} ->
          {:error,
           %{
             error: "Failed to create review request: #{inspect_errors_safe(reason)}",
             recoverable: true,
             suggestion: "Check that items have valid labels and validation_id is correct"
           }}
      end
    else
      nil ->
        {:error,
         %{
           error: "Validation, stage, or plan not found for validation_id: #{validation_id}",
           recoverable: false,
           suggestion:
             "Verify the validation_id belongs to an existing manual_approval validation"
         }}
    end
  end

  # ── Space tools ─────────────────────────────────────────────────────────

  def execute("space_list", args, context) do
    agent_id = Map.get(context, :agent_id)
    kind = Map.get(args, "kind")

    spaces = Chat.list_spaces_for_agent(agent_id, kind: kind)

    {:ok,
     Enum.map(spaces, fn s ->
       %{id: s.id, name: s.name, kind: s.kind, description: s.description}
     end)}
  end

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

  # ── Context read tools ──────────────────────────────────────────────────

  def execute("space_get_context", args, context) do
    space_id = Map.get(args, "space_id")

    with :ok <- assert_agent_in_space(space_id, context) do
      bundle = ContextPlane.build_context_bundle(space_id)

      # Enrich with space metadata from DB
      space_meta =
        case Chat.get_space(space_id) do
          nil -> %{}
          s -> %{id: s.id, name: s.name, kind: s.kind, description: s.description}
        end

      {:ok, Map.put(bundle, :space, space_meta)}
    end
  end

  def execute("space_search_messages", args, context) do
    space_id = Map.get(args, "space_id")
    query = Map.get(args, "query", "")
    limit = args |> Map.get("limit", 10) |> min(10)

    with :ok <- assert_agent_in_space(space_id, context) do
      messages = Chat.search_messages(space_id, query, limit: limit)

      {:ok,
       Enum.map(messages, fn m ->
         %{
           id: m.id,
           participant_id: m.participant_id,
           content: String.slice(m.content || "", 0, 500),
           search_headline: m.search_headline,
           inserted_at: format_datetime(m.inserted_at)
         }
       end)}
    end
  end

  def execute("space_get_messages", args, context) do
    space_id = Map.get(args, "space_id")
    limit = args |> Map.get("limit", 20) |> min(20)
    before_id = Map.get(args, "before_id")

    with :ok <- assert_agent_in_space(space_id, context) do
      opts = [limit: limit, top_level_only: true]
      opts = if before_id, do: Keyword.put(opts, :before_id, before_id), else: opts

      messages = Chat.list_messages(space_id, opts)

      {:ok,
       Enum.map(messages, fn m ->
         %{
           id: m.id,
           participant_id: m.participant_id,
           content_type: m.content_type,
           content: String.slice(m.content || "", 0, 500),
           thread_id: m.thread_id,
           inserted_at: format_datetime(m.inserted_at)
         }
       end)}
    end
  end

  def execute("canvas_list", args, context) do
    space_id = Map.get(args, "space_id")

    with :ok <- assert_agent_in_space(space_id, context) do
      canvases = Chat.list_canvases(space_id)

      {:ok,
       Enum.map(canvases, fn c ->
         %{
           id: c.id,
           title: c.title,
           type: c.canvas_type,
           inserted_at: format_datetime(c.inserted_at),
           updated_at: format_datetime(c.updated_at)
         }
       end)}
    end
  end

  def execute("canvas_get", args, context) do
    canvas_id = Map.get(args, "canvas_id")
    mode = Map.get(args, "mode", "summary")

    case Chat.get_canvas(canvas_id) do
      nil ->
        {:error,
         %{
           error: "Canvas not found: #{canvas_id}",
           recoverable: false,
           suggestion: "Use canvas_list to find available canvases in the space"
         }}

      canvas ->
        with :ok <- assert_agent_in_space(canvas.space_id, context) do
          result = %{
            id: canvas.id,
            title: canvas.title,
            type: canvas.canvas_type,
            space_id: canvas.space_id,
            inserted_at: format_datetime(canvas.inserted_at),
            updated_at: format_datetime(canvas.updated_at)
          }

          result =
            if mode == "full" do
              Map.put(result, :state, canvas.state)
            else
              result
            end

          {:ok, result}
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

  def execute("epic_update", args, _context) do
    epic_id = Map.get(args, "epic_id")

    case Tasks.get_epic(epic_id) do
      nil ->
        {:error,
         %{
           error: "Epic not found: #{epic_id}",
           recoverable: false,
           suggestion: "Use epic_list to find available epics"
         }}

      epic ->
        attrs =
          args
          |> Map.take(["name", "description", "status", "target_branch", "deploy_target"])
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
          |> Enum.into(%{}, fn {k, v} -> {String.to_existing_atom(k), v} end)

        case Tasks.update_epic(epic, attrs) do
          {:ok, updated} ->
            Tasks.broadcast_board({:epic_updated, updated})

            {:ok,
             %{
               id: updated.id,
               name: updated.name,
               status: updated.status,
               target_branch: updated.target_branch,
               deploy_target: updated.deploy_target
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to update epic: #{inspect_errors(changeset)}",
               recoverable: true
             }}
        end
    end
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
      assignee_id: Map.get(args, "assignee_id"),
      reported_by: Map.get(args, "reported_by")
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

  def execute("task_complete", %{"task_id" => task_id}, _context) do
    case Tasks.get_task_record(task_id) do
      nil ->
        {:error,
         %{
           error: "Task not found: #{task_id}",
           recoverable: false,
           suggestion: "Use task_list to find available tasks"
         }}

      task ->
        case Tasks.transition_task_status(task, "done") do
          {:ok, updated} ->
            Tasks.broadcast_board({:task_updated, updated})
            {:ok, %{task_id: updated.id, status: updated.status}}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error: "Cannot transition task from '#{task.status}' to 'done'",
               recoverable: false,
               suggestion:
                 "Check the task's current status — only in_progress and in_review can move to done"
             }}

          {:error, changeset} ->
            {:error,
             %{
               error: "Failed to complete task: #{inspect_errors(changeset)}",
               recoverable: true,
               suggestion: "Check that the task_id is valid"
             }}
        end
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

  def execute("task_start", args, _context) do
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
        task =
          case {Map.get(args, "assignee_id"), Map.get(args, "assignee_type", "agent")} do
            {nil, _} ->
              task

            {assignee_id, assignee_type} ->
              case Tasks.update_task(task, %{
                     assignee_id: assignee_id,
                     assignee_type: assignee_type
                   }) do
                {:ok, updated} -> updated
                _ -> task
              end
          end

        case Tasks.transition_task(task, "in_progress") do
          {:ok, updated} ->
            Tasks.broadcast_board({:task_updated, updated})

            {:ok,
             %{
               id: updated.id,
               title: updated.title,
               status: updated.status,
               assignee_id: updated.assignee_id,
               assignee_type: updated.assignee_type
             }}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error:
                 "Cannot start task from status #{task.status}. Must be backlog, planning, or ready.",
               recoverable: true,
               suggestion: "Check task status with task_get first"
             }}

          {:error, reason} ->
            {:error, %{error: "Failed to start task: #{inspect(reason)}", recoverable: true}}
        end
    end
  end

  # ── Plan / Stage / Validation tools ──────────────────────────────────────

  def execute("plan_create", args, _context) do
    task_id = Map.get(args, "task_id")
    stages_input = Map.get(args, "stages", [])

    if is_nil(task_id) do
      {:error,
       %{
         error: "task_id is required",
         recoverable: true,
         suggestion: "Provide a valid task_id"
       }}
    else
      Repo.transaction(fn ->
        case Tasks.create_plan(%{task_id: task_id}) do
          {:ok, plan} ->
            stages =
              Enum.map(stages_input, fn stage_input ->
                stage_attrs = %{
                  plan_id: plan.id,
                  name: Map.get(stage_input, "name"),
                  description: Map.get(stage_input, "description"),
                  position: Map.get(stage_input, "position"),
                  expected_artifacts: Map.get(stage_input, "expected_artifacts", [])
                }

                case Tasks.create_stage(stage_attrs) do
                  {:ok, stage} ->
                    validations =
                      stage_input
                      |> Map.get("validations", [])
                      |> Enum.map(fn v_input ->
                        case Tasks.create_validation(%{
                               stage_id: stage.id,
                               kind: Map.get(v_input, "kind")
                             }) do
                          {:ok, validation} -> validation
                          {:error, reason} -> Repo.rollback(reason)
                        end
                      end)

                    Map.put(stage, :validations, validations)

                  {:error, reason} ->
                    Repo.rollback(reason)
                end
              end)

            Map.put(plan, :stages, stages)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, plan} ->
          {:ok, serialize_plan(plan)}

        {:error, reason} ->
          {:error,
           %{
             error: "Failed to create plan: #{inspect_errors_safe(reason)}",
             recoverable: true,
             suggestion: "Check that task_id is valid and stages have valid fields"
           }}
      end
    end
  end

  def execute("plan_get", args, _context) do
    task_id = Map.get(args, "task_id")

    case Tasks.current_plan(task_id) do
      nil ->
        {:error,
         %{
           error: "No approved plan for task",
           recoverable: false,
           suggestion: "Create a plan with plan_create and approve it first"
         }}

      plan ->
        plan = Repo.preload(plan, stages: :validations)
        {:ok, serialize_plan(plan)}
    end
  end

  def execute("plan_submit", args, _context) do
    plan_id = Map.get(args, "plan_id")

    case Tasks.get_plan(plan_id) do
      nil ->
        {:error,
         %{
           error: "Plan not found: #{plan_id}",
           recoverable: false,
           suggestion: "Use plan_create to create a plan first"
         }}

      plan ->
        case Tasks.submit_plan_for_review(plan) do
          {:ok, updated} ->
            {:ok, serialize_plan(Repo.preload(updated, :stages))}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error:
                 "Plan must be in draft status to submit for review (current: #{plan.status})",
               recoverable: false,
               suggestion: "Only draft plans can be submitted for review"
             }}

          {:error, reason} ->
            {:error,
             %{
               error: "Failed to submit plan: #{inspect(reason)}",
               recoverable: true,
               suggestion: "Check the plan status"
             }}
        end
    end
  end

  def execute("plan_approve", args, _context) do
    plan_id = Map.get(args, "plan_id")
    approved_by = Map.get(args, "approved_by", "system")

    case Repo.get(Plan, plan_id) do
      nil ->
        {:error,
         %{
           error: "Plan not found: #{plan_id}",
           recoverable: false,
           suggestion: "Use plan_get to find the plan ID for a task"
         }}

      plan ->
        case Tasks.approve_plan(plan, approved_by) do
          {:ok, approved} ->
            {:ok,
             %{
               id: approved.id,
               task_id: approved.task_id,
               status: approved.status,
               approved_by: approved.approved_by
             }}

          {:error, :invalid_transition} ->
            {:error,
             %{
               error: "Cannot approve plan with status #{plan.status}. Must be pending_review.",
               recoverable: true,
               suggestion: "Use plan_submit first to move the plan to pending_review"
             }}

          {:error, reason} ->
            {:error, %{error: "Failed to approve plan: #{inspect(reason)}", recoverable: true}}
        end
    end
  end

  def execute("stage_start", args, _context) do
    stage_id = Map.get(args, "stage_id")

    case PlanEngine.start_stage(stage_id) do
      {:ok, stage} ->
        {:ok, serialize_stage(stage)}

      {:error, :invalid_transition} ->
        {:error,
         %{
           error: "Stage must be in pending status to start",
           recoverable: false,
           suggestion: "Check the stage's current status with stage_list"
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to start stage: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Verify the stage_id is valid"
         }}
    end
  end

  def execute("stage_list", args, _context) do
    plan_id = Map.get(args, "plan_id")

    stages =
      Tasks.list_stages(plan_id)
      |> Repo.preload(:validations)

    {:ok, Enum.map(stages, &serialize_stage_with_validations/1)}
  end

  def execute("validation_evaluate", args, _context) do
    validation_id = Map.get(args, "validation_id")
    status = Map.get(args, "status")
    evidence = Map.get(args, "evidence", %{})
    evaluated_by = Map.get(args, "evaluated_by", "system")

    unless status in ~w(passed failed) do
      {:error,
       %{
         error: "Invalid status: #{inspect(status)}. Must be \"passed\" or \"failed\"",
         recoverable: true,
         suggestion: "Use status \"passed\" or \"failed\""
       }}
    else
      case PlanEngine.evaluate_validation(validation_id, %{
             status: status,
             evidence: evidence,
             evaluated_by: evaluated_by
           }) do
        {:ok, validation} ->
          {:ok, serialize_validation(validation)}

        {:error, reason} ->
          {:error,
           %{
             error: "Failed to evaluate validation: #{inspect(reason)}",
             recoverable: true,
             suggestion: "Verify the validation_id is valid"
           }}
      end
    end
  end

  def execute("validation_pass", args, context) do
    execute(
      "validation_evaluate",
      %{
        "validation_id" => Map.get(args, "validation_id"),
        "status" => "passed",
        "evidence" => Map.get(args, "evidence", %{}),
        "evaluated_by" => Map.get(args, "evaluated_by", "system")
      },
      context
    )
  end

  def execute("stage_complete", args, _context) do
    stage_id = Map.get(args, "stage_id")

    with %Stage{} = stage <- Repo.get(Stage, stage_id),
         true <- stage.status == "running" || {:error, :not_running},
         validations <- Tasks.list_validations(stage.id),
         true <-
           Enum.all?(validations, &(&1.status == "passed")) || validations == [] ||
             {:error, :pending_validations},
         {:ok, plan} <- PlanEngine.advance(stage.plan_id) do
      fresh_stage = Enum.find(plan.stages || [], &(&1.id == stage.id))

      {:ok,
       %{
         stage_id: stage.id,
         stage_status: fresh_stage && fresh_stage.status,
         plan_id: plan.id,
         plan_status: plan.status
       }}
    else
      nil ->
        {:error,
         %{
           error: "Stage not found: #{inspect(stage_id)}",
           recoverable: true,
           suggestion: "Verify the stage_id is valid"
         }}

      {:error, :not_running} ->
        {:error,
         %{
           error: "Stage must be running before it can be completed",
           recoverable: false,
           suggestion: "Use stage_list to inspect the current stage status"
         }}

      {:error, :pending_validations} ->
        {:error,
         %{
           error: "Stage still has pending or failed validations",
           recoverable: true,
           suggestion: "Use validation_pass or validation_evaluate before stage_complete"
         }}

      {:error, reason} ->
        {:error,
         %{
           error: "Failed to complete stage: #{inspect(reason)}",
           recoverable: true,
           suggestion: "Verify the stage state and validations"
         }}
    end
  end

  def execute("report_blocker", args, context) do
    task_id = Map.get(args, "task_id")
    stage_id = Map.get(args, "stage_id")
    description = Map.get(args, "description")
    needs_human = Map.get(args, "needs_human", false)

    cond do
      is_nil(task_id) or task_id == "" ->
        {:error,
         %{
           error: "task_id is required",
           recoverable: true,
           suggestion: "Provide the current task_id from the execution context"
         }}

      is_nil(stage_id) or stage_id == "" ->
        {:error,
         %{
           error: "stage_id is required",
           recoverable: true,
           suggestion: "Provide the current stage_id from the execution context"
         }}

      is_nil(description) or String.trim(description) == "" ->
        {:error,
         %{
           error: "description is required",
           recoverable: true,
           suggestion: "Describe what is blocked and what is needed to continue"
         }}

      true ->
        attrs = %{
          "task_id" => task_id,
          "phase" => current_phase_for_blocker(task_id),
          "runtime_id" => Map.get(context, :runtime_id) || "tool-surface",
          "event_type" => "execution.blocked",
          "execution_space_id" => execution_space_id_for_task(task_id),
          "payload" => %{
            "stage_id" => stage_id,
            "description" => description,
            "needs_human" => needs_human,
            "reported_by" => Map.get(context, :agent_id) || "agent"
          }
        }

        case Platform.Orchestration.record_runtime_event(attrs) do
          {:ok, event} ->
            if needs_human do
              if space_id = execution_space_id_for_task(task_id) do
                Platform.Orchestration.ExecutionSpace.post_engagement(
                  space_id,
                  "Blocker reported: #{description}",
                  metadata: %{"reason" => "runtime_blocker", "stage_id" => stage_id}
                )
              end
            end

            {:ok, %{event_id: event.id, task_id: task_id, stage_id: stage_id, blocked: true}}

          {:error, reason} ->
            {:error,
             %{
               error: "Failed to record blocker: #{inspect(reason)}",
               recoverable: true,
               suggestion: "Retry the blocker report or post the blocker in the execution space"
             }}
        end
    end
  end

  def execute("validation_list", args, _context) do
    stage_id = Map.get(args, "stage_id")
    validations = Tasks.list_validations(stage_id)
    {:ok, Enum.map(validations, &serialize_validation/1)}
  end

  def execute("prompt_template_list", _args, _context) do
    templates = Platform.Orchestration.PromptTemplates.list_templates()

    result =
      Enum.map(templates, fn t ->
        %{
          slug: t.slug,
          name: t.name,
          description: t.description,
          variables: t.variables,
          updated_by: t.updated_by,
          updated_at: format_datetime(t.updated_at)
        }
      end)

    {:ok, result}
  end

  def execute("prompt_template_update", args, _context) do
    slug = Map.get(args, "slug")
    content = Map.get(args, "content")

    cond do
      is_nil(slug) || slug == "" ->
        {:error,
         %{
           error: "slug is required",
           recoverable: true,
           suggestion: "Provide a valid template slug (e.g. dispatch.planning, heartbeat)"
         }}

      is_nil(content) ->
        {:error,
         %{
           error: "content is required",
           recoverable: true,
           suggestion: "Provide the new template content with {{variable_name}} placeholders"
         }}

      true ->
        case Platform.Orchestration.PromptTemplates.get_template_by_slug(slug) do
          nil ->
            {:error,
             %{
               error: "Template not found: #{slug}",
               recoverable: true,
               suggestion: "Use prompt_template_list to see available slugs, or check spelling"
             }}

          template ->
            case Platform.Orchestration.PromptTemplates.update_template(template, %{
                   "content" => content,
                   "updated_by" => "agent"
                 }) do
              {:ok, updated} ->
                {:ok,
                 %{
                   slug: updated.slug,
                   name: updated.name,
                   description: updated.description,
                   variables: updated.variables,
                   updated_by: updated.updated_by,
                   updated_at: format_datetime(updated.updated_at)
                 }}

              {:error, changeset} ->
                {:error,
                 %{
                   error: "Failed to update template: #{inspect_errors_safe(changeset)}",
                   recoverable: true,
                   suggestion: "Check that content is not empty"
                 }}
            end
        end
    end
  end

  # ── Federation tools ─────────────────────────────────────────────────

  def execute("federation_status", _args, _context) do
    status = Platform.Federation.federation_status()

    runtimes =
      Enum.map(status, fn r ->
        %{
          runtime_id: r.runtime_id,
          agent_name: r.agent_name,
          agent_slug: r.agent_slug,
          online: r.online,
          connected_at: format_datetime(r.connected_at),
          last_seen_at: format_datetime(r.last_seen_at),
          last_connected_at: format_datetime(r.last_connected_at)
        }
      end)

    {:ok, %{runtimes: runtimes}}
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

  defp serialize_plan(plan) do
    stages =
      case plan.stages do
        %Ecto.Association.NotLoaded{} -> []
        stages -> Enum.map(stages, &serialize_stage_with_validations/1)
      end

    %{
      id: plan.id,
      task_id: plan.task_id,
      status: plan.status,
      version: plan.version,
      approved_by: plan.approved_by,
      approved_at: format_datetime(plan.approved_at),
      stages: stages,
      inserted_at: format_datetime(plan.inserted_at),
      updated_at: format_datetime(plan.updated_at)
    }
  end

  defp serialize_stage(stage) do
    %{
      id: stage.id,
      plan_id: stage.plan_id,
      name: stage.name,
      description: stage.description,
      position: stage.position,
      status: stage.status,
      expected_artifacts: stage.expected_artifacts,
      started_at: format_datetime(stage.started_at),
      completed_at: format_datetime(stage.completed_at),
      inserted_at: format_datetime(stage.inserted_at),
      updated_at: format_datetime(stage.updated_at)
    }
  end

  defp serialize_stage_with_validations(stage) do
    validations =
      case stage.validations do
        %Ecto.Association.NotLoaded{} -> []
        validations -> Enum.map(validations, &serialize_validation/1)
      end

    stage
    |> serialize_stage()
    |> Map.put(:validations, validations)
  end

  defp serialize_validation(validation) do
    %{
      id: validation.id,
      stage_id: validation.stage_id,
      kind: validation.kind,
      status: validation.status,
      evidence: validation.evidence,
      evaluated_by: validation.evaluated_by,
      evaluated_at: format_datetime(validation.evaluated_at),
      inserted_at: format_datetime(validation.inserted_at),
      updated_at: format_datetime(validation.updated_at)
    }
  end

  defp serialize_review_request(request) do
    items =
      case request.items do
        %Ecto.Association.NotLoaded{} -> []
        items -> Enum.map(items, &serialize_review_item/1)
      end

    %{
      id: request.id,
      validation_id: request.validation_id,
      task_id: request.task_id,
      status: request.status,
      submitted_by: request.submitted_by,
      items: items,
      inserted_at: format_datetime(request.inserted_at),
      updated_at: format_datetime(request.updated_at)
    }
  end

  defp serialize_review_item(item) do
    %{
      id: item.id,
      label: item.label,
      canvas_id: item.canvas_id,
      content: item.content,
      status: item.status,
      feedback: item.feedback,
      reviewed_by: item.reviewed_by,
      reviewed_at: format_datetime(item.reviewed_at)
    }
  end

  defp current_phase_for_blocker(task_id) do
    case Platform.Tasks.current_plan(task_id) do
      %{stages: stages} ->
        cond do
          Enum.any?(
            stages || [],
            &(&1.status == "running" and
                  String.contains?(String.downcase(&1.name || ""), "review"))
          ) ->
            "review"

          Enum.any?(
            stages || [],
            &(&1.status == "running" and String.contains?(String.downcase(&1.name || ""), "plan"))
          ) ->
            "planning"

          true ->
            "execution"
        end

      _ ->
        "execution"
    end
  end

  defp execution_space_id_for_task(task_id) do
    case Platform.Orchestration.ExecutionSpace.find_by_task_id(task_id) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp assert_agent_in_space(space_id, context) do
    agent_id = Map.get(context, :agent_id)

    cond do
      is_nil(space_id) ->
        {:error,
         %{
           error: "space_id is required",
           recoverable: true,
           suggestion: "Provide a valid space_id"
         }}

      is_nil(agent_id) ->
        {:error,
         %{
           error: "Agent identity required for read operations",
           recoverable: false,
           suggestion: "Ensure the agent context includes agent_id"
         }}

      true ->
        participant =
          Repo.get_by(Chat.Participant,
            space_id: space_id,
            participant_type: "agent",
            participant_id: agent_id
          )

        case participant do
          %{left_at: nil} ->
            :ok

          _ ->
            {:error,
             %{
               error: "Access denied: agent is not an active participant in space #{space_id}",
               recoverable: false,
               suggestion: "Use space_list to find spaces the agent has access to"
             }}
        end
    end
  end

  defp get_agent_participant_id_for_space(space_id, context) do
    agent_id = Map.get(context, :agent_id)

    if agent_id && space_id do
      case Chat.ensure_agent_participant(space_id, agent_id) do
        {:ok, participant} -> participant.id
        _ -> nil
      end
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp inspect_errors_safe(%Ecto.Changeset{} = changeset), do: inspect_errors(changeset)
  defp inspect_errors_safe(reason), do: inspect(reason)

  defp inspect_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end
end
