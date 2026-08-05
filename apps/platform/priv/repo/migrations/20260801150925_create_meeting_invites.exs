defmodule Platform.Repo.Migrations.CreateMeetingInvites do
  @moduledoc """
  Task `019fb954-3ac2-7e43-9642-185280ac9983`, stage 1 — makes "invited" a
  declaration.

  Before this table there was no invitee set at all. `MeetingNotifier` derived
  recipients from the backing chat space's human participants, which means you
  could not invite anyone who was not already in the space, and you could not
  invite anyone *before* that membership existed. `meeting_invites` is the
  declaration those downstream surfaces (calendar, invite UX, invite delivery,
  `.ics`, external room access) need.

  ## Shape

  One row shape carries all three invite kinds:

    * **internal user** — `user_id` set.
    * **external qualified user** — `user_id` set; the external org membership
      was already provisioned by `Platform.Accounts.ExternalAdmission`, so the
      invite row needs nothing extra to describe it.
    * **guest** — no account; `display_name` (and usually `email`) identify
      them, and `expires_at` bounds their signed link.

  ## Columns

    * `meeting_id` — FK `meetings`, `on_delete: :delete_all`, NOT NULL. Invites
      are meaningless without their meeting, so they die with it.
    * `user_id` — FK `users`, `on_delete: :delete_all`, NULLABLE. Set for both
      account-holding kinds; NULL for a guest.
    * `display_name` — NULLABLE. Required for a guest (see the identity CHECK);
      optional for a user invite, where the user's own name is authoritative.
    * `email` — NULLABLE. A guest has no account, so this is the only address
      the invite-delivery member can reach them at. Nullable because a host may
      want a copyable link and nothing else.
    * `expires_at` — NULLABLE, guest-only. This column is AUTHORITATIVE for
      expiry; the signed `Platform.Meetings.GuestInvite` token carries a copy,
      and the resolve path checks both.
    * `revoked_at` — NULLABLE. The revocation surface. An issued HMAC token
      cannot be un-issued, so revoking has to be a row fact.

  ## Constraints and indexes

    * `meeting_invites_identity_check` — `user_id IS NOT NULL OR display_name
      IS NOT NULL`. A row with neither is an unattributable invite, which
      defeats the point of declaring invitees at all.
    * partial `unique_index([:meeting_id, :user_id]) WHERE user_id IS NOT NULL`
      — one invite per user per meeting, so re-inviting is idempotent instead of
      duplicating recipients. Partial because multiple guests on one meeting are
      legitimate and each is a distinct row.
    * `index([:meeting_id])` — the notifier's read path is meeting-scoped.

  ## Deliberate omissions (do not re-add without a reader)

    * **No `status` column.** `invited` / `accepted` / `declined` is tempting
      and speculative: no member of this stack exposes an RSVP action, and
      `MeetingNotifier` notifies every non-revoked invitee regardless. A column
      nothing reads goes stale and is then trusted. `revoked_at` is here
      precisely because it IS read in v1.
    * **No `kind` column.** Kind is derived, not stored: `user_id != nil`
      separates account-holder from guest, and internal-vs-external is a
      property of the user's org membership (`org_memberships.external`, written
      by `ExternalAdmission`). Copying it onto the invite row creates a second
      source of truth that drifts the moment membership changes. See
      `Platform.Meetings.Invite.kind/1`.
    * **`meeting_participants` gains nothing.** A nullable `invite_id` FK there
      would have no writer — participant rows are created off the LiveKit
      webhook path from the room/identity payload, which carries no invite id,
      so the column would be NULL on every row. The correct future move is to
      encode the invite id into the LiveKit participant identity so the webhook
      can resolve it; that is a webhook-identity change, not a schema change.
  """

  use Ecto.Migration

  def change do
    create table(:meeting_invites, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :meeting_id,
        references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))

      add(:display_name, :string)
      add(:email, :string)
      add(:expires_at, :utc_datetime_usec)
      add(:revoked_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:meeting_invites, :meeting_invites_identity_check,
        check: "user_id IS NOT NULL OR display_name IS NOT NULL"
      )
    )

    create(
      unique_index(:meeting_invites, [:meeting_id, :user_id], where: "user_id IS NOT NULL")
    )

    create(index(:meeting_invites, [:meeting_id]))
  end
end
