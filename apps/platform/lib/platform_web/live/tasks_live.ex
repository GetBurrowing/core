defmodule PlatformWeb.TasksLive do
  use PlatformWeb, :live_view

  require Logger

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.AttachmentStorage
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, ReviewRequest, ReviewRequests, Task}

  @kanban_columns [
    {"backlog", "Backlog"},
    {"in_progress", "In Progress"},
    {"in_review", "In Review"},
    {"done", "Done"}
  ]

  # Statuses that map into each kanban column
  @column_statuses %{
    "backlog" => ~w(backlog planning ready blocked),
    "in_progress" => ~w(in_progress),
    "in_review" => ~w(in_review),
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
     # Bottom sheet state
     |> assign(:show_task_sheet, false)
     |> assign(:task_form, to_form(Task.changeset(%Task{}, %{}), as: "task"))
     |> assign(:sheet_what, "")
     |> assign(:sheet_why, "")
     |> assign(:epics, enrich_epics(Tasks.list_epics_for_project(nil)))
     |> assign(:epics_collapsed, false)
     |> assign(:agents, agents)
     |> assign(:validation_modes, MapSet.new())
     |> assign(:manual_validation_text, "")
     |> assign(:pending_reviews, [])
     |> assign(:review_feedback_open, MapSet.new())
     |> assign(:review_items_feedback, %{})
     |> allow_upload(:task_attachments,
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

          {:noreply,
           socket
           |> assign(:selected_task, task)
           |> assign(:show_detail, true)
           |> assign(:execution_space_id, space_id)
           |> assign(:execution_log, log)
           |> assign(:pending_reviews, pending_reviews)
           |> assign(:page_title, "Tasks · #{task.title}")}
        else
          {:noreply,
           socket
           |> assign(:selected_task, nil)
           |> assign(:show_detail, false)
           |> assign(:execution_space_id, nil)
           |> assign(:execution_log, [])
           |> put_flash(:error, "Task not found.")}
        end

      :error ->
        {:noreply,
         socket
         |> assign(:selected_task, nil)
         |> assign(:show_detail, false)
         |> assign(:execution_space_id, nil)
         |> assign(:execution_log, [])
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
     |> push_patch(to: ~p"/tasks")}
  end

  def handle_event("transition_task", %{"id" => task_id, "status" => new_status}, socket) do
    task = Tasks.get_task_detail(task_id)

    socket =
      if task do
        case Tasks.transition_task(task, new_status) do
          {:ok, updated} ->
            if new_status == "planning" && updated.assignee_type == "agent" && updated.assignee_id do
              Elixir.Task.start(fn ->
                # assignee_id is the agent UUID — resolve to runtime_id for dispatch
                agent = Platform.Repo.get(Platform.Agents.Agent, updated.assignee_id)
                runtime = agent && Platform.Federation.get_runtime_for_agent(agent)

                if runtime do
                  Platform.Orchestration.assign_task(task_id, %{
                    type: :federated,
                    id: runtime.runtime_id
                  })
                end
              end)
            end

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
        |> assign(:task_form, to_form(Task.changeset(%Task{}, %{}), as: "task"))
        |> assign(:sheet_what, "")
        |> assign(:sheet_why, "")
        |> assign(:validation_modes, MapSet.new())
        |> assign(:manual_validation_text, "")
      else
        assign(socket, :show_task_sheet, false)
      end

    {:noreply, socket}
  end

  def handle_event("close_task_sheet", _params, socket) do
    {:noreply, assign(socket, :show_task_sheet, false)}
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    changeset =
      %Task{}
      |> Task.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:task_form, to_form(changeset, as: "task"))
     |> assign(:sheet_what, Map.get(params, "what", ""))
     |> assign(:sheet_why, Map.get(params, "why", ""))
     |> assign(:manual_validation_text, Map.get(params, "manual_validation_text", ""))}
  end

  def handle_event("toggle_validation_mode", %{"mode" => mode}, socket) do
    modes = socket.assigns.validation_modes

    updated =
      if MapSet.member?(modes, mode),
        do: MapSet.delete(modes, mode),
        else: MapSet.put(modes, mode)

    {:noreply, assign(socket, :validation_modes, updated)}
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

  # Upload cancel
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
        {:noreply, assign(socket, :execution_log, log)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Private — Task creation ─────────────────────────────────────────────

  defp do_create_task(params, socket, status) do
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

    # Merge deploy_target — convert "" to nil
    deploy_target =
      case Map.get(params, "deploy_target", "") do
        "" -> nil
        v -> v
      end

    task_attrs =
      params
      |> Map.put("description", description)
      |> Map.put("status", status)
      |> Map.put("metadata", metadata)
      |> Map.put("deploy_target", deploy_target)

    case Tasks.create_task(task_attrs) do
      {:ok, task} ->
        # Persist attachments
        persist_task_attachments(socket, task)

        Tasks.broadcast_board({:task_created, task})

        {:noreply,
         socket
         |> assign(:show_task_sheet, false)
         |> put_flash(:info, "Task created.")
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

      socket
      |> assign(:selected_task, updated)
      |> assign(:pending_reviews, pending_reviews)
      |> refresh_execution_log()
    else
      socket
      |> assign(:pending_reviews, [])
    end
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
  defp status_label("done"), do: "Done"
  defp status_label("blocked"), do: "Blocked"
  defp status_label(other), do: other

  defp column_header_class("backlog"), do: "text-base-content/60"
  defp column_header_class("in_progress"), do: "text-info"
  defp column_header_class("in_review"), do: "text-warning"
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

  defp available_transitions("backlog"), do: [{"planning", "Start Planning"}]
  defp available_transitions("planning"), do: [{"ready", "Mark Ready"}, {"backlog", "Back"}]
  defp available_transitions("ready"), do: [{"in_progress", "Start"}, {"planning", "Back"}]

  defp available_transitions("in_progress"),
    do: [{"in_review", "Submit for Review"}, {"done", "Mark Done"}]

  defp available_transitions("in_review"),
    do: [{"done", "Approve"}, {"in_progress", "Return"}]

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
  defp log_sender_color(_sender_type, _content_type), do: "text-base-content/60"

  defp stage_status_icon("passed"), do: "hero-check-circle text-success"
  defp stage_status_icon("failed"), do: "hero-x-circle text-error"
  defp stage_status_icon("running"), do: "hero-arrow-path text-info animate-spin"
  defp stage_status_icon("skipped"), do: "hero-minus-circle text-base-content/40"
  defp stage_status_icon(_), do: "hero-clock text-base-content/40"
end
