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
  def status_label(other), do: other

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
