defmodule Platform.Repo.Migrations.AddAppColorsToInstallBranding do
  @moduledoc """
  Task `01a0dbee-f598-7001-b450-7890103f44c4`, stage 1 — in-app theme colours
  an admin picks per mode: action, surface and accent for light and for dark,
  plus the preset key the current values started from.

  ## Same row, no new table

  The colours go on the existing `install_branding` singleton. The CHECK
  `install_branding_singleton_true` and the unique index on `singleton` from
  `20260910120000_create_install_branding.exs` stay the ONLY guarantee there
  is one row; a second table would need a second singleton guarantee, and two
  guarantees are two places to get it wrong.

  ## Nullable, no defaults

  NULL means "Suite default" for that slot, which is what every existing
  install must keep meaning after this migration: nothing about today's
  rendering may change until an admin saves a colour. A default here would
  copy today's hex into the row, and the row would then silently disagree
  with `app.css` the next time the design tokens move.

  `color_preset` is the key of the curated preset the values were started
  from (so the admin form can say "Custom (from Nord)"); NULL means none.

  ## Migration hygiene

  No `Platform.Audit.record/1`, no `Phoenix.PubSub` — migrations run before
  the supervision tree is up.
  """

  use Ecto.Migration

  def change do
    alter table(:install_branding) do
      add(:light_action, :string, null: true)
      add(:light_surface, :string, null: true)
      add(:light_accent, :string, null: true)
      add(:dark_action, :string, null: true)
      add(:dark_surface, :string, null: true)
      add(:dark_accent, :string, null: true)
      add(:color_preset, :string, null: true)
    end
  end
end
