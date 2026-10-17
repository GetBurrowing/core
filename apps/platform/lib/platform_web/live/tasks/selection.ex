defmodule PlatformWeb.Tasks.Selection do
  @moduledoc """
  Selected-task assign plumbing for the Tasks surface (task 01a008f6 stage 7).

  Owns the four functions that every "the selected task changed" path in
  `PlatformWeb.TasksLive` funnels through:

    * `assign_selected_task/2` — the single writer of `:selected_task`,
      `:selected_task_canvases` and `:merge_control`
    * `bump_detail_epoch/1` — the counter `TaskDetailComponent` watches to
      reset its own local state
    * `reload_selected_task/1` — re-read the open task and its review lists
    * `load_attached_canvases/1` — chip-render shape for the canvas strip
    * `readable_task_detail/2` — `Tasks.get_task_detail/1` for a task the
      viewer's `@access_scope` may `tasks.read` (task 01a14721 stage 1)

  Extracted so `BoardHooks` can reload the selection after a PubSub board
  event without calling back into the shell. A hook that depends on its
  own LiveView is the circular reference ADR 0016 flagged on
  `ControlCenterLive` and left in place; this surface does not repeat it.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Platform.Skills
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tasks.MergeControl
  alias Platform.Tasks.ReviewRequests
  alias Platform.Tasks.Task

  import PlatformWeb.Tasks.ReviewLoaders, only: [load_review_canvases: 1]

  @doc """
  `Tasks.get_task_detail/1`, or `nil` when the viewer's `@access_scope` may
  not `tasks.read` the task (`Platform.Access.can?/3`, which applies the org
  fence and explicit denies; task 01a14721 stage 1). The access check runs
  first and a refusal reads exactly like a missing row, so the detail view
  is no existence oracle. A socket with no Scope reads as before, as the
  board's listings do (`BoardHooks`).
  """
  @spec readable_task_detail(Phoenix.LiveView.Socket.t(), binary()) :: Task.t() | nil
  def readable_task_detail(socket, task_id) do
    if readable_task?(socket.assigns[:access_scope], task_id),
      do: Tasks.get_task_detail(task_id),
      else: nil
  end

  @doc """
  May the viewer behind `access_scope` `tasks.read` the task? The check
  `readable_task_detail/2` runs, for the Tasks components' by-id event
  handlers, whose task id arrives from the client. `nil` (no Scope) is
  `true`, as the board's listings read it.
  """
  @spec readable_task?(Platform.Access.Scope.t() | nil, binary()) :: boolean()
  def readable_task?(%Platform.Access.Scope{} = scope, task_id),
    do: Platform.Access.can?(scope, "tasks.read", {:task, task_id})

  def readable_task?(_scope, _task_id), do: true

  @doc "Centralised assign for `:selected_task`."
  def assign_selected_task(socket, nil) do
    socket
    |> assign(:selected_task, nil)
    |> assign(:selected_task_canvases, [])
    |> assign(:merge_control, nil)
    |> bump_detail_epoch()
  end

  def assign_selected_task(socket, %Task{} = task) do
    socket
    |> assign(:selected_task, task)
    |> assign(:selected_task_canvases, load_attached_canvases(task.id))
    |> assign(:merge_control, MergeControl.for_task(task))
    |> bump_detail_epoch()
  end

  @doc """
  Selecting a task (and every reload of the selected one) resets the
  detail panel's local state: you drop out of edit mode and plan
  revisions re-fold. Before task 01a008f6 stage 4 the shell wrote
  `:edit_mode` and `:expanded_plans` directly; those assigns now belong to
  `PlatformWeb.Tasks.TaskDetailComponent`, so we bump a counter and the
  component resets itself when it sees a new one.
  """
  def bump_detail_epoch(socket) do
    assign(socket, :detail_epoch, System.unique_integer([:monotonic]))
  end

  @doc """
  Re-read the open task plus its pending/superseded review lists, review
  canvases and attached skills. No-op reset when nothing is selected.
  """
  def reload_selected_task(socket) do
    if task = socket.assigns[:selected_task] do
      updated = readable_task_detail(socket, task.id)
      pending_reviews = if updated, do: ReviewRequests.list_pending_for_task(updated.id), else: []

      superseded_reviews =
        if updated, do: ReviewRequests.list_superseded_for_task(updated.id), else: []

      review_canvases = load_review_canvases(pending_reviews)
      attached_skills = if updated, do: Skills.resolve_skills(updated.id), else: []

      socket
      |> assign_selected_task(updated)
      |> assign(:pending_reviews, pending_reviews)
      |> assign(:superseded_reviews, superseded_reviews)
      |> assign(:review_canvases, review_canvases)
      |> assign(:attached_skills, attached_skills)
    else
      socket
      |> assign(:pending_reviews, [])
      |> assign(:superseded_reviews, [])
      |> assign(:review_canvases, %{})
      |> assign(:attached_skills, [])
    end
  end

  @doc """
  Flatten `CanvasAttachments.list_task_canvases/1` into a chip-render
  shape (`canvas_id`, `title`, `canvas_present`). Soft-deleted canvases
  stay in the list with `canvas_present: false` so the strip can render a
  "(deleted canvas)" affordance + detach button rather than silently
  dropping the stale row.
  """
  def load_attached_canvases(task_id) when is_binary(task_id) do
    task_id
    |> CanvasAttachments.list_task_canvases()
    |> Enum.map(fn %{attachment: attachment, canvas: canvas} ->
      %{
        canvas_id: attachment.canvas_id,
        title: canvas && canvas.title,
        canvas_present: not is_nil(canvas)
      }
    end)
  end

  def load_attached_canvases(_), do: []
end
