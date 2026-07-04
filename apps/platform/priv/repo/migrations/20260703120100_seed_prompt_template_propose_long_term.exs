defmodule Platform.Repo.Migrations.SeedPromptTemplateProposeLongTerm do
  use Ecto.Migration

  @moduledoc """
  Seed the Historian bundle `memory.propose_long_term.v1` prompt
  template (task 019f2455 stage 2).

  Idempotent — if the slug already exists we leave the row alone (this
  matches the `PromptTemplates.seed_defaults/0` behaviour). `down/0`
  deletes only the single slug this migration introduced.
  """

  @templates [
    %{
      slug: "memory.propose_long_term.v1",
      name: "Memory: Propose Long-Term Entries",
      description:
        "Historian sweeps the last week of org journal for entries worth promoting into long-term org memory.",
      variables: ["recent_journal", "org_identity"],
      content: """
      You are the Historian's `memory.propose_long_term` responsibility. Once a week you sweep the org journal for observations worth promoting into long-term org pages.
      Input: last 7 days of org journal + org identity, both in your context.
      Output: a JSON object matching {"proposals": ["<one candidate long-term entry>", ...]}.
      List 3–8 concise proposals, each self-contained. The Historian's next dreaming pass decides which land in `org/page/memory.md`.
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
