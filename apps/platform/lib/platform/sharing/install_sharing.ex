defmodule Platform.Sharing.InstallSharing do
  @moduledoc """
  Schema for the `install_sharing` singleton row: what this install shares
  with Burrow (task 01a1b678 stage 1).

  One row, ever. `singleton` is pinned `true` by a DB CHECK and covered by a
  unique index, the same shape as `Platform.Branding.InstallBranding`.

  One boolean column per `Platform.Sharing.registry/0` key. A registry entry
  added later (support access, automatic updates) adds its column in its own
  migration.

  `sharing_install_id` is a random UUIDv4 written once at seed time. It is
  NOT the federation install id (`Platform.Federation.Peers.InstallIdentity`)
  and is linked to no account, so nothing sent under it can be joined back
  to a user.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  @switches [
    :feedback,
    :usage_counts,
    :friction_reports,
    :help_channel_reports,
    :instruction_updates
  ]

  @type t :: %__MODULE__{}

  schema "install_sharing" do
    field(:singleton, :boolean, default: true)
    field(:sharing_install_id, Ecto.UUID)
    field(:feedback, :boolean, default: false)
    field(:usage_counts, :boolean, default: false)
    field(:friction_reports, :boolean, default: false)
    field(:help_channel_reports, :boolean, default: false)
    field(:instruction_updates, :boolean, default: false)
    field(:instruction_updates_stopped, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The switch columns, one per registry key."
  @spec switches() :: [atom()]
  def switches, do: @switches

  @doc "Changeset for the seed insert: every switch plus the random id."
  @spec seed_changeset(t(), map()) :: Ecto.Changeset.t()
  def seed_changeset(%__MODULE__{} = row, attrs) do
    row
    |> cast(attrs, [:sharing_install_id | @switches])
    |> validate_required([:sharing_install_id | @switches])
  end

  @doc "Changeset for one switch. Casts that switch only."
  @spec switch_changeset(t(), atom(), boolean()) :: Ecto.Changeset.t()
  def switch_changeset(%__MODULE__{} = row, key, value)
      when (key in @switches or key == :instruction_updates_stopped) and is_boolean(value) do
    row
    |> cast(%{key => value}, [key])
    |> validate_required([key])
  end
end
