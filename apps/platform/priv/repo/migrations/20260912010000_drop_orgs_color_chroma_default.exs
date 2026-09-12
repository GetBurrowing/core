defmodule Platform.Repo.Migrations.DropOrgsColorChromaDefault do
  @moduledoc """
  Removes the `orgs.color_chroma` column default.

  Task 01a09287 stage 5. `20260911220000_add_color_to_orgs.exs` declared
  `add(:color_chroma, :float, null: true, default: 0.16)` — a FOURTH place
  naming a default chroma, and the only one the database consulted. The other
  three (`Platform.Tenancy`, `PlatformWeb.Components.ScopeColorStyles`,
  `PlatformWeb.AdminOrgsLive`) all said 0.15. So the admin colour picker
  previewed a colour at 0.15, the row stored 0.16, and the rail painted
  0.16 — against that module's own stated contract that "the numbers an
  operator reads off this panel are the numbers the server will store and
  the rail will paint". Verified on the `hueless_co` row created through the
  panel.

  The three Elixir readers now all resolve
  `Platform.Tenancy.ScopeColor.default_chroma/0`, and `AdminOrgsLive`
  writes `color_chroma` explicitly on create, so the column default has no
  remaining job except to disagree.

  NOT a data migration: the six backfilled orgs carry their own per-org
  chroma (0.15-0.20) and are untouched. Any row written between the two
  migrations holds a literal 0.16, which is left alone rather than rewritten
  — a stored value an operator's pick produced is not this migration's to
  reinterpret, and 0.16 is a legal chroma.
  """
  use Ecto.Migration

  def up do
    alter table(:orgs) do
      modify(:color_chroma, :float, default: nil)
    end
  end

  def down do
    alter table(:orgs) do
      modify(:color_chroma, :float, default: 0.16)
    end
  end
end
