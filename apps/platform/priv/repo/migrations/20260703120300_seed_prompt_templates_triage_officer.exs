defmodule Platform.Repo.Migrations.SeedPromptTemplatesTriageOfficer do
  use Ecto.Migration

  @moduledoc """
  Seed the Triage Officer bundle prompt templates for the three new
  responsibilities added in task 019f2455 stage 4:

    * `tasks.triage.v1`
    * `tasks.unblock.v1`
    * `tasks.weekly_review.v1`

  Idempotent — if a slug already exists we leave the row alone (matches
  the `PromptTemplates.seed_defaults/0` behaviour). `down/0` deletes only
  the slugs this migration introduced.
  """

  @templates [
    %{
      slug: "tasks.triage.v1",
      name: "Tasks: Triage",
      description:
        "Triage Officer sweeps the project backlog on weekday mornings and proposes a priority pass.",
      variables: ["org_identity"],
      content: """
      You are the Triage Officer's `tasks.triage` responsibility. Weekday mornings you sweep the project backlog and propose a priority pass.
      Input: org identity + you will call the `task_list` MCP tool to fetch open tasks for the current project.
      Output: a JSON object matching {"triage": [{"task_id": "<uuid>", "suggested_priority": "high|medium|low", "reason": "<one clause>"}, ...]}.
      Only emit rows for tasks whose current priority you would change. Empty list is a valid answer.
      """
    },
    %{
      slug: "tasks.unblock.v1",
      name: "Tasks: Unblock",
      description:
        "Triage Officer proposes concrete next steps when someone reports being blocked in chat.",
      variables: ["org_identity"],
      content: """
      You are the Triage Officer's `tasks.unblock` responsibility. Someone said they are blocked; propose next steps.
      Input: the triggering chat message + org identity.
      Output: a JSON object matching {"suggestions": ["<one concrete step>", ...]}.
      List 1–4 concrete steps the person can take right now. Reference the person or task by name when it appears in the trigger.
      """
    },
    %{
      slug: "tasks.weekly_review.v1",
      name: "Tasks: Weekly Review",
      description:
        "Triage Officer writes a short Friday-afternoon digest of the project's shipped work + slips.",
      variables: ["org_identity", "recent_journal"],
      content: """
      You are the Triage Officer's `tasks.weekly_review` responsibility. Friday afternoons you write a short weekly digest for the project.
      Input: org identity + last 7 days of org journal + you will call `task_list` for tasks touched this week.
      Output: a JSON object matching {"review": "<one-paragraph summary of what shipped + what slipped>", "followups": ["<optional carry-over>", ...]}.
      One paragraph, no bullets in the review body. Follow-ups are optional and terse.
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
