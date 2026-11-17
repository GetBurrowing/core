defmodule Platform.Repo.Migrations.AddShowrunnerRole do
  @moduledoc """
  Admit and seed the platform-fixed `showrunner` role, its bundle
  (`showrunner.weekly_pitch`, `showrunner.research_brief`,
  `showrunner.run_sheet`) and their three prompt templates (task
  `01a1eaf6-604e-7000-a018-3163ad6909b1` stage 3). Modelled on
  `20261009060918_add_janitor_role.exs`.

  One file, three steps, in this order:

    1. **Extend `roles_key_check`** to the ELEVEN-key roster: every key valid
       at this version plus `showrunner`. `Platform.Roles.Role` pins
       `@valid_keys` and the CHECK enforces the same roster at the DB layer.
    2. **Seed the role and bundle** with `seed_defaults(only_keys:
       ["showrunner"])`. Scoped so this file never inserts a role a later
       migration is meant to admit. Idempotent (`on_conflict: :nothing`).
       Stage 4 of the same task appends three more bundle keys and seeds them
       in its own migration.
    3. **Seed the three `showrunner.*.v1` templates** from their
       `default_templates/0` descriptors, insert-or-force-update. A missing
       descriptor raises.

  NO ASSIGNMENT IS SEEDED, and no space, project or person: those live in
  each row's `trigger_config` (`Platform.Showrunner.Config`), written by an
  operator. Until an agent is pinned to `showrunner`, every fire returns
  `{:ok, :unfilled}`.

  `down/0` deletes the three template rows and the `showrunner` role (the FK
  cascade clears its bundle and assignment rows), then restores the ten-key
  CHECK.
  """

  use Ecto.Migration

  @slugs [
    "showrunner.weekly_pitch.v1",
    "showrunner.research_brief.v1",
    "showrunner.run_sheet.v1"
  ]

  @roster_with_showrunner "key IN ('designer','historian','meeting_scribe','meeting_producer'," <>
                            "'triage_officer','security_guard','architect','agents_leader'," <>
                            "'scientist','janitor','showrunner')"

  @roster_without_showrunner "key IN ('designer','historian','meeting_scribe','meeting_producer'," <>
                               "'triage_officer','security_guard','architect','agents_leader'," <>
                               "'scientist','janitor')"

  def up do
    drop(constraint(:roles, :roles_key_check))
    create(constraint(:roles, :roles_key_check, check: @roster_with_showrunner))

    # The DDL above must be applied before the seed's INSERT reads the CHECK.
    flush()

    Platform.Roles.Seeds.seed_defaults(only_keys: ["showrunner"])

    Enum.each(@slugs, &seed_prompt_template!/1)
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM prompt_templates WHERE slug = ANY($1)",
      [@slugs]
    )

    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM roles WHERE key = $1",
      ["showrunner"]
    )

    drop(constraint(:roles, :roles_key_check))
    create(constraint(:roles, :roles_key_check, check: @roster_without_showrunner))
  end

  @doc "The template slugs this migration seeds."
  def slugs, do: @slugs

  # Descriptor positions, so the closed-roster ownership scan credits this file:
  #   slug: "showrunner.weekly_pitch.v1"
  #   slug: "showrunner.research_brief.v1"
  #   slug: "showrunner.run_sheet.v1"
  defp seed_prompt_template!(slug) do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

    unless descriptor do
      raise "[AddShowrunnerRole] no default descriptor for slug=#{slug} — " <>
              "did do_default_templates/0 lose the entry?"
    end

    attrs = %{
      slug: slug,
      name: descriptor.name,
      description: descriptor.description,
      content: content,
      variables: descriptor.variables
    }

    case PromptTemplates.get_template_by_slug(slug) do
      nil ->
        case PromptTemplates.create_template(attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end

      %PromptTemplate{} = template ->
        case PromptTemplates.update_template(template, %{
               content: content,
               description: descriptor.description,
               variables: descriptor.variables
             }) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end

    :ok
  end
end
