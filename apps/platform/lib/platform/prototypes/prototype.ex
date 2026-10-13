defmodule Platform.Prototypes.Prototype do
  @moduledoc """
  A published prototype (ADR 0057 Decision 1). The bytes live in
  `Platform.Prototypes.Version` rows; this row is the stable identity a URL
  names and the org whose members may open it.

  `latest_version` is a pointer. Publishing moves it to the new version;
  `Platform.Prototypes.rollback/3` moves it back without copying anything.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "prototypes" do
    field(:org_id, :binary_id)
    field(:space_id, :binary_id)
    field(:name, :string)
    field(:created_by_user_id, :binary_id)
    field(:created_by_agent_id, :binary_id)
    field(:latest_version, :integer, default: 0)

    has_many(:versions, Platform.Prototypes.Version)

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:org_id, :space_id, :name, :created_by_user_id, :created_by_agent_id])
    |> validate_required([:org_id, :name])
    |> validate_length(:name, min: 1, max: 200)
  end
end
