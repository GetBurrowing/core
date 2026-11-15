defmodule Platform.Goals.Sources.TaskCount do
  @moduledoc "Counts live tasks in a validated project and organization scope."
  @behaviour Platform.Goals.Source
  import Ecto.Query
  alias Platform.{Repo, Tasks, Tenancy}
  alias Platform.Tasks.{Project, Task}

  @impl true
  def key, do: "task_count"
  @impl true
  def label, do: "Counted from the task board"
  @impl true
  def kind, do: :measured

  @impl true
  def population(goal) do
    with {:ok, id, count} <- scope(goal) do
      {:ok, "task_count:#{id}:#{count}"}
    end
  end

  @impl true
  def measure(goal) do
    with {:ok, id, count} <- scope(goal) do
      query = from(t in Task, where: t.project_id == ^id and is_nil(t.deleted_at))

      query =
        if count == "open",
          do: where(query, [t], t.status not in ["done", "cancelled"]),
          else: where(query, [t], t.status == "done")

      value = Repo.one(from(t in query, select: count(t.id)))

      {:ok,
       %{value: value, unit: unit(goal.unit, count), population: "task_count:#{id}:#{count}"}}
    end
  rescue
    _ -> {:cannot_measure, :count_failed}
  end

  defp scope(%{source_settings: settings} = goal) when is_map(settings) do
    if settings["count"] in ["open", "completed"] do
      with {:ok, id} <- Platform.UUID.cast(settings["project_id"]),
           %Project{archived_at: nil, deletion_scheduled_at: nil} = project <-
             Tasks.get_project(id),
           %Tenancy.Org{} = org <- Tenancy.get_org(goal.org_id),
           true <- Tenancy.tier(org) == :root or project.org_id == goal.org_id do
        {:ok, id, settings["count"]}
      else
        _ -> {:cannot_measure, :unknown_project}
      end
    else
      {:cannot_measure, :bad_settings}
    end
  end

  defp scope(_), do: {:cannot_measure, :bad_settings}

  defp unit(unit, count) do
    if is_binary(unit) and String.trim(unit) != "",
      do: unit,
      else: if(count == "open", do: "open tasks", else: "tasks done")
  end
end
