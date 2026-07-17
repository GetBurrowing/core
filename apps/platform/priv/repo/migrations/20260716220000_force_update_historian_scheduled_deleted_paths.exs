defmodule Platform.Repo.Migrations.ForceUpdateHistorianScheduledDeletedPaths do
  use Ecto.Migration

  # Refresh `historian.scheduled` to pick up the new "Intentionally
  # deleted paths" section (task 019f6381 stage 5). The section injects
  # the recent `Platform.MemoryFeedback` delete corpus so the Historian
  # knows which paths were intentionally removed — treats broken links
  # to them as a signal to clean up the referring page rather than
  # restore the target.
  #
  # `seed_defaults/0` only INSERTs when a slug is missing; deployments
  # that already seeded `historian.scheduled` via the T6 or later force-
  # update migrations need an explicit overwrite here. Follows the
  # established `force_update_*` pattern from 20260520050000 and
  # 20260714000050.
  @slug "historian.scheduled"

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        content = PromptTemplates.default_content_for_slug(@slug)

        if content do
          {:ok, _} = PromptTemplates.update_template(template, %{content: content})
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
