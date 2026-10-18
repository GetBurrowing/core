defmodule Platform.Repo.Migrations.ForceUpdateEvidenceTemplatesForCdp do
  use Ecto.Migration

  @moduledoc """
  Switches the dispatch evidence-capture flow from the macOS node-screenshot
  skill (`openclaw nodes canvas navigate/snapshot --node <mac node>`) to a workstation-local
  headless Chrome via CDP at 127.0.0.1:9222 (driven by the new
  `apps/platform/priv/scripts/cdp_capture.sh` helper).

  The actual capture-step text lives in HeartbeatScheduler's
  `@evidence_workflow_reference` module attribute, which is interpolated into
  the `dispatch.in_progress` and `dispatch.in_review` templates via
  `{{evidence_workflow_reference}}`. So the templates whose persisted DB rows
  need a refresh are exactly those two — `dispatch.review_e2e` carries no
  capture-step text of its own and is unaffected.

  Force-update pattern (NOT `seed_defaults` — that path is insert-only and
  ignores existing rows; see task `019df9cb`).
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
