defmodule Platform.Access.RuntimeProfile do
  @moduledoc "Access-owned tool profile and optional permission restriction for a runtime."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "access_runtime_profiles" do
    belongs_to(:runtime, Platform.Agents.AgentRuntime, primary_key: true)
    field(:tool_profile, {:array, :string})
    field(:restricted_permissions, :map)
    field(:updated_by, :binary_id)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:runtime_id, :tool_profile, :restricted_permissions, :updated_by])
    |> validate_required([:runtime_id])
    |> unique_constraint(:runtime_id)
  end
end
