defmodule Platform.Goals.GoalTasks do
  @moduledoc """
  The core tasks a coach creates or tags for a goal (Goals 3/8, task
  01a1dfc1-05b0; several tasks and contributors, Goals 7/8 stage 2, task
  01a1dfc1-dffb). Called only from `Platform.Goals`, inside the
  transaction of `close_wake_up/4` or `link_task/4`, which has already
  checked the switch, the coach and the goal's mode.

  One `goal_do` may carry ONE task map (member 3's shape) or a LIST of 1 to
  `Limits.max_tasks_per_wake_up/0` maps. Every check for every task runs
  before any task is written, so a refusal creates nothing:

    * the cap: open goal-tagged tasks plus this call's tasks must not exceed
      `Limits.max_open_tasks/0` (`:task_cap_reached`);
    * the project: `TaskCount.live_project/2`, then the COACH reads it by
      `Platform.Experiments.Tools.home_org/1` (`:project_not_available`);
    * the assignee: absent, nil or the coach's own id means the coach;
      otherwise it must be a contributor (`Platform.Goals.list_contributors/2`)
      at that moment AND read the project by the same `home_org/1` rule.
      Every other value is the one `:assignee_not_available`, so a refusal
      says nothing about agents elsewhere.

  A coach's own task has the coach in all three phases. A contributor's
  task has the contributor for planning and execution and the coach for
  review: the agent that asked for the work checks it. The title and
  description are the coach's words; metadata is only
  `%{"source" => "goals.wake_up"}`; the goal id never goes on a core task.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Goals.{Limits, TaskLink, Visibility}
  alias Platform.Repo
  alias Platform.Tasks.Task

  @phases ~w(planning execution review)

  @doc false
  @spec create_for_wake_up(Agent.t(), map(), term()) :: {:ok, [Task.t()]} | {:error, term()}
  def create_for_wake_up(coach, goal, raw) do
    with {:ok, tasks} <- normalize(raw) do
      if tasks == [] do
        {:ok, []}
      else
        with :ok <- check_cap(coach, goal, length(tasks)),
             {:ok, prepared} <- prepare(coach, goal, tasks) do
          create(coach, prepared)
        end
      end
    end
  end

  # One map, a list of up to the limit, or nothing. Anything else is the
  # refusal member 3 gave a task that is not a map.
  defp normalize(nil), do: {:ok, []}
  defp normalize(task) when is_map(task), do: {:ok, [task]}

  defp normalize(tasks) when is_list(tasks) do
    cond do
      length(tasks) > Limits.max_tasks_per_wake_up() -> {:error, :too_many_tasks}
      Enum.all?(tasks, &is_map/1) -> {:ok, tasks}
      true -> {:error, :project_not_available}
    end
  end

  defp normalize(_), do: {:error, :project_not_available}

  defp prepare(coach, goal, tasks) do
    contributors = contributor_ids(coach, goal)

    Enum.reduce_while(tasks, {:ok, []}, fn task, {:ok, acc} ->
      case prepare_one(coach, goal, contributors, task) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp prepare_one(coach, goal, contributors, task) do
    with {:ok, project} <- available_project(coach, goal, attr(task, :project_id)),
         {:ok, assignee} <- assignee(coach, contributors, attr(task, :assignee_agent_id)),
         :ok <- assignee_reads(assignee, coach, goal, project) do
      {:ok, %{attrs: task, project: project, assignee: assignee}}
    end
  end

  defp assignee(coach, _contributors, nil), do: {:ok, coach}
  defp assignee(%Agent{id: id} = coach, _contributors, id), do: {:ok, coach}

  defp assignee(_coach, contributors, raw) do
    with {:ok, id} <- Ecto.UUID.cast(raw),
         true <- MapSet.member?(contributors, id),
         %Agent{} = agent <- Repo.one(from(a in Agent, where: a.id == ^id)) do
      {:ok, agent}
    else
      _ -> {:error, :assignee_not_available}
    end
  end

  defp assignee_reads(%Agent{id: id}, %Agent{id: id}, _goal, _project), do: :ok

  defp assignee_reads(assignee, _coach, goal, project) do
    case available_project(assignee, goal, project.id) do
      {:ok, _} -> :ok
      _ -> {:error, :assignee_not_available}
    end
  end

  defp create(coach, prepared) do
    Enum.reduce_while(prepared, {:ok, []}, fn row, {:ok, acc} ->
      case create_one(coach, row) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      error -> error
    end
  end

  defp create_one(coach, %{attrs: attrs, project: project, assignee: assignee}) do
    with {:ok, task} <-
           Platform.Tasks.create_task(%{
             project_id: project.id,
             title: attr(attrs, :title),
             description: attr(attrs, :description),
             kind: attr(attrs, :kind) || "chore",
             priority: attr(attrs, :priority) || "medium",
             metadata: %{"source" => "goals.wake_up"}
           }) do
      Platform.Tasks.set_phase_assignees(task, phase_assignees(coach, assignee))
    end
  end

  defp phase_assignees(coach, assignee) do
    worker = %{"assignee_type" => "agent", "assignee_id" => assignee.id}
    reviewer = %{"assignee_type" => "agent", "assignee_id" => coach.id}
    %{"planning" => worker, "execution" => worker, "review" => reviewer}
  end

  @doc false
  @spec check_cap(term(), map(), non_neg_integer()) :: :ok | {:error, :task_cap_reached}
  def check_cap(actor, goal, adding) do
    if open_count(actor, goal) + adding <= Limits.max_open_tasks(),
      do: :ok,
      else: {:error, :task_cap_reached}
  end

  defp open_count(actor, goal) do
    closed = Platform.Goals.Sources.TaskCount.closed_statuses()

    Repo.aggregate(
      from(l in TaskLink,
        join: g in subquery(Visibility.visible_goals(actor)),
        on: g.id == l.goal_id,
        join: t in Task,
        on: t.id == l.task_id,
        where: l.goal_id == ^goal.id and is_nil(t.deleted_at) and t.status not in ^closed
      ),
      :count
    )
  end

  @doc false
  @spec available_project(term(), map(), term()) ::
          {:ok, map()} | {:error, :project_not_available}
  def available_project(actor, goal, id) do
    with {:ok, project} <- Platform.Goals.Sources.TaskCount.live_project(goal, id),
         home = Platform.Experiments.Tools.home_org(actor),
         true <- home == :root or home == {:tenant, project.org_id} do
      {:ok, project}
    else
      _ -> {:error, :project_not_available}
    end
  end

  @doc """
  `link_task/4`'s extra rule: when an existing task's execution assignee
  (falling back to its top-level assignee) is an agent other than the
  coach, that agent must be a contributor now.
  """
  @spec check_assignee(Agent.t(), map(), Task.t()) :: :ok | {:error, :assignee_not_available}
  def check_assignee(%Agent{id: coach_id} = coach, goal, %Task{} = task) do
    case assignee_of(task) do
      {"agent", id} when is_binary(id) and id != coach_id ->
        if MapSet.member?(contributor_ids(coach, goal), id),
          do: :ok,
          else: {:error, :assignee_not_available}

      _ ->
        :ok
    end
  end

  @doc """
  Adds `assignee_agent_id` and `assignee_name` to rows that carry a core
  task's `phase_assignees`, `assignee_id` and `assignee_type`, and drops
  those three. The execution phase wins; the top-level assignee is the
  fallback; nil when there is none. Two queries whatever the row count.
  """
  @spec annotate([map()]) :: [map()]
  def annotate(rows) do
    pairs = Enum.map(rows, &assignee_of/1)
    agents = names(Agent, for({"agent", id} <- pairs, is_binary(id), do: id))
    users = names(User, for({"user", id} <- pairs, is_binary(id), do: id))

    rows
    |> Enum.zip(pairs)
    |> Enum.map(fn {row, pair} ->
      {agent_id, name} =
        case pair do
          {"agent", id} -> {id, Map.get(agents, id)}
          {"user", id} -> {nil, Map.get(users, id)}
          _ -> {nil, nil}
        end

      row
      |> Map.drop([:phase_assignees, :assignee_id, :assignee_type])
      |> Map.merge(%{assignee_agent_id: agent_id, assignee_name: name})
    end)
  end

  defp assignee_of(%{phase_assignees: phases} = row) do
    case (phases || %{})["execution"] do
      %{"assignee_id" => id} = execution when is_binary(id) ->
        {execution["assignee_type"], id}

      _ ->
        if is_binary(Map.get(row, :assignee_id)),
          do: {row.assignee_type, row.assignee_id},
          else: nil
    end
  end

  defp names(_schema, []), do: %{}

  defp names(User, ids) do
    from(u in User, where: u.id in ^Enum.uniq(ids), select: {u.id, coalesce(u.name, u.email)})
    |> Repo.all()
    |> Map.new()
  end

  defp names(Agent, ids) do
    from(a in Agent, where: a.id in ^Enum.uniq(ids), select: {a.id, a.name})
    |> Repo.all()
    |> Map.new()
  end

  defp contributor_ids(coach, goal) do
    {:ok, contributors} = Platform.Goals.list_contributors(coach, goal.id)
    MapSet.new(contributors, & &1.agent_id)
  end

  defp attr(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
