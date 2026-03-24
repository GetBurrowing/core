defmodule Platform.Skills.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "skills" do
    field(:name, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:content, :string)

    has_many(:skill_attachments, Platform.Skills.SkillAttachment)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:name, :description, :content])
    |> validate_required([:name, :content])
    |> generate_slug()
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end

  defp generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil ->
        changeset

      name ->
        slug =
          name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9\s-]/, "")
          |> String.replace(~r/\s+/, "-")
          |> String.replace(~r/-+/, "-")
          |> String.trim("-")

        put_change(changeset, :slug, slug)
    end
  end
end
