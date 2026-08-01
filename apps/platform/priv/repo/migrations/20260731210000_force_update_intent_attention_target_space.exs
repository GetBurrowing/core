defmodule Platform.Repo.Migrations.ForceUpdateIntentAttentionTargetSpace do
  use Ecto.Migration

  @moduledoc """
  Refresh the `dispatch.intent_attention` prompt template so it names
  `target_space_id` — the meeting chat space a dispatched intent now writes its
  result into.

  Editing `PromptTemplates.default_templates/0` is NOT the deliverable on its
  own. `seed_defaults/0` is INSERT-only, and
  `20260725120000_seed_and_force_update_intent_attention_template.exs` already
  claimed this slug on every migrated environment, so the row is only reached
  by a force-update like this one. The runtime renders from the DB row, not
  from the module: without this migration the receiving agent would keep being
  handed a prompt that never mentions the space it was just invited into,
  while every test in the suite read the module and stayed green.

  Insert-when-absent is kept for the same reason the earlier migration kept it:
  a fresh boot that has not run `seed_defaults/0` yet has no row to update.

  `down/0` is `:ok`. Rolling the body back to one that omits `target_space_id`
  would leave the wire payload and the prompt disagreeing about where results
  go, which is worse than leaving the newer copy in place.

  Admitted by task 019fb90f stage 4, PR #648 — invite a dispatched agent
  into the space it was dispatched to.
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
