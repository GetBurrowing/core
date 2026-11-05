defmodule Platform.Repo.Migrations.AddMailReceiptToMeetingInvites do
  @moduledoc """
  Task 01a1a933 stage 3 (meeting invite email).

  The invite email's receipt on the invite row, mirroring
  `calendar_bookings.delivery_id` / `delivery_error`:

    * `mail_delivery_id` — the `mail_deliveries` row the invitation was
      queued as (or refused as). NILIFY on delete: the invite outlives its
      audit row;
    * `mail_error` — why no email was queued (no meetings sender, mail
      disabled, a refused policy), in words a host can act on.

  A later SMTP failure is read off the delivery row's status, not copied
  here (`Platform.Meetings.invite_mail_failed?/1`).
  """
  use Ecto.Migration

  def change do
    alter table(:meeting_invites) do
      add(
        :mail_delivery_id,
        references(:mail_deliveries, type: :binary_id, on_delete: :nilify_all)
      )

      add(:mail_error, :text)
    end

    create(index(:meeting_invites, [:mail_delivery_id]))
  end
end
