defmodule Platform.Repo.Migrations.ScrubRockNodeFromEvidenceTemplates do
  use Ecto.Migration

  @moduledoc """
  Removes the `openclaw nodes canvas snapshot --node Rock` fallback mention
  from the dispatch evidence-capture step.

  The rock-node-screenshot skill (a macOS WKWebView fallback) has been
  deleted; mentioning it in the dispatch templates was priming agents to
  reach for it instead of the canonical hive-local CDP path. This refreshes
  the persisted templates so the rock-node sentence no longer ships to
  dispatched agents.

  The capture-step text lives in HeartbeatScheduler's
  `@evidence_workflow_reference` module attribute, interpolated into
  `dispatch.in_progress` and `dispatch.in_review` via
  `{{evidence_workflow_reference}}`. Those are the two persisted rows that
  need a refresh.

  Force-update pattern (NOT `seed_defaults` — that path is insert-only and
  ignores existing rows).
  """

  @slugs ["dispatch.in_progress", "dispatch.in_review"]

  def up do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@slugs, fn slug ->
      case PromptTemplates.get_template_by_slug(slug) do
        nil ->
          :skip

        template ->
          content = PromptTemplates.default_content_for_slug(slug)

          if content do
            {:ok, _} = PromptTemplates.update_template(template, %{content: content})
          end
      end
    end)

    :ok
  end

  def down do
    :ok
  end
end
