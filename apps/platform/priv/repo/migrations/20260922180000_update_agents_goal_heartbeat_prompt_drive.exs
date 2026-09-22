defmodule Platform.Repo.Migrations.UpdateAgentsGoalHeartbeatPromptDrive do
  use Ecto.Migration

  @moduledoc """
  Replace the `agents.goal_heartbeat.v1` prompt body with the hourly
  drive template (task `01a0ca24` stage 1).

  PR #1050 moved the heartbeat from daily 09:00 UTC to the top of every
  hour, but the row seeded by `20260918160000_seed_agents_goal_heartbeat_prompt`
  still says "daily goal heartbeat", caps the reply at three sentences and
  asks for a JSON `{"heartbeat": ...}` object. The new body turns the ping
  into a prod to drive the goal: it adds `{{prior_claim}}` (last beat's
  "Next:" line, read back by stage 3) and `{{drive}}` (the zero/N delegate
  instruction, stage 2), and ends with a "Next:" line instruction. The
  JSON-output instruction is dropped on purpose: on the native dispatch
  path nothing parses the model's output, so a JSON body posted to chat is
  noise.

  Why an UPDATE migration rather than editing the seed: the seed is
  already applied on live databases, so editing it is a no-op there.
  `PromptTemplates.render_template/2` reads the `prompt_templates` ROW and
  `seed_defaults/0` is INSERT-only, so a code-side change never reaches a
  migrated install. The seed file also stays the slug's owner for the
  closed-roster coverage sweep.

  Before this was written, the live row was read on both moon installs
  (fabrikam `core_platform`, milv `milv_platform`): both were byte-identical to
  the 20260918160000 body (md5 `7b598efb0aad2e09087350f8391683ad`), so the
  overwrite discards no human edit.

  `up/0` is idempotent and creates the row when it is missing (fresh DB).
  `down/0` restores the 20260918160000 content, variables and description.
  """

  @slug "agents.goal_heartbeat.v1"

  @drive %{
    slug: "agents.goal_heartbeat.v1",
    name: "Agents: Goal Heartbeat",
    description:
      "The agents leader's hourly heartbeat: goal, measurement, last beat's claim, and the instruction to drive the goal.",
    variables: ["goal", "measurement", "prior_claim", "drive"],
    content: """
    You are the agents leader. This is the hourly goal heartbeat for the agents space: a prod to move the goal, not a status report.

    Goal: {{goal}}
    Measurement: {{measurement}}

    {{prior_claim}}

    {{drive}}

    Lead with the measurement and its movement exactly as given above. Do not recompute it, do not round it, and do not invent a number that is not there. If the measurement says this is the first run, say so rather than reporting no change.

    Post your reply in this space. End it with one line that starts "Next:" naming the single action you will have done before the next beat.
    """
  }

  # The 20260918160000 literal, verbatim, for `down/0`.
  @seeded %{
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

  def up, do: put(@drive)

  def down, do: put(@seeded)

  defp put(attrs) do
    alias Platform.Orchestration.PromptTemplates

    case PromptTemplates.get_template_by_slug(@slug) do
      nil ->
        {:ok, _} = PromptTemplates.create_template(attrs)

      template ->
        {:ok, _} =
          PromptTemplates.update_template(template, %{
            name: attrs.name,
            description: attrs.description,
            variables: attrs.variables,
            content: attrs.content
          })
    end

    :ok
  end
end
