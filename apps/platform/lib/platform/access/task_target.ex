defmodule Platform.Access.TaskTarget do
  @moduledoc """
  Resolves a client-supplied Tasks target id to the typed resource
  `Platform.Access` decides on (task 01a1472d stage 1).

  A Tasks write handler receives a task, project, stack, plan, stage,
  validation, review item, review request, epic, space or org id from the
  wire. `Platform.Access.Lineage` types only projects, tasks, stacks,
  spaces and canvases, so the plan-engine and review rows are walked up to
  the task that owns them here, and an epic to its project. This module
  makes no decision. `Platform.Access.task_target/3` decides on what it
  returns.

  ## Forms

    * `{:task | :project | :stack | :space, id}` pass through once the row
      exists;
    * `{:plan, id}` -> `{:task, plan.task_id}`;
    * `{:stage, id}` -> `{:task, stage.plan.task_id}`;
    * `{:validation, id}` -> `{:task, validation.stage.plan.task_id}`;
    * `{:review_item, id}` -> the item's review request, then as below;
    * `{:review_request, id}` -> `{:task, review_request.task_id}`, or the
      validation's task when the request carries no `task_id`;
    * `{:epic, id}` -> `{:project, epic.project_id}`;
    * `{:org, id}` passes through once the org exists.

  An id that is not a canonical UUID (`Platform.UUID.valid?/1`), a row that
  does not exist, and a chain that ends in a nil foreign key are all
  `:not_found`. The caller cannot tell them apart, so a forbidden id and a
  missing one read the same downstream.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks.{Epic, Plan, Project, ReviewItem, ReviewRequest, Stack, Stage, Task}
  alias Platform.Tasks.Validation
  alias Platform.Tenancy.Org

  @type target ::
          {:task | :project | :stack | :space | :org | :plan | :stage | :validation | :epic,
           term()}
          | {:review_item | :review_request, term()}

  @type resolved :: {:task | :project | :stack | :space | :org, binary()}

  @doc "The target forms `resolve/1` accepts."
  @spec forms() :: [atom()]
  def forms,
    do: ~w(task project stack space org plan stage validation review_item review_request epic)a

  @doc """
  The typed resource `target` names, or `:not_found`. See the moduledoc.
  """
  @spec resolve(target() | term()) :: {:ok, resolved()} | :not_found
  def resolve({type, id}) when is_atom(type) and is_binary(id) do
    case Platform.UUID.cast(id) do
      {:ok, uuid} -> do_resolve(type, uuid)
      :error -> :not_found
    end
  end

  def resolve(_target), do: :not_found

  defp do_resolve(:task, id), do: exists(Task, :task, id)
  defp do_resolve(:project, id), do: exists(Project, :project, id)
  defp do_resolve(:stack, id), do: exists(Stack, :stack, id)
  defp do_resolve(:space, id), do: exists(Space, :space, id)
  defp do_resolve(:org, id), do: exists(Org, :org, id)

  defp do_resolve(:plan, id),
    do: one(from(p in Plan, where: p.id == ^id, select: p.task_id), :task)

  defp do_resolve(:stage, id) do
    from(s in Stage,
      join: p in Plan,
      on: p.id == s.plan_id,
      where: s.id == ^id,
      select: p.task_id
    )
    |> one(:task)
  end

  defp do_resolve(:validation, id) do
    from(v in Validation,
      join: s in Stage,
      on: s.id == v.stage_id,
      join: p in Plan,
      on: p.id == s.plan_id,
      where: v.id == ^id,
      select: p.task_id
    )
    |> one(:task)
  end

  defp do_resolve(:review_item, id) do
    case Repo.one(from(i in ReviewItem, where: i.id == ^id, select: i.review_request_id)) do
      nil -> :not_found
      request_id -> do_resolve(:review_request, request_id)
    end
  end

  defp do_resolve(:review_request, id) do
    case Repo.one(
           from(r in ReviewRequest,
             where: r.id == ^id,
             select: {r.task_id, r.validation_id}
           )
         ) do
      {task_id, _} when is_binary(task_id) -> {:ok, {:task, task_id}}
      {nil, validation_id} when is_binary(validation_id) -> do_resolve(:validation, validation_id)
      _ -> :not_found
    end
  end

  defp do_resolve(:epic, id),
    do: one(from(e in Epic, where: e.id == ^id, select: e.project_id), :project)

  defp do_resolve(_type, _id), do: :not_found

  defp exists(schema, type, id) do
    if Repo.exists?(from(r in schema, where: r.id == ^id)),
      do: {:ok, {type, id}},
      else: :not_found
  end

  defp one(query, type) do
    case Repo.one(query) do
      id when is_binary(id) -> {:ok, {type, id}}
      _ -> :not_found
    end
  end
end
