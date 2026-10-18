defmodule Platform.Repo.Migrations.AddColorLightnessToOrgs do
  @moduledoc """
  Task 01a09333-d374 stage 5: adds `orgs.color_lightness` and pins the six
  shipped orgs' colour to the values they shipped with.

  ## Why a third colour column

  Stage 5 moves the six shipped scope orgs off their hand-authored `app.css`
  blocks onto the runtime colour path, which colours an org from its ROW
  (`PlatformWeb.Components.ScopeColorStyles`). Their hue and chroma were
  already stored by `20260911220000_add_color_to_orgs`, but the runtime path
  solves every org at a fixed 72% fill lightness, and five of the six ship
  at another one. Hue and chroma alone would therefore move five fills (the
  dot, the active pill) and every tint derived from them. The fill lightness
  becomes data, beside the hue and chroma, and `ScopeColorStyles` solves
  each org at its own. NULL keeps the 72% default, so every org created
  through the admin panel is unaffected.

  ## The pinned values

  Read from each slug's own `oklch()` literal in the per-slug blocks of
  `app.css` at 98eb79ab, the last commit that carried them:

      (root)      oklch(72% 0.16 50)      paragon    oklch(80% 0.16 95)
      soylent    oklch(65% 0.20 295)     sxi         oklch(70% 0.15 162)
      wayne_tech    oklch(68% 0.15 240)     cyberdyne  oklch(66% 0.19 340)

  `wayne-tech` is listed as well as `wayne_tech` for the same reason the 09-11
  backfill listed both: the seed writes the underscore form, and an install
  set up by hand may hold the hyphen one.

  ## Unconditional, and why

  The write goes over whatever the row holds. Until this stage the six
  rendered from their `app.css` blocks and ignored the row entirely, so any
  hue stored for them was invisible; preserving what users see means
  reproducing the shipped fill, not the stored value. The only path that
  can store a hue is the admin panel's CREATE form (there is no edit path),
  so the one row this can overwrite is an org created there under one of
  these six slugs after the 09-11 backfill: in practice, `cyberdyne`.

  It is a no-op for a slug with no row: it updates, never inserts. Dev and
  test databases seed five of the six and have no `cyberdyne`.

  ## Down

  Drops the column and its constraint. Hue and chroma are left as `up`
  wrote them: they equal the 09-11 backfill's values on every install where
  that backfill ran, and the value `up` may have overwritten on an
  admin-created row is not recoverable. Setting them NULL instead would
  erase that earlier backfill, which is not this migration's to undo.
  """
  use Ecto.Migration

  @shipped [
    {{:sha256, "9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c"}, 50, 0.16, 0.72},
    {"soylent", 295, 0.20, 0.65},
    {"wayne_tech", 240, 0.15, 0.68},
    {"wayne-tech", 240, 0.15, 0.68},
    {"sxi", 162, 0.15, 0.70},
    {"paragon", 95, 0.16, 0.80},
    {"cyberdyne", 340, 0.19, 0.66}
  ]

  @doc """
  `{key, hue, chroma, fill_lightness}` for every row this migration pins,
  where `key` is a slug or, for the root org's historical slug,
  `{:sha256, hex}` (see `pin_colours/2`).
  """
  def shipped, do: @shipped

  def up do
    alter table(:orgs) do
      add(:color_lightness, :float, null: true)
    end

    create(
      constraint(:orgs, :orgs_color_lightness_range,
        check: "color_lightness IS NULL OR (color_lightness > 0 AND color_lightness < 1)"
      )
    )

    flush()

    pin_shipped_colours(repo())
  end

  def down do
    drop(constraint(:orgs, :orgs_color_lightness_range))

    alter table(:orgs) do
      remove(:color_lightness)
    end
  end

  @doc """
  Writes the pinned hue, chroma and fill lightness onto each of the six
  slugs' rows, unconditionally. Returns `%{key => rows updated}`: 1 where
  the row exists, 0 where it does not. Raw SQL through `repo.query!/2`, so
  it runs inside the migration and inside a test sandbox alike.
  """
  def pin_shipped_colours(repo), do: pin_colours(repo, @shipped)

  @doc """
  `pin_shipped_colours/1` over an explicit row list, so a test can drive
  the digest-keyed arm with a slug of its own. A row's key is either a
  slug or `{:sha256, hex}`: the root org's historical slug is matched by
  the sha256 of the slug, so the public tree does not spell it (task
  01a14b9e stage 5), and that predicate is true for exactly the rows the
  literal `slug = <slug>` matched.
  """
  def pin_colours(repo, rows) do
    Map.new(rows, fn {key, hue, chroma, lightness} ->
      %{num_rows: updated} =
        repo.query!(
          """
          UPDATE orgs
             SET color_hue = $1, color_chroma = $2, color_lightness = $3
           WHERE #{match_sql(key)}
          """,
          [hue, chroma, lightness, match_value(key)]
        )

      {key, updated}
    end)
  end

  defp match_sql({:sha256, _hex}), do: "encode(sha256(convert_to(slug, 'UTF8')), 'hex') = $4"
  defp match_sql(slug) when is_binary(slug), do: "slug = $4"

  defp match_value({:sha256, hex}), do: hex
  defp match_value(slug) when is_binary(slug), do: slug
end
