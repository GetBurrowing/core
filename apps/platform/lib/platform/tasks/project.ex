defmodule Platform.Tasks.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field(:workspace_id, :binary_id)
    field(:name, :string)
    field(:slug, :string)
    field(:repo_url, :string)
    field(:default_branch, :string, default: "main")
    field(:tech_stack, :map, default: %{})
    field(:deploy_config, :map, default: %{})
    field(:config, :map, default: %{})

    has_many(:epics, Platform.Tasks.Epic)
    has_many(:tasks, Platform.Tasks.Task)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(workspace_id name slug repo_url default_branch tech_stack deploy_config config)a

  def changeset(project, attrs) do
    project
    |> cast(attrs, @cast_fields)
    |> validate_required([:name])
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> unique_constraint(:slug)
  end

  defp maybe_generate_slug(changeset) do
    case get_field(changeset, :slug) do
      nil ->
        case get_field(changeset, :name) do
          nil -> changeset
          name -> put_change(changeset, :slug, slugify(name))
        end

      _ ->
        changeset
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.trim("-")
  end
end
