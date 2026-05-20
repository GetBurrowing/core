defmodule Platform.Tasks.Projects do
  @moduledoc """
  Tiny helper module for the workspace fan-out path used by
  `Platform.Agents.SystemEventScheduler` (ADR-0041 / T6).

  Distinct from `Platform.Tasks` (the broader Project/Epic/Task context); kept
  separate so the scheduler depends only on the fan-out surface, not the
  entire tasks API.
  """

  @doc """
  Return the list of active workspace UUIDs eligible for the every-6h
  Historian fan-out.

  For V1, returns `[nil]` — org-scope only, matching the org-level memory
  semantics that ship in this stack. Real multi-tenancy is bigger than T6;
  swapping this for a `SELECT DISTINCT workspace_id FROM ...` is a one-line
  change when multi-tenancy lands.

  # TODO(0041-T6): workspace_id=nil collides with the
  # `org_historian_cursors.workspace_id NOT NULL` migration shipped in T1.
  # The 100k-token auto-trigger path (T6 stage 5) calls
  # `Historian.mark_run_started(nil)` which will violate the constraint.
  # Resolution options: (a) relax the migration to allow NULL with a partial
  # unique index, or (b) introduce a sentinel UUID for org-scope. Coordinate
  # with the stage 5 implementer before that path goes live.
  """
  @spec list_active_workspaces() :: [binary() | nil]
  def list_active_workspaces, do: [nil]
end
