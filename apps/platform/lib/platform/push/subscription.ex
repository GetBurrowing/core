defmodule Platform.Push.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "push_subscriptions" do
    field(:participant_id, :binary_id)
    field(:endpoint, :string)
    field(:p256dh, :string)
    field(:auth, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:participant_id, :endpoint, :p256dh, :auth])
    |> validate_required([:participant_id, :endpoint, :p256dh, :auth])
    |> unique_constraint([:participant_id, :endpoint])
  end
end
