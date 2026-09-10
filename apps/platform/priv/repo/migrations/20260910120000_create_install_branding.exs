defmodule Platform.Repo.Migrations.CreateInstallBranding do
  @moduledoc """
  Task `01a0879a-4578-7001-a029-fd126d0cd416`, stage 1 — the singleton row
  holding this install's PWA identity (app name, colours, uploaded icon).

  ## Why a table and not env vars

  The requirement is: upload an icon in the admin panel, refresh, Add to
  Home Screen, see it — with NO redeploy and NO container restart. An
  `Application.get_env` value cannot change without one. The database is the
  only store this deployment treats as durable that a running process can
  write, so the identity lives here.

  ## Singleton enforced by the DATABASE

  `singleton` is a boolean pinned to `true` by a CHECK constraint and
  covered by a unique index. A second row would mean two different
  manifests depending on which one a query ordered first, and that failure
  is silent — so it is refused at the storage layer rather than by
  convention in the context module.

  ## The default row ships with the migration

  Inserting it here means `Platform.Branding.get/0` never has to handle
  "table empty". `source_storage_key` is NULL, which `icon_url/1` reads as
  "no upload yet, use the repo defaults" — so a fresh install behaves
  exactly as it does today until somebody uploads.

  ## Migration hygiene

  No `Platform.Audit.record/1`, no `Phoenix.PubSub` — migrations run before
  the supervision tree is up.
  """

  use Ecto.Migration

  def change do
    create table(:install_branding, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:singleton, :boolean, null: false, default: true)

      add(:app_name, :string, null: false)
      add(:theme_color, :string, null: false)
      add(:background_color, :string, null: false)

      # The ORIGINAL uploaded square image. NULL = no upload yet.
      add(:source_storage_key, :string, null: true)

      # variant name => storage key. Written by stage 2 (derivation).
      add(:derived, :map, null: false, default: %{})

      # Short content-addressed token used as a URL path segment for cache
      # busting. Stage 3 owns its shape and its population.
      add(:version, :string, null: true)

      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:install_branding, :install_branding_singleton_true, check: "singleton"))
    create(unique_index(:install_branding, [:singleton]))

    # `#171b25` is the DARK `base-100` / surface token value. The web app
    # manifest format accepts only a literal hex and cannot be theme-aware,
    # so the literal is unavoidable — but it appears EXACTLY ONCE, here.
    # If that design token moves, update this row (and any install whose
    # admin has not overridden it).
    #
    # This deliberately corrects two shipped defects in the static
    # manifest.json: `background_color: #ffffff` (a white splash flash into
    # a dark-first app on every cold launch) and `theme_color: #000000`
    # (matches neither theme).
    execute(
      """
      INSERT INTO install_branding
        (id, singleton, app_name, theme_color, background_color,
         source_storage_key, derived, version, inserted_at, updated_at)
      VALUES
        (gen_random_uuid(), true, 'Suite', '#171b25', '#171b25',
         NULL, '{}'::jsonb, NULL, now(), now())
      """,
      "DELETE FROM install_branding"
    )
  end
end
