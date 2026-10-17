defmodule Platform.Repo.Migrations.AccessGrantsModuleLocks do
  @moduledoc """
  Task 01a14721 stage 2: MODULE LOCKS as module-scoped deny rows in
  `access_grants` (`Platform.Access.Grant`, "Module locks").

    * `access_grants_resource_type_check` is dropped and recreated with
      `'module'` added to the resource types.
    * `access_grants_module_deny_check`: `resource_type <> 'module' OR
      effect = 'deny'`. An allow on a module would widen past role rules, so
      the database refuses it as well as the changeset.

  A module row's `resource_id` is its org (NOT NULL uuid, equal to `org_id`)
  and its `permission` a module name, so no column is added and the ledger
  snapshot shape (`Grant.snapshot/1`) is unchanged.

  ## Nothing existing changes

  Both CHECKs only admit a new value. No existing row is touched.

  ## down/0

  Deletes every module row, then drops the module CHECK and restores the
  original resource-type CHECK. Ledger rows (`access_grant_changes`) that
  recorded a module lock keep their snapshots; undoing one after a rollback
  is refused by the restored CHECK.
  """

  use Ecto.Migration

  @original "resource_type IN ('project', 'space', 'canvas', 'memory_node')"
  @with_module "resource_type IN ('project', 'space', 'canvas', 'memory_node', 'module')"

  def up do
    drop(constraint(:access_grants, :access_grants_resource_type_check))

    create(constraint(:access_grants, :access_grants_resource_type_check, check: @with_module))

    create(
      constraint(:access_grants, :access_grants_module_deny_check,
        check: "resource_type <> 'module' OR effect = 'deny'"
      )
    )
  end

  def down do
    execute("DELETE FROM access_grants WHERE resource_type = 'module'")

    drop(constraint(:access_grants, :access_grants_module_deny_check))
    drop(constraint(:access_grants, :access_grants_resource_type_check))

    create(constraint(:access_grants, :access_grants_resource_type_check, check: @original))
  end
end
