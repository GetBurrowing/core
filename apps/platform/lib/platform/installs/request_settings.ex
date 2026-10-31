defmodule Platform.Installs.RequestSettings do
  @moduledoc """
  The `install_request_settings` singleton (task 01a18f0c stage 1): the spend
  gate for install requests. Mirrors `Platform.Prototypes.Settings`: one row,
  enforced by a DB CHECK and a unique index, seeded by the migration.

  ## Fields

    * `auto_provision_requests` — default `false`. While off, a request from
      the public form waits as a `requested` row until a root admin clicks
      Provision; `Platform.Installs.request/1` makes no provider call. While
      on, `request/1` provisions immediately, which buys a server.

  ## Why a row and not `config :platform, Platform.Installs`

  `Platform.Installs.config/2` reads `Application.get_env`, which prod sets
  only from `config/runtime.exs` at release boot: flipping it is an env edit
  plus a restart. `get/0` reads the row fresh on every call, so an operator's
  change applies to the next request with no restart. There is deliberately
  no config key as well; two switches would disagree.

  `update/2` is root admin only, re-checked with
  `Platform.Access.authorize_install/1` (the route gate is not an
  authorization boundary for a context function).
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Repo

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "install_request_settings" do
    field(:singleton, :boolean, default: true)
    field(:auto_provision_requests, :boolean, default: false)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The singleton row, read fresh."
  @spec get() :: t()
  def get, do: Repo.one!(from(s in __MODULE__, limit: 1))

  @doc "Update the settings. Root-admin only (`Platform.Access.authorize_install/1`)."
  @spec update(any(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def update(actor, attrs) do
    with :ok <- Access.authorize_install(actor) do
      get() |> changeset(attrs) |> Repo.update()
    end
  end

  @doc false
  def changeset(%__MODULE__{} = settings, attrs) do
    settings
    |> cast(attrs, [:auto_provision_requests])
    |> validate_required([:auto_provision_requests])
  end
end
