defmodule Platform.Repo.Migrations.SeedHrProfileTemplateAndBundle do
  @moduledoc """
  Seed the `hr.profile.v1` prompt template and add the two `hr.*` keys to the
  `historian` role's bundle (task `01a1aa47-837b-7000-ba1b-83ab03ec3265`
  stage 4).

  Two steps, in this order:

    1. **Seed `hr.profile.v1`** from its `default_templates/0` descriptor,
       insert-or-force-update, exactly as step 3 of
       `20261009060918_add_janitor_role.exs` does: `PromptTemplates.seed_defaults/0`
       is INSERT-only and never called at boot, so a descriptor alone reaches
       no already-migrated install. A missing descriptor raises.
    2. **Seed the bundle rows** with `seed_defaults(only_keys: ["historian"])`.
       Ecto runs each version once, so adding `hr.daily_sweep` and
       `hr.meeting_completed` to `Platform.Roles.Seeds.default_roles/0` alone
       never reaches an existing database. NO new role: the roster is CLOSED
       by the `roles_key_check` CHECK and this file does not touch it.
       Idempotent: both inserts use `on_conflict: :nothing`.

  NO ASSIGNMENT IS SEEDED. Whoever holds `historian` holds HR.

  `down/0` deletes the template row and the two `role_responsibilities` rows,
  leaving the role and the rest of its bundle as they were.
  """

  use Ecto.Migration

  @slug "hr.profile.v1"
  @role "historian"
  @keys ["hr.daily_sweep", "hr.meeting_completed"]

  def up do
    seed_prompt_template!()
    Platform.Roles.Seeds.seed_defaults(only_keys: [@role])
    :ok
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM prompt_templates WHERE slug = $1",
      [@slug]
    )

    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = ANY($2)",
      [@role, @keys]
    )

    :ok
  end

  @doc "The one slug this migration seeds."
  def slugs, do: [@slug]

  @doc "The bundle rows this migration adds."
  def bundle_keys, do: @keys

  defp seed_prompt_template! do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(@slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    unless descriptor do
      raise "[SeedHrProfileTemplateAndBundle] no default descriptor for slug=#{@slug} — " <>
              "did do_default_templates/0 lose the entry?"
    end

    attrs = %{
      slug: @slug,
      name: descriptor.name,
      description: descriptor.description,
      content: content,
      variables: descriptor.variables
    }

    case PromptTemplates.get_template_by_slug(@slug) do
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
