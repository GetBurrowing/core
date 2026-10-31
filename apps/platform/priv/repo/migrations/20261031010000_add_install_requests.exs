defmodule Platform.Repo.Migrations.AddInstallRequests do
  @moduledoc """
  Install requests (task 01a18f0c-441d-7000-a8ca-f1a29e96bd37, stage 1): a
  request from the getburrow.ing form IS an `installs` row with status
  `requested`. There is no second store.

    * `requester_name`, `request_note`, `requested_at`: what the requester
      typed, and when. `requested_at` stays set after Provision, so an
      install that came from a request is recognisable for good.
    * `handover_email_claimed_at`, `handover_email_delivery_id`: the
      one-email CAS column and the delivery it produced (stage 4).
    * A requested row has no region, size, host, key or token yet, so those
      lose NOT NULL; `installs_provisioned_fields_check` keeps them required
      for every other status.
    * `installs_one_open_request_per_email`: one `requested` row per
      lower(owner_email), enforced by the database.
    * `install_request_settings`: the spend-gate singleton (mirrors
      `install_prototype_settings`). `auto_provision_requests` defaults OFF,
      so a request never buys a server without an operator click.
  """
  use Ecto.Migration

  @provision_fields ~w(region size domain_mode primary_host ssh_public_key status_token_hash)a

  def change do
    alter table(:installs) do
      add(:requester_name, :string)
      add(:request_note, :text)
      add(:requested_at, :utc_datetime_usec)
      add(:handover_email_claimed_at, :utc_datetime_usec)
      add(:handover_email_delivery_id, :uuid)
    end

    for field <- @provision_fields do
      execute(
        "ALTER TABLE installs ALTER COLUMN #{field} DROP NOT NULL",
        "ALTER TABLE installs ALTER COLUMN #{field} SET NOT NULL"
      )
    end

    drop(
      constraint(:installs, :installs_status_check,
        check:
          "status IN ('queued', 'provisioning', 'ready', 'failed', 'destroying', 'destroyed')"
      )
    )

    create(
      constraint(:installs, :installs_status_check,
        check:
          "status IN ('requested', 'queued', 'provisioning', 'ready', 'failed', 'destroying', 'destroyed')"
      )
    )

    create(
      constraint(:installs, :installs_provisioned_fields_check,
        check:
          "status = 'requested' OR (region IS NOT NULL AND size IS NOT NULL AND " <>
            "domain_mode IS NOT NULL AND primary_host IS NOT NULL AND " <>
            "ssh_public_key IS NOT NULL AND status_token_hash IS NOT NULL)"
      )
    )

    create(
      unique_index(:installs, ["lower(owner_email)"],
        where: "status = 'requested'",
        name: :installs_one_open_request_per_email
      )
    )

    create table(:install_request_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:singleton, :boolean, null: false, default: true)
      add(:auto_provision_requests, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:install_request_settings, :install_request_settings_singleton_true,
        check: "singleton"
      )
    )

    create(unique_index(:install_request_settings, [:singleton]))

    execute(
      """
      INSERT INTO install_request_settings
        (id, singleton, auto_provision_requests, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), true, false, now(), now())
      """,
      "DELETE FROM install_request_settings"
    )
  end
end
