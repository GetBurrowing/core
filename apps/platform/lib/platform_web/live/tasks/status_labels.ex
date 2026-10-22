defmodule PlatformWeb.Tasks.StatusLabels do
  @moduledoc """
  Human-readable label helpers shared across the Tasks surface.

  These were private to `PlatformWeb.TasksLive` and are read by nearly every
  concern being extracted (Stacks in stage 3, Detail in stage 4, Assignees in
  stage 5, Filters in stage 6). Giving them one home now avoids each stage
  either copying them or calling back into the shell's privates.
  """

  @doc "Task/stack status atom-ish string → title-case label."
  def status_label("backlog"), do: "Backlog"
  def status_label("planning"), do: "Planning"
  def status_label("in_progress"), do: "In Progress"
  def status_label("in_review"), do: "In Review"
  def status_label("deploying"), do: "Deploying"
  def status_label("done"), do: "Done"
  def status_label("blocked"), do: "Blocked"
  def status_label("stack_pending"), do: "Waiting"
  def status_label("cancelled"), do: "Cancelled"
  def status_label("forming"), do: "Forming"
  def status_label("abandoned"), do: "Abandoned"
  def status_label("unknown"), do: "Unknown"

  # The vocabulary above is closed by design: a status that reaches this
  # point has no human label anywhere on the Tasks surface. The old catch-all
  # `def status_label(other), do: other` laundered raw status identifiers
  # straight into the UI; any future status added elsewhere in Tasks now
  # fails loudly at render time instead of leaking silently.
  def status_label(other) do
    raise ArgumentError,
          "status_label/1 has no clause for #{inspect(other)}"
  end

  @doc """
  The status word in sentence case ("In progress", "Waiting"), for the phone
  Tasks list and its filter sheet (task 01a161fd stage 3).
  """
  def status_sentence(status), do: status |> status_label() |> String.capitalize()

  @doc """
  The status dot's colour slot, the binding palette of canvas 01a15db1 node
  `dots` (task 01a161fd stage 3): in_progress and deploying are `bg-info`,
  blocked is `bg-warning`, done is `bg-success`, and backlog, planning,
  in_review, stack_pending, cancelled and anything else are the neutral
  `bg-edge`. The dot is decorative (`aria-hidden`); the status word beside it
  carries the meaning. The board's own `status_dot_class/1` is NOT this
  function: unifying the two belongs to task 01a15dc7.
  """
  def dot_class(status) when status in ~w(in_progress deploying), do: "bg-info"
  def dot_class("blocked"), do: "bg-warning"
  def dot_class("done"), do: "bg-success"
  def dot_class(_status), do: "bg-edge"

  @doc "Phase key → the label the UI shows for it."
  def phase_label("planning"), do: "Planning"
  def phase_label("execution"), do: "Implementation"
  def phase_label("review"), do: "Validation"
  def phase_label(other), do: String.capitalize(other)

  @doc "Singular/plural \"member\" for stack-cascade flash summaries."
  def member_word(1), do: "member"
  def member_word(_), do: "members"

  @doc "Singular/plural \"request\" for the stack-feedback overlay header copy."
  def request_word(1), do: "request"
  def request_word(_), do: "requests"
end
