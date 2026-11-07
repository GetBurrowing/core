defmodule Platform.Repo.Migrations.SeedUxFrictionWatchTemplateAndBundle do
  @moduledoc """
  Seed the `ux.friction_watch.v1` prompt template and add `ux.friction_watch`
  to the `designer` role's bundle (task `01a1af00-86ac-7000-94ba-a121d5cb8116`
  stage 2). Modelled on `20261105070000_seed_hr_profile_template_and_bundle.exs`.

  Two steps, in this order:

    1. **Seed `ux.friction_watch.v1`** from its `default_templates/0`
       descriptor, insert-or-force-update: `PromptTemplates.seed_defaults/0`
       is INSERT-only and never called at boot, so a descriptor alone reaches
       no already-migrated install. A missing descriptor raises.
    2. **Seed the bundle row** with `seed_defaults(only_keys: ["designer"])`.
       Ecto runs each version once, so adding the key to
       `Platform.Roles.Seeds.default_roles/0` alone never reaches an existing
       database. NO new role: the roster is CLOSED by the `roles_key_check`
       CHECK and this file does not touch it. Idempotent (`on_conflict:
       :nothing`).

  NO ASSIGNMENT IS SEEDED. Whoever holds `designer` holds the friction watch.

  `down/0` deletes the template row and the one `role_responsibilities` row,
  leaving the role and the rest of its bundle as they were.
  """

  use Ecto.Migration

  @slug "ux.friction_watch.v1"
  @role "designer"
  @keys ["ux.friction_watch"]

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
      raise "[SeedUxFrictionWatchTemplateAndBundle] no default descriptor for slug=#{@slug} — " <>
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
