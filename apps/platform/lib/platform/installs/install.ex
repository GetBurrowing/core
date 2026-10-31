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

  @statuses ~w(requested queued provisioning ready failed destroying destroyed)
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
    # Stage 6: the DigitalOcean account key registered for ssh_public_key.
    field(:ssh_key_id, :integer)
    field(:ssh_public_key, :string)
    field(:status_token_hash, :binary)
    field(:handover_sealed, Platform.Installs.Handover.Type)
    field(:ready_at, :utc_datetime_usec)
    field(:handover_acknowledged_at, :utc_datetime_usec)
    field(:handover_expired_at, :utc_datetime_usec)
    # Task 01a18f0c: an install request from the public form (status
    # `requested`), and the one hand-over email it gets at ready.
    field(:requester_name, :string)
    field(:request_note, :string)
    field(:requested_at, :utc_datetime_usec)
    field(:handover_email_claimed_at, :utc_datetime_usec)
    field(:handover_email_delivery_id, Ecto.UUID)
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

  @doc """
  A `requested` row (task 01a18f0c stage 1): no region, size, host, key or
  token yet. One open request per lower(owner_email), enforced by the
  partial unique index `installs_one_open_request_per_email`.
  """
  def request_changeset(install, attrs) do
    install
    |> cast(attrs, [
      :slug,
      :business_name,
      :owner_email,
      :requester_name,
      :request_note,
      :requested_at,
      :status
    ])
    |> validate_required([:slug, :business_name, :owner_email, :requested_at, :status])
    |> validate_inclusion(:status, ["requested"])
    |> unique_constraint(:slug)
    |> unique_constraint(:owner_email, name: :installs_one_open_request_per_email)
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
      :ssh_key_id,
      :handover_sealed,
      :ready_at,
      :handover_acknowledged_at,
      :handover_expired_at,
      :handover_email_claimed_at,
      :handover_email_delivery_id,
      # Provision of a request (`Platform.Installs.provision_request/2`).
      :region,
      :size,
      :domain_mode,
      :primary_host,
      :ssh_public_key,
      :status_token_hash
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:domain_mode, @domain_modes)
    |> unique_constraint(:status_token_hash)
  end
end
