defmodule Platform.Repo.Migrations.AddRichPartsToMailDraftsAndDeliveries do
  @moduledoc """
  Task 01a1a933 stage 1 (meeting invite email with a calendar attachment).

  Adds the parts a meeting invite needs to both `mail_drafts` and
  `mail_deliveries`:

    * `html_body` — an HTML alternative to the plain `body`;
    * `reply_to` — a Reply-To address;
    * `calendar_method` — `REQUEST` or `CANCEL` (nil for ordinary mail);
    * `calendar_ics` — the iCalendar text, present exactly when
      `calendar_method` is.

  On `mail_deliveries` the four are snapshot columns, so the
  `mail_deliveries_snapshot_immutable` trigger function is replaced with one
  that also refuses an UPDATE changing any of them. `down` restores the
  original column list.
  """
  use Ecto.Migration

  @original ~w(org_id account_id sender_key from_address recipients subject body
               actor_type actor_id drafted_by_type drafted_by_id on_behalf_of_user_id
               responsibility draft_id task_id stage_id message_id_header
               refusal_reason inserted_at)

  @added ~w(html_body reply_to calendar_method calendar_ics)

  def up do
    for table <- [:mail_drafts, :mail_deliveries] do
      alter table(table) do
        add(:html_body, :text)
        add(:reply_to, :text)
        add(:calendar_method, :text)
        add(:calendar_ics, :text)
      end

      create(
        constraint(table, :"#{table}_calendar_method_check",
          check:
            "(calendar_method IS NULL AND calendar_ics IS NULL) OR " <>
              "(calendar_method IN ('REQUEST', 'CANCEL') AND calendar_ics IS NOT NULL)"
        )
      )
    end

    execute(trigger_function(@original ++ @added))
  end

  def down do
    execute(trigger_function(@original))

    for table <- [:mail_deliveries, :mail_drafts] do
      drop(constraint(table, :"#{table}_calendar_method_check"))

      alter table(table) do
        remove(:html_body)
        remove(:reply_to)
        remove(:calendar_method)
        remove(:calendar_ics)
      end
    end
  end

  defp trigger_function(columns) do
    changed =
      columns
      |> Enum.map(&"OLD.#{&1} IS DISTINCT FROM NEW.#{&1}")
      |> Enum.join(" OR ")

    """
    CREATE OR REPLACE FUNCTION mail_deliveries_snapshot_immutable() RETURNS trigger AS $$
    BEGIN
      IF #{changed} THEN
        RAISE EXCEPTION 'mail_deliveries snapshot columns are immutable (delivery %)', OLD.id
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """
  end
end
