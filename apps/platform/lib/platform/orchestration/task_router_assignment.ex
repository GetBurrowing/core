defmodule Platform.Orchestration.TaskRouterAssignment do
  @moduledoc """
  Persisted record of an active task router assignment.

  Written when `TaskRouter.init/1` starts a router for a task, marked
  `"completed"` on explicit `unassign_task/1`. Crash or restart leaves the
  record `"active"` so the Rehydrator can restart the router on next boot.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Platform.Repo

  @valid_statuses ~w(active completed failed)

  @primary_key {:task_id, :binary_id, autogenerate: false}

  schema "task_router_assignments" do
    field(:assignee_type, :string)
    field(:assignee_id, :string)
    field(:execution_space_id, :binary_id)
    field(:assigned_at, :utc_datetime_usec)
    field(:status, :string, default: "active")
  end

  @doc "Changeset for creating a new assignment record."
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:task_id, :assignee_type, :assignee_id, :execution_space_id, :assigned_at])
    |> validate_required([:task_id, :assignee_type, :assignee_id])
    |> put_default_assigned_at()
  end

  @doc "Changeset for updating the status of an existing assignment."
  @spec status_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def status_changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
  end

  @doc "Return all assignments with status `\"active\"`. Used by the Rehydrator on boot."
  @spec list_active() :: [%__MODULE__{}]
  def list_active do
    from(a in __MODULE__, where: a.status == "active")
    |> Repo.all()
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp put_default_assigned_at(%Ecto.Changeset{} = cs) do
    if get_field(cs, :assigned_at) do
      cs
    else
      put_change(cs, :assigned_at, DateTime.utc_now())
    end
  end
end
