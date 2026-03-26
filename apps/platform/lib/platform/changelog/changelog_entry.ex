defmodule Platform.Changelog.ChangelogEntry do
  @moduledoc "Schema for a changelog entry sourced from a merged GitHub PR."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  schema "changelog_entries" do
    field(:title, :string)
    field(:description, :string)
    field(:pr_number, :integer)
    field(:pr_url, :string)
    field(:commit_sha, :string)
    field(:author, :string)
    field(:tags, {:array, :string}, default: [])
    field(:merged_at, :utc_datetime_usec)

    belongs_to(:task, Platform.Tasks.Task)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(title merged_at)a
  @optional ~w(description pr_number pr_url commit_sha author task_id tags)a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:pr_number)
    |> foreign_key_constraint(:task_id)
  end
end
