defmodule Platform.Repo.Migrations.ForceUpdateHistorianThresholdWindowed do
  use Ecto.Migration

  # Task 019f4f55 stage 2 — the `historian.threshold` template is now
  # driven by `Platform.Agents.HistorianDispatcher.dispatch_windowed/4`
  # (one message per corpus window with a bounded `activity_digest`
  # inlined), not the legacy single-shot fire that only substituted
  # `{{workspace_id}}` and `{{pending_tokens}}`. `seed_defaults/0` is
  # INSERT-only, so deployments that already had a `historian.threshold`
  # row from the T6 seed migration would keep serving the pre-windowed
  # copy — this force-update swaps in `default_content_for_slug/1`'s
  # current output which includes the `{{activity_digest}}` placeholder.
  #
  # Skips slugs with no DB row (fresh boots pick them up via
  # `seed_defaults/0`). Mirrors the `force_update_*` migration pattern
  # at 20260520050000, 20260708123000, and neighbouring rows.

  @slug "historian.threshold"

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        content = PromptTemplates.default_content_for_slug(@slug)

        if content do
          {:ok, _} =
            PromptTemplates.update_template(template, %{
              content: content,
              variables: ["workspace_id", "pending_tokens", "activity_digest"],
              name: "Historian 100k-Token Threshold Dispatch Prompt"
            })
        end
    end

    :ok
  end

  def down do
    :ok
  end
end
