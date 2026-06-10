defmodule Platform.Tasks.Projects do
  @moduledoc """
  Tiny helper module for the workspace fan-out path used by
  `Platform.Agents.SystemEventScheduler` (ADR-0041 / T6).

  Distinct from `Platform.Tasks` (the broader Project/Epic/Task context); kept
  separate so the scheduler depends only on the fan-out surface, not the
  entire tasks API.
  """

  @org_scope_workspace_id "00000000-0000-0000-0000-000000000000"

  @doc """
  Return the list of active workspace UUIDs eligible for the every-6h
  Historian fan-out.

  For V1, returns `[@org_scope_workspace_id]` — a sentinel UUID standing in
  for "the org-scope workspace". Stage 3 originally returned `[nil]`, but
  the `org_historian_cursors.workspace_id NOT NULL` migration from T1
  rejects `nil` writes (the threshold sweep's `Historian.mark_run_started/1`
  is the canonical V1 fan-out caller — see T6 stage 5). The sentinel keeps
  the fan-out type signature (`[binary()]`) clean and dodges the NOT NULL
  constraint without forcing a follow-up migration.

  When real multi-tenancy lands, replace this with a `SELECT DISTINCT
  workspace_id FROM ...` (and consider whether to keep emitting the org-scope
  sentinel alongside per-workspace UUIDs).
  """
  @spec list_active_workspaces() :: [binary()]
  def list_active_workspaces, do: [@org_scope_workspace_id]

  @doc """
  Sentinel UUID standing in for "the org-scope workspace" — used in the V1
  Historian fan-out where there is one logical workspace per org.
  """
  @spec org_scope_workspace_id() :: binary()
  def org_scope_workspace_id, do: @org_scope_workspace_id
end
