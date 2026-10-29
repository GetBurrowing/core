defmodule Platform.Repo.Migrations.SeedSocialWeeklyNotePrompt do
  @moduledoc "Insert-only weekly-note prompt seed (task 01a16c52); preserve human edits."

  use Ecto.Migration

  def up do
    now = DateTime.utc_now()

    for t <- Platform.Social.WeeklyNotePrompts.defaults() do
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
    slugs = Enum.map(Platform.Social.WeeklyNotePrompts.defaults(), & &1.slug)
    repo().query!("DELETE FROM prompt_templates WHERE slug = ANY($1)", [slugs])
  end
end
