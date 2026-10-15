defmodule Platform.Orchestration.HeartbeatSchedulerExperimentSurfacesTest do
  @moduledoc """
  Task 01a0d415 stage 4: the `mail.draft.generator` and `planner.stage_budget`
  surfaces reach the dispatch prompt through ONE helper,
  `HeartbeatScheduler.append_experiment_directive/4`.

  Every render goes through the public `HeartbeatScheduler.dispatch_prompt/4`.
  Expected blocks are LITERALS, never re-derived from the surface under test.

  The byte-identical tests compare with `==` on binaries, which is the
  property: the surface is resolved on EVERY render, and only the
  experiment's scope keeps it off unrelated tasks, so an out-of-scope render
  must be indistinguishable from a render with no experiment at all.

  `async: false`: the raising-resolver test writes app env.
  """
  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Experiments
  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Surfaces
  alias Platform.Experiments.Surfaces.MailDraftGenerator
  alias Platform.Experiments.Surfaces.PlannerStageBudget
  alias Platform.Experiments.Variant
  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Tasks

  @budget_block "\n\n## Experiment directive (planner.stage_budget)\n\n" <>
                  "Plan at most 3 stages. Merge work into fewer stages rather than exceed this.\n"

  @generator_block "\n\n## Experiment directive (mail.draft.generator)\n\n" <>
                     "Generator: voice_model\n\nWrite in the candidate's own voice.\n"

  setup do
    :ok = PromptTemplates.seed_defaults()
    org = tenant_org_id("soylent")
    {:ok, p} = Tasks.create_project(%{name: "Job Hunt #{unique()}", org_id: org})
    {:ok, q} = Tasks.create_project(%{name: "Other #{unique()}", org_id: org})
    %{org: org, p: p, q: q}
  end

  defp unique, do: System.unique_integer([:positive])

  defp admin, do: Platform.TenancyFixtures.root_admin!()

  defp task(project_id, status) do
    %{
      id: Ecto.UUID.generate(),
      title: "Apply: Acme Robotics #{unique()}",
      description: "A job application task.",
      status: status,
      priority: "medium",
      project_id: project_id,
      epic_id: nil,
      inserted_at: ~U[2026-09-24 12:00:00Z]
    }
  end

  defp plan_and_stage do
    stage = %{
      id: "01a0d426-4529-7001-8211-9f5784514ea8",
      position: 4,
      name: "Write the application",
      description: "Write the resume and cover letter.",
      status: "running",
      validations: [
        %{id: "01a0d426-4529-7002-97c6-a25cbf1f6947", kind: "test_pass", status: "pending"}
      ]
    }

    {%{version: 1, stages: [stage]}, stage}
  end

  defp render_planning(task), do: HeartbeatScheduler.dispatch_prompt(task, nil, nil)

  defp render_in_progress(task) do
    {plan, stage} = plan_and_stage()
    HeartbeatScheduler.dispatch_prompt(task, plan, stage)
  end

  # A running experiment whose ONLY assignable arm is `arm` (the other arm's
  # weight is zeroed), so the test is deterministic about which arm a new
  # subject lands in. `arm: "control"` exercises the control arm.
  defp running!(surface_key, target, project_id, treatment_payload, arm) do
    {:ok, experiment} =
      Experiments.create_experiment(%{
        slug: "surf-#{unique()}",
        name: "Surface #{surface_key}",
        surface_key: surface_key,
        surface_target: target,
        project_id: project_id
      })

    {:ok, _} =
      Experiments.add_variant(experiment, %{
        slug: "treatment",
        payload: treatment_payload,
        weight: 1
      })

    {:ok, %Experiment{status: "running"} = running} = Experiments.start(experiment, admin())

    zero = if arm == "control", do: "treatment", else: Experiment.control_slug()

    Repo.update_all(
      from(v in Variant, where: v.experiment_id == ^running.id and v.slug == ^zero),
      set: [weight: 0]
    )

    running
  end

  defp budget!(project_id, arm \\ "treatment"),
    do:
      running!(
        "planner.stage_budget",
        "dispatch.planning",
        project_id,
        %{"max_stages" => 3},
        arm
      )

  defp generator!(project_id, arm \\ "treatment"),
    do:
      running!(
        "mail.draft.generator",
        "dispatch.in_progress",
        project_id,
        %{"generator" => "voice_model", "directive" => "Write in the candidate's own voice."},
        arm
      )

  defp assignments_for(task_id) do
    Repo.all(from(a in Assignment, where: a.subject_id == ^task_id))
  end

  defp block_count(prompt, key) do
    prompt |> String.split("## Experiment directive (#{key})") |> length() |> Kernel.-(1)
  end

  describe "registry" do
    test "both surfaces are registered with their paths" do
      assert Surfaces.get("mail.draft.generator") == MailDraftGenerator
      assert Surfaces.get("planner.stage_budget") == PlannerStageBudget
      assert MailDraftGenerator.path() == :draft
      assert PlannerStageBudget.path() == :dispatch
    end

    test "every registered surface's path is :draft or :dispatch" do
      for surface <- Surfaces.list() do
        assert surface.path() in [:draft, :dispatch], "#{inspect(surface)}"
      end
    end

    test "payload validation" do
      assert {:ok, %{"max_stages" => 3}} =
               PlannerStageBudget.validate_payload(%{"max_stages" => 3})

      assert {:ok, %{}} = PlannerStageBudget.validate_payload(%{})

      assert {:error, ["max_stages must be an integer in 1..10"]} =
               PlannerStageBudget.validate_payload(%{"max_stages" => 99})

      assert {:ok, %{"generator" => "claude"}} =
               MailDraftGenerator.validate_payload(%{"generator" => "claude", "directive" => " "})

      assert {:error, ["generator must be at most 64 chars"]} =
               MailDraftGenerator.validate_payload(%{"generator" => String.duplicate("g", 65)})

      assert {:error, ["directive must be at most 4000 chars"]} =
               MailDraftGenerator.validate_payload(%{
                 "generator" => "claude",
                 "directive" => String.duplicate("d", 4001)
               })

      assert {:error, ["generator must be a non-empty string"]} =
               MailDraftGenerator.validate_payload(%{})
    end

    test "control payloads render no block" do
      assert {:ok, control} = PlannerStageBudget.control_payload("dispatch.planning", [])
      assert PlannerStageBudget.render_directive(control) == nil
      assert {:ok, control} = MailDraftGenerator.control_payload("dispatch.in_progress", [])
      assert control == %{"generator" => "default"}
      assert MailDraftGenerator.render_directive(control) == nil
    end
  end

  describe "planner.stage_budget on the planning render" do
    test "an in-scope task gets exactly one block, and the same block on re-render", ctx do
      budget!(ctx.p.id)
      t = task(ctx.p.id, "planning")

      first = render_planning(t)
      second = render_planning(t)

      assert block_count(first, "planner.stage_budget") == 1
      assert String.ends_with?(first, @budget_block)
      assert first == second
      assert [%Assignment{variant_slug: "treatment"}] = assignments_for(t.id)
    end

    test "a task outside the project gets no block and no assignment row", ctx do
      budget!(ctx.p.id)
      t = task(ctx.q.id, "planning")

      refute render_planning(t) =~ "## Experiment directive"
      assert assignments_for(t.id) == []
    end

    test "the control arm gets no block", ctx do
      budget!(ctx.p.id, "control")
      t = task(ctx.p.id, "planning")

      refute render_planning(t) =~ "## Experiment directive"
      assert [%Assignment{variant_slug: "control"}] = assignments_for(t.id)
    end

    test "after stop the in-flight task keeps its block and a new task gets none", ctx do
      experiment = budget!(ctx.p.id)
      in_flight = task(ctx.p.id, "planning")
      assert String.ends_with?(render_planning(in_flight), @budget_block)

      {:ok, %Experiment{status: "stopped"}} = Experiments.stop(experiment, admin(), "enough")

      assert String.ends_with?(render_planning(in_flight), @budget_block)

      fresh = task(ctx.p.id, "planning")
      refute render_planning(fresh) =~ "## Experiment directive"
      assert assignments_for(fresh.id) == []
    end

    test "the derived fallback branch goes through the same helper", ctx do
      budget!(ctx.p.id)
      t = task(ctx.p.id, "planning")
      Repo.delete_all(from(pt in PromptTemplate, where: pt.slug == "dispatch.planning"))

      assert String.ends_with?(render_planning(t), @budget_block)
    end

    test "BYTE-IDENTICAL: an out-of-scope render equals the no-experiment render", ctx do
      t = task(ctx.q.id, "planning")
      before = render_planning(t)

      budget!(ctx.p.id)
      after_experiment = render_planning(t)

      assert after_experiment == before
      assert assignments_for(t.id) == []
    end
  end

  describe "mail.draft.generator on the in_progress render" do
    test "an in-scope task gets exactly one block, and the same block on re-render", ctx do
      generator!(ctx.p.id)
      t = task(ctx.p.id, "in_progress")

      first = render_in_progress(t)
      second = render_in_progress(t)

      assert block_count(first, "mail.draft.generator") == 1
      assert String.ends_with?(first, @generator_block)
      assert first == second
      assert [%Assignment{variant_slug: "treatment"}] = assignments_for(t.id)
    end

    test "a task outside the project gets no block and no assignment row", ctx do
      generator!(ctx.p.id)
      t = task(ctx.q.id, "in_progress")

      refute render_in_progress(t) =~ "## Experiment directive"
      assert assignments_for(t.id) == []
    end

    test "the control arm gets no block", ctx do
      generator!(ctx.p.id, "control")
      t = task(ctx.p.id, "in_progress")

      refute render_in_progress(t) =~ "## Experiment directive"
      assert [%Assignment{variant_slug: "control"}] = assignments_for(t.id)
    end

    test "after stop the in-flight task keeps its block and a new task gets none", ctx do
      experiment = generator!(ctx.p.id)
      in_flight = task(ctx.p.id, "in_progress")
      assert String.ends_with?(render_in_progress(in_flight), @generator_block)

      {:ok, %Experiment{status: "stopped"}} = Experiments.stop(experiment, admin(), "enough")

      assert String.ends_with?(render_in_progress(in_flight), @generator_block)

      fresh = task(ctx.p.id, "in_progress")
      refute render_in_progress(fresh) =~ "## Experiment directive"
      assert assignments_for(fresh.id) == []
    end

    test "the planning render of the same task does not carry the generator block", ctx do
      generator!(ctx.p.id)
      t = task(ctx.p.id, "planning")

      refute render_planning(t) =~ "mail.draft.generator"
    end

    test "BYTE-IDENTICAL: an out-of-scope render equals the no-experiment render", ctx do
      t = task(ctx.q.id, "in_progress")
      before = render_in_progress(t)

      generator!(ctx.p.id)
      after_experiment = render_in_progress(t)

      assert after_experiment == before
      assert assignments_for(t.id) == []
    end

    test "a mention token in a directive is escaped", ctx do
      running!(
        "mail.draft.generator",
        "dispatch.in_progress",
        ctx.p.id,
        %{"generator" => "claude", "directive" => "Ask @[Dalton] for help."},
        "treatment"
      )

      prompt = render_in_progress(task(ctx.p.id, "in_progress"))
      refute prompt =~ "@[Dalton]"
      assert prompt =~ "Ask ＠[Dalton] for help."
    end
  end

  describe "the helper returns its input unchanged when no block applies" do
    # The byte-identical render tests compare two renders that BOTH go through
    # the helper, so a change that alters every blockless render the same way
    # (e.g. a trailing newline on :none) is invisible to them. This compares
    # against a LITERAL input instead.
    @sentinel "PROMPT-SENTINEL: no trailing whitespace"

    test "with no experiment at all", ctx do
      for {key, target} <- [
            {"planner.stage_budget", "dispatch.planning"},
            {"mail.draft.generator", "dispatch.in_progress"}
          ] do
        assert HeartbeatScheduler.append_experiment_directive(
                 @sentinel,
                 key,
                 target,
                 task(ctx.q.id, "planning")
               ) == @sentinel
      end
    end

    test "for an out-of-scope task while experiments run", ctx do
      budget!(ctx.p.id)
      generator!(ctx.p.id)
      t = task(ctx.q.id, "in_progress")

      assert HeartbeatScheduler.append_experiment_directive(
               @sentinel,
               "planner.stage_budget",
               "dispatch.planning",
               t
             ) == @sentinel

      assert HeartbeatScheduler.append_experiment_directive(
               @sentinel,
               "mail.draft.generator",
               "dispatch.in_progress",
               t
             ) == @sentinel
    end

    test "for a task with no usable id" do
      assert HeartbeatScheduler.append_experiment_directive(
               @sentinel,
               "planner.stage_budget",
               "dispatch.planning",
               %{id: "not-a-uuid"}
             ) == @sentinel
    end

    test "and appends exactly the literal block for an in-scope task", ctx do
      budget!(ctx.p.id)

      assert HeartbeatScheduler.append_experiment_directive(
               @sentinel,
               "planner.stage_budget",
               "dispatch.planning",
               task(ctx.p.id, "planning")
             ) == @sentinel <> @budget_block
    end
  end

  describe "a raising resolver" do
    defmodule RaisingResolver do
      def resolve(_key, _target, _subject, _opts), do: raise("resolver exploded")
    end

    defmodule ThrowingResolver do
      def resolve(_key, _target, _subject, _opts), do: throw(:resolver_threw)
    end

    setup do
      on_exit(fn -> Application.delete_env(:platform, :experiments_surface_resolver) end)
      :ok
    end

    for resolver <- [RaisingResolver, ThrowingResolver] do
      test "#{inspect(resolver)} leaves both prompts byte-identical to the no-experiment render",
           ctx do
        planning_task = task(ctx.p.id, "planning")
        exec_task = task(ctx.p.id, "in_progress")
        planning_before = render_planning(planning_task)
        exec_before = render_in_progress(exec_task)

        budget!(ctx.p.id)
        generator!(ctx.p.id)
        Application.put_env(:platform, :experiments_surface_resolver, unquote(resolver))

        assert render_planning(planning_task) == planning_before
        assert render_in_progress(exec_task) == exec_before
      end
    end
  end

  describe "the tool surface refuses a target no read point resolves" do
    test "experiment_create on mail.draft.generator with the wrong target", ctx do
      assert {:error, %{code: :unknown_surface_target}} =
               Platform.Experiments.Tools.execute(
                 "experiment_create",
                 %{
                   "surface_key" => "mail.draft.generator",
                   "surface_target" => "dispatch.planning",
                   "name" => "Wrong target",
                   "project_id" => ctx.p.id
                 },
                 %{}
               )
    end
  end
end
