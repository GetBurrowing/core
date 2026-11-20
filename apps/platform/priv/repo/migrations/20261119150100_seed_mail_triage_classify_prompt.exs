defmodule Platform.Repo.Migrations.SeedMailTriageClassifyPrompt do
  @slug "mail.triage.classify.v1"

  @moduledoc """
  Seeds the `mail.triage.classify.v1` prompt template (the system prompt of
  the tool-less mail triage classifier, `Platform.Mail.Triage.Classifier`)
  and adds `mail.triage` to the `relationship_steward` role's bundle. Task
  `01a1f426-a361-7000-84c7-56ea730b5e6b` stage 1.

  ## The bundle row

  `seed_defaults(only_keys: ["relationship_steward"])`, as
  `20261105070000_seed_hr_profile_template_and_bundle.exs` does for the
  historian: Ecto runs each version once, so adding the key to
  `Platform.Roles.Seeds.default_roles/0` alone never reaches an existing
  database. No new role, no assignment: whoever holds the steward role (or a
  `mail.triage` responsibility override) is the triage agent. Idempotent
  (`on_conflict: :nothing`).

  The template tells the model that the wrapped email is DATA TO CLASSIFY,
  never instructions, and fixes the closed JSON output shape the classifier
  parses (`tier`, `needs`, `why`, `next_step`).

  ## Insert-only, never a force-update

  `PromptTemplates.seed_defaults/0` is INSERT-only and never re-runs on an
  already-migrated install, so the descriptor in `do_default_templates/0`
  alone would reach fresh databases only; this migration is the half that
  reaches a live install. The slug is new, so there is no live row to
  compare against. If a row with this slug already exists (an operator
  created it by hand before this ran), it is left exactly as it is: this
  migration compares nothing and must not overwrite a human edit blind.

  Body and variables come from the matching `default_templates/0`
  descriptor so the row and its source cannot drift. A missing descriptor
  raises rather than silently writing nothing.

  ## `down/0`

  Deletes the bundle row only. The template row is kept, as in
  `20260924190000_seed_experiments_labeler_prompt.exs`: dropping it on
  rollback would leave the classifier rendering from the in-code default
  only, which hides the rollback rather than undoing it.
  """
  use Ecto.Migration

  # old-code-compatible: inserts a new prompt template slug and a bundle key; the previous release ignores both.

  @role "relationship_steward"
  @key "mail.triage"

  def up do
    seed_prompt_template!()
    Platform.Roles.Seeds.seed_defaults(only_keys: [@role])
    :ok
  end

  def down do
    Ecto.Adapters.SQL.query!(
      Platform.Repo,
      "DELETE FROM role_responsibilities WHERE role_key = $1 AND responsibility_key = $2",
      [@role, @key]
    )

    :ok
  end

  @doc "The one slug this migration seeds."
  def slugs, do: [@slug]

  # Descriptor position, so the closed-roster ownership scan credits this file:
  #   slug: "mail.triage.classify.v1"
  defp seed_prompt_template! do
    alias Platform.Orchestration.PromptTemplates

    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    unless descriptor do
      raise "[SeedMailTriageClassifyPrompt] no default descriptor for slug=#{@slug} — " <>
              "did do_default_templates/0 lose the entry?"
    end

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        attrs = %{
          slug: @slug,
          name: descriptor.name,
          description: descriptor.description,
          content: PromptTemplates.default_content_for_slug(@slug),
          variables: descriptor.variables
        }

        case PromptTemplates.create_template(attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end

      _existing ->
        :ok
    end
  end
end
