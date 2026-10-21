defmodule Platform.Social.OwnerDm do
  @moduledoc """
  The canonical Social system-sender DM of one account owner in one org
  (task 01a14ce1, stage 3). Written only by
  `Platform.Social.Approvals.owner_dm/2`; unique on `(org_id,
  owner_user_id)`, so an owner has exactly one such DM per org.
  """
  use Ecto.Schema

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "social_owner_dms" do
    field(:org_id, :binary_id)
    field(:owner_user_id, :binary_id)
    field(:space_id, :binary_id)

    timestamps()
  end
end
