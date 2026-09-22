defmodule Platform.Repo.Migrations.UpdateAgentsGoalHeartbeatPromptDriveTest do
  @moduledoc """
  Regression coverage for
  `20260922180000_update_agents_goal_heartbeat_prompt_drive` (task
  `01a0ca24` stage 1).

  Migrations run to `:up` before ExUnit boots, so the LIVE row is
  directly assertable. That is the point of testing here: the handler's
  `fallback_body/1` is only reached when no row exists, and
  `PromptTemplates.render_template/2` renders the ROW — a body changed
  only in code never reaches an already-migrated database.

  Mirrors `add_meeting_space_to_intent_prompt_templates_test.exs`,
  including the force-update control: an INSERT-only `up/0` would leave
  the 20260918160000 body in place on every live install.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo.Migrations.UpdateAgentsGoalHeartbeatPromptDrive, as: Migration
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: Handler

  @slug "agents.goal_heartbeat.v1"

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260922180000_update_agents_goal_heartbeat_prompt_drive.exs"
                  ])

  setup_all do
    unless Code.ensure_loaded?(Migration) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp assert_drive_row do
    assert %{content: content, variables: variables, description: description} =
             PromptTemplates.get_template_by_slug(@slug)

    assert content =~ "{{prior_claim}}"
    assert content =~ "{{drive}}"
    assert content =~ "{{goal}}"
    assert content =~ "{{measurement}}"

    assert content =~
             ~s(End it with one line that starts "Next:" naming the single action you will have done before the next beat.)

    assert content =~ "This is the hourly goal heartbeat for the agents space"
    refute content =~ "daily"
    refute content =~ "three sentences"
    refute content =~ ~s({"heartbeat")

    assert variables == ["goal", "measurement", "prior_claim", "drive"]
    refute description =~ "daily"
    refute description =~ "09:00"

    content
  end

  describe "the live row after the migration" do
    test "carries the drive body, the new placeholders and the Next: instruction" do
      assert_drive_row()
    end

    test "render_template/2 fills prior_claim and drive" do
      assert {:ok, body} =
               PromptTemplates.render_template(@slug, %{
                 goal: "G",
                 measurement: "M",
                 prior_claim: "PC-LITERAL",
                 drive: "DR-LITERAL"
               })

      assert body =~ "Goal: G\nMeasurement: M\n\nPC-LITERAL\n\nDR-LITERAL\n\n"
    end
  end

  describe "down/0 and up/0" do
    test "down/0 restores the seeded body; up/0 twice is idempotent" do
      assert :ok = apply(Migration, :down, [])

      assert %{content: seeded, variables: seeded_vars, description: seeded_desc} =
               PromptTemplates.get_template_by_slug(@slug)

      assert seeded =~
               "You are the agents leader posting the daily goal heartbeat for the agents space."

      assert seeded =~ ~s(Output: a JSON object matching {"heartbeat": "<the message body>"}.)
      refute seeded =~ "{{prior_claim}}"
      assert seeded_vars == ["goal", "measurement"]

      assert seeded_desc ==
               "The agents leader's daily 09:00 UTC heartbeat: the space's goal plus the measurement that tracks it."

      assert :ok = apply(Migration, :up, [])
      first = assert_drive_row()
      assert :ok = apply(Migration, :up, [])
      second = assert_drive_row()

      assert first == second

      # Exactly one row for the slug, and the Next: instruction once.
      assert [_] =
               Repo.all(from(t in Platform.Orchestration.PromptTemplate, where: t.slug == ^@slug))

      assert length(String.split(second, ~s(starts "Next:"))) == 2
    end

    test "up/0 CREATES the row on a database that has none" do
      template = PromptTemplates.get_template_by_slug(@slug)
      {:ok, _} = PromptTemplates.delete_template(template)
      refute PromptTemplates.get_template_by_slug(@slug)

      assert :ok = apply(Migration, :up, [])
      assert_drive_row()
    end
  end

  describe "the handler fallback (no row at all)" do
    test "renders the same layout, without daily or three sentences" do
      template = PromptTemplates.get_template_by_slug(@slug)
      {:ok, _} = PromptTemplates.delete_template(template)

      context = %{
        goal: "Close backlog items in Suite",
        measurement: %{missing?: false, value: 7, unit: "open tasks", delta: nil},
        prior_claim_text: "PC-FALLBACK",
        drive_text: "DR-FALLBACK"
      }

      assert {:ok, %{user: user}} = Handler.build_prompt(context)

      assert user =~
               "Goal: Close backlog items in Suite\n" <>
                 "Measurement: 7 open tasks (first measurement — no prior run to compare against)\n\n" <>
                 "PC-FALLBACK\n\nDR-FALLBACK\n\n"

      assert user =~ ~s(End it with one line that starts "Next:")
      refute user =~ "daily"
      refute user =~ "three sentences"
    end
  end
end
