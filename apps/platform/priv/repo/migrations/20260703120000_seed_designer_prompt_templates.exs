defmodule Platform.Repo.Migrations.SeedDesignerPromptTemplates do
  use Ecto.Migration

  @moduledoc """
  Seed the three Designer-bundle prompt templates (task 019f2455 stage 1):

    * `design.critique.v1`
    * `design.spec_writer.v1`
    * `design.brand_check.v1`

  Content is intentionally short + single-responsibility-focused — Rowan
  and Marlowe iterate the wording live via `prompt_template_update` MCP
  after the seed lands. This migration only needs to guarantee the
  slugs resolve so the first dispatch call succeeds.

  Idempotent — if a slug already exists we leave the row alone (this
  matches the `PromptTemplates.seed_defaults/0` behaviour). `down/0`
  deletes only the three slugs this migration introduced.
  """

  @templates [
    %{
      slug: "design.critique.v1",
      name: "Design Critique",
      description: "Vega critiques a canvas or design brief for hierarchy, contrast, and brand.",
      variables: ["canvas_snapshot", "grounding_notes"],
      content: """
      You are Vega, filling the design.critique responsibility for the Designer role.

      Input: a canvas snapshot (title, description, key markdown text, image URLs if any) plus optional grounding notes.
      Output: a JSON object matching {"issues": [{"severity": "high|medium|low", "location": "<canvas node or region>", "issue": "<one sentence>", "suggestion": "<one sentence>"}]}.

      Critique the design for: visual hierarchy, layout balance, contrast/accessibility, brand consistency (if brand context provided), and cross-platform coherence. Be direct; do not pad. Return an empty issues array if the design is already strong.
      """
    },
    %{
      slug: "design.spec_writer.v1",
      name: "Design Spec Writer",
      description: "Vega extracts implementable component specs from a design canvas.",
      variables: ["canvas_snapshot", "grounding_notes"],
      content: """
      You are Vega, filling the design.spec_writer responsibility for the Designer role.

      Input: a canvas or design brief + any grounding notes.
      Output: a JSON object matching {"spec": {"components": [{"name": "<string>", "props": {"<key>": "<string>"}, "notes": "<one sentence>"}], "acceptance_criteria": ["<string>"]}}.

      Extract concrete implementable components from the design. Do not invent components not present in the source. If a section is ambiguous, note it in acceptance_criteria instead of guessing.
      """
    },
    %{
      slug: "design.brand_check.v1",
      name: "Design Brand Check",
      description: "Vega checks a design against the org's brand guidelines.",
      variables: ["canvas_snapshot", "brand_guidelines"],
      content: """
      You are Vega, filling the design.brand_check responsibility for the Designer role.

      Input: a canvas snapshot + the org's brand guidelines file (referenced by file_id in grounding).
      Output: a JSON object matching {"verdict": "on_brand|drift|off_brand", "reasons": ["<string>"], "fixes": ["<string>"]}.

      Check the design against the guidelines. Flag color palette drift, type-scale drift, tone-of-voice mismatch, and layout-pattern violations. If no brand guidelines are provided in context, return {"verdict": "no_brand_context", "reasons": [...], "fixes": []}.
      """
    }
  ]

  def up do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@templates, fn template ->
      case PromptTemplates.get_template_by_slug(template.slug) do
        nil ->
          {:ok, _} = PromptTemplates.create_template(template)

        _existing ->
          :skip
      end
    end)

    :ok
  end

  def down do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@templates, fn %{slug: slug} ->
      case PromptTemplates.get_template_by_slug(slug) do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end
    end)

    :ok
  end
end
