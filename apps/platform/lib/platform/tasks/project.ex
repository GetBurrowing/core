defmodule Platform.Tasks.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
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
    field(:archived_at, :utc_datetime_usec)
    field(:deletion_scheduled_at, :utc_datetime_usec)
    field(:archived_cascade_org_id, :binary_id)

    belongs_to(:org, Platform.Tenancy.Org)

    has_many(:epics, Platform.Tasks.Epic)
    has_many(:tasks, Platform.Tasks.Task)

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(workspace_id name slug repo_url default_branch tech_stack deploy_config config org_id archived_at deletion_scheduled_at archived_cascade_org_id)a

  def changeset(project, attrs) do
    project
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :org_id])
    |> maybe_generate_slug()
    |> validate_required([:slug])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:org_id)
    |> validate_deploy_strategy()
  end

  defp validate_deploy_strategy(changeset) do
    case get_change(changeset, :deploy_config) do
      nil ->
        changeset

      deploy_config when is_map(deploy_config) ->
        case Map.get(deploy_config, "default_strategy") do
          nil ->
            changeset

          strategy when is_map(strategy) ->
            case Platform.Tasks.DeployStageBuilder.validate_strategy(strategy) do
              :ok -> changeset
              {:error, reason} -> add_error(changeset, :deploy_config, reason)
            end

          _ ->
            add_error(changeset, :deploy_config, "default_strategy must be a map")
        end

      _ ->
        changeset
    end
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
