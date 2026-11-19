defmodule Platform.Repo.Migrations.AddMailTriageDrafts do
  @moduledoc """
  Task 01a1f426-a361-7000-84c7-56ea730b5e6b stage 4 (the draft-reply and
  fulfilment-plan generator, Level 2 backend). Add-only: new nullable
  columns and one trigger; nothing existing is dropped or rewritten.

    * `mail_drafts.in_reply_to_inbound_id` — the inbound email a draft
      answers (FK ON DELETE SET NULL). Only a system or agent write sets it
      (`Platform.Mail.Drafts`); `Platform.Mail.Deliverer` turns it into the
      `In-Reply-To` / `References` headers so the reply threads in the
      recipient's client.
    * `mail_triage_items.drafted_at` — when the drafter took the item (the
      dedupe, and the per-reader daily cap counts it).
    * `mail_triage_items.plan_summary` — the one-line summary of a
      fulfilment plan, next to the existing `plan_steps`.

  ## The draft copy goes when the draft does

  `mail_triage_items.draft_original_body` is a second copy of the model's
  reply, kept for the edit ratio of a SENT draft. The trigger
  `mail_triage_items_forget_draft` clears it the moment its draft is
  discarded (status becomes `discarded`) or deleted, whatever path did it.
  On discard `draft_id` stays (the draft row still exists, as `discarded`,
  and the metric counts it as not acted); on delete `draft_id` is cleared
  too, so it never names a row that is gone.
  """
  use Ecto.Migration

  def up do
    alter table(:mail_drafts) do
      add(
        :in_reply_to_inbound_id,
        references(:mail_inbound_messages, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create(index(:mail_drafts, [:in_reply_to_inbound_id]))

    alter table(:mail_triage_items) do
      add(:drafted_at, :utc_datetime_usec)
      add(:plan_summary, :text)
    end

    create(index(:mail_triage_items, [:draft_id]))
    create(index(:mail_triage_items, [:user_id, :drafted_at]))

    execute("""
    CREATE OR REPLACE FUNCTION mail_triage_items_forget_draft() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        UPDATE mail_triage_items
           SET draft_original_body = NULL, draft_id = NULL, updated_at = now()
         WHERE draft_id = OLD.id;
        RETURN OLD;
      END IF;

      IF NEW.status = 'discarded' AND OLD.status IS DISTINCT FROM 'discarded' THEN
        UPDATE mail_triage_items
           SET draft_original_body = NULL, updated_at = now()
         WHERE draft_id = NEW.id AND draft_original_body IS NOT NULL;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER mail_triage_items_forget_draft
    AFTER UPDATE OF status OR DELETE ON mail_drafts
    FOR EACH ROW EXECUTE FUNCTION mail_triage_items_forget_draft()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS mail_triage_items_forget_draft ON mail_drafts")
    execute("DROP FUNCTION IF EXISTS mail_triage_items_forget_draft()")

    drop(index(:mail_triage_items, [:user_id, :drafted_at]))
    drop(index(:mail_triage_items, [:draft_id]))

    alter table(:mail_triage_items) do
      remove(:plan_summary)
      remove(:drafted_at)
    end

    drop(index(:mail_drafts, [:in_reply_to_inbound_id]))

    alter table(:mail_drafts) do
      remove(:in_reply_to_inbound_id)
    end
  end
end
