defmodule PlatformWeb.Tasks.TaskDisplay do
  @moduledoc """
  Pure display helpers shared by the Tasks surface's shell template and its
  extracted LiveComponents (task 01a008f6 stage 4).

  Every function here is a pure `data -> string / tuple` mapping with no
  socket and no LiveView. They were private to `PlatformWeb.TasksLive` until
  the detail panel moved into `PlatformWeb.Tasks.TaskDetailComponent` — the
  board (shell) and the detail panel both render them, so they had to become
  a shared module rather than be duplicated into the component.

  Follows the same shape as `PlatformWeb.Tasks.StackStyles` and
  `PlatformWeb.Tasks.StatusLabels`, which stages 2 and 3 hoisted for the
  same reason.
  """

  alias Platform.Tasks
  alias Platform.Tasks.Task

  import PlatformWeb.Tasks.StatusLabels, only: [status_label: 1]

  @doc """
  Task-aware status badge: when a task is in `planning` AND has a plan
  waiting on human review, surface "Plan Ready" with a warning badge to
  signal action-needed. All other cases fall through to `status_label/1`
  with the neutral outline badge. Requires `:plans` preloaded — both
  `Tasks.list_all_tasks/1` and `Tasks.get_task_detail/1` do this.
  """
  def task_display_status(%Task{status: "planning", plans: plans} = _task)
      when is_list(plans) do
    if Enum.any?(plans, &(&1.status == "pending_review")) do
      {"Plan Ready", "badge badge-warning"}
    else
      {status_label("planning"), "badge badge-outline"}
    end
  end

  def task_display_status(%Task{status: status} = _task) do
    {status_label(status), "badge badge-outline"}
  end

  def priority_badge_class("critical"), do: "badge badge-error badge-sm"
  def priority_badge_class("high"), do: "badge badge-error badge-outline badge-sm"
  def priority_badge_class("medium"), do: "badge badge-warning badge-outline badge-sm"
  def priority_badge_class("low"), do: "badge badge-success badge-outline badge-sm"
  def priority_badge_class(_), do: "badge badge-ghost badge-sm"

  def assignee_name(%Task{assignee_type: "agent", assignee_id: id}, agent_names)
      when is_binary(id) do
    Map.get(agent_names, id, "Agent")
  end

  def assignee_name(%Task{assignee_type: "user"}, _agent_names), do: "User"

  def assignee_name(_, _), do: nil

  def current_phase_label(%{} = task), do: Tasks.current_phase(task)

  def phase_assignee_id(%{phase_assignees: pa}, phase) when is_map(pa) do
    case Map.get(pa, phase) do
      %{"assignee_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  def phase_assignee_id(_, _), do: nil

  def agent_name_for(_agents_by_id, nil), do: nil

  def agent_name_for(agents_by_id, agent_id) when is_map(agents_by_id) do
    case Map.get(agents_by_id, agent_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  @doc """
  Display name for the sponsor if set, or `nil` so the template can `:if`
  the whole row away when there's no sponsor. Falls back to `email` when
  `name` is blank, and to a sentinel string when the FK points at a user
  that no longer exists in the local `users_by_id` map.
  """
  def sponsor_name(%Task{sponsor_user_id: nil}, _users_by_id), do: nil

  def sponsor_name(%Task{sponsor_user_id: id}, users_by_id) when is_binary(id) do
    case Map.get(users_by_id, id) do
      nil -> "Unknown user"
      user -> user.name || user.email
    end
  end

  def sponsor_name(_, _), do: nil

  @doc """
  Authoritative sponsor gate for BOTH the DOM `:if` (pin button rendered
  only for the task sponsor) AND the server-side re-check inside the
  pin/unpin handler.
  """
  def sponsor?(%Task{sponsor_user_id: sponsor_id}, user_id)
      when is_binary(sponsor_id) and is_binary(user_id),
      do: sponsor_id == user_id

  def sponsor?(_task, _user_id), do: false

  def pinned_by_me?(%Task{id: id}, user_id, %MapSet{} = pinned_ids)
      when is_binary(user_id),
      do: MapSet.member?(pinned_ids, id)

  def pinned_by_me?(_task, _user_id, _pinned_ids), do: false

  def project_deploy_targets(%{deploy_config: %{"deploy_targets" => targets}})
      when is_list(targets) do
    targets
    |> Enum.map(fn
      %{"name" => n} when is_binary(n) -> n
      n when is_binary(n) -> n
      _ -> nil
    end)
    |> Enum.filter(& &1)
  end

  def project_deploy_targets(_), do: []

  def deploy_target_label("hive_production"), do: "Hive Production"
  def deploy_target_label("github_pr"), do: "GitHub PR"
  def deploy_target_label("google_drive"), do: "Google Drive"
  def deploy_target_label(other), do: other

  def deletable_task?(%Task{} = task), do: Task.deletable?(task)
  def deletable_task?(_), do: false

  def relative_time(nil), do: ""

  def relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  def relative_time(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> relative_time()
  end

  # Cheap, per-card. Reads `metadata["unmet_dependencies"]` set by
  # `Tasks.create_task/_/transition_*` whenever a task is parked or
  # partially unblocked. No DB hit.
  #
  # Lives here rather than in a component because BOTH read it: the board's
  # card-face "Blocked · N" badge and the detail panel's
  # `blocked_explanation/1` dispatcher. It was private to `BoardComponent`
  # until task 01a004ad's explanation panel needed the same count from the
  # detail side; duplicating six pure lines across two components is the
  # only alternative and would let the two counts drift.
  def unmet_dependency_count(%Task{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("unmet_dependencies", [])
    |> length()
  end

  def unmet_dependency_count(_), do: 0
end
