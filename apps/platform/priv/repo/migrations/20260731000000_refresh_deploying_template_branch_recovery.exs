defmodule Platform.Repo.Migrations.RefreshDeployingTemplateBranchRecovery do
  use Ecto.Migration

  @slug "dispatch.deploying"

  @moduledoc """
  Force-updates the `dispatch.deploying` prompt template so the deploy phase
  names the branch it is deploying and offers the transitional recovery step
  for tasks whose branch predates full-UUID branch names (task 019fb949
  stage 4).

  Why a migration rather than a code change alone: `deploying_prompt/3` tries
  `PromptTemplates.render_template/2` FIRST and only falls back to the
  hardcoded body when the row is absent. `20260326190000_seed_deploying_prompt_template`
  created that row in every migrated environment, so the seeded template — not
  the hardcoded fallback — is what a real deployer reads. Guidance added only
  to the fallback would be dead on arrival.

  The template also gains the `legacy_branch_prefix` variable, which carries
  the task id's first hyphen segment so the recovery step can name the branch
  a pre-change dispatch would have created.

  Force-update pattern (same as `20260715220000_refresh_dispatch_templates_alarm_silence_fallback`):
  re-write the body to the current `default_content_for_slug/1` output and
  re-copy the descriptor's variables. A missing row is skipped —
  `seed_defaults/0` creates it correctly on first boot. A row that already
  matches sees a changeset no-op, so re-running is safe.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :ok

      %PromptTemplate{} = template ->
        content = PromptTemplates.default_content_for_slug(@slug)
        descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
        variables = (descriptor && descriptor.variables) || template.variables

        case PromptTemplates.update_template(template, %{content: content, variables: variables}) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
