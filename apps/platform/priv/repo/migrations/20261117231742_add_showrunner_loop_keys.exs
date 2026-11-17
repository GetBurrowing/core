defmodule Platform.Repo.Migrations.AddShowrunnerLoopKeys do
  @moduledoc """
  Append the second half of the How to Computer weekly loop to the
  `showrunner` bundle (`showrunner.recording_prep`, `showrunner.post_show`,
  `showrunner.retro`) and seed their three prompt templates (task
  `01a1eaf6-604e-7000-a018-3163ad6909b1` stage 4). The role and its first
  three keys came from `20261117214509_add_showrunner_role.exs`.

  No CHECK change: the roster is unchanged (still eleven roles). The bundle
  rows go in through `seed_defaults(only_keys: ["showrunner"])`, which is
  `on_conflict: :nothing` per row, so the three existing rows are untouched
  and only the new three are inserted.

  NO ASSIGNMENT, space, project or person is seeded: those are written at
  run time by `mix platform.showrunner.provision`.

  `down/0` deletes the three bundle rows and the three template rows.
  """

  use Ecto.Migration

  @keys ["showrunner.recording_prep", "showrunner.post_show", "showrunner.retro"]

  @slugs [
    "showrunner.recording_prep.v1",
    "showrunner.post_show.v1",
    "showrunner.retro.v1"
  ]

  def up do
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
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = ANY($2)",
      ["showrunner", @keys]
    )
  end

  @doc "The template slugs this migration seeds."
  def slugs, do: @slugs

  @doc "The bundle keys this migration appends."
  def keys, do: @keys

  # Descriptor positions, so the closed-roster ownership scan credits this file:
  #   slug: "showrunner.recording_prep.v1"
  #   slug: "showrunner.post_show.v1"
  #   slug: "showrunner.retro.v1"
  defp seed_prompt_template!(slug) do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    content = PromptTemplates.default_content_for_slug(slug)
    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))

    unless descriptor do
      raise "[AddShowrunnerLoopKeys] no default descriptor for slug=#{slug} — " <>
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
