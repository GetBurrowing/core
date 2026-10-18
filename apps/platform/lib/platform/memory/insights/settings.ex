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
    * `apply_page_edits` — default `false`, and REFUSED when set `true`
      ("not available yet"): automatic page edits are deferred.
    * `file_tasks` — default `false`, and refused the same way.

  The refusal is in `changeset/2` and again in a DB CHECK, so neither a
  caller of `update/2` nor a raw write can turn a deferred path on.

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

  @deferred [:apply_page_edits, :file_tasks]
  @not_available "not available yet"

  @type t :: %__MODULE__{}

  schema "install_insight_settings" do
    field(:singleton, :boolean, default: true)
    field(:dissemination_enabled, :boolean, default: false)
    field(:deliver_briefings, :boolean, default: true)
    field(:deliver_questions, :boolean, default: true)
    field(:apply_page_edits, :boolean, default: false)
    field(:file_tasks, :boolean, default: false)

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
    |> refuse_deferred()
    |> check_constraint(:apply_page_edits,
      name: :install_insight_settings_deferred_off,
      message: @not_available
    )
  end

  defp refuse_deferred(changeset) do
    Enum.reduce(@deferred, changeset, fn field, acc ->
      validate_change(acc, field, fn
        ^field, true -> [{field, @not_available}]
        _field, _value -> []
      end)
    end)
  end
end
