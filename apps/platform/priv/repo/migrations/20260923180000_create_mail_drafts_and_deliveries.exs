defmodule Platform.Repo.Migrations.CreateMailDraftsAndDeliveries do
  @moduledoc """
  Task 01a0cf21-29ba-7001-8690-3c59d6cb17c6 stage 2 (Email integration).

  Creates `mail_drafts` and `mail_deliveries`, backing `Platform.Mail.Draft`
  and `Platform.Mail.Delivery`, the tables of the audited send path in
  `Platform.Mail.Dispatch`.

  ## mail_deliveries is the audit row

  A row is inserted — as `sending` or `refused` — in the same committed
  transaction that evaluated the send policy, BEFORE anything reaches SMTP.
  It snapshots what was sent and who was responsible: from address,
  expanded recipients, subject, body, actor, drafter, on-behalf-of user.

  After insert only `status`, `error`, `smtp_response`, `accepted_at` and
  `updated_at` may change. The changeset enforces that in the application,
  and the `mail_deliveries_snapshot_immutable` trigger below enforces it in
  the database, so a raw `update_all` cannot rewrite history either.

  ## Foreign keys that must not rewrite a snapshot

  `account_id` and `draft_id` are NO ACTION, not SET NULL: a SET NULL would
  be an UPDATE of a snapshot column and the trigger would refuse it. Deleting
  an org cascades to its accounts, drafts and deliveries in one statement,
  and NO ACTION is checked at the end of that statement, so org deletion
  still succeeds. Accounts and drafts are archived / discarded, not deleted.

  ## Statuses

  `queued | sending | accepted | failed | refused`. `accepted` means the SMTP
  relay answered 250 — the only acknowledgment available — never "delivered".
  """
  use Ecto.Migration

  @snapshot_columns ~w(org_id account_id sender_key from_address recipients subject body
                       actor_type actor_id drafted_by_type drafted_by_id on_behalf_of_user_id
                       responsibility draft_id task_id stage_id message_id_header
                       refusal_reason inserted_at)

  def up do
    create table(:mail_drafts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(:account_id, references(:mail_accounts, type: :binary_id, on_delete: :nilify_all))

      add(:sender_key, :string)
      add(:to_addresses, {:array, :text}, null: false, default: [])
      add(:to_user_ids, {:array, :binary_id}, null: false, default: [])
      add(:subject, :text)
      add(:body, :text)
      add(:created_by_type, :string, null: false)
      add(:created_by_id, :binary_id)
      add(:on_behalf_of_user_id, :binary_id)
      add(:responsibility, :string)
      add(:task_id, :binary_id)
      add(:stage_id, :binary_id)
      add(:status, :string, null: false, default: "draft")

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:mail_drafts, [:org_id, :status]))

    create(
      constraint(:mail_drafts, :mail_drafts_status_check,
        check: "status IN ('draft', 'dispatched', 'discarded')"
      )
    )

    create(
      constraint(:mail_drafts, :mail_drafts_created_by_type_check,
        check: "created_by_type IN ('user', 'agent', 'system')"
      )
    )

    create table(:mail_deliveries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(
        :account_id,
        references(:mail_accounts, type: :binary_id, on_delete: :nothing),
        null: false
      )

      add(:sender_key, :string, null: false)
      add(:from_address, :string, null: false)
      add(:recipients, {:array, :text}, null: false, default: [])
      add(:subject, :text)
      add(:body, :text)
      add(:actor_type, :string, null: false)
      add(:actor_id, :binary_id)
      add(:drafted_by_type, :string)
      add(:drafted_by_id, :binary_id)
      add(:on_behalf_of_user_id, :binary_id)
      add(:responsibility, :string)
      add(:draft_id, references(:mail_drafts, type: :binary_id, on_delete: :nothing))
      add(:task_id, :binary_id)
      add(:stage_id, :binary_id)
      add(:message_id_header, :string, null: false)
      add(:status, :string, null: false)
      add(:refusal_reason, :map)
      add(:error, :text)
      add(:smtp_response, :text)
      add(:accepted_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    # The rate-limit count: per account, recent rows by status.
    create(index(:mail_deliveries, [:account_id, :inserted_at]))
    create(index(:mail_deliveries, [:org_id, :status, :inserted_at]))
    create(index(:mail_deliveries, [:draft_id]))

    create(
      constraint(:mail_deliveries, :mail_deliveries_status_check,
        check: "status IN ('queued', 'sending', 'accepted', 'failed', 'refused')"
      )
    )

    changed =
      @snapshot_columns
      |> Enum.map(&"OLD.#{&1} IS DISTINCT FROM NEW.#{&1}")
      |> Enum.join(" OR ")

    execute("""
    CREATE FUNCTION mail_deliveries_snapshot_immutable() RETURNS trigger AS $$
    BEGIN
      IF #{changed} THEN
        RAISE EXCEPTION 'mail_deliveries snapshot columns are immutable (delivery %)', OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER mail_deliveries_snapshot_immutable
    BEFORE UPDATE ON mail_deliveries
    FOR EACH ROW EXECUTE FUNCTION mail_deliveries_snapshot_immutable()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS mail_deliveries_snapshot_immutable ON mail_deliveries")
    execute("DROP FUNCTION IF EXISTS mail_deliveries_snapshot_immutable()")
    drop(table(:mail_deliveries))
    drop(table(:mail_drafts))
  end
end
