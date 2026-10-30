defmodule Platform.Repo.Migrations.AccessGrantsOrgResourceType do
  @moduledoc """
  Task 01a18d38 stage 2: ORG-LEVEL deny grants in `access_grants`
  (`Platform.Access.Grant`, "Org denies").

  `access_grants_resource_type_check` is dropped and recreated with `'org'`
  added to the resource types. An org row's `resource_id` is its org and
  equals `org_id`. Coverage is computed when a check runs
  (`Platform.Access.Lineage`), so a space, meeting or project created after
  the deny is covered without any row being copied.

  ## Nothing existing changes

  The CHECK only admits one new value. No row is inserted, updated or
  deleted.

  ## down/0

  Refuses (raises) while any `'org'` row exists, rather than deleting it:
  an org deny may be a legal-hold control, and a rollback must not silently
  drop it. Revoke those rows through `Platform.Access.Grants.revoke/2` (which
  ledgers the change) first, then roll back. With none present, it restores
  the previous resource-type CHECK.
  """

  use Ecto.Migration

  @previous "resource_type IN ('project', 'space', 'canvas', 'memory_node', 'module')"
  @with_org "resource_type IN ('project', 'space', 'canvas', 'memory_node', 'module', 'org')"

  def up do
    drop(constraint(:access_grants, :access_grants_resource_type_check))
    create(constraint(:access_grants, :access_grants_resource_type_check, check: @with_org))
  end

  def down do
    refuse_while_org_rows!(repo())

    drop(constraint(:access_grants, :access_grants_resource_type_check))
    create(constraint(:access_grants, :access_grants_resource_type_check, check: @previous))
  end

  @doc """
  Raises while any `'org'` grant row exists; `:ok` otherwise. Public so the
  refusal can be tested without running a rollback.
  """
  def refuse_while_org_rows!(repo) do
    %{rows: [[count]]} =
      repo.query!("SELECT count(*) FROM access_grants WHERE resource_type = 'org'")

    if count > 0 do
      raise "refusing to roll back: #{count} org-level access_grants row(s) exist. " <>
              "Revoke them through Platform.Access.Grants.revoke/2 first; this " <>
              "migration never deletes a grant."
    end

    :ok
  end
end
