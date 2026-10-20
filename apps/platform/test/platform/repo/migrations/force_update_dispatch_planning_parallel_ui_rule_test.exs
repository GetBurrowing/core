defmodule Platform.Repo.Migrations.ForceUpdateDispatchPlanningParallelUiRuleTest do
  @moduledoc """
  Task 01a156cb stage 3: the planner is told the parallel-UI rule on every
  route a planning prompt can take, and the force-update migration
  `20261020030000_force_update_dispatch_planning_parallel_ui_rule` carries it
  to deployed rows.

  Routes:

  1. the served `dispatch.planning` row (`HeartbeatScheduler.dispatch_prompt/3`);
  2. the descriptor (`PromptTemplates.default_content_for_slug/1`), which is
     what `seed_defaults/0` and every force-update migration write;
  3. `HeartbeatScheduler.hardcoded_dispatch_planning/4`, called DIRECTLY:
     `dispatch.planning` is a registered default, so a test that deletes the
     row and calls `dispatch_prompt/3` renders the descriptor and never
     reaches the hardcoded body (see
     `dispatch_planning_experiment_surface_test.exs`).

  As in `force_update_dispatch_templates_design_fidelity_test.exs`, asserting
  that the seeded test row carries the rule says nothing about the migration
  (the row is seeded from current code). The migration tests below write a
  body of their own into the row and assert the delta.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplates

  @moduletag :regression

  @migration_module Platform.Repo.Migrations.ForceUpdateDispatchPlanningParallelUiRule

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20261020030000_force_update_dispatch_planning_parallel_ui_rule.exs"
                  ])

  # LITERAL heading, never re-derived from the accessor under test.
  @rule_heading "## Parallel-UI shims are registered in the same commit"

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  defp planning_task do
    %{
      id: "01a156cb-71f8-7000-89f2-7842bacbdbf1",
      title: "Parallel-UI rule parity probe",
      description: "A task that needs a plan before any implementation begins.",
      status: "planning",
      priority: "medium"
    }
  end

  defp md5(content), do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)

  defp write_row!(content) do
    template = PromptTemplates.get_template_by_slug("dispatch.planning")
    refute is_nil(template), "dispatch.planning must be seeded before this test can rewrite it"
    {:ok, written} = PromptTemplates.update_template(template, %{content: content})
    assert written.content == content
    written
  end

  defp row_content, do: PromptTemplates.get_template_by_slug("dispatch.planning").content

  describe "the rule text (literals)" do
    test "names the registry, the marker, the column comment and the report" do
      rule = PromptTemplates.planning_parallel_ui_rule()

      assert rule =~ @rule_heading
      assert rule =~ "legacy event, field, column, dual write or route"
      assert rule =~ "`Platform.ParallelUI` entry"
      assert rule =~ "`# parallel-ui: <id>` markers in the same commit"
      assert rule =~ "COMMENT ON COLUMN <table>.<column> IS 'parallel-ui: <id>'"
      assert rule =~ "`mix parallel_ui.report`"
      refute rule =~ "{{", "the rule is interpolated at definition time; no placeholders"
    end

    test "is never read as a live marker by the ParallelUI scanner" do
      # The rule sits in lib/, which Markers scans. Its `<id>` placeholder
      # cannot match the id grammar, so it yields no marker.
      path =
        Path.join(System.tmp_dir!(), "parallel_ui_rule_#{System.unique_integer([:positive])}")

      File.mkdir_p!(path)
      File.write!(Path.join(path, "rule.ex"), PromptTemplates.planning_parallel_ui_rule())

      try do
        assert %{markers: [], files_scanned: 1} = Platform.ParallelUI.Markers.scan([path])
      after
        File.rm_rf!(path)
      end
    end
  end

  describe "every planning route carries the rule" do
    test "the descriptor carries it, after the CI-evidence section and before Validation kinds" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")
      rule = PromptTemplates.planning_parallel_ui_rule()

      assert content =~ rule,
             "the dispatch.planning descriptor lost `planning_parallel_ui_rule/0`"

      {ci_at, _} = :binary.match(content, PromptTemplates.planning_ci_evidence_section())
      {rule_at, _} = :binary.match(content, rule)
      {kinds_at, _} = :binary.match(content, "## Validation kinds")
      assert ci_at < rule_at and rule_at < kinds_at
    end

    test "the hardcoded planning fallback carries it" do
      body = HeartbeatScheduler.hardcoded_dispatch_planning(planning_task(), "", nil, nil)

      assert body =~ "You have been assigned a task that requires a plan",
             "the hardcoded fallback body must actually have rendered"

      assert body =~ PromptTemplates.planning_parallel_ui_rule(),
             "the hardcoded planning fallback lost `PromptTemplates.planning_parallel_ui_rule/0`"

      assert body =~ @rule_heading
    end

    test "the served dispatch.planning row renders it" do
      assert PromptTemplates.get_template_by_slug("dispatch.planning"),
             "the DB-row route needs a seeded row"

      output = HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil)
      assert output =~ PromptTemplates.planning_parallel_ui_rule()
    end
  end

  describe "20261020030000 force-update migration" do
    test "a deployed row without the rule, at the pre-change md5, is rewritten" do
      stale =
        String.replace(
          PromptTemplates.default_content_for_slug("dispatch.planning"),
          PromptTemplates.planning_parallel_ui_rule(),
          ""
        )

      write_row!(stale)
      refute row_content() =~ @rule_heading

      # The KEY comes from the migration's own map; only the md5 VALUE is
      # replaced, because the production pre-change body is not available.
      pre_change =
        apply(@migration_module, :pre_change_md5, [])
        |> Map.replace!("dispatch.planning", md5(stale))

      assert :ok = apply(@migration_module, :run, [pre_change])

      assert row_content() == PromptTemplates.default_content_for_slug("dispatch.planning")
      assert row_content() =~ @rule_heading
    end

    test "an operator row whose md5 is not in the map is preserved, with a warning" do
      operator = "OPERATOR EDIT of dispatch.planning {{task_title}}"
      write_row!(operator)

      log =
        capture_log(fn ->
          assert :ok = apply(@migration_module, :up, [])
        end)

      assert row_content() == operator
      assert log =~ "skipping dispatch.planning"
      assert log =~ md5(operator)
    end

    test "a row already equal to the descriptor is untouched" do
      descriptor = PromptTemplates.default_content_for_slug("dispatch.planning")
      written = write_row!(descriptor)

      log =
        capture_log(fn ->
          assert :ok = apply(@migration_module, :run, [%{"dispatch.planning" => md5("x")}])
        end)

      reloaded = PromptTemplates.get_template_by_slug("dispatch.planning")
      assert reloaded.content == descriptor
      assert reloaded.updated_at == written.updated_at
      refute log =~ "skipping dispatch.planning"
    end

    test "an absent row is skipped and not created" do
      {:ok, _} =
        PromptTemplates.delete_template(PromptTemplates.get_template_by_slug("dispatch.planning"))

      assert :ok = apply(@migration_module, :up, [])
      assert is_nil(PromptTemplates.get_template_by_slug("dispatch.planning"))
    end

    # Measured read-only 2026-10-20 on installs A, B and C (all three equal):
    # the pre-#1271 descriptor, NOT the descriptor on main 60af1f6fe
    # (a0ca095a…). Written down here, not read back from the migration.
    test "carries exactly the md5 measured on the production installs" do
      assert apply(@migration_module, :pre_change_md5, []) == %{
               "dispatch.planning" => "a01b8696047ae6fc8f4912490e8f232f"
             }
    end
  end
end
