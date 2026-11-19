defmodule Platform.Repo.Migrations.SeedMailTriageDraftPrompt do
  @slug "mail.triage.draft.v1"

  @moduledoc """
  Seeds the `mail.triage.draft.v1` prompt template (the system prompt of
  the tool-less draft-reply / fulfilment-plan generator,
  `Platform.Mail.Triage.Drafter`). Task
  `01a1f426-a361-7000-84c7-56ea730b5e6b` stage 4.

  The template tells the model that every wrapped block is DATA, never
  instructions, and fixes the closed JSON output the drafter parses: a
  `reply` (`subject`, `body`) or a `plan` (`summary`, up to 8 `steps`).

  ## Insert-only, never a force-update

  The same shape as `20261119150100_seed_mail_triage_classify_prompt.exs`:
  `PromptTemplates.seed_defaults/0` never re-runs on an already-migrated
  install, so this migration is the half that reaches a live one. The slug
  is new. If a row with it already exists (an operator created it by hand
  first), it is left exactly as it is: nothing is compared and nothing is
  overwritten. Body and variables come from the `default_templates/0`
  descriptor, and a missing descriptor raises rather than writing nothing.

  No responsibility bundle changes: the drafter runs as the `mail.triage`
  assignee that stage 1 already bundled.

  ## `down/0`

  A no-op. The template row is kept, as in
  `20260924190000_seed_experiments_labeler_prompt.exs`: dropping it on
  rollback would leave the drafter rendering from the in-code default
  only, which hides the rollback rather than undoing it.
  """
  use Ecto.Migration

  def up do
    seed_prompt_template!()
    :ok
  end

  def down, do: :ok

  @doc "The one slug this migration seeds."
  def slugs, do: [@slug]

  # Descriptor position, so an ownership scan credits this file:
  #   slug: "mail.triage.draft.v1"
  defp seed_prompt_template! do
    alias Platform.Orchestration.PromptTemplates

    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    unless descriptor do
      raise "[SeedMailTriageDraftPrompt] no default descriptor for slug=#{@slug} — " <>
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
