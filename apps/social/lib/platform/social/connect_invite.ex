defmodule Platform.Social.ConnectInvite do
  @moduledoc """
  A single-use invite to connect one account on one platform under a
  `Platform.Social.Profile` (task 01a14ce1, stage 2). The invitee who
  completes it becomes the account's `owner_user_id`.

  Every field is set by `Platform.Social`; nothing is cast from attrs. Only
  sha256 hashes of the shared token and of the per-connect nonce are
  stored, never the raw values, and the row holds no vendor key or token.
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "social_connect_invites" do
    field(:org_id, :binary_id)
    belongs_to(:profile, Platform.Social.Profile)
    field(:platform, :string)
    field(:token_hash, :binary, redact: true)
    field(:created_by_user_id, :binary_id)
    field(:expires_at, :utc_datetime_usec)
    field(:used_at, :utc_datetime_usec)
    field(:used_by_user_id, :binary_id)
    belongs_to(:account, Platform.Social.Account)
    field(:cancelled_at, :utc_datetime_usec)
    field(:started_by_user_id, :binary_id)
    field(:connect_nonce_hash, :binary, redact: true)
    field(:connect_nonce_expires_at, :utc_datetime_usec)

    timestamps()
  end
end
