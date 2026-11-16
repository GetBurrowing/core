defmodule Platform.Install.BootMarkers do
  @moduledoc """
  Durable "this one-shot boot step has finished on this install" markers,
  the `install_boot_markers` table (task 01a1e65e stage 2).

  A boot step that must run at most once per install, rather than on every
  boot, checks `set?/1` before doing anything and calls `put/1` only after it
  succeeded. Every auto-update reboots core, so a step that re-applies a
  setting on every boot would silently undo an admin who changed it since.

  Keys are a closed set of atoms (`keys/0`), never caller strings. `put/1`
  is idempotent: a second call, or a concurrent one, keeps the first row.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Platform.Repo

  @keys [:pocket_id_email_login_code]

  @type key :: :pocket_id_email_login_code

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}

  schema "install_boot_markers" do
    field(:key, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The marker keys this install knows."
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc "Has the step named `key` finished on this install?"
  @spec set?(key()) :: boolean()
  def set?(key) when key in @keys do
    Repo.exists?(from(m in __MODULE__, where: m.key == ^Atom.to_string(key)))
  end

  @doc "Records that the step named `key` has finished. Idempotent."
  @spec put(key()) :: :ok | {:error, term()}
  def put(key) when key in @keys do
    %__MODULE__{key: Atom.to_string(key)}
    |> Repo.insert(on_conflict: :nothing, conflict_target: :key)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
