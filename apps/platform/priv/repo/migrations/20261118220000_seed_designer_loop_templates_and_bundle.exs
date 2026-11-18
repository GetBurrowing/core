defmodule Platform.Repo.Migrations.SeedDesignerLoopTemplatesAndBundle do
  @moduledoc """
  Seed the three UX super agent loop templates (`design.reflect.v1`,
  `design.scout.v1`, `design.prototype_eval.v1`) and add their keys to the
  `designer` role's bundle (task 01a1f048). Modelled on
  `20261107184211_seed_ux_friction_watch_template_and_bundle.exs`.

  The templates are reference rows: each handler owns `build_prompt/1`. They
  exist so every closed-roster key names a seeded template.

  The bundle rows come from `seed_defaults(only_keys: ["designer"])`
  (idempotent, `on_conflict: :nothing`). NO ASSIGNMENT IS SEEDED: whoever
  holds `designer` holds the loop.
  """

  use Ecto.Migration

  @slugs ["design.reflect.v1", "design.scout.v1", "design.prototype_eval.v1"]
  @role "designer"
  @keys ["design.reflect", "design.scout", "design.prototype_eval"]

  def up do
    Enum.each(@slugs, &seed_prompt_template!/1)
    Platform.Roles.Seeds.seed_defaults(only_keys: [@role])
    :ok
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM prompt_templates WHERE slug = ANY($1)",
      [@slugs]
    )

    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = ANY($2)",
      [@role, @keys]
    )

    :ok
  end

  @doc "The slugs this migration seeds."
  def slugs, do: @slugs

  @doc "The bundle rows this migration adds."
  def bundle_keys, do: @keys

  defp seed_prompt_template!(slug) do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

    unless descriptor do
      raise "[SeedDesignerLoopTemplatesAndBundle] no default descriptor for slug=#{slug}"
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
        case PromptTemplates.update_template(template, Map.delete(attrs, :slug)) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end

    :ok
  end
end
