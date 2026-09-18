defmodule Platform.Repo.Migrations.SeedAgentsGoalHeartbeatPrompt do
  use Ecto.Migration

  @moduledoc """
  Seed the `agents.goal_heartbeat.v1` prompt template for task
  `01a0b491` stage 3.

  A migration rather than a `do_default_templates/0` entry because
  `PromptTemplates.render_template/2` reads the `prompt_templates` ROW
  and `seed_defaults/0` is INSERT-only: editing the code default is a
  runtime no-op wherever a row already exists, and on an environment
  that never calls `seed_defaults/0` there is no row at all. The
  closed-roster coverage sweep enforces exactly this — a slug is owned
  only by a file carrying `slug: "<slug>"` plus a creation call.

  Idempotent. `down/0` deletes only the slug this migration introduced.
  """

  @templates [
    %{
      slug: "agents.goal_heartbeat.v1",
      name: "Agents: Goal Heartbeat",
      description:
        "The agents leader's daily 09:00 UTC heartbeat: the space's goal plus the measurement that tracks it.",
      variables: ["goal", "measurement"],
      content: """
      You are the agents leader posting the daily goal heartbeat for the agents space.

      Goal: {{goal}}
      Measurement: {{measurement}}

      Write at most three sentences. Lead with the measurement and its movement exactly as given above — do not recompute it, do not round it, and do not invent a number that is not there. If the measurement says this is the first run, say so rather than reporting no change. Close with one sentence on what you are doing about it today.

      Output: a JSON object matching {"heartbeat": "<the message body>"}.
      """
    }
  ]

  def up do
    alias Platform.Orchestration.PromptTemplates

    Enum.each(@templates, fn template ->
      case PromptTemplates.get_template_by_slug(template.slug) do
        nil -> {:ok, _} = PromptTemplates.create_template(template)
        _existing -> :skip
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
