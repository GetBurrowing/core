defmodule PlatformWeb.Tasks.PhaseAssigneeParams do
  @moduledoc """
  Shared form-param helpers for the two phase-assignee modals: the per-task
  one (Assignees concern, extracted in stage 5) and the stack-level one
  (Stacks concern, extracted in stage 3).

  They were private to `PlatformWeb.TasksLive` and used by both. Extracting
  Stacks first would have forced either a copy or a call back into the
  shell's privates, so they get their own home instead.
  """

  @doc """
  Normalise one modal select's value into a phase-assignee entry map.
  Blank/nil clears the phase (`%{}`); anything else is an agent id.
  """
  def phase_entry(""), do: %{}
  def phase_entry(nil), do: %{}
  def phase_entry(agent_id), do: %{"assignee_id" => agent_id, "assignee_type" => "agent"}

  @doc """
  True when planning/execution/review all resolve to the same agent id —
  used to decide whether a modal opens in `:simple` or `:advanced` mode.
  """
  def all_phases_same_agent?(pa) do
    ids =
      ~w(planning execution review)
      |> Enum.map(fn phase ->
        case Map.get(pa, phase) do
          %{"assignee_id" => id} -> id
          _ -> nil
        end
      end)

    case Enum.uniq(ids) do
      [_single] -> true
      _ -> false
    end
  end
end
