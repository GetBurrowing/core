defmodule Platform.Repo.Migrations.SeedAndForceUpdateIntentAttentionTemplate do
  use Ecto.Migration

  @moduledoc """
  Seed **and** force-update the `dispatch.intent_attention` prompt template
  (task 019f70b8 stage 5).

  This migration deliberately does BOTH halves, unlike the two patterns it
  borrows from:

    * `20260707120000_seed_prompt_template_intent_classify.exs` is
      insert-if-missing only. On its own that would leave every environment
      that later needs a body revision serving the first version forever.
    * `20260708123000_force_update_architect_review_plan_template.exs` is
      force-update-with-`:skip`-when-absent only. On its own that would
      no-op on prod (`app.example.com`), which has already run
      the earlier seed migrations and therefore never re-runs
      `PromptTemplates.seed_defaults/0` — the row for this NEW slug would
      simply never exist there.

  Fresh boots take the insert branch here and would also pick the row up
  from `seed_defaults/0`; established deployments take the update branch
  and get the current `default_content_for_slug/1` output plus a refreshed
  `variables` list. Either way the DB ends up byte-identical to the
  hardcoded descriptor, which is the only invariant that matters — the
  runtime renders from the DB row, not from the module.

  `down/0` is `:ok`: this template is additive, and rolling back to a body
  that no longer matches the shipped `intent_ack` contract would be worse
  than leaving it in place.
  """

  @slug "dispatch.intent_attention"

  def up do
    alias Platform.Orchestration.PromptTemplates

    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

    if descriptor do
      case PromptTemplates.get_template_by_slug(@slug) do
        nil ->
          {:ok, _} = PromptTemplates.create_template(descriptor)

        template ->
          {:ok, _} =
            PromptTemplates.update_template(template, %{
              name: descriptor.name,
              description: descriptor.description,
              content: descriptor.content,
              variables: descriptor.variables
            })
      end
    end

    :ok
  end

  def down do
    :ok
  end
end
