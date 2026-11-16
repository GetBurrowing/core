defmodule Platform.Repo.Migrations.AddVersionToSocialPosts do
  @moduledoc """
  Social Studio slice A: `social_posts.version`, the content version an
  approval names. Starts at 1; `version >= 1` is a CHECK. Legacy rows keep
  1 and nothing legacy reads or bumps it.

  `state_rev` (0 and up, CHECK) is the optimistic counter every Studio
  transition increments in its own transaction. Never cast.

  Ships with Social as a build-time module's migration (ADR 0055).
  """

  use Ecto.Migration

  # old-code-compatible: additive: version (default 1) and state_rev (default 0) are NOT NULL with
  # defaults, and their CHECKs hold for every default; the previous release never
  # reads or writes either column.
  # Safe for the previous release only while no Studio rows exist; once they do,
  # rollback is barred by listing 20261114100000 in
  # deployment/release/irreversible-migrations.txt (the updater refuses to roll
  # back from the release that crossed it, once the crossing run completes; an
  # interrupted crossing run is not covered). This waiver depends on that listing.

  # version, plus state_rev (the optimistic counter).

  def up do
    alter table(:social_posts) do
      add(:version, :integer, null: false, default: 1)
      add(:state_rev, :integer, null: false, default: 0)
    end

    create(constraint(:social_posts, :social_posts_state_rev_check, check: "state_rev >= 0"))

    create(constraint(:social_posts, :social_posts_version_check, check: "version >= 1"))
  end

  def down do
    drop(constraint(:social_posts, :social_posts_state_rev_check))

    drop(constraint(:social_posts, :social_posts_version_check))

    alter table(:social_posts) do
      remove(:state_rev)
      remove(:version)
    end
  end
end
