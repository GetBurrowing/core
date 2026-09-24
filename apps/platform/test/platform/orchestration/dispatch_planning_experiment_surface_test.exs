defmodule Platform.Orchestration.DispatchPlanningExperimentSurfaceTest do
  @moduledoc """
  Task 01a0d41e stage 2: the planner's experiment-surface line.

  Three relations are pinned here:

  1. The notice text itself names the rule the architect enforces (LITERALS,
     never re-derived from the constant under test).
  2. Parity: the `dispatch.planning` descriptor AND
     `HeartbeatScheduler.hardcoded_dispatch_planning/4` both carry
     `PromptTemplates.planning_experiment_surface_notice/0`. The fallback is
     called DIRECTLY: `dispatch.planning` is a registered default, so
     deleting the row and calling `dispatch_prompt/3` renders the descriptor
     via `render_default/2` and never reaches the hardcoded body — such a
     test stays green with the fallback interpolation removed.
  3. The force-update migration
     `20260924171000_force_update_architect_and_planning_templates_experiment_surface`
     actually rewrites stale rows (anti-vacuity: the rows are made stale and
     the precondition asserted first, because a freshly migrated test DB
     already holds the current descriptor).
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  @migration_path Path.join([
                    __ENV__.file
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname()
                    |> Path.dirname(),
                    "priv/repo/migrations/20260924171000_force_update_architect_and_planning_templates_experiment_surface.exs"
                  ])

  @migration_module Platform.Repo.Migrations.ForceUpdateArchitectAndPlanningTemplatesExperimentSurface

  @slugs ["architecture.review_plan.v1", "architecture.audit_diff.v1", "dispatch.planning"]

  setup do
    unless Code.ensure_loaded?(@migration_module) do
      Code.require_file(@migration_path)
    end

    :ok = PromptTemplates.seed_defaults()
    :ok
  end

  defp planning_task do
    %{
      id: "01a0d41e-bca9-7001-8a0d-8b23ce0cad93",
      title: "Experiment surface parity probe",
      description: "A task that needs a plan before any implementation begins.",
      status: "planning",
      priority: "medium"
    }
  end

  describe "the notice text (literals)" do
    test "names the constraint, both first-line forms, the exemptions and the truncation reason" do
      notice = PromptTemplates.planning_experiment_surface_notice()

      assert notice =~ "experiment_surface"
      assert notice =~ "FIRST LINE of stage 1's description"

      assert notice =~
               "`Experiment surface: <decision point>, variants configurable as data; metric: <what it moves>`"

      assert notice =~ "`Not experimentable because: <reason>`"
      assert notice =~ "a model, prompt, budget, threshold or generator"
      assert notice =~ "Bug fixes, refactors and infra/config changes are exempt"
      assert notice =~ "0048-experimentation-substrate.md"
      assert notice =~ "600 characters"
      refute notice =~ "{{", "the notice is interpolated at definition time; no placeholders"
    end
  end

  describe "parity: descriptor and hardcoded fallback" do
    test "the dispatch.planning descriptor carries the notice, before the submit line" do
      notice = PromptTemplates.planning_experiment_surface_notice()
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ notice,
             "the dispatch.planning descriptor lost `planning_experiment_surface_notice/0`"

      {notice_at, _} = :binary.match(content, notice)
      {submit_at, _} = :binary.match(content, "Submit the plan with plan_submit")
      assert notice_at < submit_at
    end

    test "the hardcoded planning fallback carries the notice" do
      body = HeartbeatScheduler.hardcoded_dispatch_planning(planning_task(), "", nil, nil)

      assert body =~ "You have been assigned a task that requires a plan",
             "the hardcoded fallback body must actually have rendered"

      assert body =~ PromptTemplates.planning_experiment_surface_notice(),
             "the hardcoded planning fallback lost `PromptTemplates.planning_experiment_surface_notice/0`"

      assert body =~ "Not experimentable because:"
    end

    test "the served dispatch.planning row renders the notice" do
      output = HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil)
      assert output =~ PromptTemplates.planning_experiment_surface_notice()
    end
  end

  describe "the CI-evidence section survives force-updates (folded from the live row)" do
    # The section lived only in the live `dispatch.planning` row (a 2026-09-10
    # hand edit) until task 01a0d41e stage 2; the force-update migration would
    # have deleted it on both installs. LITERAL heading, never re-derived from
    # the accessor under test.
    @ci_heading "## CI evidence: what actually triggers a run (verified 2026-09-11)"

    test "the dispatch.planning descriptor carries the section, before Validation kinds" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ @ci_heading,
             "the CI-evidence section is gone from the descriptor; the next force-update " <>
               "migration for dispatch.planning would delete it from every install"

      assert content =~ "A push to `task/<uuid>` never starts a CI run."

      {ci_at, _} = :binary.match(content, @ci_heading)
      {kinds_at, _} = :binary.match(content, "## Validation kinds")
      assert ci_at < kinds_at
    end

    test "the hardcoded planning fallback carries the same section" do
      body = HeartbeatScheduler.hardcoded_dispatch_planning(planning_task(), "", nil, nil)
      assert body =~ @ci_heading
      assert body =~ PromptTemplates.planning_ci_evidence_section()
    end

    test "the migration writes the section into a stale row" do
      template = PromptTemplates.get_template_by_slug("dispatch.planning")
      heading = @ci_heading

      stale =
        String.replace(
          PromptTemplates.default_content_for_slug("dispatch.planning"),
          PromptTemplates.planning_ci_evidence_section(),
          ""
        )

      {:ok, _} = PromptTemplates.update_template(template, %{content: stale})
      refute PromptTemplates.get_template_by_slug("dispatch.planning").content =~ heading

      assert :ok = apply(@migration_module, :up, [])
      assert PromptTemplates.get_template_by_slug("dispatch.planning").content =~ heading
    end
  end

  describe "20260924171000 force-update migration" do
    defp stale_body("dispatch.planning", content) do
      String.replace(content, PromptTemplates.planning_experiment_surface_notice(), "")
    end

    defp stale_body(_slug, content) do
      String.replace(content, "experiment_surface", "module_boundary")
    end

    defp make_stale!(slug) do
      template = PromptTemplates.get_template_by_slug(slug)
      assert template, "seed_defaults/0 should have created #{slug}"

      stale = stale_body(slug, PromptTemplates.default_content_for_slug(slug))
      {:ok, updated} = PromptTemplates.update_template(template, %{content: stale})

      # The precondition. Without it the assertions below pass on a row the
      # test DB already held at the current descriptor.
      refute updated.content =~ "experiment_surface"
      refute updated.content == PromptTemplates.default_content_for_slug(slug)
      updated
    end

    test "rewrites each stale row to its descriptor" do
      assert apply(@migration_module, :slugs, []) == @slugs

      stale = Map.new(@slugs, &{&1, make_stale!(&1)})

      assert :ok = apply(@migration_module, :up, [])

      for slug <- @slugs do
        row = PromptTemplates.get_template_by_slug(slug)

        assert row.content == PromptTemplates.default_content_for_slug(slug),
               "#{slug} must be rewritten to the shipped descriptor"

        assert row.content =~ "experiment_surface"
        refute row.content == stale[slug].content
      end

      assert PromptTemplates.get_template_by_slug("dispatch.planning").content =~
               PromptTemplates.planning_experiment_surface_notice()

      # Idempotent, and no duplicated rows.
      assert :ok = apply(@migration_module, :up, [])

      assert Repo.aggregate(
               from(t in PromptTemplate, where: t.slug == "dispatch.planning"),
               :count
             ) == 1
    end

    test "seed_defaults/0 does NOT repair a stale row — the migration is load-bearing" do
      stale = make_stale!("dispatch.planning")
      :ok = PromptTemplates.seed_defaults()

      assert PromptTemplates.get_template_by_slug("dispatch.planning").content == stale.content
    end

    test "skips a deleted row without raising" do
      # The FIRST slug is deleted, so the later ones prove the loop carries on.
      template = PromptTemplates.get_template_by_slug("architecture.review_plan.v1")
      {:ok, _} = PromptTemplates.delete_template(template)
      make_stale!("dispatch.planning")

      assert :ok = apply(@migration_module, :up, [])

      assert is_nil(PromptTemplates.get_template_by_slug("architecture.review_plan.v1"))

      assert PromptTemplates.get_template_by_slug("dispatch.planning").content ==
               PromptTemplates.default_content_for_slug("dispatch.planning"),
             "a missing row must not stop the remaining slugs from being written"
    end
  end
end
