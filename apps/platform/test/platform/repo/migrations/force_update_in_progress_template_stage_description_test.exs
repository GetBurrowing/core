defmodule Platform.Repo.Migrations.ForceUpdateInProgressTemplateStageDescriptionTest do
  @moduledoc """
  Coverage for `20260731220000_force_update_in_progress_template_stage_description`
  (task 019fba28 stage 2).

  READ THIS BEFORE ADDING AN ASSERTION HERE — the obvious test is vacuous by
  construction. `assert get_template_by_slug("dispatch.in_progress").content =~
  "{{stage_description}}"` PASSES WITH THE MIGRATION FILE DELETED: in the test
  database that row is created by `20260324200001_seed_prompt_templates`
  running `PromptTemplates.seed_defaults/0` against the CURRENT code, so the
  row already equals stage 1's default before anything in this file runs. That
  assertion cannot fail on the thing it appears to check.

  What every test below does instead is model a DEPLOYED environment: put the
  live row into a deliberately stale pre-stage-1 state, then run the
  migration's `up/0` and assert the delta. The stale write is the before-state,
  and it is the only thing that makes the after-state mean anything.
  """

  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @slug "dispatch.in_progress"

  @migration_module Platform.Repo.Migrations.ForceUpdateInProgressTemplateStageDescription

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
                    "priv/repo/migrations/20260731220000_force_update_in_progress_template_stage_description.exs"
                  ])

  # The pre-stage-1 shape: a body with no `{{stage_description}}` placeholder
  # and a variable list that never declared one. Deliberately unlike the
  # shipped default in every respect the assertions read.
  @stale_content "STALE BODY {{stage_info}}"
  @stale_variables ["task_id", "stage_id", "task_title", "stage_info"]

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
    # the post-`up/0` assertions below would pass against a row that was never
    # stale, which is exactly the vacuity this file exists to avoid.
    assert staled.content == @stale_content
    refute staled.content =~ "{{stage_description}}"
    refute "stage_description" in staled.variables

    staled
  end

  describe "up/0 against a deployed-shaped (stale) row" do
    test "rewrites content to the shipped default, restoring {{stage_description}}" do
      stale_the_row!()

      assert :ok = @migration_module.up()

      reloaded = PromptTemplates.get_template_by_slug(@slug)

      assert reloaded.content == PromptTemplates.default_content_for_slug(@slug)

      assert reloaded.content =~ "{{stage_description}}",
             "the migrated row must carry the stage-description placeholder — without it " <>
               "`render_template/2` interpolates nothing and the planner's specification " <>
               "never reaches the implementer"

      refute reloaded.content == @stale_content
    end

    test "rewrites variables so \"stage_description\" is declared on the row" do
      stale_the_row!()

      assert :ok = @migration_module.up()

      reloaded = PromptTemplates.get_template_by_slug(@slug)

      assert "stage_description" in reloaded.variables,
             "the migrated row must declare stage_description in `variables` — the " <>
               "prompt-template admin UI lists that field, and a content-only rewrite " <>
               "leaves the row's declared variables disagreeing with its own body"

      descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @slug))
      assert reloaded.variables == descriptor.variables
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
