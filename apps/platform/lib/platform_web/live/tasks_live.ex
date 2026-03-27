defmodule PlatformWeb.TasksLive do
  use PlatformWeb, :live_view

  require Logger

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.AttachmentStorage
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Skills
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, ReviewRequest, ReviewRequests, Task}

  @kanban_columns [
    {"backlog", "Backlog"},
    {"in_progress", "In Progress"},
    {"in_review", "In Review"},
    {"deploying", "Deploying"},
    {"done", "Done"}
  ]

  # Statuses that map into each kanban column
  @column_statuses %{
    "backlog" => ~w(backlog planning ready blocked),
    "in_progress" => ~w(in_progress),
    "in_review" => ~w(in_review),
    "deploying" => ~w(deploying),
    "done" => ~w(done)
  }

  @max_upload_entries 5
  @max_upload_size 15_000_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: Tasks.subscribe_board()

    projects = Tasks.list_projects()
    all_tasks = Tasks.list_all_tasks()
    agents = Chat.list_agents_for_picker()
    default_task_agent_id = default_task_agent_id(agents)

    {:ok,
     socket
     |> assign(:page_title, "Tasks")
     |> assign(:current_user_id, session["current_user_id"])
     |> assign(:projects, projects)
     |> assign(:selected_project_id, nil)
     |> assign(:selected_epic_id, nil)
     |> assign(:sidebar_open, true)
     |> assign(:projects_collapsed, false)
     |> assign(:show_project_sheet, false)
     |> assign(:all_tasks, all_tasks)
     |> assign(:columns, group_by_column(all_tasks))
     |> assign(:kanban_columns, @kanban_columns)
     |> assign(:pending_plan_count, count_pending_plans(all_tasks))
     |> assign(:review_counts, pending_review_counts(all_tasks))
     |> assign(:selected_task, nil)
     |> assign(:show_detail, false)
     # Execution log state
     |> assign(:execution_space_id, nil)
     |> assign(:execution_log, [])
     |> assign(:execution_log_collapsed, false)
     # Steering input state
     |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
     |> assign(:execution_participant, nil)
     # Bottom sheet state
     |> assign(:show_task_sheet, false)
     |> assign(:default_task_agent_id, default_task_agent_id)
     |> assign(
       :task_form,
       to_form(Task.changeset(%Task{}, default_task_form_attrs(default_task_agent_id)),
         as: "task"
       )
     )
     |> assign(:sheet_what, "")
     |> assign(:sheet_why, "")
     |> assign(:epics, enrich_epics(Tasks.list_epics_for_project(nil)))
     |> assign(:epics_collapsed, false)
     |> assign(:agents, agents)
     |> assign(:validation_modes, MapSet.new())
     |> assign(:manual_validation_text, "")
     |> assign(:deploy_strategy_type, "inherit")
     |> assign(:auto_merge_enabled, false)
     |> assign(:merge_method, "squash")
     |> assign(:pending_reviews, [])
     |> assign(:review_canvases, %{})
     |> assign(:review_output_ids, MapSet.new())
     |> assign(:output_canvases, [])
     |> assign(:active_review_canvas, nil)
     |> assign(:review_feedback_open, MapSet.new())
     |> assign(:review_items_feedback, %{})
     |> assign(:attached_skills, [])
     |> assign(:available_skills, Skills.list_skills())
     |> allow_upload(:task_attachments,
       accept: :any,
       auto_upload: true,
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_size
     )
     |> allow_upload(:steering_attachments,
       accept: :any,
       auto_upload: true,
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_size
     )}
  end

  @impl true
  def handle_params(%{"task_id" => task_id}, _url, socket) do
    case Ecto.UUID.cast(task_id) do
      {:ok, _} ->
        task = Tasks.get_task_detail(task_id)

        if task do
          # Unsubscribe from previous execution space if any
          unsubscribe_execution_space(socket)

          # Load execution log for this task
          {space_id, log} = load_execution_log(task_id)

          # Subscribe to real-time updates if space exists
          if space_id, do: Chat.PubSub.subscribe(space_id)

          pending_reviews = ReviewRequests.list_pending_for_task(task.id)
          review_canvases = load_review_canvases(pending_reviews)
          review_output_ids = review_canvas_ids(pending_reviews)
          output_canvases = load_output_canvases(space_id)
          attached_skills = Skills.resolve_skills(task.id)

          # Lazily resolve participant for the execution space
          execution_participant =
            if space_id do
              resolve_execution_participant(space_id, socket.assigns.current_user_id)
            else
              nil
            end

          {:noreply,
           socket
           |> assign(:selected_task, task)
           |> assign(:show_detail, true)
           |> assign(:execution_space_id, space_id)
           |> assign(:execution_log, log)
           |> assign(:execution_participant, execution_participant)
           |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
           |> assign(:pending_reviews, pending_reviews)
           |> assign(:review_canvases, review_canvases)
           |> assign(:review_output_ids, review_output_ids)
           |> assign(:output_canvases, output_canvases)
           |> assign(:active_review_canvas, nil)
           |> assign(:attached_skills, attached_skills)
           |> assign(:available_skills, Skills.list_skills())
           |> assign(:page_title, "Tasks · #{task.title}")}
        else
          {:noreply,
           socket
           |> assign(:selected_task, nil)
           |> assign(:show_detail, false)
           |> assign(:execution_space_id, nil)
           |> assign(:execution_log, [])
           |> assign(:execution_participant, nil)
           |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
           |> assign(:pending_reviews, [])
           |> assign(:review_canvases, %{})
           |> assign(:review_output_ids, MapSet.new())
           |> assign(:output_canvases, [])
           |> assign(:active_review_canvas, nil)
           |> put_flash(:error, "Task not found.")}
        end

      :error ->
        {:noreply,
         socket
         |> assign(:selected_task, nil)
         |> assign(:show_detail, false)
         |> assign(:execution_space_id, nil)
         |> assign(:execution_log, [])
         |> assign(:execution_participant, nil)
         |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
         |> assign(:pending_reviews, [])
         |> assign(:review_canvases, %{})
         |> assign(:review_output_ids, MapSet.new())
         |> assign(:output_canvases, [])
         |> assign(:active_review_canvas, nil)
         |> put_flash(:error, "Invalid task ID.")}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected_task, nil)
     |> assign(:show_detail, false)}
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  def handle_event("toggle_project_sheet", _params, socket) do
    {:noreply, assign(socket, :show_project_sheet, !socket.assigns.show_project_sheet)}
  end

  def handle_event("close_project_sheet", _params, socket) do
    {:noreply, assign(socket, :show_project_sheet, false)}
  end

  def handle_event("select_project", %{"id" => project_id}, socket) do
    epics = enrich_epics(Tasks.list_epics_for_project(project_id))

    {:noreply,
     socket
     |> assign(:selected_project_id, project_id)
     |> assign(:selected_epic_id, nil)
     |> assign(:epics, epics)
     |> assign(:show_project_sheet, false)
     |> refresh_board()}
  end

  def handle_event("select_epic", %{"id" => epic_id}, socket) do
    new_id = if socket.assigns.selected_epic_id == epic_id, do: nil, else: epic_id

    {:noreply,
     socket
     |> assign(:selected_epic_id, new_id)
     |> refresh_board()}
  end

  def handle_event("toggle_projects_section", _params, socket) do
    {:noreply, assign(socket, :projects_collapsed, !socket.assigns.projects_collapsed)}
  end

  def handle_event("toggle_epics_panel", _params, socket) do
    {:noreply, assign(socket, :epics_collapsed, !socket.assigns.epics_collapsed)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_project_id, nil)
     |> assign(:selected_epic_id, nil)
     |> assign(:epics, enrich_epics(Tasks.list_epics_for_project(nil)))
     |> assign(:show_project_sheet, false)
     |> refresh_board()}
  end

  def handle_event("select_task", %{"id" => task_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/tasks/#{task_id}")}
  end

  def handle_event("close_detail", _params, socket) do
    unsubscribe_execution_space(socket)

    {:noreply,
     socket
     |> assign(:selected_task, nil)
     |> assign(:show_detail, false)
     |> assign(:execution_space_id, nil)
     |> assign(:execution_log, [])
     |> assign(:execution_participant, nil)
     |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
     |> assign(:pending_reviews, [])
     |> assign(:review_canvases, %{})
     |> assign(:review_output_ids, MapSet.new())
     |> assign(:output_canvases, [])
     |> assign(:active_review_canvas, nil)
     |> push_patch(to: ~p"/tasks")}
  end

  def handle_event("transition_task", %{"id" => task_id, "status" => new_status}, socket) do
    task = Tasks.get_task_detail(task_id)

    socket =
      if task do
        case Tasks.transition_task(task, new_status) do
          {:ok, updated} ->
            socket
            |> put_flash(:info, "Task moved to #{new_status}.")
            |> refresh_board()
            |> assign(:selected_task, Tasks.get_task_detail(updated.id))

          {:error, :invalid_transition} ->
            put_flash(socket, :error, "Cannot transition to #{new_status} from #{task.status}.")

          {:error, reason} ->
            put_flash(socket, :error, "Transition failed: #{inspect(reason)}")
        end
      else
        put_flash(socket, :error, "Task not found.")
      end

    {:noreply, socket}
  end

  def handle_event("assign_agent", %{"agent_id" => agent_id}, socket) do
    task = socket.assigns.selected_task

    if task do
      attrs =
        if agent_id == "" do
          %{assignee_id: nil, assignee_type: nil}
        else
          %{assignee_id: agent_id, assignee_type: "agent"}
        end

      case Tasks.update_task(task, attrs) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> refresh_board()
           |> assign(:selected_task, Tasks.get_task_detail(updated.id))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to assign agent.")}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Skill picker events ─────────────────────────────────────────────────

  def handle_event("attach_skill", %{"skill_id" => skill_id}, socket) do
    task = socket.assigns.selected_task

    if task && skill_id != "" do
      Skills.attach_skill(skill_id, "task", task.id)

      {:noreply,
       socket
       |> assign(:attached_skills, Skills.resolve_skills(task.id))
       |> assign(:available_skills, Skills.list_skills())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("detach_skill", %{"skill_id" => skill_id}, socket) do
    task = socket.assigns.selected_task

    if task do
      Skills.detach_skill(skill_id, "task", task.id)

      {:noreply,
       socket
       |> assign(:attached_skills, Skills.resolve_skills(task.id))
       |> assign(:available_skills, Skills.list_skills())}
    else
      {:noreply, socket}
    end
  end

  # ── Plan review events ──────────────────────────────────────────────────

  def handle_event("approve_plan", %{"plan-id" => plan_id}, socket) do
    plan =
      case Ecto.UUID.cast(plan_id) do
        {:ok, uuid} -> Repo.get(Plan, uuid)
        :error -> nil
      end

    if plan && plan.status == "pending_review" do
      approved_by = socket.assigns[:current_user_id]

      case Tasks.approve_plan(plan, approved_by) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Plan approved.")
           |> refresh_board()
           |> reload_selected_task()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to approve plan.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Plan not found or not pending review.")}
    end
  end

  def handle_event("reject_plan", %{"plan-id" => plan_id}, socket) do
    plan =
      case Ecto.UUID.cast(plan_id) do
        {:ok, uuid} -> Repo.get(Plan, uuid)
        :error -> nil
      end

    if plan && plan.status == "pending_review" do
      rejected_by = socket.assigns[:current_user_id]

      case Tasks.reject_plan(plan, rejected_by) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Plan rejected.")
           |> refresh_board()
           |> reload_selected_task()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to reject plan.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Plan not found or not pending review.")}
    end
  end

  # ── Review item events ──────────────────────────────────────────────────

  def handle_event("approve_review_item", %{"item-id" => item_id}, socket) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    case ReviewRequests.approve_item(item_id, reviewed_by) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_board()
         |> reload_selected_task()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to approve review item.")}
    end
  end

  def handle_event(
        "submit_review_feedback",
        %{"item-id" => item_id, "feedback" => feedback},
        socket
      ) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    case ReviewRequests.reject_item(item_id, reviewed_by, feedback) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           :review_items_feedback,
           Map.delete(socket.assigns.review_items_feedback, item_id)
         )
         |> assign(
           :review_feedback_open,
           MapSet.delete(socket.assigns.review_feedback_open, item_id)
         )
         |> refresh_board()
         |> reload_selected_task()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to submit feedback.")}
    end
  end

  def handle_event("toggle_review_feedback", %{"item-id" => item_id}, socket) do
    open = socket.assigns.review_feedback_open

    updated =
      if MapSet.member?(open, item_id),
        do: MapSet.delete(open, item_id),
        else: MapSet.put(open, item_id)

    {:noreply, assign(socket, :review_feedback_open, updated)}
  end

  def handle_event("open_review_canvas", %{"canvas-id" => canvas_id}, socket) do
    canvas = find_canvas_for_display(socket, canvas_id)
    {:noreply, assign(socket, :active_review_canvas, canvas)}
  end

  def handle_event("open_canvas", %{"canvas-id" => canvas_id}, socket) do
    canvas = find_canvas_for_display(socket, canvas_id)
    {:noreply, assign(socket, :active_review_canvas, canvas)}
  end

  def handle_event("close_review_canvas", _params, socket) do
    {:noreply, assign(socket, :active_review_canvas, nil)}
  end

  def handle_event(
        "update_review_feedback_text",
        %{"item-id" => item_id, "value" => text},
        socket
      ) do
    {:noreply,
     assign(
       socket,
       :review_items_feedback,
       Map.put(socket.assigns.review_items_feedback, item_id, text)
     )}
  end

  # ── Bottom sheet events ─────────────────────────────────────────────────

  def handle_event("toggle_task_sheet", _params, socket) do
    showing = !socket.assigns.show_task_sheet

    socket =
      if showing do
        socket
        |> assign(:show_task_sheet, true)
        |> assign(
          :task_form,
          to_form(
            Task.changeset(
              %Task{},
              default_task_form_attrs(socket.assigns.default_task_agent_id)
            ),
            as: "task"
          )
        )
        |> assign(:sheet_what, "")
        |> assign(:sheet_why, "")
        |> assign(:validation_modes, MapSet.new())
        |> assign(:manual_validation_text, "")
        |> assign(:deploy_strategy_type, "inherit")
        |> assign(:auto_merge_enabled, false)
        |> assign(:merge_method, "squash")
      else
        assign(socket, :show_task_sheet, false)
      end

    {:noreply, socket}
  end

  def handle_event("close_task_sheet", _params, socket) do
    {:noreply, assign(socket, :show_task_sheet, false)}
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    Logger.debug(
      "[TasksLive] validate_task: deploy_strategy_type=#{inspect(Map.get(params, "deploy_strategy_type"))}"
    )

    changeset =
      %Task{}
      |> Task.changeset(params)
      |> Map.put(:action, :validate)

    strategy_type = Map.get(params, "deploy_strategy_type", socket.assigns.deploy_strategy_type)
    auto_merge = Map.get(params, "auto_merge") == "true"
    merge_method = Map.get(params, "merge_method", socket.assigns.merge_method)

    {:noreply,
     socket
     |> assign(:task_form, to_form(changeset, as: "task"))
     |> assign(:sheet_what, Map.get(params, "what", ""))
     |> assign(:sheet_why, Map.get(params, "why", ""))
     |> assign(:manual_validation_text, Map.get(params, "manual_validation_text", ""))
     |> assign(:deploy_strategy_type, strategy_type)
     |> assign(:auto_merge_enabled, auto_merge)
     |> assign(:merge_method, merge_method)}
  end

  def handle_event("toggle_validation_mode", %{"mode" => mode}, socket) do
    modes = socket.assigns.validation_modes

    updated =
      if MapSet.member?(modes, mode),
        do: MapSet.delete(modes, mode),
        else: MapSet.put(modes, mode)

    {:noreply, assign(socket, :validation_modes, updated)}
  end

  def handle_event("toggle_auto_merge", _params, socket) do
    {:noreply, assign(socket, :auto_merge_enabled, !socket.assigns.auto_merge_enabled)}
  end

  def handle_event("create_task", %{"task" => params}, socket) do
    status =
      case Map.get(params, "action") do
        "create_and_plan" -> "planning"
        _ -> "backlog"
      end

    do_create_task(params, socket, status)
  end

  def handle_event("toggle_execution_log", _params, socket) do
    {:noreply, assign(socket, :execution_log_collapsed, !socket.assigns.execution_log_collapsed)}
  end

  # ── Kanban drag-and-drop ────────────────────────────────────────────────

  def handle_event("kanban_drop", %{"task_id" => task_id, "column" => column}, socket) do
    task = Tasks.get_task_detail(task_id)

    if is_nil(task) do
      {:noreply, put_flash(socket, :error, "Task not found.")}
    else
      case Tasks.drop_task_to_column(task, column) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Task moved to #{status_label(column_to_status(column))}.")
           |> refresh_board()
           |> reload_selected_task()}

        {:error, :unknown_column} ->
          {:noreply, put_flash(socket, :error, "Unknown column.")}

        {:error, :invalid_drop} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Cannot move task from #{status_label(task.status)} to #{status_label(column_to_status(column))}."
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Move failed: #{inspect(reason)}")}
      end
    end
  end

  defp column_to_status("backlog"), do: "backlog"
  defp column_to_status("in_progress"), do: "in_progress"
  defp column_to_status("in_review"), do: "in_review"
  defp column_to_status("deploying"), do: "deploying"
  defp column_to_status("done"), do: "done"
  defp column_to_status(_), do: "unknown"

  # ── Steering input events ──────────────────────────────────────────────

  def handle_event("send_steering_message", %{"steering" => %{"text" => content}}, socket) do
    content = String.trim(content || "")
    has_uploads = has_completed_steering_uploads?(socket)

    with true <- content != "" or has_uploads,
         space_id when not is_nil(space_id) <- socket.assigns.execution_space_id do
      # Ensure we have a participant (lazy resolve on first send)
      participant =
        socket.assigns.execution_participant ||
          resolve_execution_participant(space_id, socket.assigns.current_user_id)

      if participant do
        attrs = %{
          space_id: space_id,
          participant_id: participant.id,
          content_type: "text",
          content: content,
          log_only: false
        }

        result =
          if has_uploads do
            case persist_steering_attachments(socket) do
              {:ok, pending_attachments} ->
                Chat.post_message_with_attachments(attrs, pending_attachments)

              {:error, :storage_failed} ->
                {:error, :storage_failed}
            end
          else
            case Chat.post_message(attrs) do
              {:ok, msg} -> {:ok, msg, []}
              error -> error
            end
          end

        case result do
          {:ok, _msg, _attachments} ->
            {:noreply,
             socket
             |> assign(:execution_participant, participant)
             |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))}

          {:ok, _msg} ->
            {:noreply,
             socket
             |> assign(:execution_participant, participant)
             |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))}

          {:error, :storage_failed} ->
            {:noreply, put_flash(socket, :error, "Failed to store attachment.")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to send steering message.")}
        end
      else
        {:noreply, put_flash(socket, :error, "Could not join execution space.")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("steering_changed", %{"steering" => params}, socket) do
    {:noreply, assign(socket, :steering_compose_form, to_form(params, as: :steering))}
  end

  def handle_event("cancel_steering_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :steering_attachments, ref)}
  end

  # Upload cancel
  # ── Mention suggestion no-ops (ComposeInput hook fires these; TasksLive has no mention UI) ──

  def handle_event("clear_mention_suggestions", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("mention_query", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_task_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :task_attachments, ref)}
  end

  # ── PubSub handlers ────────────────────────────────────────────────────

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, socket |> refresh_board() |> reload_selected_task()}
  end

  def handle_info({:task_created, _task}, socket) do
    {:noreply, refresh_board(socket)}
  end

  def handle_info({:plan_updated, _plan}, socket) do
    {:noreply, socket |> refresh_board() |> reload_selected_task()}
  end

  # Execution space PubSub — re-fetch log on any new message
  def handle_info({:new_message, _msg}, socket) do
    case socket.assigns[:execution_space_id] do
      nil ->
        {:noreply, socket}

      space_id ->
        log = ExecutionSpace.list_messages_with_participants(space_id)

        {:noreply,
         socket
         |> assign(:execution_log, log)
         |> assign(:output_canvases, load_output_canvases(space_id))}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Private — Task creation ─────────────────────────────────────────────

  defp do_create_task(params, socket, status) do
    requested_plan? = status == "planning"

    case normalize_task_assignee(params, socket.assigns.default_task_agent_id, requested_plan?) do
      {:error, :no_agent_available} ->
        {:noreply,
         socket
         |> put_flash(:error, "Select an agent before requesting a plan.")}

      normalized_assignee ->
        do_create_task_with_assignee(params, socket, status, normalized_assignee)
    end
  end

  defp do_create_task_with_assignee(params, socket, status, {assignee_id, assignee_type}) do
    what = Map.get(params, "what", "")
    why = Map.get(params, "why", "")

    description =
      case {String.trim(what), String.trim(why)} do
        {"", ""} -> nil
        {w, ""} -> "## What\n#{w}"
        {"", w} -> "## Why\n#{w}"
        {w, y} -> "## What\n#{w}\n\n## Why\n#{y}"
      end

    # Build validation metadata
    modes = socket.assigns.validation_modes
    manual_text = socket.assigns.manual_validation_text

    validation_meta =
      %{}
      |> then(fn m ->
        if MapSet.size(modes) > 0,
          do: Map.put(m, "validation_modes", MapSet.to_list(modes)),
          else: m
      end)
      |> then(fn m ->
        if MapSet.member?(modes, "manual") && String.trim(manual_text) != "",
          do: Map.put(m, "manual_validation", String.trim(manual_text)),
          else: m
      end)

    existing_meta = Map.get(params, "metadata", %{})
    metadata = Map.merge(existing_meta, validation_meta)

    # Merge deploy_target — convert "" to nil (kept for backward compat)
    deploy_target =
      case Map.get(params, "deploy_target", "") do
        "" -> nil
        v -> v
      end

    # Parse deploy_strategy from form
    deploy_strategy = parse_deploy_strategy(params)

    task_attrs =
      params
      |> Map.put("description", description)
      |> Map.put("status", status)
      |> Map.put("metadata", metadata)
      |> Map.put("deploy_target", deploy_target)
      |> Map.put("deploy_strategy", deploy_strategy)
      |> Map.put("assignee_id", assignee_id)
      |> Map.put("assignee_type", assignee_type)

    case Tasks.create_task(task_attrs) do
      {:ok, task} ->
        # Persist attachments
        persist_task_attachments(socket, task)

        Tasks.broadcast_board({:task_created, task})

        flash_message =
          if status == "planning",
            do: "Task created and planning requested.",
            else: "Task created."

        {:noreply,
         socket
         |> assign(:show_task_sheet, false)
         |> put_flash(:info, flash_message)
         |> refresh_board()}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:task_form, to_form(changeset, as: "task"))
         |> put_flash(:error, "Could not create task. Check the form for errors.")}
    end
  end

  defp persist_task_attachments(socket, _task) do
    consume_uploaded_entries(socket, :task_attachments, fn %{path: path}, entry ->
      case AttachmentStorage.persist_upload(path, entry.client_name, entry.client_type) do
        {:ok, _attrs} -> {:ok, :persisted}
        {:error, _reason} -> {:ok, :failed}
      end
    end)
  end

  # ── Private — Steering participant helper ──────────────────────────────────

  defp resolve_execution_participant(space_id, user_id)
       when is_binary(space_id) and is_binary(user_id) do
    existing =
      space_id
      |> Chat.list_participants(include_left: true)
      |> Enum.find(fn p -> p.participant_id == user_id end)

    case existing do
      nil ->
        display_name =
          case Accounts.get_user(user_id) do
            %{name: name} when is_binary(name) and name != "" -> name
            %{email: email} when is_binary(email) -> email
            _ -> "User"
          end

        case Chat.add_participant(space_id, %{
               participant_type: "user",
               participant_id: user_id,
               display_name: display_name,
               joined_at: DateTime.utc_now()
             }) do
          {:ok, p} -> p
          {:error, _} -> nil
        end

      %{left_at: nil} = p ->
        p

      p ->
        case Chat.update_participant(p, %{left_at: nil, joined_at: DateTime.utc_now()}) do
          {:ok, rejoined} -> rejoined
          {:error, _} -> p
        end
    end
  end

  defp resolve_execution_participant(_space_id, _user_id), do: nil

  # ── Private — Steering upload helpers ────────────────────────────────────

  defp has_completed_steering_uploads?(socket) do
    case uploaded_entries(socket, :steering_attachments) do
      {[_ | _], _in_progress} -> true
      _ -> false
    end
  end

  defp persist_steering_attachments(socket) do
    results =
      consume_uploaded_entries(socket, :steering_attachments, fn %{path: path}, entry ->
        result =
          case AttachmentStorage.persist_upload(path, entry.client_name, entry.client_type) do
            {:ok, attrs} -> {:ok, attrs}
            {:error, _reason} -> {:error, :storage_failed}
          end

        {:ok, result}
      end)

    {ok_results, error_results} = Enum.split_with(results, &match?({:ok, _}, &1))
    attachments = Enum.map(ok_results, fn {:ok, attrs} -> attrs end)

    if error_results == [] do
      {:ok, attachments}
    else
      AttachmentStorage.delete_many(attachments)
      {:error, :storage_failed}
    end
  end

  # ── Private — Execution log helpers ──────────────────────────────────────

  defp load_execution_log(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      %{id: space_id} ->
        {space_id, ExecutionSpace.list_messages_with_participants(space_id)}

      nil ->
        {nil, []}
    end
  end

  defp refresh_execution_log(socket) do
    case socket.assigns[:execution_space_id] do
      nil ->
        socket

      space_id ->
        assign(socket, :execution_log, ExecutionSpace.list_messages_with_participants(space_id))
    end
  end

  defp unsubscribe_execution_space(socket) do
    if space_id = socket.assigns[:execution_space_id] do
      Chat.PubSub.unsubscribe(space_id)
    end
  end

  # ── Private — Kanban helpers ───────────────────────────────────────────

  defp group_by_column(tasks) do
    Enum.reduce(@kanban_columns, %{}, fn {col_key, _label}, acc ->
      statuses = Map.get(@column_statuses, col_key, [])
      col_tasks = Enum.filter(tasks, &(&1.status in statuses))
      Map.put(acc, col_key, col_tasks)
    end)
  end

  defp refresh_board(socket) do
    opts =
      []
      |> then(fn o ->
        case socket.assigns.selected_project_id do
          nil -> o
          id -> Keyword.put(o, :project_id, id)
        end
      end)
      |> then(fn o ->
        case socket.assigns.selected_epic_id do
          nil -> o
          id -> Keyword.put(o, :epic_id, id)
        end
      end)

    tasks = Tasks.list_all_tasks(opts)

    socket
    |> assign(:all_tasks, tasks)
    |> assign(:columns, group_by_column(tasks))
    |> assign(:pending_plan_count, count_pending_plans(tasks))
    |> assign(:review_counts, pending_review_counts(tasks))
  end

  defp reload_selected_task(socket) do
    if task = socket.assigns[:selected_task] do
      updated = Tasks.get_task_detail(task.id)
      pending_reviews = if updated, do: ReviewRequests.list_pending_for_task(updated.id), else: []
      review_canvases = load_review_canvases(pending_reviews)
      review_output_ids = review_canvas_ids(pending_reviews)
      output_canvases = load_output_canvases(socket.assigns[:execution_space_id])
      attached_skills = if updated, do: Skills.resolve_skills(updated.id), else: []

      active_review_canvas =
        case socket.assigns[:active_review_canvas] do
          %Canvas{id: id} ->
            Enum.find(output_canvases, &(&1.id == id)) || Map.get(review_canvases, id)

          _ ->
            nil
        end

      socket
      |> assign(:selected_task, updated)
      |> assign(:pending_reviews, pending_reviews)
      |> assign(:review_canvases, review_canvases)
      |> assign(:review_output_ids, review_output_ids)
      |> assign(:output_canvases, output_canvases)
      |> assign(:active_review_canvas, active_review_canvas)
      |> assign(:attached_skills, attached_skills)
      |> refresh_execution_log()
    else
      socket
      |> assign(:pending_reviews, [])
      |> assign(:review_canvases, %{})
      |> assign(:review_output_ids, MapSet.new())
      |> assign(:output_canvases, [])
      |> assign(:active_review_canvas, nil)
      |> assign(:attached_skills, [])
    end
  end

  defp load_review_canvases(pending_reviews) do
    pending_reviews
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.map(& &1.canvas_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn canvas_id, acc ->
      case Chat.get_canvas(canvas_id) do
        %Canvas{} = canvas -> Map.put(acc, canvas_id, canvas)
        _ -> acc
      end
    end)
  end

  defp review_canvas_ids(pending_reviews) do
    pending_reviews
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.map(& &1.canvas_id)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp load_output_canvases(nil), do: []
  defp load_output_canvases(space_id), do: Chat.list_canvases(space_id)

  defp find_canvas_for_display(socket, canvas_id) do
    Enum.find(socket.assigns[:output_canvases] || [], &(&1.id == canvas_id)) ||
      Map.get(socket.assigns[:review_canvases] || %{}, canvas_id)
  end

  defp count_pending_plans(tasks) do
    Enum.count(tasks, fn task ->
      Enum.any?(task.plans || [], &(&1.status == "pending_review"))
    end)
  end

  defp pending_review_counts(tasks) do
    task_ids = Enum.map(tasks, & &1.id)

    if task_ids == [] do
      %{}
    else
      ReviewRequest
      |> where([rr], rr.task_id in ^task_ids and rr.status == "pending")
      |> group_by([rr], rr.task_id)
      |> select([rr], {rr.task_id, count(rr.id)})
      |> Repo.all()
      |> Map.new()
    end
  end

  # ── View helpers ───────────────────────────────────────────────────────

  defp deploy_target_label("hive_production"), do: "Hive Production"
  defp deploy_target_label("github_pr"), do: "GitHub PR"
  defp deploy_target_label("google_drive"), do: "Google Drive"
  defp deploy_target_label(other), do: other

  defp deploy_strategy_label(nil), do: "Inherit from project"
  defp deploy_strategy_label(%{"type" => "pr_merge"}), do: "PR Merge"
  defp deploy_strategy_label(%{"type" => "docker_deploy"}), do: "Docker Deploy"
  defp deploy_strategy_label(%{"type" => "skill_driven"}), do: "Skill Driven"
  defp deploy_strategy_label(%{"type" => "manual"}), do: "Manual"
  defp deploy_strategy_label(%{"type" => "none"}), do: "None (skip deploy)"
  defp deploy_strategy_label(_), do: "Unknown"

  defp parse_deploy_strategy(params) do
    case Map.get(params, "deploy_strategy_type", "") do
      "" -> nil
      "inherit" -> nil
      "pr_merge" -> %{"type" => "pr_merge", "config" => parse_pr_merge_config(params)}
      "docker_deploy" -> %{"type" => "docker_deploy", "config" => %{}}
      "skill_driven" -> %{"type" => "skill_driven", "config" => %{}}
      "manual" -> %{"type" => "manual"}
      "none" -> %{"type" => "none"}
      _ -> nil
    end
  end

  defp parse_pr_merge_config(params) do
    base = %{
      "require_ci_pass" => Map.get(params, "require_ci_pass") == "true",
      "auto_merge" => Map.get(params, "auto_merge") == "true",
      "require_review_approval" => Map.get(params, "require_review_approval") == "true"
    }

    # Only include merge_method when auto_merge is enabled
    if base["auto_merge"] do
      method = Map.get(params, "merge_method", "squash")

      if method in ~w(squash merge rebase),
        do: Map.put(base, "merge_method", method),
        else: Map.put(base, "merge_method", "squash")
    else
      base
    end
  end

  defp priority_badge_class("critical"), do: "badge badge-error badge-sm"
  defp priority_badge_class("high"), do: "badge badge-error badge-outline badge-sm"
  defp priority_badge_class("medium"), do: "badge badge-warning badge-outline badge-sm"
  defp priority_badge_class("low"), do: "badge badge-success badge-outline badge-sm"
  defp priority_badge_class(_), do: "badge badge-ghost badge-sm"

  defp status_label("backlog"), do: "Backlog"
  defp status_label("planning"), do: "Planning"
  defp status_label("ready"), do: "Ready"
  defp status_label("in_progress"), do: "In Progress"
  defp status_label("in_review"), do: "In Review"
  defp status_label("deploying"), do: "Deploying"
  defp status_label("done"), do: "Done"
  defp status_label("blocked"), do: "Blocked"
  defp status_label(other), do: other

  defp column_header_class("backlog"), do: "text-base-content/60"
  defp column_header_class("in_progress"), do: "text-info"
  defp column_header_class("in_review"), do: "text-warning"
  defp column_header_class("deploying"), do: "text-secondary"
  defp column_header_class("done"), do: "text-success"
  defp column_header_class(_), do: "text-base-content/60"

  defp has_active_run?(%Task{} = _task) do
    # TODO: check active runs via Execution plane when wired up
    false
  end

  defp plan_progress(%Task{plans: plans}) when is_list(plans) do
    case Enum.find(plans, &(&1.status in ~w(approved executing))) do
      nil ->
        nil

      plan ->
        stages = plan.stages || []
        total = length(stages)

        if total > 0 do
          completed = Enum.count(stages, &(&1.status in ~w(passed skipped)))
          {completed, total}
        else
          nil
        end
    end
  end

  defp plan_progress(_), do: nil

  defp assignee_initials(%Task{assignee_type: nil}), do: nil

  defp assignee_initials(%Task{assignee_type: "agent", assignee_id: id}) when is_binary(id),
    do: "A"

  defp assignee_initials(%Task{assignee_type: "user", assignee_id: id}) when is_binary(id),
    do: "U"

  defp assignee_initials(_), do: nil

  defp default_task_agent_id([agent | _]), do: agent.id
  defp default_task_agent_id([]), do: nil

  defp default_task_form_attrs(nil), do: %{}

  defp default_task_form_attrs(agent_id) do
    %{"assignee_id" => agent_id, "assignee_type" => "agent"}
  end

  defp normalize_task_assignee(params, default_agent_id, requested_plan?) do
    selected_assignee_id =
      case Map.get(params, "assignee_id", "") do
        "" -> nil
        nil -> nil
        id -> id
      end

    cond do
      is_binary(selected_assignee_id) ->
        {selected_assignee_id, "agent"}

      requested_plan? && is_binary(default_agent_id) ->
        {default_agent_id, "agent"}

      requested_plan? ->
        {:error, :no_agent_available}

      true ->
        {nil, nil}
    end
  end

  defp available_transitions("backlog"), do: [{"planning", "Start Planning"}]
  defp available_transitions("planning"), do: [{"ready", "Mark Ready"}, {"backlog", "Back"}]
  defp available_transitions("ready"), do: [{"in_progress", "Start"}, {"planning", "Back"}]

  defp available_transitions("in_progress"),
    do: [{"in_review", "Submit for Review"}, {"done", "Mark Done"}]

  # Review outcomes flow through validations / review requests, not blunt status buttons.
  defp available_transitions("in_review"), do: []

  # Deploying outcomes flow through deploy stage validations, not manual transitions.
  defp available_transitions("deploying"), do: []

  defp available_transitions("blocked"),
    do: [{"backlog", "To Backlog"}, {"in_progress", "Resume"}]

  defp available_transitions("done"), do: []
  defp available_transitions(_), do: []

  defp transition_btn_class(status) do
    case status do
      "done" -> "btn btn-sm btn-success"
      "in_review" -> "btn btn-sm btn-warning"
      "in_progress" -> "btn btn-sm btn-info"
      _ -> "btn btn-sm btn-ghost"
    end
  end

  defp enrich_epics(epics) do
    epic_ids = Enum.map(epics, & &1.id)
    counts = Tasks.epic_task_counts(epic_ids)

    Enum.map(epics, fn epic ->
      c = Map.get(counts, epic.id, %{total: 0, done: 0})

      %{
        id: epic.id,
        name: epic.name,
        description: epic.description,
        status: epic.status,
        task_count: c.total,
        done_count: c.done
      }
    end)
  end

  defp epic_status_badge_class("in_progress"), do: "badge badge-warning badge-xs"
  defp epic_status_badge_class("closed"), do: "badge badge-success badge-xs"
  defp epic_status_badge_class(_), do: "badge badge-ghost badge-xs"

  defp format_log_timestamp(nil), do: ""

  defp format_log_timestamp(%DateTime{} = dt) do
    now = DateTime.utc_now()

    if Date.compare(DateTime.to_date(dt), DateTime.to_date(now)) == :eq do
      # Today — just HH:MM
      Calendar.strftime(dt, "%H:%M")
    else
      # Older — Mon DD HH:MM
      Calendar.strftime(dt, "%b %d %H:%M")
    end
  end

  defp log_sender_color("agent", "system"), do: "text-warning"
  defp log_sender_color("agent", _content_type), do: "text-info"
  defp log_sender_color("user", _content_type), do: "text-primary"
  defp log_sender_color(_sender_type, _content_type), do: "text-base-content/60"

  defp stage_status_icon("passed"), do: "hero-check-circle text-success"
  defp stage_status_icon("failed"), do: "hero-x-circle text-error"
  defp stage_status_icon("running"), do: "hero-arrow-path text-info animate-spin"
  defp stage_status_icon("skipped"), do: "hero-minus-circle text-base-content/40"
  defp stage_status_icon(_), do: "hero-clock text-base-content/40"

  defp upload_error_to_string(:too_large), do: "File is too large"
  defp upload_error_to_string(:too_many_files), do: "Too many files selected"
  defp upload_error_to_string(:not_accepted), do: "File type is not accepted"
  defp upload_error_to_string(error), do: inspect(error)
end
