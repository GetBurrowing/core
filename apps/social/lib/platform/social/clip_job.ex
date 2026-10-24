defmodule Platform.Social.ClipJob do
  @moduledoc """
  One job on Clip Studio's job list (task 01a16661-e234, Clip Studio 1/9):
  what the htc-clip-tool contract calls the render queue. A human enqueues
  it through `Platform.Social.ClipJobs`; a runner agent claims it, reports
  progress, and completes or fails it.

  `kind` is `new_clip`, `rerender` or `save_default` (a plain string with the
  named CHECK `social_clip_jobs_kind_check`, so a later kind is a CHECK
  change, never an enum migration). `status` runs `queued` -> `claimed` ->
  `running` -> `done` | `failed`. At most one open job per clip (partial
  unique index `social_clip_jobs_one_open_per_clip`).

  `payload` is what the runner needs (built by `Platform.Social.ClipJobs`,
  string keys); `result` is the runner's whitelisted answer.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @kinds ~w(new_clip rerender save_default)
  @statuses ~w(queued claimed running done failed)
  @open_statuses ~w(queued claimed running)

  @type t :: %__MODULE__{}

  schema "social_clip_jobs" do
    belongs_to(:profile, Platform.Social.Profile)
    belongs_to(:clip, Platform.Social.Clip)
    field(:kind, :string)
    field(:status, :string, default: "queued")
    field(:progress, :float)
    field(:eta_s, :integer)
    field(:payload, :map, default: %{})
    field(:result, :map)
    field(:error, :string)
    belongs_to(:claimed_by_agent, Platform.Agents.Agent)
    field(:claimed_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    belongs_to(:requested_by_user, Platform.Accounts.User)

    timestamps()
  end

  @doc "Accepted `kind` values."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Accepted `status` values."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "The statuses of a job that is still open (one per clip)."
  @spec open_statuses() :: [String.t()]
  def open_statuses, do: @open_statuses

  @doc "A new queued job. Written by `Platform.Social.ClipJobs`, never from agent attrs."
  @spec enqueue_changeset(t(), map()) :: Ecto.Changeset.t()
  def enqueue_changeset(%__MODULE__{} = job, attrs) do
    job
    |> cast(attrs, [:profile_id, :clip_id, :kind, :payload, :requested_by_user_id])
    |> put_change(:status, "queued")
    |> validate_required([:profile_id, :kind, :payload])
    |> validate_inclusion(:kind, @kinds)
    |> validate_clip()
    |> job_constraints()
  end

  @doc "Claimed by `agent_id` now."
  @spec claim_changeset(t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def claim_changeset(%__MODULE__{} = job, agent_id) do
    job
    |> change(status: "claimed", claimed_by_agent_id: agent_id, claimed_at: now())
    |> job_constraints()
  end

  @doc "Running, with `progress` in 0..1 and `eta_s` >= 0 (nil allowed)."
  @spec progress_changeset(t(), map()) :: Ecto.Changeset.t()
  def progress_changeset(%__MODULE__{} = job, attrs) do
    job
    |> cast(attrs, [:progress, :eta_s])
    |> put_change(:status, "running")
    |> validate_required([:progress])
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> validate_number(:eta_s, greater_than_or_equal_to: 0)
    |> job_constraints()
  end

  @doc "Done (with the whitelisted `result`) or failed (with `error`)."
  @spec finish_changeset(t(), :done | :failed, map()) :: Ecto.Changeset.t()
  def finish_changeset(%__MODULE__{} = job, :done, result) do
    job
    |> change(status: "done", progress: 1.0, result: result, error: nil, finished_at: now())
    |> job_constraints()
  end

  def finish_changeset(%__MODULE__{} = job, :failed, error) when is_binary(error) do
    job
    |> change(status: "failed", error: String.slice(error, 0, 2000), finished_at: now())
    |> job_constraints()
  end

  defp validate_clip(changeset) do
    if get_field(changeset, :kind) != "save_default",
      do: validate_required(changeset, [:clip_id]),
      else: changeset
  end

  defp job_constraints(changeset) do
    changeset
    |> check_constraint(:kind, name: :social_clip_jobs_kind_check)
    |> check_constraint(:status, name: :social_clip_jobs_status_check)
    |> check_constraint(:progress, name: :social_clip_jobs_progress_check)
    |> check_constraint(:eta_s, name: :social_clip_jobs_eta_check)
    |> check_constraint(:clip_id, name: :social_clip_jobs_clip_needed_check)
    |> unique_constraint(:clip_id,
      name: :social_clip_jobs_one_open_per_clip,
      message: "already has an open job"
    )
    |> foreign_key_constraint(:profile_id)
    |> foreign_key_constraint(:clip_id)
    |> foreign_key_constraint(:claimed_by_agent_id)
    |> foreign_key_constraint(:requested_by_user_id)
  end

  defp now, do: DateTime.utc_now()
end
