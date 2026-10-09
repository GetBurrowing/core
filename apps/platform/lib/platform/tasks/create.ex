defmodule Platform.Tasks.Create do
  @moduledoc """
  The one creation path for a task filed by a person (task 01a111bb), reached
  as `Platform.Tasks.create_from_request/2`.

  Two callers use it: the web New Task sheet
  (`PlatformWeb.TasksLive.TaskCreateComponent`) and the native app's
  `POST /api/app/tasks` (`PlatformWeb.AppIntentsController`). Neither calls
  `Platform.Tasks.create_task/1` itself.

  ## Why there is exactly one

  Task 019f42fd bug 1: a creation path that handed a flat
  `assignee_id + assignee_type` straight to `Tasks.create_task/1` left
  `phase_assignees = %{}`, and the first phase transition then lost the
  assignee entirely. The fix routes the flat pair through
  `Platform.Federation.TaskAttrs.build_task_attrs/3` with
  `auto_route_flat_assignee_current_phase: true`, which lands it in
  `phase_assignees["planning"]`, the same shape the MCP `task_create` path
  writes. A second copy of this sequence is how that bug comes back, so the
  sequence lives here and nowhere else.

  ## The sequence, in order

    1. `TaskAttrs.build_task_attrs(raw_attrs, :create,
       auto_route_flat_assignee_current_phase: true, current_phase: "planning")`;
    2. `merge_ui_extras/2`: `TaskAttrs` keeps only its canonical fields, so
       `metadata`, `deploy_strategy` and `dependencies` are carried across;
    3. `Platform.Tasks.create_task/1`;
    4. `Platform.Tasks.set_phase_assignees/2` when step 1 produced phase
       attrs.

  Attachments, board broadcasts and flashes are the caller's.
  """

  alias Platform.Federation.TaskAttrs
  alias Platform.Tasks
  alias Platform.Tasks.Task

  @doc """
  Create a task from a raw, string-keyed request map. `opts` is reserved;
  every caller files into the planning phase today.
  """
  @spec from_request(map(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def from_request(raw_attrs, _opts \\ []) when is_map(raw_attrs) do
    with {:ok, flat_attrs, phase_attrs} <-
           TaskAttrs.build_task_attrs(raw_attrs, :create,
             auto_route_flat_assignee_current_phase: true,
             current_phase: "planning"
           ),
         flat_attrs = merge_ui_extras(flat_attrs, raw_attrs),
         {:ok, task} <- Tasks.create_task(flat_attrs) do
      maybe_apply_phase_assignees(task, phase_attrs)
    end
  end

  # `TaskAttrs.build_task_attrs/3` restricts `flat_attrs` to the canonical
  # field list. The new-task form also carries `metadata`,
  # `deploy_strategy`, and `dependencies`: UI-only concerns, not part of
  # the ADR 0044 canonical shape.
  defp merge_ui_extras(flat_attrs, raw_attrs) do
    Enum.reduce(~w(metadata deploy_strategy dependencies), flat_attrs, fn key, acc ->
      case Map.get(raw_attrs, key) do
        nil -> acc
        value -> Map.put(acc, String.to_existing_atom(key), value)
      end
    end)
  end

  defp maybe_apply_phase_assignees(task, nil), do: {:ok, task}

  defp maybe_apply_phase_assignees(task, phase_attrs) when is_map(phase_attrs),
    do: Tasks.set_phase_assignees(task, phase_attrs)
end
