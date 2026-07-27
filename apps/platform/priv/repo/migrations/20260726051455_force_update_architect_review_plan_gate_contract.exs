defmodule Platform.Repo.Migrations.ForceUpdateArchitectReviewPlanGateContract do
  use Ecto.Migration

  # ADR-0046 stack member 5 (task `019f9b28-ef50`) stage 4: the
  # `architecture.review_plan.v1` body opened with "You are **additive,
  # not a blocker** — the architect annotates; it does NOT block plan
  # approval" and closed with "The plan advances to `pending_review`
  # regardless of what you find". Stage 3 landed the guard in
  # `Tasks.approve_plan/3`, so BOTH sentences are now false — and a
  # prompt that tells the architect its verdict does not matter trains it
  # out of using the gate that now holds the plan. The new body carries
  # the gate authority, the four closed `constraint` values, the
  # not-for-style rule WITH its reason, the fast-pass default, the
  # `plan_architecture_verdict` output shape and the deadline.
  #
  # `seed_defaults/0` is INSERT-only, and this row is already claimed on
  # every deployed environment — twice over, by
  # `20260708123000_force_update_architect_review_plan_template.exs` and
  # `20260726210000_force_update_architect_review_plan_citation_guidance.exs`.
  # Editing `do_default_templates/0` alone would move the FALLBACK body
  # (which only renders when the DB row is missing) while every deployed
  # environment kept serving a prompt that says the gate does not exist.
  # Same force-update shape as those two, for the same reason.
  #
  # `description` moves with `content` on purpose: it is what an operator
  # reads in the prompt-template list before deciding whether to edit the
  # row, and the old one described an additive annotator.
  #
  # Skips slugs with no DB row (fresh boots pick them up via
  # `seed_defaults/0`).
  #
  # ## Why this timestamp sorts BEFORE member 3's, and why that is safe
  #
  # `20260726051455` is the slot the stack coordinator reserved for this
  # stage (it pairs with `20260726051454`, this member's stage-1 schema
  # migration). It therefore runs BEFORE
  # `20260726210000_..._citation_guidance.exs` on a fresh database, and
  # AFTER it on every already-migrated environment — Ecto applies any
  # version absent from `schema_migrations`, regardless of whether a
  # higher one has already run.
  #
  # Both orderings converge, because both migrations write
  # `PromptTemplates.default_content_for_slug/1` rather than a literal
  # body: whichever runs last writes the same current default. That is
  # the property that makes the reserved slot safe here, and it is the
  # reason a force-update migration must never inline the prompt text.
  #
  # Consequently this migration is REDUNDANT on a fresh boot (member 3's
  # would have written the same body a moment later) and LOAD-BEARING on
  # a deployed environment, where `20260726210000` has already run and
  # this is the only pending version that touches the row.

  @slug "architecture.review_plan.v1"

  def up do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        :skip

      template ->
        case default_descriptor() do
          nil ->
            :skip

          %{content: content} = descriptor ->
            {:ok, _} =
              PromptTemplates.update_template(template, %{
                content: content,
                description: Map.get(descriptor, :description, template.description)
              })
        end
    end

    :ok
  end

  def down do
    :ok
  end

  defp default_descriptor do
    alias Platform.Orchestration.PromptTemplates

    Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
  end
end
