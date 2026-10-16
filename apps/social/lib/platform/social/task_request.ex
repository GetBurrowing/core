defmodule Platform.Social.TaskRequest do
  @moduledoc """
  One social task Social filed or adopted (task 01a140a9-831e, Social 6/7),
  written by `Platform.Social.TaskBridge` only.

  `changeset/2` never casts `settled_digest` / `settled_at`: only the
  write-back (`settled_changeset/2`) sets them, after it has written the
  task.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "social_task_requests" do
    belongs_to(:profile, Platform.Social.Profile)
    belongs_to(:task, Platform.Tasks.Task)
    field(:request_key, :string)
    field(:platforms, {:array, :string})
    field(:refs, :map)
    field(:ask, :string)
    belongs_to(:requested_by_agent, Platform.Agents.Agent)
    belongs_to(:requested_in_space, Platform.Chat.Space)
    field(:adopted_candidate_id, :binary_id)
    field(:settled_digest, :string)
    field(:settled_at, :utc_datetime_usec)

    timestamps()
  end

  @fields ~w(profile_id task_id request_key platforms refs ask requested_by_agent_id
             requested_in_space_id adopted_candidate_id)a

  @doc "The insert changeset. Never casts the settlement fields."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = request, attrs) do
    request
    |> cast(attrs, @fields)
    |> validate_required([:profile_id, :task_id, :request_key, :platforms, :refs])
    |> unique_constraint(:task_id)
    |> unique_constraint(:request_key)
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:requested_by_agent_id)
    |> foreign_key_constraint(:requested_in_space_id)
  end

  @doc "The write-back's stamp: the settled record's digest and time."
  @spec settled_changeset(t(), String.t()) :: Ecto.Changeset.t()
  def settled_changeset(%__MODULE__{} = request, digest) when is_binary(digest) do
    change(request, settled_digest: digest, settled_at: DateTime.utc_now())
  end
end
