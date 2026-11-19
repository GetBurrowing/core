defmodule Platform.Repo.Migrations.AddMailTriage do
  @moduledoc """
  Task 01a1f426-a361-7000-84c7-56ea730b5e6b stage 1 (morning briefing mail
  triage, Level 1 backend). Add-only: two new tables, nothing existing is
  altered, dropped or rewritten.

    * `mail_triage_items` — one row per (inbound message, reader): the
      reader's triage of that email (`Platform.Mail.Triage.Item`). `why` is a
      model-written line of at most 160 characters about the email, so it
      lives inside the mailbox boundary with the same visibility as the mail.
      `signals` holds KINDS and IDS only, never text. The draft columns
      (`draft_id`, `draft_original_body`, `plan_steps`, `edit_ratio`) are
      written by later stages; they exist now so no second migration alters
      this table.
    * `mail_triage_feedback` — a reader's "not important" / "this needed me"
      verdicts, keyed by sender domain (`Platform.Mail.Triage.Feedback`).

  Every row cascades with its reader, its mailbox and (items) its inbound
  message, so revoking a mailbox by deleting it, or deleting a person,
  leaves no triage of their mail behind. A feedback row outlives the
  inbound it was given on (the verdict is about the sender), so that FK is
  nilified.
  """
  use Ecto.Migration

  # old-code-compatible: two new tables (mail_triage_items, mail_triage_feedback) the previous release never reads or writes; drop/null:false/unique_index apply to them only.

  def up do
    create table(:mail_triage_items, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)

      add(:account_id, references(:mail_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :inbound_message_id,
        references(:mail_inbound_messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:tier, :text, null: false)
      add(:needs, :text, null: false, default: "none")
      add(:why, :text)
      add(:signals, :jsonb, null: false, default: fragment("'[]'::jsonb"))
      add(:classifier, :text, null: false)
      add(:status, :text, null: false, default: "open")
      add(:acted_at, :utc_datetime_usec)
      add(:acted_how, :text)
      add(:notified_at, :utc_datetime_usec)
      add(:draft_id, :binary_id)
      add(:draft_original_body, :text)
      add(:plan_steps, :jsonb)
      add(:edit_ratio, :float)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:mail_triage_items, :mail_triage_items_tier_check,
        check: "tier IN ('top', 'action', 'routine', 'promo')"
      )
    )

    create(
      constraint(:mail_triage_items, :mail_triage_items_needs_check,
        check: "needs IN ('reply', 'decision', 'plan', 'none')"
      )
    )

    create(
      constraint(:mail_triage_items, :mail_triage_items_status_check,
        check: "status IN ('open', 'acted', 'dismissed')"
      )
    )

    create(
      constraint(:mail_triage_items, :mail_triage_items_why_length_check,
        check: "why IS NULL OR char_length(why) <= 160"
      )
    )

    create(unique_index(:mail_triage_items, [:inbound_message_id, :user_id]))
    create(index(:mail_triage_items, [:user_id, :status, :inserted_at]))
    create(index(:mail_triage_items, [:account_id]))

    create table(:mail_triage_feedback, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)

      add(:account_id, references(:mail_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :inbound_message_id,
        references(:mail_inbound_messages, type: :binary_id, on_delete: :nilify_all)
      )

      add(:sender_address, :text, null: false)
      add(:sender_domain, :text, null: false)
      add(:verdict, :text, null: false)

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(
      constraint(:mail_triage_feedback, :mail_triage_feedback_verdict_check,
        check: "verdict IN ('not_important', 'missed')"
      )
    )

    create(index(:mail_triage_feedback, [:user_id, :sender_domain]))
    create(index(:mail_triage_feedback, [:account_id]))
  end

  def down do
    drop(table(:mail_triage_feedback))
    drop(table(:mail_triage_items))
  end
end
