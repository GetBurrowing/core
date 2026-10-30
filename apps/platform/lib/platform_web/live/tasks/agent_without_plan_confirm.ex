defmodule PlatformWeb.Tasks.AgentWithoutPlanConfirm do
  @moduledoc """
  The one warning a human status move can raise (task 01a18e02 stage 3).

  Humans move tasks freely. The single exception is moving a task into
  `in_progress` when an agent is assigned for execution and the task has no
  approved plan: the agent would start without a plan.
  `Platform.Tasks.human_move_needs_confirmation?/3` decides when that is
  true; this module renders the confirm and builds its `pending_move`.

  Decided (task 01a18e02): confirming sends the task to `planning`, not
  `in_progress`, so the agent gets a planning dispatch first. Cancelling
  changes nothing. Both the board (`BoardComponent`, `"board_drop"`) and the
  task panel (`TaskDetailComponent`, `"detail_transition"`) render this one
  markup, and each handles the two events it pushes, `"confirm_plan_first"`
  and `"cancel_move"`, against its own `phx-target`.
  """
  use Phoenix.Component

  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias PlatformWeb.Tasks.TaskDisplay

  @doc """
  The `pending_move` assign for a move that needs confirming: the task id,
  its title, the from/to statuses and the execution agent's display name.
  """
  @spec pending_move(Task.t(), String.t(), map()) :: map()
  def pending_move(%Task{} = task, to, agents_by_id) do
    {agent_id, _type} = Tasks.assignee_for_phase(task, "execution")

    %{
      task_id: task.id,
      title: task.title,
      from: task.status,
      to: to,
      agent_name:
        TaskDisplay.agent_name_for(agents_by_id || %{}, agent_id) || "The assigned agent"
    }
  end

  @doc "The success flash for a confirmed plan-first move."
  def sent_to_planning_message, do: "Sent to planning — the agent will plan first."

  attr(:pending_move, :map, default: nil)
  attr(:target, :any, required: true)

  @doc """
  Mobile-first: a bottom sheet clear of the safe-area inset on small
  screens, a centered dialog from `sm` up. The backdrop cancels.
  """
  def agent_without_plan_confirm(assigns) do
    ~H"""
    <div
      :if={@pending_move}
      class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
      id="agent-without-plan-confirm"
    >
      <div class="absolute inset-0 bg-black/40" phx-click="cancel_move" phx-target={@target} />
      <div
        class="relative w-full max-w-md rounded-t-2xl sm:rounded-2xl bg-base-100 shadow-2xl pb-[env(safe-area-inset-bottom)]"
        role="dialog"
        aria-modal="true"
        aria-labelledby="agent-without-plan-confirm-title"
        data-role="agent-without-plan-confirm"
        data-task-id={@pending_move.task_id}
      >
        <div class="flex items-start gap-3 px-4 pt-4">
          <span class="hero-exclamation-triangle size-5 shrink-0 text-warning"></span>
          <div class="min-w-0">
            <h2 id="agent-without-plan-confirm-title" class="text-base font-semibold">
              Start without a plan?
            </h2>
            <p class="mt-0.5 text-xs text-base-content truncate">{@pending_move.title}</p>
          </div>
        </div>
        <p class="px-4 py-3 text-sm text-base-content">
          {@pending_move.agent_name} is assigned and this task has no approved plan. Send it to planning first so the agent starts with a plan?
        </p>
        <div class="flex flex-col-reverse gap-2 px-4 pb-4 sm:flex-row sm:justify-end">
          <button
            type="button"
            class="btn btn-ghost min-h-11"
            phx-click="cancel_move"
            phx-target={@target}
            data-role="cancel-move"
          >
            Cancel
          </button>
          <button
            type="button"
            class="btn btn-primary min-h-11"
            phx-click="confirm_plan_first"
            phx-target={@target}
            phx-value-id={@pending_move.task_id}
            data-role="confirm-plan-first"
          >
            Send to planning
          </button>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Runs the confirmed move: the task goes to `planning`. A task already in
  `planning` is left there (it already gets a planning dispatch).
  """
  @spec confirm(Task.t(), Tasks.actor()) :: {:ok, Task.t()} | tuple()
  def confirm(%Task{status: "planning"} = task, _actor), do: {:ok, task}
  def confirm(%Task{} = task, actor), do: Tasks.transition_task(task, "planning", actor)
end
