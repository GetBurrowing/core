defmodule Platform.Repo.Migrations.SeedSocialComposerPrompts do
  @moduledoc """
  Composer 1/5 (task 01a14aca), carried onto main by Social authoring 6/11
  (task 01a16c50): seeds the composer's five prompt templates
  (`social.composer.adapt.<platform>.v1` for linkedin, x, instagram,
  youtube and tiktok) from
  `Platform.Social.Composer.Prompts.defaults/0`, so they are editable in
  Admin > Prompts and an experiment arm can point at a copy.

  Idempotent: `ON CONFLICT (slug) DO NOTHING`, so an operator's edit to a
  row is never overwritten. `down/0` deletes only these slugs.
  """

  use Ecto.Migration

  def up do
    now = DateTime.utc_now()

    for t <- Platform.Social.Composer.Prompts.defaults() do
      repo().query!(
        """
        INSERT INTO prompt_templates
          (id, slug, name, description, content, variables, updated_by, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, 'migration', $7, $7)
        ON CONFLICT (slug) DO NOTHING
        """,
        [
          Ecto.UUID.dump!(Platform.Types.UUIDv7.generate()),
          t.slug,
          t.name,
          t.description,
          t.content,
          t.variables,
          now
        ]
      )
    end
  end

  def down do
    slugs = Enum.map(Platform.Social.Composer.Prompts.defaults(), & &1.slug)
    repo().query!("DELETE FROM prompt_templates WHERE slug = ANY($1)", [slugs])
  end
end
