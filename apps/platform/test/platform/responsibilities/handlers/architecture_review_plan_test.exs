defmodule Platform.Responsibilities.Handlers.ArchitectureReviewPlanTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.ArchitectureReviewPlan` —
  the Architect role bundle's plan-time review handler (ADR-0044, task
  `019f3da3`).

  Stage 1 shipped the registration placeholder + ADR body. Stage 2
  wired `submit_plan_for_review/1` to fire the responsibility. Stage 3
  (this test file's target) fills in `gather_context/2`,
  `render_instruction/1`, `build_prompt/1`, and `handle_output/3` with
  real logic.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: ArchitectureReviewPlan.key(),
      feature: "architecture",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "plan:submitted"},
      scope: "per_project",
      context_provided: ["plan_payload", "sibling_tasks", "adr_index"],
      enabled: true
    }
  end

  defp make_project(name \\ "Architect Test Project") do
    {:ok, project} = Tasks.create_project(%{name: name})
    project
  end

  defp make_task(project_id, opts) do
    attrs =
      %{
        project_id: project_id,
        title: Keyword.get(opts, :title, "Architect Sibling Task"),
        status: Keyword.get(opts, :status, "in_progress")
      }
      |> Map.merge(Map.new(Keyword.get(opts, :extra, [])))

    {:ok, task} = Tasks.create_task(attrs)
    task
  end

  defp make_plan(task_id, opts \\ []) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task_id})
    version = Keyword.get(opts, :version, plan.version)

    plan =
      case Keyword.get(opts, :status, "draft") do
        "draft" ->
          plan

        other ->
          plan
          |> Ecto.Changeset.change(status: other, version: version)
          |> Repo.update!()
      end

    plan
  end

  # ── register/0 shape guard ────────────────────────────────────────────────

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = ArchitectureReviewPlan.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "architecture.review_plan"
      assert spec.feature == "architecture"
      assert spec.trigger_kind == "event_topic"
      assert spec.trigger_config == %{"topic" => "plan:submitted"}
      assert spec.scope == "per_project"
      assert spec.context_provided == ["plan_payload", "sibling_tasks", "adr_index"]
      assert spec.default_prompt_template == "architecture.review_plan.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values — satisfies the M1 schema invariant" do
      [spec] = ArchitectureReviewPlan.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)
    end

    test "metadata names the owner + role + ADR + active status" do
      [spec] = ArchitectureReviewPlan.register()

      assert spec.metadata["owner"] == "platform.architecture"
      assert spec.metadata["role"] == "architect"
      assert spec.metadata["adr"] == "0044"
      # Stage 3 promotes the row from placeholder → active.
      assert spec.metadata["status"] == "active"
    end
  end

  # ── gather_context/2 ──────────────────────────────────────────────────────

  describe "gather_context/2 — sibling walk" do
    setup do
      project = make_project()
      other_project = make_project("Unrelated Project")

      task_under_review = make_task(project.id, title: "Under Review", status: "planning")
      plan_under_review = make_plan(task_under_review.id)

      # 3 sibling tasks in the same project — all in-flight statuses.
      sibling_planning =
        make_task(project.id, title: "Sibling Planning", status: "planning")

      _ = make_plan(sibling_planning.id, status: "pending_review")

      sibling_in_progress =
        make_task(project.id, title: "Sibling In Progress", status: "in_progress")

      _ = make_plan(sibling_in_progress.id, status: "approved")

      sibling_in_review =
        make_task(project.id, title: "Sibling In Review", status: "in_review")

      _ = make_plan(sibling_in_review.id, status: "approved")

      # Excluded: done + cancelled statuses.
      _sibling_done = make_task(project.id, title: "Sibling Done", status: "done")
      _sibling_cancelled = make_task(project.id, title: "Sibling Cancelled", status: "cancelled")

      # Excluded: task in another project.
      _foreign = make_task(other_project.id, title: "Foreign Task", status: "in_progress")

      %{
        project: project,
        task_under_review: task_under_review,
        plan_under_review: plan_under_review,
        sibling_planning: sibling_planning,
        sibling_in_progress: sibling_in_progress,
        sibling_in_review: sibling_in_review
      }
    end

    test "returns sibling tasks in the same project", ctx do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{
          plan: ctx.plan_under_review
        })

      siblings = Map.get(gathered, :sibling_tasks)
      assert is_list(siblings)

      sibling_ids = Enum.map(siblings, & &1.task_id) |> MapSet.new()

      assert MapSet.member?(sibling_ids, ctx.sibling_planning.id)
      assert MapSet.member?(sibling_ids, ctx.sibling_in_progress.id)
      assert MapSet.member?(sibling_ids, ctx.sibling_in_review.id)
    end

    test "excludes the task under review itself", ctx do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{
          plan: ctx.plan_under_review
        })

      sibling_ids = Enum.map(gathered.sibling_tasks, & &1.task_id) |> MapSet.new()

      refute MapSet.member?(sibling_ids, ctx.task_under_review.id),
             "the task being reviewed must not appear in its own sibling list"
    end

    test "excludes done and cancelled statuses", ctx do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{
          plan: ctx.plan_under_review
        })

      statuses = Enum.map(gathered.sibling_tasks, & &1.status)

      refute "done" in statuses
      refute "cancelled" in statuses
    end

    test "excludes tasks from other projects", ctx do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{
          plan: ctx.plan_under_review
        })

      titles = Enum.map(gathered.sibling_tasks, & &1.title)
      refute "Foreign Task" in titles
    end

    test "populates plan_payload with plan + task metadata", ctx do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{
          plan: ctx.plan_under_review
        })

      payload = Map.get(gathered, :plan_payload)

      assert payload.plan_id == ctx.plan_under_review.id
      assert payload.task_id == ctx.task_under_review.id
      assert payload.task_title == "Under Review"
      assert payload.project_id == ctx.project.id
    end

    test "populates adr_index from docs/decisions when reachable" do
      # In the test build the file lookup may or may not resolve, but the
      # slot must always be a list (never crash the context gather).
      project = make_project("ADR Index Test Project")
      task = make_task(project.id, title: "ADR Index Task", status: "planning")
      plan = make_plan(task.id)

      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{plan: plan})

      assert is_list(gathered.adr_index),
             "adr_index must be a list (empty is fine when docs/decisions isn't reachable)"
    end

    test "refuses the dispatch when no plan is resolvable" do
      # ADR-0046 puts the architecture pass strictly after plan
      # submission, so an unresolvable plan is a wiring bug, not an empty
      # state. Before task 019f9b28-6ca7 this returned `{:ok, empty}` and
      # an LLM was dispatched to review nothing; the Router's
      # context-refusal arm (stage 2) now stops the dispatch instead.
      assert {:error, :no_plan_payload} =
               ArchitectureReviewPlan.gather_context(responsibility(), %{})

      assert {:error, :no_plan_payload} =
               ArchitectureReviewPlan.gather_context(responsibility(), %{
                 plan_id: Ecto.UUID.generate()
               })
    end

    test "still resolves when the trigger carried only a task_id", ctx do
      # Paired positive control for the refusal above: the same callback,
      # the thinnest legitimate trigger shape, must succeed.
      assert {:ok, gathered} =
               ArchitectureReviewPlan.gather_context(responsibility(), %{
                 task_id: ctx.task_under_review.id
               })

      assert gathered.plan_payload.plan_id == ctx.plan_under_review.id
      assert Enum.any?(gathered.sibling_tasks, &(&1.task_id == ctx.sibling_planning.id))
    end
  end

  # ── plan_payload slot content ─────────────────────────────────────────────

  describe "gather_context/2 — plan_payload gates + intent" do
    setup do
      project = make_project("Gate Surface Project")

      task =
        make_task(project.id,
          title: "Gate Surface Task",
          status: "planning",
          extra: [description: "Surface every gate kind so the architect can see the holes."]
        )

      plan = make_plan(task.id)

      {:ok, gated} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 1,
          name: "Gated Stage",
          description: "Has all three gate kinds."
        })

      {:ok, _} = Tasks.create_validation(%{stage_id: gated.id, kind: "test_pass"})
      {:ok, _} = Tasks.create_validation(%{stage_id: gated.id, kind: "manual_approval"})

      {:ok, _} =
        Tasks.create_validation(%{
          stage_id: gated.id,
          kind: "e2e_behavior",
          evaluation_payload: %{
            "setup" => "seed an unreviewed plan",
            "actions" => "fire architecture.review_plan",
            "expected" => "the architect annotation names the colliding module"
          }
        })

      {:ok, _ungated} =
        Tasks.create_stage(%{
          plan_id: plan.id,
          position: 2,
          name: "Ungated Stage",
          description: "No gates at all."
        })

      :ok = PromptTemplates.seed_defaults()

      %{plan: plan, task: task}
    end

    test "emits the validation kinds the old private summariser preloaded and dropped", %{
      plan: plan
    } do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{plan: plan})

      [gated, ungated] = gathered.plan_payload.stages

      assert Enum.map(gated.validations, & &1.kind) |> Enum.sort() ==
               ["e2e_behavior", "manual_approval", "test_pass"]

      assert gated.e2e_expected == ["the architect annotation names the colliding module"]
      assert ungated.validations == []
    end

    test "emits the task description so the plan can be judged against its intent", %{plan: plan} do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{plan: plan})

      assert gathered.plan_payload.task_description =~ "Surface every gate kind"
      assert gathered.plan_payload.stage_count == 2
    end

    test "render_instruction/1 puts stage names, gate kinds and the intent in the prompt", %{
      plan: plan
    } do
      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "Gated Stage"
      assert rendered =~ "Ungated Stage"
      assert rendered =~ "test_pass"
      assert rendered =~ "manual_approval"
      assert rendered =~ "e2e_behavior"
      assert rendered =~ "e2e expects: the architect annotation names the colliding module"
      assert rendered =~ "Surface every gate kind"
      assert rendered =~ "(none — this stage is unprotected)"
    end
  end

  # ── gather_context/1 (public convenience) ─────────────────────────────────

  describe "gather_context/1" do
    setup do
      project = make_project("Gather1 Project")
      task = make_task(project.id, title: "Gather1 Task", status: "planning")
      plan = make_plan(task.id)

      %{plan: plan, task: task, project: project}
    end

    test "accepts a bare context map and returns the same shape as arity-2", %{plan: plan} do
      arity_1 = ArchitectureReviewPlan.gather_context(%{plan: plan})

      assert is_map(arity_1)

      for key <- [:plan_payload, :sibling_tasks, :adr_index] do
        assert Map.has_key?(arity_1, key)
      end
    end

    test "renders the refusal as a map rather than propagating the error tuple" do
      # The arity-2 Provider callback refuses; this convenience wrapper
      # must still hand back something formattable, because
      # `render_instruction/1` and eight call sites in this file assume a
      # map.
      refused = ArchitectureReviewPlan.gather_context(%{})

      assert refused.plan_payload.missing? == true
      assert refused.plan_payload.error == :no_plan_payload
      assert refused.sibling_tasks == []

      assert ArchitectureReviewPlan.render_instruction(refused) =~ "no plan summary available"
    end
  end

  # ── render_instruction/1 ──────────────────────────────────────────────────

  describe "render_instruction/1" do
    setup do
      project = make_project("Render Instruction Project")
      task = make_task(project.id, title: "Render Test", status: "planning")
      plan = make_plan(task.id)

      # Seed the template so the DB-render path is exercised.
      :ok = PromptTemplates.seed_defaults()

      context = ArchitectureReviewPlan.gather_context(%{plan: plan})

      %{context: context, task: task, plan: plan}
    end

    test "produces a non-empty string", %{context: context} do
      rendered = ArchitectureReviewPlan.render_instruction(context)

      assert is_binary(rendered)
      assert rendered != ""
      assert byte_size(rendered) > 200
    end

    test "carries a plan_summary section with the task id", %{context: context, task: task} do
      rendered = ArchitectureReviewPlan.render_instruction(context)

      # The prompt template mentions the plan_summary block and the
      # gather_context payload puts the task id into that block.
      assert rendered =~ "Plan summary"
      assert rendered =~ task.id
      assert rendered =~ "Render Test"
    end

    test "carries the three concern-check anchors (collision / adr_drift / dup_abstraction)",
         %{context: context} do
      rendered = ArchitectureReviewPlan.render_instruction(context)

      assert rendered =~ "collision"
      assert rendered =~ "adr_drift" or rendered =~ "ADR"
      assert rendered =~ "dup_abstraction" or rendered =~ "duplication"
    end

    test "renders even when the DB row is missing (fallback path)", %{context: context} do
      # Delete the seeded template row to exercise the fallback.
      case PromptTemplates.get_template_by_slug("architecture.review_plan.v1") do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end

      rendered = ArchitectureReviewPlan.render_instruction(context)

      assert is_binary(rendered)
      assert rendered != ""
      assert rendered =~ "Architect"
    end
  end

  # ── build_prompt/1 ────────────────────────────────────────────────────────

  describe "build_prompt/1" do
    setup do
      project = make_project("Build Prompt Project")
      task = make_task(project.id, title: "Build Prompt Task", status: "planning")
      plan = make_plan(task.id)

      :ok = PromptTemplates.seed_defaults()

      context = ArchitectureReviewPlan.gather_context(%{plan: plan})

      %{context: context}
    end

    test "returns {:ok, %{system:, user:}} with non-empty strings", %{context: context} do
      assert {:ok, %{system: system, user: user}} =
               ArchitectureReviewPlan.build_prompt(context)

      assert is_binary(system) and system != ""
      assert is_binary(user) and user != ""
    end

    test "system slot names the Architect role + additive contract", %{context: context} do
      {:ok, %{system: system}} = ArchitectureReviewPlan.build_prompt(context)

      assert system =~ "Architect"
      assert system =~ "additive"
    end
  end

  # ── handle_output/3 ───────────────────────────────────────────────────────

  describe "handle_output/3" do
    setup do
      project = make_project("Handle Output Project")
      task = make_task(project.id, title: "Handle Output Task", status: "planning")
      plan = make_plan(task.id)

      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      %{task: task, plan: plan, space: space}
    end

    test "posts the architect annotation to the task's execution space", ctx do
      output = %{"comments" => [%{"content" => "no collisions — plan looks clean"}]}

      trigger_meta = %{task_id: ctx.task.id, plan_id: ctx.plan.id, plan: ctx.plan}

      assert :ok = ArchitectureReviewPlan.handle_output(responsibility(), output, trigger_meta)

      messages = Platform.Chat.list_messages(ctx.space.id)

      architect_msg =
        Enum.find(messages, fn m ->
          is_binary(m.content) and String.contains?(m.content, "[architect]")
        end)

      assert architect_msg,
             "expected an architect-tagged annotation posted to the execution space"

      assert architect_msg.content =~ "no collisions"
    end

    test "returns :ok without crashing when task has no execution space" do
      # Task with no execution space — handle_output should log and skip.
      project = make_project("No Space Project")
      task = make_task(project.id, title: "No Space Task", status: "planning")

      trigger_meta = %{task_id: task.id}
      output = %{"comments" => [%{"content" => "test"}]}

      assert :ok = ArchitectureReviewPlan.handle_output(responsibility(), output, trigger_meta)
    end

    test "returns :ok when trigger_meta has no task_id", ctx do
      output = %{"comments" => [%{"content" => "test"}]}

      # No task_id in trigger_meta and no :plan struct either.
      assert :ok = ArchitectureReviewPlan.handle_output(responsibility(), output, %{})

      # Space should have no architect message.
      messages = Platform.Chat.list_messages(ctx.space.id)

      refute Enum.any?(messages, fn m ->
               is_binary(m.content) and String.contains?(m.content, "[architect]")
             end)
    end

    test "accepts a bare-string output payload", ctx do
      trigger_meta = %{task_id: ctx.task.id}

      assert :ok =
               ArchitectureReviewPlan.handle_output(
                 responsibility(),
                 "bare comment",
                 trigger_meta
               )

      messages = Platform.Chat.list_messages(ctx.space.id)

      assert Enum.any?(messages, fn m ->
               is_binary(m.content) and String.contains?(m.content, "bare comment")
             end)
    end
  end

  # ── handle_output/2 arity-2 forwards to arity-3 ───────────────────────────

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3 and returns :ok on empty trigger_meta" do
      # No task_id in trigger_meta → logs + returns :ok (contract: never
      # crash the Router).
      assert :ok = ArchitectureReviewPlan.handle_output(responsibility(), %{"comments" => []})
    end
  end

  # ── key/0 + template_slug/0 ───────────────────────────────────────────────

  describe "key/0 + template_slug/0" do
    test "key/0 matches the registered spec key" do
      [spec] = ArchitectureReviewPlan.register()
      assert ArchitectureReviewPlan.key() == spec.key
      assert ArchitectureReviewPlan.key() == "architecture.review_plan"
    end

    test "template_slug/0 matches the registered default_prompt_template" do
      [spec] = ArchitectureReviewPlan.register()
      assert ArchitectureReviewPlan.template_slug() == spec.default_prompt_template
      assert ArchitectureReviewPlan.template_slug() == "architecture.review_plan.v1"
    end
  end
end
