defmodule Platform.Repo.Migrations.AddDeliveryReceiptToMeetingInvites do
  @moduledoc """
  Task `019fb955-6577-7fb0-8c97-c70d233bba23`, stage 3 — the delivery receipt
  on `meeting_invites`.

  `019fb954-3ac2` made "invited" a declaration. It did not make it a *send*.
  An invite row said who was named; nothing on it said whether anything ever
  reached them, or by which surface. This migration adds the receipt.

  ## Columns

    * `delivered_at :utc_datetime_usec`, NULLABLE — the compare-and-swap
      claim. `Platform.Meetings.InviteDelivery.deliver/2` performs
      `UPDATE ... WHERE id = ? AND delivered_at IS NULL` BEFORE any
      downstream work, exactly as `Platform.Meetings.mark_notified/1` does
      on `meetings.notified_at`. Exactly one caller sees `{1, _}`; the rest
      see `{0, _}` and send nothing.

      This is load-bearing rather than decorative. `Meetings.invite_user/3`
      is idempotent on the partial `unique_index(:meeting_invites,
      [:meeting_id, :user_id])` and returns the EXISTING row on a re-invite,
      so without this column a host who double-submits fires a second inbox
      row and a second web push at the same person.

    * `delivery_carrier :string`, NULLABLE — which surface actually carried
      it: `guest_link`, `internal_inbox_push`, or (from stage 4)
      `external_chat`. This is the only after-the-fact answer to "which
      surface did this person actually get", which is the entire subject of
      this task. A NULL carrier alongside a stamped `delivered_at` is
      itself readable: the claim was taken and no carrier ran.

    * `delivery_space_id` — FK `chat_spaces`, `on_delete: :nilify_all`,
      NULLABLE. Written by stage 4's external-chat carrier, which delivers
      into a chat space rather than an inbox. Declared here so this table
      takes ONE migration for the receipt rather than two; a second
      migration for a single nullable FK is churn with a rollback ordering
      problem attached. `:nilify_all` and not `:delete_all` because the
      receipt outlives the space: deleting a chat space must not delete the
      historical fact that an invite was delivered through it.

  ## This is NOT the rejected `status` column — do not re-litigate it

  `20260801150925_create_meeting_invites.exs` rejected an
  `invited / accepted / declined` status column, and that rejection stands.
  The stated reason was that nothing in v1 READS it: no member of the stack
  exposes an RSVP action, and the notifier notifies every non-revoked
  invitee regardless. A column nothing reads goes stale and is then
  trusted.

  These three columns fail that test in the opposite direction:

    * `delivered_at` is read on EVERY delivery — it IS the concurrency
      control, not a record of one. Remove it and the duplicate push is
      immediate and user-visible.
    * `delivery_carrier` is read by the operator question this task exists
      to answer. There is no other place that answer lives: the inbox row,
      the push subscription and the chat message are three different tables
      and none of them knows the others were skipped.
    * `delivery_space_id` is read by stage 4 to find the space it wrote to.

  None of the three describes the invitee's INTENT (which is what a status
  column would have claimed to know and would have been wrong about). They
  describe what this system did.

  ## Nullable, all three

  Every existing row predates delivery and every future guest/external row
  may legitimately never acquire a carrier. NULL is the correct "not
  delivered" state and needs no backfill.
  """

  use Ecto.Migration

  def change do
    alter table(:meeting_invites) do
      add(:delivered_at, :utc_datetime_usec)
      add(:delivery_carrier, :string)

      add(
        :delivery_space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :nilify_all)
      )
    end
  end
end
