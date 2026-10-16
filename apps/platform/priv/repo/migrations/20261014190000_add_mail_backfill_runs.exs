defmodule Platform.Repo.Migrations.AddMailBackfillRuns do
  @moduledoc """
  Task 01a13ba5-42a7-7000-8f2b-4c63003f3f92 stage 1 (one-off 30-day mail
  backfill, imported quietly).

  ## mail_backfill_runs

  One row per admin-triggered backfill of one account
  (`Platform.Mail.BackfillRun`, written by `Platform.Mail.start_backfill/4`
  and `Platform.Mail.Inbound.Backfill`). `status` is `running`, `done` or
  `failed`; the counters are rewritten as the run progresses so progress
  survives a reload and shows on any node.

  The partial unique index on `(account_id) WHERE status = 'running'` is
  the cross-node lock: at most one running backfill per account exists, and
  a second start hits the index (`:already_running`). A run stuck in
  `running` by a node restart is reaped to `failed` by the next start.

  ## mail_inbound_messages.ingest_source

  `'poll'` for rows the live poller wrote (the default, so every existing
  row is `'poll'`) and `'backfill'` for rows the backfill wrote. A backfill
  row was never posted to chat or broadcast, and
  `Platform.Experiments.Signals.MailSource.reconcile/0` excludes it. A CHECK
  constraint keeps the column to those two values.

  `down/0` drops both.
  """
  use Ecto.Migration

  def up do
    create table(:mail_backfill_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :account_id,
        references(:mail_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :requested_by_user_id,
        references(:users, type: :binary_id, on_delete: :nilify_all)
      )

      add(:window_days, :integer, null: false)
      add(:since_date, :date, null: false)
      add(:status, :string, null: false, default: "running")
      add(:total, :integer, null: false, default: 0)
      add(:imported, :integer, null: false, default: 0)
      add(:already_present, :integer, null: false, default: 0)
      add(:folders, {:array, :text}, null: false, default: [])
      add(:skipped_folders, {:array, :text}, null: false, default: [])
      add(:error, :text)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:mail_backfill_runs, :mail_backfill_runs_status_check,
        check: "status IN ('running', 'done', 'failed')"
      )
    )

    create(
      unique_index(:mail_backfill_runs, [:account_id],
        where: "status = 'running'",
        name: :mail_backfill_runs_one_running_per_account
      )
    )

    create(index(:mail_backfill_runs, [:account_id, :inserted_at]))

    alter table(:mail_inbound_messages) do
      add(:ingest_source, :string, null: false, default: "poll")
    end

    create(
      constraint(:mail_inbound_messages, :mail_inbound_messages_ingest_source_check,
        check: "ingest_source IN ('poll', 'backfill')"
      )
    )
  end

  def down do
    drop(
      constraint(:mail_inbound_messages, :mail_inbound_messages_ingest_source_check)
    )

    alter table(:mail_inbound_messages) do
      remove(:ingest_source)
    end

    drop(table(:mail_backfill_runs))
  end
end
