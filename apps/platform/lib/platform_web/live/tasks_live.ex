defmodule PlatformWeb.TasksLive do
  use PlatformWeb, :live_view

  require Logger

  alias Platform.Tasks
  alias Platform.Tasks.Task

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

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Tasks.subscribe_board()

    projects = Tasks.list_projects()
    all_tasks = Tasks.list_all_tasks()

    {:ok,
     socket
     |> assign(:page_title, "Tasks")
     |> assign(:projects, projects)
     |> assign(:selected_project_id, nil)
     |> assign(:all_tasks, all_tasks)
     |> assign(:columns, group_by_column(all_tasks))
     |> assign(:kanban_columns, @kanban_columns)
     |> assign(:selected_task, nil)
     |> assign(:show_detail, false)}
  end

  @impl true
  def handle_params(%{"task_id" => task_id}, _url, socket) do
    case Ecto.UUID.cast(task_id) do
      {:ok, _} ->
        task = Tasks.get_task_detail(task_id)

        if task do
          {:noreply,
           socket
           |> assign(:selected_task, task)
           |> assign(:show_detail, true)
           |> assign(:page_title, "Tasks · #{task.title}")}
        else
          {:noreply,
           socket
           |> assign(:selected_task, nil)
           |> assign(:show_detail, false)
           |> put_flash(:error, "Task not found.")}
        end

      :error ->
        {:noreply,
         socket
         |> assign(:selected_task, nil)
         |> assign(:show_detail, false)
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
  def handle_event("filter_project", %{"project_id" => ""}, socket) do
    tasks = Tasks.list_all_tasks()

    {:noreply,
     socket
     |> assign(:selected_project_id, nil)
     |> assign(:all_tasks, tasks)
     |> assign(:columns, group_by_column(tasks))}
  end

  def handle_event("filter_project", %{"project_id" => project_id}, socket) do
    tasks = Tasks.list_all_tasks(project_id: project_id)

    {:noreply,
     socket
     |> assign(:selected_project_id, project_id)
     |> assign(:all_tasks, tasks)
     |> assign(:columns, group_by_column(tasks))}
  end

  def handle_event("select_task", %{"id" => task_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/tasks/#{task_id}")}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_task, nil)
     |> assign(:show_detail, false)
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

  # ── PubSub handlers ────────────────────────────────────────────────────

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, refresh_board(socket)}
  end

  def handle_info({:task_created, _task}, socket) do
    {:noreply, refresh_board(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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
      case socket.assigns.selected_project_id do
        nil -> []
        id -> [project_id: id]
      end

    tasks = Tasks.list_all_tasks(opts)

    socket
    |> assign(:all_tasks, tasks)
    |> assign(:columns, group_by_column(tasks))
  end

  # ── View helpers ───────────────────────────────────────────────────────

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

  defp stage_status_icon("passed"), do: "hero-check-circle text-success"
  defp stage_status_icon("failed"), do: "hero-x-circle text-error"
  defp stage_status_icon("running"), do: "hero-arrow-path text-info animate-spin"
  defp stage_status_icon("skipped"), do: "hero-minus-circle text-base-content/40"
  defp stage_status_icon(_), do: "hero-clock text-base-content/40"
end
