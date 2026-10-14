defmodule Platform.Repo.Migrations.RebrandInstallBrandingDefaultsToBurrow do
  @moduledoc """
  Task `01a120c5-9c98-7001-af58-38f6a2c596a6`, stage 3: the default product
  name becomes "Burrow", and the manifest/launch colours follow the new dark
  surface token (`#191b20`, stage 1's dark `--color-base-100`).

  ## Why a data migration and not a constant

  There is no code-level app-name default. `Platform.Branding.app_name/0`
  reads the singleton `install_branding` row, which every install already
  has: `20260910120000_create_install_branding` seeded it with app_name
  'Suite', theme_color '#171b25' and background_color '#171b25'. Changing a
  constant would change nothing on an existing install, so the seeded values
  are rewritten here. The create migration is not edited: a fresh install
  runs it and then this one, and lands on Burrow.

  ## Each column is conditioned only on itself

  Three independent UPDATEs, each guarded by its own column still holding
  the exact seeded value. A column an admin edited is left alone, whatever
  the other columns hold: a row ('Acme', '#123456', '#171b25') becomes
  ('Acme', '#123456', '#191b20'). No other column is written, `updated_at`
  included.

  `down` reverses exact matches only ('Burrow' -> 'Suite', '#191b20' ->
  '#171b25'), column by column.

  The six in-app colour slots (`light_action` .. `dark_accent`) are not
  touched: NULL there already means "the app.css default", and stage 1 moved
  those defaults.

  ## Known, accepted limit

  An admin who deliberately typed exactly "Suite" as the app name (or chose
  exactly '#171b25' for a colour) is indistinguishable from the seed, and
  will be renamed to "Burrow" (or moved to '#191b20'). The row keeps no
  record of which values were typed, and adding one is out of scope for a
  defaults-only rebrand. Likewise `down` cannot tell an admin who typed
  "Burrow" after this ran from the migrated seed, and will rename it back to
  "Suite".

  ## Migration hygiene

  No `Platform.Audit.record/1`, no `Phoenix.PubSub`: migrations run before
  the supervision tree is up. Plain SQL only, so the migration does not
  depend on the current shape of the `InstallBranding` schema.
  """

  use Ecto.Migration

  @old_name "Suite"
  @new_name "Burrow"
  @old_color "#171b25"
  @new_color "#191b20"

  def up do
    rewrite("app_name", @old_name, @new_name)
    rewrite("theme_color", @old_color, @new_color)
    rewrite("background_color", @old_color, @new_color)
  end

  def down do
    rewrite("app_name", @new_name, @old_name)
    rewrite("theme_color", @new_color, @old_color)
    rewrite("background_color", @new_color, @old_color)
  end

  # `column`, `from` and `to` are the compile-time literals above, never
  # input, so building the statement from them is safe.
  defp rewrite(column, from, to) do
    execute("UPDATE install_branding SET #{column} = '#{to}' WHERE #{column} = '#{from}'")
  end
end
