defmodule Platform.Repo.Migrations.AddColorToOrgs do
  use Ecto.Migration

  @moduledoc """
  Task 01a09287 stage 1: make an org's colour DATA rather than code.

  Before this migration an org's colour lived in three hardcoded places —
  six hand-authored `.text-<slug>` / `.bg-<slug>` / `.text-<slug>-label`
  blocks in `assets/css/app.css`, `@scope_classes` / `@scope_labels` in
  `Platform.Tenancy`, and `@scope_keys` in `Platform.Tasks`. Standing up a
  tenant therefore required a deploy. These two columns plus
  `Platform.Tenancy.ScopeColor` move the value into the row; later stages
  of this task retire the hardcoding.

  `color_hue` is degrees on the OKLCH hue wheel, `color_chroma` the OKLCH
  chroma. NULL stays legal and means "no colour set" — orgs created before
  this ticket have none, and `Platform.Tenancy.scope_color/1` already falls
  back to `text-muted` for an unknown slug, so an absent colour has a safe
  rendering and must not be forced to a default.

  The CHECK constraint is deliberately a SECOND guard alongside the
  changeset's `validate_number/3`: only the constraint survives a raw
  insert, and only the changeset produces a form error.

  The six shipped orgs are backfilled from the oklch() literals already in
  app.css so nothing regresses: the root org 50/0.16, hooli 95/0.16, globex
  162/0.15, vandelay_ind 240/0.15, initech 295/0.20, wonka 340/0.19.
  """

  # Keyed by the sha256 of each slug, so the tree does not spell an
  # install's org names (root: task 01a14b9e stage 5; tenants: task 01a14dd9
  # stage 3). The comment above each row names it by its placeholder slug.
  @backfill [
    {{:sha256, "9cfdc719f125bfd24830658f109d785ecca57a0c05022add0f6cf4aaec5dc25c"}, 50, 0.16},
    # hooli
    {{:sha256, "d0a708d7a9b0c25273ca7f43937716d81397b5a7052b6ef000267913d62aea2c"}, 95, 0.16},
    # globex
    {{:sha256, "3cf2fb332fb3792a8205afc17b4207c37b0d149891b6eb8b1a7cb9503aaf0f3d"}, 162, 0.15},
    # vandelay_ind
    {{:sha256, "6033c506fee05cd2e9291a63854efcd0357866cb82dd5b6fceac7916f74cfdb3"}, 240, 0.15},
    # vandelay-ind
    {{:sha256, "f80cf60200f6c7c32e92dae3c84a45a76d7cc8468ddb679983582805ac8d4a4b"}, 240, 0.15},
    # initech
    {{:sha256, "1b52d98ac973dc62528babc79163ab13f455755d1b3835992cfec045ff751c0b"}, 295, 0.20},
    # wonka
    {{:sha256, "71ce8a1658507fc4e432cb3621322632972d9256e652b1dee92af6528719216f"}, 340, 0.19}
  ]

  def up do
    alter table(:orgs) do
      add(:color_hue, :integer, null: true)
      add(:color_chroma, :float, null: true, default: 0.16)
    end

    create(
      constraint(:orgs, :orgs_color_hue_range,
        check: "color_hue IS NULL OR (color_hue >= 0 AND color_hue < 360)"
      )
    )

    flush()

    for {slug, hue, chroma} <- @backfill do
      execute("""
      UPDATE orgs
         SET color_hue = #{hue}, color_chroma = #{chroma}
       WHERE #{slug_match(slug)} AND color_hue IS NULL
      """)
    end
  end

  # Every slug is matched by its sha256 digest so the public tree does not
  # spell it (the root by task 01a14b9e stage 5, the tenants by task 01a14dd9
  # stage 3); the predicate is true for exactly the rows the literal
  # `slug = '<slug>'` matched.
  defp slug_match({:sha256, hex}),
    do: "encode(sha256(convert_to(slug, 'UTF8')), 'hex') = '#{hex}'"

  def down do
    drop(constraint(:orgs, :orgs_color_hue_range))

    alter table(:orgs) do
      remove(:color_chroma)
      remove(:color_hue)
    end
  end
end
