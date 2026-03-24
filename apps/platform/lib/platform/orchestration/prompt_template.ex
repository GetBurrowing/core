defmodule Platform.Orchestration.PromptTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "prompt_templates" do
    field(:slug, :string)
    field(:name, :string)
    field(:description, :string)
    field(:content, :string)
    field(:variables, {:array, :string}, default: [])
    field(:updated_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [:slug, :name, :description, :content, :variables, :updated_by])
    |> validate_required([:slug, :name, :content])
    |> unique_constraint(:slug)
  end
end
