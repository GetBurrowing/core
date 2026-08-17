defmodule PlatformWeb.Tasks.ReviewLoaders do
  @moduledoc """
  Read-side loaders shared by the Tasks surfaces that render review state:
  the per-task detail panel (shell today, stage 4's component tomorrow) and
  the stack detail panel + rollup overlay (`StacksComponent`).

  Extracted from `PlatformWeb.TasksLive`'s privates in stage 3 so the stacks
  component does not have to call back into the shell.
  """

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Repo
  alias Platform.Tasks.ReviewRequest

  @doc """
  Pre-load every canvas referenced by any item of `requests` into a
  `%{canvas_id => %Canvas{}}` map so templates stay DB-free.
  """
  def load_review_canvases(requests) do
    requests
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

  @doc """
  `%{task_id => pending_review_request_count}` for the given tasks.
  """
  def pending_review_counts(tasks) do
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
end
