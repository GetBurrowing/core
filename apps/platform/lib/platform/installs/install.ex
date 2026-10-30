defmodule Platform.Installs.Install do
  @moduledoc """
  One install `Platform.Installs` provisions on DigitalOcean (task 01a10315
  stage 2). See the `installs` migration for what each column holds.

  `handover_sealed` is redacted from `inspect/1`, and so is the token hash:
  a struct printed into a log or an error carries no credential.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @derive {Inspect, except: [:handover_sealed, :status_token_hash]}

  @type t :: %__MODULE__{}

  @statuses ~w(queued provisioning ready failed destroying destroyed)
  @domain_modes ~w(ours customer)

  schema "installs" do
    field(:slug, :string)
    field(:business_name, :string)
    field(:owner_email, :string)
    field(:region, :string)
    field(:size, :string)
    field(:domain_mode, :string)
    field(:primary_host, :string)
    field(:status, :string, default: "queued")
    field(:steps, {:array, :map}, default: [])
    field(:droplet_id, :integer)
    field(:droplet_ip, :string)
    field(:firewall_id, :string)
    field(:ssh_public_key, :string)
    field(:status_token_hash, :binary)
    field(:handover_sealed, Platform.Vault.EncryptedBinary)
    field(:ready_at, :utc_datetime_usec)
    field(:handover_acknowledged_at, :utc_datetime_usec)
    field(:handover_expired_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Every status an install can be in."
  def statuses, do: @statuses

  @doc false
  def create_changeset(install, attrs) do
    install
    |> cast(attrs, [
      :slug,
      :business_name,
      :owner_email,
      :region,
      :size,
      :domain_mode,
      :primary_host,
      :status,
      :steps,
      :ssh_public_key,
      :status_token_hash,
      :handover_sealed
    ])
    |> validate_required([
      :slug,
      :business_name,
      :owner_email,
      :region,
      :size,
      :domain_mode,
      :primary_host,
      :ssh_public_key,
      :status_token_hash
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:domain_mode, @domain_modes)
    |> unique_constraint(:slug)
    |> unique_constraint(:status_token_hash)
  end

  @doc false
  def update_changeset(install, attrs) do
    install
    |> cast(attrs, [
      :status,
      :steps,
      :droplet_id,
      :droplet_ip,
      :firewall_id,
      :handover_sealed,
      :ready_at,
      :handover_acknowledged_at,
      :handover_expired_at
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
