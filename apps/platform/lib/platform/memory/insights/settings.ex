defmodule Platform.Memory.Insights.Settings do
  @moduledoc """
  The `install_insight_settings` singleton: whether dreaming insights are
  disseminated on this install, and which kinds. Task
  `01a13867-3213-7001-a128-6b4c6b34283f`, stage 3. Mirrors
  `Platform.Prototypes.Settings`: one row, enforced by a DB CHECK and a
  unique index, seeded by the migration, never on the orgs table.

  Read fresh at call time (`get/0`), so an admin turning dissemination off
  takes effect on the next digest with no restart.

  ## Fields

    * `dissemination_enabled` — master switch, default `false`. While off,
      `Platform.Memory.Insights.Digest.select/2` selects nothing.
    * `deliver_briefings` — default `true`.
    * `deliver_questions` — default `true`.
    * `apply_page_edits` — default `false`. When on, a grounded `page_edit`
      insight at or above the run's `auto_apply_min_confidence` is applied
      unattended and can be reverted from the briefing.
    * `file_tasks` — default `true` (task
      `01a15ee1-48c8-7000-a8f1-33a5586cb458`, stage 2). When on, a `task`
      insight at or above the same threshold is filed to the backlog
      unattended, into the project
      `Platform.Memory.Insights.ProjectInference` presumes, and can be
      deleted or moved from the briefing.

  `apply_page_edits` ships off and only a root admin can turn it on (task
  `01a15587-afc8-7000-b76d-4e1c48eee5ed` lifted the earlier deferral and its
  DB CHECK). `file_tasks` shipped off too until the sponsor, 2026-10-21:
  "the tasks should already have been filed to the presumed appropriate
  project. those should be in the easily reversible column". Migration
  `20261021160100_insight_settings_file_tasks_default_on` makes the column
  default true and flips only a row that was never edited, so an admin's
  saved choice stands.

  ## Authorization

  `update/2` re-checks `Platform.Access.authorize_install/1` (root admin),
  because a route gate is not an authorization boundary for a context
  function. The refusal shape is `{:error, :unauthorized}`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Repo

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "install_insight_settings" do
    field(:singleton, :boolean, default: true)
    field(:dissemination_enabled, :boolean, default: false)
    field(:deliver_briefings, :boolean, default: true)
    field(:deliver_questions, :boolean, default: true)
    field(:apply_page_edits, :boolean, default: false)
    field(:file_tasks, :boolean, default: true)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The singleton row, read fresh."
  @spec get() :: t()
  def get, do: Repo.one!(from(s in __MODULE__, limit: 1))

  @doc """
  Update the settings. Root-admin only (`Platform.Access.authorize_install/1`).
  """
  @spec update(any(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update(actor, attrs) do
    with :ok <- Access.authorize_install(actor) do
      get() |> changeset(attrs) |> Repo.update()
    end
  end

  @doc false
  def changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, [
      :dissemination_enabled,
      :deliver_briefings,
      :deliver_questions,
      :apply_page_edits,
      :file_tasks
    ])
    |> validate_required([
      :dissemination_enabled,
      :deliver_briefings,
      :deliver_questions,
      :apply_page_edits,
      :file_tasks
    ])
  end
end
