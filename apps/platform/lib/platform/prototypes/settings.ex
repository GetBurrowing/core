defmodule Platform.Prototypes.Settings do
  @moduledoc """
  The `install_prototype_settings` singleton (ADR 0057 Decision 5): this
  install's switch and caps for prototype publishing. Mirrors
  `Platform.Branding.InstallBranding`: one row, enforced by a DB CHECK and a
  unique index, seeded by the migration, never on the orgs table.

  Read fresh at call time (`get/0`), so an admin turning publishing off takes
  effect on the next publish with no restart.

  ## Fields

    * `enabled` — default `false`. Publishing fails closed while off.
    * `who_may_publish` — `"members"` (default), `"admins"` or `"agents_only"`.
      See `Platform.Prototypes.authorize_publish/3` for exactly what each
      admits.
    * `max_bundle_bytes` — uncompressed total, default 25 MiB.
    * `max_files` — default 500.
    * `retention_days` — default 90. `nil` keeps every version forever.
      The latest version is never removed whatever this says.

  Stage 2 builds `/admin/prototypes` on `update/2`.

  ## Authorization goes through `Platform.Access` (task 01a1386d-fb6e stage 2)

  The re-check is `Platform.Access.authorize_install/1`, not a local
  `Tenancy.root_admin?/1`. It answers the same for every internal actor and is
  STRICTER for exactly one class, the external root admin (guest dominates,
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Root-admin carve-outs`),
  who is now refused here too. Today the `ExternalUserScope` plug already
  refuses that user over HTTP, so HTTP outcomes are unchanged. The refusal
  shape stays `{:error, :unauthorized}`.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Platform.Access
  alias Platform.Repo

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @publish_policies ~w(members admins agents_only)

  @type t :: %__MODULE__{}

  schema "install_prototype_settings" do
    field(:singleton, :boolean, default: true)
    field(:enabled, :boolean, default: false)
    field(:who_may_publish, :string, default: "members")
    field(:max_bundle_bytes, :integer, default: 26_214_400)
    field(:max_files, :integer, default: 500)
    field(:retention_days, :integer, default: 90)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The values `who_may_publish` accepts."
  @spec publish_policies() :: [String.t()]
  def publish_policies, do: @publish_policies

  @doc "The singleton row, read fresh."
  @spec get() :: t()
  def get, do: Repo.one!(from(s in __MODULE__, limit: 1))

  @doc """
  Update the settings. Root-admin only (`Platform.Access.authorize_install/1`),
  re-checked here because a route gate is not an authorization boundary for a
  context function.
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
    |> cast(attrs, [:enabled, :who_may_publish, :max_bundle_bytes, :max_files, :retention_days])
    |> validate_required([:enabled, :who_may_publish, :max_bundle_bytes, :max_files])
    |> validate_inclusion(:who_may_publish, @publish_policies)
    |> validate_number(:max_bundle_bytes, greater_than: 0)
    |> validate_number(:max_files, greater_than: 0)
    |> validate_number(:retention_days, greater_than: 0)
  end
end
