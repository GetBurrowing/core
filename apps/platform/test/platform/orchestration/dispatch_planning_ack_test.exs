defmodule Platform.Orchestration.DispatchPlanningAckTest do
  @moduledoc """
  Task 019fa469 stage 5 — the planning dispatch must not instruct an ack it
  cannot satisfy.

  The defect: `dispatch.planning` opened with the shared ack-first preamble,
  `**Your first tool call must be task_ack(task_id="...", stage_id="", ...)**`.
  A planning dispatch has no plan and therefore no `status == "running"` stage,
  and `ToolSurface.resolve_ack_stage_id/2` returns `{:error, :no_running_stage}`
  in exactly that shape — the runtime is told
  `task_id=<id> has no running stage — cannot ack without a stage_id.` The
  documented escape hatch, `alarm_silence`, fails identically through the same
  resolver.

  The ticket offered a second option — give `task_ack` a task-level form. The
  router rules it out: `TaskRouter`'s
  `arm_liveness_timers(_task_id, nil, _stage_kind), do: :ok` clause means a
  stage-less dispatch arms neither `:check_no_ack` nor `:check_safety_net` and
  never calls `LeaseManager.record_dispatch/4`. There is no alarm for a
  planning ack to satisfy, so the preamble's threat ("the router will fire a
  no-ack alert in 5 minutes") is false on that branch and a task-level ack form
  would be API surface for a nonexistent alarm.

  ## Anti-vacuity

  Every `refute output =~ ...` here is paired, in the SAME test, with a
  positive assertion that the planning body actually rendered plus a length
  floor. "The render does not contain `task_ack(`" passes trivially if the
  render errored, returned "", or fell through to a different slug — which is
  the failure mode stage 3 of this task found in the wild
  (`heartbeat_scheduler_test.exs:918`, a green test fed a shape production
  never produces).

  The third describe block is the counterfactual for the whole stage: the
  stage-scoped slugs MUST still carry the ack. A change that stripped
  `task_ack(` everywhere would pass every refute in this file and break the
  liveness net on the stages that do arm timers.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  # Migration files are not on the compile path — climb from
  # `test/platform/orchestration/<this>.exs` to the `apps/platform/` root,
  # then descend into `priv/repo/migrations/`. Same walk as
  # `prompt_templates_test.exs:1061`.
  @drop_ack_migration_path Path.join([
                             __ENV__.file
                             |> Path.dirname()
                             |> Path.dirname()
                             |> Path.dirname()
                             |> Path.dirname(),
                             "priv/repo/migrations/20260727183000_force_update_planning_template_drop_ack.exs"
                           ])

  Code.compile_file(@drop_ack_migration_path)

  @stage_scoped_slugs ~w(dispatch.in_progress dispatch.in_review dispatch.deploying)

  defp planning_task do
    %{
      id: "019fa469-6bae-78ca-892f-92420f4f4b59",
      title: "Planning ack regression probe",
      description: "A task that needs a plan before any implementation begins.",
      status: "planning",
      priority: "medium"
    }
  end

  defp force_default!(slug) do
    content = PromptTemplates.default_content_for_slug(slug)
    assert is_binary(content), "#{slug} must have default content"

    descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))
    assert descriptor, "#{slug} must appear in default_templates/0"

    case Repo.get_by(PromptTemplate, slug: slug) do
      nil ->
        {:ok, template} =
          PromptTemplates.create_template(%{
            slug: slug,
            name: descriptor.name,
            description: descriptor.description,
            variables: descriptor.variables,
            content: content
          })

        template

      existing ->
        {:ok, template} =
          PromptTemplates.update_template(existing, %{
            content: content,
            variables: descriptor.variables
          })

        template
    end
  end

  describe "dispatch.planning carries no ack instruction (task 019fa469 stage 5)" do
    setup do
      force_default!("dispatch.planning")
      :ok
    end

    test "the rendered planning dispatch names no ack call" do
      output = HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil)

      # Positive pins FIRST — if the render errored, fell through to another
      # slug, or came back empty, these fail and the refutes below never get
      # to pass by absence.
      assert output =~ "You have been assigned a task that requires a plan",
             "the planning body must actually have rendered"

      assert output =~ "## Subagent-spawn discipline",
             "the federation preamble must still be injected"

      assert String.length(output) > 200,
             "an empty or truncated render must not satisfy the refutes below"

      refute output =~ "task_ack(",
             "planning dispatch must not instruct a task_ack call — there is no running stage to ack"

      refute output =~ "alarm_silence(",
             "planning dispatch must not instruct alarm_silence either — it fails through the same resolver"
    end

    test "the rendered planning dispatch explains that no ack is expected" do
      output = HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil)

      assert output =~ "no running stage",
             "the planning body must say WHY there is nothing to ack"

      assert output =~ "no liveness timers",
             "the planning body must state that no alarm is armed, so a missing ack fails nothing"

      refute output =~ "no-ack alert in 5 minutes",
             "the preamble's threat is false on the planning branch and must not survive"
    end

    test "the planning render leaves no unconsumed stage_id placeholder" do
      output = HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil)

      assert output =~ "You have been assigned a task that requires a plan"

      refute output =~ "{{stage_id}}",
             "dropping stage_id from the assigns must not leave a raw mustache placeholder"

      refute output =~ ~s(stage_id=""),
             "no empty-stage_id call shape may survive in the planning body"
    end

    test "the hardcoded fallback planning render also names no ack call" do
      # Environments without the seeded row (fresh dev DBs before migrations,
      # tests against an empty templates table) take
      # `hardcoded_dispatch_planning/4`, which the module documents as "kept in
      # parity with the DB dispatch.planning template". Parity has to include
      # this fix or the defect simply relocates to the unseeded environments.
      template = Repo.get_by(PromptTemplate, slug: "dispatch.planning")
      {:ok, _} = PromptTemplates.delete_template(template)
      refute PromptTemplates.get_template_by_slug("dispatch.planning")

      output = HeartbeatScheduler.dispatch_prompt(planning_task(), nil, nil)

      assert output =~ "You have been assigned a task that requires a plan",
             "the hardcoded fallback body must actually have rendered"

      assert String.length(output) > 200

      refute output =~ "task_ack(",
             "hardcoded planning fallback must not instruct a task_ack call either"

      refute output =~ "alarm_silence(",
             "hardcoded planning fallback must not instruct alarm_silence either"
    end
  end

  describe "dispatch.planning descriptor drops stage_id (task 019fa469 stage 5)" do
    test "the shipped descriptor no longer declares stage_id" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.planning"))

      assert descriptor, "dispatch.planning must appear in default_templates/0"

      # Positive pin: the variables list is still populated and still carries
      # task_id, so a wholesale deletion of the list cannot pass the refute.
      assert "task_id" in descriptor.variables,
             "dispatch.planning must still declare task_id"

      assert "federation_preamble" in descriptor.variables,
             "dispatch.planning must still declare federation_preamble"

      refute "stage_id" in descriptor.variables,
             "dispatch.planning must not declare stage_id — nothing interpolates it any more"
    end

    test "the forced DB row's variables match the descriptor" do
      template = force_default!("dispatch.planning")

      assert "task_id" in template.variables
      refute "stage_id" in template.variables
    end
  end

  describe "stage-scoped dispatch slugs KEEP the ack (counterfactual)" do
    # The negative control for this whole stage. These slugs are only ever
    # rendered with a resolved running stage, `arm_liveness_timers/3` DOES arm
    # `:check_no_ack` for them, and stripping the ack there would silently
    # disable the liveness net rather than fix a defect.

    test "in_progress / in_review / deploying default bodies still instruct task_ack" do
      for slug <- @stage_scoped_slugs do
        content = PromptTemplates.default_content_for_slug(slug)
        assert is_binary(content), "#{slug} must have default content"

        assert content =~ "task_ack(",
               "#{slug} must keep the ack — it has a running stage and an armed timer"

        assert content =~ "alarm_silence(",
               "#{slug} must keep the operator escape hatch"

        assert "stage_id" in Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug)).variables,
               "#{slug} must keep declaring stage_id so the ack call interpolates"
      end
    end

    test "a rendered in_progress dispatch still instructs task_ack" do
      force_default!("dispatch.in_progress")

      task = %{
        id: "019fa469-6bae-78ca-892f-92420f4f4b59",
        title: "Stage-scoped ack control",
        description: "Body",
        status: "in_progress",
        priority: "medium",
        project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
      }

      stage = %{
        id: "019fa48c-0b0d-79f1-bdac-5cd2167de5a2",
        position: 1,
        name: "coding",
        status: "running",
        validations: [%{kind: "test_pass", status: "pending"}]
      }

      plan = %{version: 1, stages: [stage]}

      output = HeartbeatScheduler.dispatch_prompt(task, plan, stage)

      assert output =~ "Plan approved — execute the current stage.",
             "the in_progress body must actually have rendered"

      assert output =~
               ~s|task_ack(task_id="019fa469-6bae-78ca-892f-92420f4f4b59", stage_id="019fa48c-0b0d-79f1-bdac-5cd2167de5a2"|,
             "the stage-scoped ack must still interpolate a real stage_id"
    end
  end

  describe "20260727183000 force-update migration" do
    # The deliverable of this stage is the MIGRATION, not the edit to
    # `do_default_templates/0`. `seed_defaults/0` is INSERT-only
    # (`prompt_templates.ex:121-133`), so on every deployed environment the
    # `dispatch.planning` row already exists and the default-function edit
    # reaches nothing. These three exercise force-update, the insert-only
    # control that proves the migration is load-bearing, and the missing-row
    # skip.
    @stale_ack_preamble """
    **Your first tool call must be `task_ack(task_id="{{task_id}}", stage_id="{{stage_id}}", subagent_id="<the id returned when you spawned the SuiteExecutor / SuiteReviewer via the Agent tool>")`.**

    Without a successful ack the router will fire a no-ack alert in 5 minutes.

    **If `task_ack` is missing from your MCP tool cache**, call `alarm_silence(task_id="{{task_id}}", stage_id="{{stage_id}}", until_seconds=1800, reason="...")`.
    """

    defp stale_planning_row! do
      template = force_default!("dispatch.planning")

      {:ok, updated} =
        PromptTemplates.update_template(template, %{
          content: @stale_ack_preamble <> template.content,
          variables: template.variables ++ ["stage_id"]
        })

      # Assert the precondition rather than assume it — a fixture that failed
      # to go stale would make the force-update assertions vacuous.
      assert updated.content =~ "task_ack("
      assert updated.content =~ "alarm_silence("
      assert "stage_id" in updated.variables

      updated
    end

    test "FORCE-UPDATES a deployed row that still carries the ack preamble" do
      stale = stale_planning_row!()

      :ok = Platform.Repo.Migrations.ForceUpdatePlanningTemplateDropAck.up()

      refreshed = PromptTemplates.get_template_by_slug("dispatch.planning")

      assert refreshed.content == PromptTemplates.default_content_for_slug("dispatch.planning"),
             "the migration must rewrite the row to the shipped body"

      refute refreshed.content == stale.content

      refute refreshed.content =~ "task_ack(",
             "the deployed row must stop instructing an unsatisfiable ack"

      refute refreshed.content =~ "alarm_silence(",
             "the deployed row must stop instructing the escape hatch either"

      refute "stage_id" in refreshed.variables,
             "the migration must rewrite variables too, not just content"

      assert "task_id" in refreshed.variables

      # Idempotent, and it does not duplicate the row.
      :ok = Platform.Repo.Migrations.ForceUpdatePlanningTemplateDropAck.up()

      assert PromptTemplates.get_template_by_slug("dispatch.planning").content ==
               refreshed.content

      assert Repo.aggregate(
               Ecto.Query.from(t in PromptTemplate, where: t.slug == "dispatch.planning"),
               :count
             ) == 1
    end

    test "seed_defaults/0 does NOT repair the stale row — the migration is load-bearing" do
      # The control. If seeding repaired existing rows the migration would be
      # ceremony and the whole stage could have been a one-line edit to
      # `do_default_templates/0`. It is INSERT-only, so a deployed environment
      # keeps serving the old body forever.
      stale = stale_planning_row!()

      :ok = PromptTemplates.seed_defaults()

      after_seed = PromptTemplates.get_template_by_slug("dispatch.planning")

      assert after_seed.content == stale.content,
             "seed_defaults/0 must leave an existing row untouched (insert-only)"

      assert after_seed.content =~ "task_ack(",
             "which is exactly why prod would keep serving the ack instruction"

      :ok = Platform.Repo.Migrations.ForceUpdatePlanningTemplateDropAck.up()

      refute PromptTemplates.get_template_by_slug("dispatch.planning").content =~ "task_ack(",
             "the migration does what seeding cannot"
    end

    test "SKIPS a database with no dispatch.planning row" do
      template = PromptTemplates.get_template_by_slug("dispatch.planning")
      {:ok, _} = PromptTemplates.delete_template(template)
      refute PromptTemplates.get_template_by_slug("dispatch.planning")

      assert :ok = Platform.Repo.Migrations.ForceUpdatePlanningTemplateDropAck.up()

      refute PromptTemplates.get_template_by_slug("dispatch.planning"),
             "the migration must skip a missing row, not insert one"
    end
  end
end
