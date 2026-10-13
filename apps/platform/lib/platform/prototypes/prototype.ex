defmodule Platform.Prototypes.Prototype do
  @moduledoc """
  A published prototype (ADR 0057 Decision 1). The bytes live in
  `Platform.Prototypes.Version` rows; this row is the stable identity a URL
  names and the org whose members may open it.

  `latest_version` is a pointer. Publishing moves it to the new version;
  `Platform.Prototypes.rollback/3` moves it back without copying anything.

  ## Canvas-owned prototypes (task 01a1316b-677a)

  A `scripts: true` canvas embed runs as a single-file prototype with
  `canvas_id` and `canvas_node_id` set. Only
  `Platform.Prototypes.publish_embed/1` writes versions of one;
  `publish/3` and `rollback/3` refuse it (`canvas_owned?/1`).
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
    field(:canvas_id, :binary_id)
    field(:canvas_node_id, :string)

    has_many(:versions, Platform.Prototypes.Version)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Is this prototype owned by a canvas embed node?"
  @spec canvas_owned?(t()) :: boolean()
  def canvas_owned?(%__MODULE__{canvas_id: canvas_id}), do: not is_nil(canvas_id)

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :org_id,
      :space_id,
      :name,
      :created_by_user_id,
      :created_by_agent_id,
      :canvas_id,
      :canvas_node_id
    ])
    |> validate_required([:org_id, :name])
    |> validate_length(:name, min: 1, max: 200)
    |> unique_constraint([:canvas_id, :canvas_node_id], name: :prototypes_canvas_node_index)
  end
end
