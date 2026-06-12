defmodule Platform.Repo.Migrations.AgentRuntimeMemoryBundle do
  @moduledoc """
  ADR-0041 T5: swap the V1 `org_context` capability bundle for the new
  `memory` bundle on every existing agent runtime. The `org_context`
  bundle's tools (`org_context_*`, `org_memory_*`) have been deleted
  from the federation surface and replaced with the memory_* family
  (`memory_view`, `memory_create`, `memory_str_replace`, `memory_insert`,
  `memory_delete`, `memory_rename`, `memory_search`) under the renamed
  `memory` bundle.

  `allowed_bundles` is a per-runtime array column (not derived from the
  `@bundles` whitelist at runtime), so without this migration any runtime
  previously granted `org_context` would silently lose access to org-
  memory tools instead of picking up the new bundle.

  Mirrors the `agent_runtime_attachment_bundle` (20260419220000) and
  `agent_runtime_skill_bundle` (20260506203637) migration patterns: a
  single SQL `UPDATE` that mutates the array in place, guarded by `WHERE`
  so it's a no-op on already-migrated rows.
  """

  use Ecto.Migration

  def up do
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_append(array_remove(allowed_bundles, 'org_context'), 'memory')
    WHERE 'org_context' = ANY(allowed_bundles)
      AND NOT 'memory' = ANY(allowed_bundles)
    """)

    # Defensive: any runtime that already had `memory` but still carries
    # the obsolete `org_context` entry (e.g. mid-rollout state) should
    # drop `org_context` cleanly.
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_remove(allowed_bundles, 'org_context')
    WHERE 'org_context' = ANY(allowed_bundles)
    """)
  end

  def down do
    execute("""
    UPDATE agent_runtimes
    SET allowed_bundles = array_append(array_remove(allowed_bundles, 'memory'), 'org_context')
    WHERE 'memory' = ANY(allowed_bundles)
      AND NOT 'org_context' = ANY(allowed_bundles)
    """)
  end
end
