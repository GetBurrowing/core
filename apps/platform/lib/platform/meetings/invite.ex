defmodule Platform.Meetings.Invite do
  @moduledoc """
  Schema for the `meeting_invites` table — the declared invitee set for a
  meeting (task `019fb954-3ac2-7e43-9642-185280ac9983`).

  Before this table, "invited" was an inference: `Platform.Meetings.MeetingNotifier`
  derived recipients from the human participants of the meeting's backing chat
  space. That made it impossible to invite anyone who was not already in the
  space, or to invite anyone before that membership existed. An invite row is a
  declaration that stands on its own.

  ## The three invite kinds share one row shape

    * **internal user** — `user_id` set.
    * **external qualified user** — `user_id` set; their external org membership
      was already provisioned by `Platform.Accounts.ExternalAdmission`.
    * **guest** — no account; identified by `display_name`, reachable at
      `email`, bounded by `expires_at`.

  There is deliberately **no `kind` column**. Kind is derived: `user_id != nil`
  separates account-holder from guest, and internal-vs-external is a property of
  the user's org membership (`org_memberships.external`), which is already
  authoritative. Storing it here would create a second source of truth that
  drifts the moment the membership changes. Use `kind/1`.

  There is deliberately **no `status` column**. `invited` / `accepted` /
  `declined` has no reader in v1 — no member of this stack exposes an RSVP
  action, and the notifier notifies every non-revoked invitee regardless.
  `revoked_at` exists because it *is* read: a signed `Platform.Meetings.GuestInvite`
  token cannot be un-issued, so revocation has to be a row fact.

  ## `meeting_participants` does not reference invites

  `Platform.Meetings.Participant` deliberately gains no `invite_id`. There is no
  writer for it: participant rows are created off the LiveKit webhook path from
  the room/identity payload, which carries no invite id, so the column would be
  NULL on every row — worse than absent, because a reader will trust it. The
  correct future move is to encode the invite id into the LiveKit participant
  identity so the webhook can resolve it. Do not add a dead FK here.

  ## Delivery receipt (task `019fb955-6577-7fb0-8c97-c70d233bba23`)

  `delivered_at`, `delivery_carrier` and `delivery_space_id` record what
  `Platform.Meetings.InviteDelivery` actually did with this row. They are
  NOT the `status` column rejected above, and the difference is the same
  test that rejected it — whether anything reads the value:

    * `delivered_at` is read on EVERY delivery as the compare-and-swap
      claim (`UPDATE ... WHERE id = ? AND delivered_at IS NULL`, the idiom
      `Platform.Meetings.mark_notified/1` uses on `meetings.notified_at`).
      It is concurrency control, not bookkeeping. `Meetings.invite_user/3`
      returns the EXISTING row on a re-invite, so without it a double
      submit sends the same person a second inbox row and a second push.
    * `delivery_carrier` is the only after-the-fact answer to "which
      surface did this person actually get" — the inbox row, the push
      subscription and the chat message live in three tables and none of
      them knows the other two were skipped.
    * `delivery_space_id` names the chat space stage 4's external carrier
      wrote into.

  None of the three claims to know the invitee's INTENT, which is what
  `accepted` / `declined` would have asserted and been wrong about. They
  record what this system did.

  ## `short_code`: a code is stored, never a token (task 01a18d0a-ec37)

  A guest's short link is `https://<guest host>/g/<short_code>`. The column
  holds an opaque 22-character code from `Platform.Meetings.GuestShortCode`,
  and nothing else. The signed `Platform.Meetings.GuestInvite` token is
  deliberately NOT stored: it is a live bearer credential, so a copy at rest
  is a copy anyone with read access to this table could use. The row is the
  source of truth and is already enough to re-mint the token
  (`Platform.Meetings.guest_invite_link/2`), which is what
  `Platform.Meetings.resolve_guest_short_code/1` does on every hit.

  `short_code` is not in the cast list. Only `Platform.Meetings` sets it, with
  `put_change/3` on the same insert that creates the guest row, so no caller
  can choose or overwrite a code. Account-holder rows never carry one.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type kind :: :user | :guest

  schema "meeting_invites" do
    belongs_to(:meeting, Platform.Meetings.Meeting)
    belongs_to(:user, Platform.Accounts.User)

    field(:display_name, :string)
    field(:email, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    # Set only by `Platform.Meetings` internals; never cast. See the
    # `short_code` section of the moduledoc.
    field(:short_code, :string)

    # Delivery receipt (task `019fb955-6577-7fb0-8c97-c70d233bba23`). See the
    # "Delivery receipt" section of the moduledoc for why these three are not
    # the rejected `status` column.
    field(:delivered_at, :utc_datetime_usec)
    field(:delivery_carrier, :string)
    belongs_to(:delivery_space, Platform.Chat.Space)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(meeting_id user_id display_name email expires_at revoked_at
                  delivered_at delivery_carrier delivery_space_id)a

  # The same predicate `Platform.Accounts.User.changeset/2` validates `:email`
  # with, and the one `Meetings.resolve_invite_candidates/2` offers an address
  # under. Checked only when an email is present: a guest invite needs no
  # address at all (task 01a18d0a-ec37 stage 2, "+ Add email (optional)").
  @email_format ~r/^[^\s]+@[^\s]+$/

  @doc """
  Changeset for creating or updating an invite.

  `email` is optional; when given it must look like an address (`@email_format`).

  `meeting_id` is the only required field at the changeset level. The
  "who is this?" rule — a row must carry either a `user_id` or a
  `display_name` — is enforced by the `meeting_invites_identity_check` database
  CHECK, surfaced here on `:display_name` so the caller gets a changeset error
  instead of a raised `Postgrex.Error`.
  """
  def changeset(invite, attrs) do
    invite
    |> cast(attrs, @cast_fields)
    |> validate_required([:meeting_id])
    |> validate_format(:email, @email_format, message: "must be an email address")
    |> check_constraint(:display_name, name: :meeting_invites_identity_check)
    |> unique_constraint([:meeting_id, :user_id])
    |> unique_constraint(:short_code, name: :meeting_invites_short_code_index)
    |> foreign_key_constraint(:meeting_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Derives the invite kind from the row rather than reading a stored column.

  Returns `:user` when the invite names an account (internal or external
  qualified — that distinction lives on the user's org membership, not here) and
  `:guest` when it does not.
  """
  @spec kind(t :: %__MODULE__{}) :: kind()
  def kind(%__MODULE__{user_id: nil}), do: :guest
  def kind(%__MODULE__{}), do: :user
end
