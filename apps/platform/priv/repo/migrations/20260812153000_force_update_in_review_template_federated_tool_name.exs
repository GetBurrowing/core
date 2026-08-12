defmodule Platform.Repo.Migrations.ForceUpdateInReviewTemplateFederatedToolName do
  use Ecto.Migration

  @moduledoc """
  Force-updates the `dispatch.in_review` prompt template so the design-review
  step names the tool in the SAME form as every other tool in the same body
  (task 019fed8d stage 1).

  `20260809220000_force_update_in_review_template_design_critique_tool.exs`
  pointed the paragraph at a real mechanism, but wrote the bare surface name
  `design_critique_request` while the surrounding paragraphs write
  `suite_review_request_create`, `suite_task_get`, `suite_plan_get` and
  `suite_validation_list`. A federated runtime looks its tools up under the
  `suite_` namespace its client applies, so the bare form resolves to nothing
  and the reviewer reports the tool absent. That is what three runtimes
  reported, and what the pairing test added in this stage now prevents.

  THIS MIGRATION IS THE DELIVERABLE, not the descriptor edit in
  `do_default_templates/0`. `render_template/2` prefers the DB row and
  `seed_defaults/0` is INSERT-only, so every environment that has ever booted
  still holds the bare-name paragraph. Same force-update shape as
  20260809220000: look up by slug, `:skip` when absent, otherwise rewrite
  `content` and `variables` from the shipped descriptor so the row cannot
  drift from it. `down/0` is `:ok` — restoring a tool name no runtime can
  resolve is not a state worth returning to.

  ## Why this is not scoped to `dispatch.in_review` alone

  The pairing test added with this stage found a second bare name that the
  in_review body inherits rather than owns: the shared ack preamble
  (`PromptTemplates.task_ack_preamble/0`) writes `task_ack` and
  `alarm_silence` unprefixed, and that block is interpolated into EVERY
  stage-scoped dispatch template. Fixing it in one slug and leaving the
  others holding the old text would reintroduce the same divergence one
  template over. So the slug set is DERIVED at migration time — every shipped
  default whose content carries the ack preamble's marker, plus
  `dispatch.in_review` itself — rather than typed. A literal slug list is the
  thing that goes stale when a template is added.

  NOT a bundle grant: every runtime the dispatcher can address for a
  review-phase `manual_approval` dispatch already carries the `review`
  bundle, so no `allowed_bundles` migration ships here.
  """
  def up do
    alias Platform.Orchestration.{PromptTemplate, PromptTemplates}

    PromptTemplates.default_templates()
    |> Enum.filter(fn descriptor ->
      descriptor.slug == "dispatch.in_review" or
        String.contains?(descriptor.content || "", "suite_task_ack(task_id=")
    end)
    |> Enum.each(&force_update(&1, PromptTemplate, PromptTemplates))

    :ok
  end

  defp force_update(descriptor, template_mod, templates_mod) do
    case templates_mod.get_template_by_slug(descriptor.slug) do
      nil ->
        :skip

      template ->
        true = match?(%^template_mod{}, template)

        attrs = %{
          content: templates_mod.default_content_for_slug(descriptor.slug),
          variables: descriptor.variables || template.variables
        }

        case templates_mod.update_template(template, attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
        end
    end
  end

  def down do
    :ok
  end
end
