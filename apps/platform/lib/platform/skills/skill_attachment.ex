defmodule Platform.Skills.SkillAttachment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @entity_types ~w(project epic task)

  schema "skill_attachments" do
    belongs_to(:skill, Platform.Skills.Skill)
    field(:entity_type, :string)
    field(:entity_id, :binary_id)

    # Immutable — only inserted_at (no timestamps macro)
    field(:inserted_at, :utc_datetime_usec)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:skill_id, :entity_type, :entity_id])
    |> validate_required([:skill_id, :entity_type, :entity_id])
    |> validate_inclusion(:entity_type, @entity_types)
    |> foreign_key_constraint(:skill_id)
    |> unique_constraint([:skill_id, :entity_type, :entity_id],
      name: :skill_attachments_unique_triple,
      message: "skill already attached to this entity"
    )
    |> maybe_set_inserted_at()
  end

  defp maybe_set_inserted_at(changeset) do
    if get_field(changeset, :inserted_at) do
      changeset
    else
      put_change(changeset, :inserted_at, DateTime.utc_now())
    end
  end
end
