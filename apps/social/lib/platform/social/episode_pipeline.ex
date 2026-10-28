defmodule Platform.Social.EpisodePipeline do
  @moduledoc """
  Persistent activation boundary for automatic episode discovery (task 01a17e37).
  The first sweep records a cutoff once per configured profile and pipeline
  version. Restarts retain it, so missed uploads are recovered without replaying
  the historical catalog. A new version must be explicitly activated.

  The episode's pick plan and child identities are persisted under the parent
  ClipJobs row lock. Children use the canonical headline-review/1 runner and
  immutable version completion; the parent completes only after its children.
  Generated headline text remains local to the runner.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "social_episode_pipelines" do
    belongs_to(:profile, Platform.Social.Profile)
    field(:version, :string)
    field(:activated_at, :utc_datetime_usec)
    timestamps()
  end

  def changeset(pipeline, attrs) do
    pipeline
    |> cast(attrs, [:profile_id, :version, :activated_at])
    |> validate_required([:profile_id, :version, :activated_at])
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:profile_id, :version])
  end
end
