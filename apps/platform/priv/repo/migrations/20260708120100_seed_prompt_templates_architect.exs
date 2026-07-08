defmodule Platform.Repo.Migrations.SeedPromptTemplatesArchitect do
  use Ecto.Migration

  @moduledoc """
  Seed placeholder prompt templates for the Architect role bundle
  (ADR-0044 stage 1, task `019f3da3`).

  Three slugs land here so the closed-roster template-coverage test
  (`Platform.Responsibilities.ClosedRosterTemplateCoverageTest`) can
  resolve each `architecture.*` seed key to a real
  `Platform.Orchestration.PromptTemplate` row:

    * `architecture.review_plan.v1`
    * `architecture.audit_diff.v1`
    * `architecture.cron_sweep.v1`

  Content is intentionally minimal — stages 3-4 of ADR-0044 iterate the
  actual prompt content via the `prompt_template_update` MCP after
  this seed migration lands. The placeholder body just names the
  responsibility and lists the context slots the runtime will materialize
  once the sibling-task-walk and diff-fetch plumbing exist.

  Idempotent — if a slug already exists we leave the row alone (matches
  the `PromptTemplates.seed_defaults/0` behaviour). `down/0` deletes
  only the slugs this migration introduced.
  """

  @templates [
    %{
      slug: "architecture.review_plan.v1",
      name: "Architecture: Plan Review",
      description:
        "Architect reviews a submitted plan for collisions, superseded patterns, and duplicated abstractions.",
      variables: ["plan_payload", "sibling_tasks", "adr_index"],
      content: """
      You are the Architect's `architecture.review_plan` responsibility. A plan was submitted for review; scan it for architectural coherence before the approve gate.
      Input: the plan payload + open sibling tasks in the same project + the ADR index (docs/decisions/*.md).
      Output: a JSON object matching {"comments": [{"category": "collision|superseded|duplication|other", "note": "<one clause>", "refs": ["<task_id or ADR slug>", ...]}, ...]}.
      Only emit comments where a specific ADR, sibling task, or durable memory entry supports the concern. Empty list is a valid answer.
      Placeholder body — stages 3-4 of ADR-0044 will iterate this content via the prompt_template_update MCP.
      """
    },
    %{
      slug: "architecture.audit_diff.v1",
      name: "Architecture: Diff Audit",
      description:
        "Architect compares a shipped stage diff against the stage's planned architecture and org memory patterns.",
      variables: ["stage_diff", "planned_shape", "org_memory_entries"],
      content: """
      You are the Architect's `architecture.audit_diff` responsibility. An executor just shipped a stage; audit the diff against the plan's declared architecture.
      Input: the stage diff + the plan's stage description + relevant ORG_MEMORY entries.
      Output: a JSON object matching {"annotations": [{"category": "divergence|new_dep|migration|memory_violation|other", "note": "<one clause>", "refs": ["<file:line or ADR slug>", ...]}, ...]}.
      Additive signal only — do not gate the reviewer. Empty list is a valid answer.
      Placeholder body — stages 3-4 of ADR-0044 will iterate this content via the prompt_template_update MCP.
      """
    },
    %{
      slug: "architecture.cron_sweep.v1",
      name: "Architecture: Weekly Sweep",
      description:
        "Architect walks open PRs, closed tasks, ADR gaps, and doc drift once per week to file tech-debt follow-ups.",
      variables: ["open_prs", "recent_closed_tasks", "adr_index"],
      content: """
      You are the Architect's `architecture.cron_sweep` responsibility. Once per week you scan for tech-debt patterns that survived the per-task actors.
      Input: open PRs + last 7 days of closed tasks + the ADR index.
      Output: a JSON object matching {"followups": [{"title": "<one clause>", "rationale": "<why this deserves a task>", "refs": ["<task_id, PR#, or ADR slug>", ...]}, ...]}.
      File at most 3 follow-ups per sweep. Empty list is a valid answer.
      Placeholder body — stages 3-4 of ADR-0044 will iterate this content via the prompt_template_update MCP.
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
