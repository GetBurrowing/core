defmodule Platform.Repo.Migrations.ForceUpdatePlanningTemplateStageDescriptionRuleTest do
  @moduledoc """
  Coverage for
  `20260731234500_force_update_planning_template_stage_description_rule`
  (task 019fba28 stage 4).

  READ THIS BEFORE ADDING AN ASSERTION HERE — the obvious test is vacuous by
  construction. `assert get_template_by_slug("dispatch.planning").content =~
  "## A constraint binds only if you restate it"` PASSES WITH THE MIGRATION
  FILE DELETED: in the test database that row is created by
  `20260324200001_seed_prompt_templates` running
  `PromptTemplates.seed_defaults/0` against the CURRENT code, so the row
  already equals this branch's default before anything in this file runs. That
  assertion cannot fail on the thing it appears to check.

  What every test below does instead is model a DEPLOYED environment: put the
  live row into a deliberately stale pre-change state, then run the migration's
  `up/0` and assert the delta. The stale write is the before-state, asserted
  rather than assumed, and it is the only thing that makes the after-state mean
  anything.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @slug "dispatch.planning"

  @migration_module Platform.Repo.Migrations.ForceUpdatePlanningTemplateStageDescriptionRule

  # Migration files live under `priv/repo/migrations/` and are not on the
  # compile path — walk five `dirname`s to climb from
  # `test/platform/repo/migrations/<this>.exs` up to the `apps/platform/` app
  # root, then descend into `priv/repo/migrations/`.
  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260731234500_force_update_planning_template_stage_description_rule.exs"
                  ])

  # The pre-change shape: a planning body with no mention of the boundary at
  # all. Deliberately unlike the shipped default in every respect the
  # assertions below read.
  @stale_content """
  You have been assigned a task that requires a plan before any implementation begins.

  Task: {{task_title}}
  Description: {{task_description}}

  ## Validation kinds

  STALE PLANNING BODY — this row predates task 019fba28 stage 4.
  """

  @stale_variables ["task_id", "task_title", "task_description", "task_priority"]

  @rule_heading "## A constraint binds only if you restate it inside a stage description"

  setup do
    # `mix test` runs `ecto.migrate` in the same VM, which compiles every
    # migration file — so the module is normally already loaded. Load it
    # ourselves when it is not, so a syntax error in the migration surfaces
    # here rather than as a full-suite compile break at deploy time.
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok
  end

  defp stale_the_row! do
    template = PromptTemplates.get_template_by_slug(@slug)
    refute is_nil(template), "#{@slug} must be seeded before this test can stale it"

    {:ok, staled} =
      PromptTemplates.update_template(template, %{
        content: @stale_content,
        variables: @stale_variables
      })

    # Before-state, asserted rather than assumed. If the write silently failed
    # the post-`up/0` assertions would pass against a row that was never stale,
    # which is exactly the vacuity this file exists to avoid.
    assert staled.content == @stale_content
    refute staled.content =~ @rule_heading
    refute staled.content =~ "survives this boundary as nothing at all"

    staled
  end

  describe "up/0 against a deployed-shaped (stale) row" do
    test "rewrites content to the shipped default, restoring the stage-description rule" do
      stale_the_row!()

      assert :ok = @migration_module.up()

      reloaded = PromptTemplates.get_template_by_slug(@slug)

      assert reloaded.content == PromptTemplates.default_content_for_slug(@slug)

      refute reloaded.content == @stale_content

      assert reloaded.content =~ @rule_heading,
             "the migrated row must carry the stage-description rule — without it every " <>
               "planner on a deployed environment keeps writing constraints into a ticket " <>
               "body no implementer is ever sent"

      for anchor <- [
            "restated inside the relevant stage's `description`",
            "survives this boundary as nothing at all",
            "has already lost them."
          ] do
        assert reloaded.content =~ anchor,
               "the migrated row is missing the anchor #{inspect(anchor)}"
      end
    end

    test "the rule lands ABOVE the Validation kinds section in the migrated row" do
      # Placement is load-bearing: the rule has to be read while the planner is
      # still writing stage bodies. The stale fixture contains
      # "## Validation kinds" and no rule at all, so a migration that appended
      # the section at the end of the body would satisfy the test above and
      # fail this one.
      stale_the_row!()

      assert :ok = @migration_module.up()

      content = PromptTemplates.get_template_by_slug(@slug).content

      assert {rule_index, _} = :binary.match(content, @rule_heading)
      assert {kinds_index, _} = :binary.match(content, "## Validation kinds")

      assert rule_index < kinds_index
    end

    test "rewrites variables from the shipped descriptor" do
      # This stage adds no new placeholder, so `variables` gains no entry — but
      # the migration still rewrites it from the descriptor, matching stages 2
      # and 3, so a row cannot drift from the shipped list. The stale fixture
      # drops several entries precisely so this assertion has something to
      # restore.
      staled = stale_the_row!()
      refute "federation_preamble" in staled.variables

      assert :ok = @migration_module.up()

      reloaded = PromptTemplates.get_template_by_slug(@slug)
      descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))

      assert reloaded.variables == descriptor.variables
      assert "federation_preamble" in reloaded.variables
    end

    test "is idempotent — a second up/0 against the migrated row changes nothing" do
      stale_the_row!()

      assert :ok = @migration_module.up()
      first = PromptTemplates.get_template_by_slug(@slug)

      assert :ok = @migration_module.up()
      second = PromptTemplates.get_template_by_slug(@slug)

      assert second.content == first.content
      assert second.variables == first.variables
    end

    test "leaves the dispatch.in_progress row alone" do
      # Scope control. The rule is addressed to the agent that authors stage
      # descriptions; no execution dispatch needs it and every dispatch body is
      # paid for on every dispatch forever. If someone later widens the
      # migration's slug set, this goes red.
      before = PromptTemplates.get_template_by_slug("dispatch.in_progress")
      refute is_nil(before)

      {:ok, _} =
        PromptTemplates.update_template(before, %{
          content: "IN PROGRESS SENTINEL BODY {{stage_description}}"
        })

      stale_the_row!()
      assert :ok = @migration_module.up()

      assert PromptTemplates.get_template_by_slug("dispatch.in_progress").content ==
               "IN PROGRESS SENTINEL BODY {{stage_description}}"
    end

    test "seed_defaults/0 does NOT repair the stale row — the migration is load-bearing" do
      # The control for the whole stage. If seeding repaired existing rows the
      # migration would be ceremony and the descriptor edit would have been
      # enough. `seed_defaults/0` is INSERT-only, so a deployed environment
      # keeps serving the old body forever.
      staled = stale_the_row!()

      :ok = PromptTemplates.seed_defaults()

      after_seed = PromptTemplates.get_template_by_slug(@slug)

      assert after_seed.content == staled.content,
             "seed_defaults/0 must leave an existing row untouched (insert-only)"

      refute after_seed.content =~ @rule_heading,
             "which is exactly why a deployed environment would never read the rule"

      assert :ok = @migration_module.up()

      assert PromptTemplates.get_template_by_slug(@slug).content =~ @rule_heading,
             "the migration does what seeding cannot"
    end
  end

  describe "up/0 when the row is absent" do
    test "skips without raising and does not create the row" do
      template = PromptTemplates.get_template_by_slug(@slug)
      refute is_nil(template)
      {:ok, _} = PromptTemplates.delete_template(template)
      assert is_nil(PromptTemplates.get_template_by_slug(@slug))

      # First boot of a brand-new environment: `seed_defaults/0` owns the
      # INSERT, not this migration. Creating the row here would race that.
      assert :ok = @migration_module.up()

      assert is_nil(PromptTemplates.get_template_by_slug(@slug)),
             "up/0 must skip an absent row, not insert one — seed_defaults/0 owns first boot"
    end
  end
end
