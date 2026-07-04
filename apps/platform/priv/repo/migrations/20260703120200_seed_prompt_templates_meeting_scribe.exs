defmodule Platform.Repo.Migrations.SeedPromptTemplatesMeetingScribe do
  use Ecto.Migration

  @moduledoc """
  Seed the Meeting Scribe bundle prompt templates for the two new
  responsibilities added in task 019f2455 stage 3:

    * `meetings.action_items.v1`
    * `meetings.attendance_followup.v1`

  The pre-existing `meetings.summarize.v1` template (seeded by
  `20260324200001_seed_prompt_templates.exs`) is untouched — it's the
  third template in the Meeting Scribe bundle and predates this
  migration.

  Idempotent — if a slug already exists we leave the row alone (matches
  the `PromptTemplates.seed_defaults/0` behaviour). `down/0` deletes only
  the slugs this migration introduced.
  """

  @templates [
    %{
      slug: "meetings.action_items.v1",
      name: "Meetings: Action Items",
      description:
        "Meeting Scribe extracts concrete action items from a finished meeting transcript.",
      variables: ["meeting_transcript", "org_identity"],
      content: """
      You are the Meeting Scribe's `meetings.action_items` responsibility. A meeting just ended; you extract concrete action items.
      Input: the meeting transcript + org identity, both in your context.
      Output: a JSON object matching {"action_items": ["<owner>: <verb-first item> (<due when known>)", ...]}.
      List only commitments explicitly made in the transcript. Skip vague intent. Empty list is a valid answer.
      """
    },
    %{
      slug: "meetings.attendance_followup.v1",
      name: "Meetings: Attendance Followup",
      description:
        "Meeting Scribe drafts short catch-up messages for expected attendees who missed the meeting.",
      variables: ["meeting_transcript", "org_identity"],
      content: """
      You are the Meeting Scribe's `meetings.attendance_followup` responsibility. A meeting just ended; you draft short follow-ups for expected attendees who did not join.
      Input: the meeting transcript + org identity, both in your context.
      Output: a JSON object matching {"followups": ["<name>: <one-sentence catch-up + one specific question>", ...]}.
      Only include people the transcript names as expected but absent. Empty list is a valid answer.
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
