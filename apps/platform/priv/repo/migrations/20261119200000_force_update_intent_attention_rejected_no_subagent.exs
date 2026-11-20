defmodule Platform.Repo.Migrations.ForceUpdateIntentAttentionRejectedNoSubagent do
  use Ecto.Migration

  @moduledoc """
  Refresh the `dispatch.intent_attention` prompt template so it says a
  `rejected` ack takes no `subagent_id`, while `working`, `completed` and
  `cancel_honored` still require the real spawned id.

  The previous body told the recipient "Empty or missing subagent_id will
  fail validation" unconditionally, and its own deliverable step 2 ("You do
  not need a subagent to decline") contradicted it. The tool now accepts a
  `rejected` ack with no id and records it as null, so the prompt has to say
  the same thing, with the literal call.

  Editing `PromptTemplates.default_templates/0` is not the deliverable on
  its own. `seed_defaults/0` is INSERT-only, and this slug was already
  force-updated by `20260725120000` and `20260731210000`, so the runtime,
  which renders from the DB row, only sees the new body through a
  force-update like this one.

  Before authoring this, the live row was read on both installs. Both carried
  the `20260731210000` body, except for one example runtime slug that a later
  code-side identifier scrub changed in the module without a force-update;
  neither carried a hand edit the branch lacks.

  Insert-when-absent is kept for a fresh boot that has not run
  `seed_defaults/0` yet. `down/0` is `:ok`: rolling back to a body that says
  every ack needs a subagent_id would contradict the tool's behaviour.

  Admitted by task 01a1f53c-1825 stage 2 (intent_ack: don't require
  subagent_id for status rejected).
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
