defmodule Platform.Repo.Migrations.AddLifecycleColumnsToOrgsProjectsChatSpaces do
  use Ecto.Migration

  # Task 019f4eaa stage 2 — soft-delete lifecycle columns for the container
  # tables (orgs, projects, chat_spaces), copying the proven two-column
  # chat_spaces shape (archived_at + deletion_scheduled_at) per table rather
  # than a generic abstraction.
  #
  # `archived_cascade_org_id` is the provenance marker: when an org is
  # archived and that archive cascades down to its projects / chat_spaces,
  # each cascaded child records which org drove the cascade so the action can
  # be attributed and (later) undone. `on_delete: :nilify_all` keeps a hard
  # org delete from orphaning the child rows.
  #
  # chat_spaces ALREADY carries archived_at + deletion_scheduled_at (added in
  # 20260314080000 / 20260711000000) — this migration only adds its
  # provenance marker.
  #
  # Every new column is NULL-by-default; the observability indexes are partial
  # on the non-NULL predicate so the common "not archived / not scheduled"
  # case stays out of the index.

  def up do
    alter table(:orgs) do
      add(:archived_at, :utc_datetime_usec, null: true)
      add(:deletion_scheduled_at, :utc_datetime_usec, null: true)
    end

    create(
      index(:orgs, [:archived_at],
        where: "archived_at IS NOT NULL",
        name: :orgs_archived_at_index
      )
    )

    create(
      index(:orgs, [:deletion_scheduled_at],
        where: "deletion_scheduled_at IS NOT NULL",
        name: :orgs_deletion_scheduled_at_index
      )
    )

    alter table(:projects) do
      add(:archived_at, :utc_datetime_usec, null: true)
      add(:deletion_scheduled_at, :utc_datetime_usec, null: true)

      add(
        :archived_cascade_org_id,
        references(:orgs, type: :binary_id, on_delete: :nilify_all),
        null: true
      )
    end

    create(
      index(:projects, [:archived_at],
        where: "archived_at IS NOT NULL",
        name: :projects_archived_at_index
      )
    )

    create(
      index(:projects, [:deletion_scheduled_at],
        where: "deletion_scheduled_at IS NOT NULL",
        name: :projects_deletion_scheduled_at_index
      )
    )

    create(
      index(:projects, [:archived_cascade_org_id],
        where: "archived_cascade_org_id IS NOT NULL",
        name: :projects_archived_cascade_org_id_index
      )
    )

    alter table(:chat_spaces) do
      add(
        :archived_cascade_org_id,
        references(:orgs, type: :binary_id, on_delete: :nilify_all),
        null: true
      )
    end

    create(
      index(:chat_spaces, [:archived_cascade_org_id],
        where: "archived_cascade_org_id IS NOT NULL",
        name: :chat_spaces_archived_cascade_org_id_index
      )
    )
  end

  def down do
    drop(
      index(:chat_spaces, [:archived_cascade_org_id],
        name: :chat_spaces_archived_cascade_org_id_index
      )
    )

    alter table(:chat_spaces) do
      remove(:archived_cascade_org_id)
    end

    drop(
      index(:projects, [:archived_cascade_org_id],
        name: :projects_archived_cascade_org_id_index
      )
    )

    drop(
      index(:projects, [:deletion_scheduled_at],
        name: :projects_deletion_scheduled_at_index
      )
    )

    drop(index(:projects, [:archived_at], name: :projects_archived_at_index))

    alter table(:projects) do
      remove(:archived_cascade_org_id)
      remove(:deletion_scheduled_at)
      remove(:archived_at)
    end

    drop(
      index(:orgs, [:deletion_scheduled_at],
        name: :orgs_deletion_scheduled_at_index
      )
    )

    drop(index(:orgs, [:archived_at], name: :orgs_archived_at_index))

    alter table(:orgs) do
      remove(:deletion_scheduled_at)
      remove(:archived_at)
    end
  end
end
