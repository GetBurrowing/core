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

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(meeting_id user_id display_name email expires_at revoked_at)a

  @doc """
  Changeset for creating or updating an invite.

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
    |> check_constraint(:display_name, name: :meeting_invites_identity_check)
    |> unique_constraint([:meeting_id, :user_id])
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
