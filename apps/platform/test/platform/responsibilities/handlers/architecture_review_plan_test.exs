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
  alias Platform.Repo
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Tasks.Plan

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

  # `Repo.insert!` rather than `Tasks.create_task/1`: a 20-sibling
  # fixture would fan 20 broadcasts at the singleton `TaskRouterWatcher`,
  # which evaluates off this test's sandbox connection (019fa003-091a).
  # The context function is not what these tests are about.
  defp insert_bare_task!(project_id, title) do
    now = DateTime.utc_now()

    %Platform.Tasks.Task{}
    |> Ecto.Changeset.change(%{
      project_id: project_id,
      title: title,
      status: "in_progress",
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp insert_sibling!(project_id, title) do
    task = insert_bare_task!(project_id, title)
    _plan = make_plan(task.id, status: "pending_review")
    task
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

      # Stage 4 wrapped the bare list in a scope + truncation envelope;
      # the tasks themselves keep the same per-sibling shape.
      assert siblings.scope == :project_window
      assert is_list(siblings.tasks)

      sibling_ids = Enum.map(siblings.tasks, & &1.task_id) |> MapSet.new()

      assert MapSet.member?(sibling_ids, ctx.sibling_planning.id)
      assert MapSet.member?(sibling_ids, ctx.sibling_in_progress.id)
      assert MapSet.member?(sibling_ids, ctx.sibling_in_review.id)
    end

    test "excludes the task under review itself", ctx do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{
          plan: ctx.plan_under_review
        })

      sibling_ids = Enum.map(gathered.sibling_tasks.tasks, & &1.task_id) |> MapSet.new()

      refute MapSet.member?(sibling_ids, ctx.task_under_review.id),
             "the task being reviewed must not appear in its own sibling list"
    end

    test "excludes done and cancelled statuses", ctx do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{
          plan: ctx.plan_under_review
        })

      statuses = Enum.map(gathered.sibling_tasks.tasks, & &1.status)

      refute "done" in statuses
      refute "cancelled" in statuses
    end

    test "excludes tasks from other projects", ctx do
      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{
          plan: ctx.plan_under_review
        })

      titles = Enum.map(gathered.sibling_tasks.tasks, & &1.title)
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

    test "populates adr_index with parsed, flagged entries" do
      # Task 019f9b28-6ca7 stage 5: this test previously asserted
      # `is_list(gathered.adr_index)` with the comment "empty is fine
      # when docs/decisions isn't reachable" — which is precisely the
      # silent degradation the `:adr_index` slot removes. A bare list of
      # filenames cannot distinguish "unreachable" from "no decisions",
      # and it cannot say that four numbers in this directory name two
      # ADRs each. The slot returns a payload with `available?` and
      # per-entry flags instead.
      project = make_project("ADR Index Test Project")
      task = make_task(project.id, title: "ADR Index Task", status: "planning")
      plan = make_plan(task.id)

      {:ok, gathered} =
        ArchitectureReviewPlan.gather_context(responsibility(), %{plan: plan})

      index = gathered.adr_index

      assert is_map(index)
      assert Map.has_key?(index, :available?)
      assert Map.has_key?(index, :entries)

      if index.available? do
        assert index.total == length(index.entries)

        for entry <- index.entries do
          assert is_binary(entry.file)
          assert Map.has_key?(entry, :number_ambiguous)
          assert Map.has_key?(entry, :superseded_by)
        end
      else
        assert index.entries == []
        assert index.reason in [:adr_dir_unreachable, :adr_dir_unreadable, :adr_dir_empty]
      end
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
      assert Enum.any?(gathered.sibling_tasks.tasks, &(&1.task_id == ctx.sibling_planning.id))
    end

    test "the sibling block is never a refusal, unlike the plan payload", ctx do
      # Stage 3 made an unresolvable plan stop the dispatch. Stage 4
      # deliberately did NOT do the same for siblings: this project has
      # three, but a project with none must still get its review.
      solo_project = make_project("Solo Project")
      solo_task = make_task(solo_project.id, title: "Solo Task", status: "planning")
      solo_plan = make_plan(solo_task.id)

      assert {:ok, solo} =
               ArchitectureReviewPlan.gather_context(responsibility(), %{plan: solo_plan})

      assert solo.sibling_tasks.scope == :none
      assert solo.sibling_tasks.tasks == []

      # Positive control: the populated project still resolves siblings
      # through the identical code path.
      assert {:ok, populated} =
               ArchitectureReviewPlan.gather_context(responsibility(), %{
                 plan: ctx.plan_under_review
               })

      assert populated.sibling_tasks.total == 3
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
      assert refused.sibling_tasks.scope == :no_anchor
      assert refused.sibling_tasks.tasks == []

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

  # ── ADR-index rendering ───────────────────────────────────────────────────

  describe "render_instruction/1 — ADR index block" do
    setup do
      project = make_project("ADR Render Project")
      task = make_task(project.id, title: "ADR Render Task", status: "planning")
      plan = make_plan(task.id)

      :ok = PromptTemplates.seed_defaults()

      %{plan: plan}
    end

    test "renders title, status and the cite-by-filename instruction", %{plan: plan} do
      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "0044-architect-responsibility.md — Architect Responsibility [Accepted]"
      assert rendered =~ "CITE ADRs BY FILENAME, NOT BY NUMBER"
    end

    test "flags the colliding numbers inline, next to the entry", %{plan: plan} do
      # DETECTOR-adjacent: the old renderer printed 50 bare filenames.
      # A model reading that block has no way to know "ADR-0044" names
      # two documents, and the prompt used to tell it to cite by number.
      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "⚠ number 0044 is shared by another ADR — cite by filename"
      assert rendered =~ "⚠ number 0017 is shared by another ADR — cite by filename"
    end

    test "names the superseding document on the superseded entry", %{plan: plan} do
      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "⚠ superseded by 0041-org-memory-v2-wiki-system.md"
      assert rendered =~ "⚠ superseded by 0036-canvases-first-class-collaboration-surfaces.md"

      # Partial supersessions say so rather than retiring a live ADR.
      assert rendered =~
               "⚠ partially superseded by 0013-attention-routing-and-channel-policy.md"
    end

    test "the prompt no longer instructs the model to cite ADRs by number", %{plan: plan} do
      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      refute rendered =~ "Prefer citing the ADR by number"

      {:ok, %{system: system}} =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.build_prompt()

      refute system =~ "ADRs by number"
      assert system =~ "FILENAME"
    end

    test "a truncated index says so and names what it dropped", %{plan: plan} do
      # Stage 4's rule, applied here: a bound is only honest if the
      # rendered block admits to it. "All 50 ADRs" and "showing 5 of 50"
      # are different claims and the model cannot tell them apart from
      # the list alone.
      #
      # THE TOTAL TRACKS THE DIRECTORY. `total` in
      # `architecture_review_plan.ex:971` is `length(Path.wildcard(...))` over
      # `docs/decisions/*.md`, so EVERY new ADR moves this number and fails this
      # assertion. Bumped 49 -> 50 when ADR-0046 itself landed in the rollup
      # (branch `docs/adr-0046-design-arch-phases`), which is the file the whole
      # stack's citations point at. The bound and the admission are what this
      # test is for; the total is incidental to it and needs re-pinning on each
      # new ADR.
      Application.put_env(:platform, :adr_index_limit, 5)
      on_exit(fn -> Application.delete_env(:platform, :adr_index_limit) end)

      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "Showing the 5 highest-numbered of 50 ADRs"
      assert rendered =~ "older ADR(s) omitted"
      assert rendered =~ "0001-repository-shape-and-boundary.md"
      refute rendered =~ "0001-repository-shape-and-boundary.md — Repository Shape"
    end

    test "an unavailable index renders an instruction, not silence", %{plan: plan} do
      Application.put_env(:platform, :adr_dir, "/nonexistent/docs/decisions")
      on_exit(fn -> Application.delete_env(:platform, :adr_dir) end)

      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "ADR index unavailable"
      assert rendered =~ "Do not cite ADRs by number or filename in this pass"
    end
  end

  # ── sibling-block rendering ───────────────────────────────────────────────

  describe "render_instruction/1 — sibling truncation disclosure" do
    setup do
      :ok = PromptTemplates.seed_defaults()
      :ok
    end

    test "DETECTOR: names the scope and states how many siblings were dropped" do
      # This is the stage's detector. Remove the project-window cap and
      # the "showing 10 of 20" line disappears — the block silently
      # renders all 20 and the model has no way to know a cap exists.
      project = make_project("Truncation Disclosure Project")
      anchor = make_task(project.id, title: "Truncation Anchor", status: "planning")
      plan = make_plan(anchor.id)

      for n <- 1..20, do: insert_sibling!(project.id, "Windowed Sibling #{n}")

      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "[scope: project_window]"
      assert rendered =~ "showing 10 of 20 in-flight tasks in this project"
      assert rendered =~ "most recently updated first"
    end

    test "an untruncated window states the plain count instead of a 'showing N of M'" do
      # Positive control for the detector above: same renderer, same
      # code path, under the cap — the disclosure must not cry wolf.
      project = make_project("Untruncated Window Project")
      anchor = make_task(project.id, title: "Untruncated Anchor", status: "planning")
      plan = make_plan(anchor.id)

      for n <- 1..3, do: insert_sibling!(project.id, "Small Window Sibling #{n}")

      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "[scope: project_window] 3 in-flight tasks in this project"
      refute rendered =~ "showing 3 of 3"
    end

    test "discloses in-flight siblings dropped for having no submitted plan" do
      project = make_project("Unplanned Disclosure Project")
      anchor = make_task(project.id, title: "Unplanned Anchor", status: "planning")
      plan = make_plan(anchor.id)

      _planned = insert_sibling!(project.id, "Has A Plan")

      for n <- 1..2, do: insert_bare_task!(project.id, "No Plan #{n}")

      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "a further 2 in-flight task(s) in this project have no submitted plan"
      refute rendered =~ "No Plan 1"
    end

    test "a sibling-less project renders an explicit empty scope, not a blank block" do
      project = make_project("No Siblings Project")
      anchor = make_task(project.id, title: "Lonely Anchor", status: "planning")
      plan = make_plan(anchor.id)

      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "[scope: none] no sibling tasks"
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

    # ADR-0046 member 5 stage 4 REPLACED the assertion that used to live
    # here (`system =~ "additive"`). Stage 3 landed the guard in
    # `Tasks.approve_plan/3`, which made "additive, not a blocker" false;
    # a system slot still claiming it would contradict the user slot and
    # train the architect out of using the gate that now holds the plan.
    # The old assertion is not deleted so much as inverted — its absence
    # half is below.
    test "system slot names the Architect role + the GATE contract, not the old additive one",
         %{context: context} do
      {:ok, %{system: system}} = ArchitectureReviewPlan.build_prompt(context)

      assert system =~ "Architect"
      assert system =~ "HELD"
      assert system =~ "plan_architecture_verdict"

      for constraint <- Plan.architecture_constraints() do
        assert system =~ constraint,
               "system slot must enumerate the constraint vocabulary the tool enforces"
      end

      refute system =~ "additive"
      refute system =~ "do not block plan approval"
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

  # ── ADR-0046 member 5 stage 4: the EXTERNAL verdict surface ───────────────
  #
  # The native architect (`moore`, `kind: "native"` — stage 2's verified
  # finding) calls the MCP tool. An EXTERNAL architect gets a rendered
  # prompt and a one-shot completion with no tools, so its verdict can
  # only arrive as text in `handle_output/3`. Both funnel into
  # `Tasks.resolve_architecture_gate/3`; neither re-implements the state
  # machine.

  describe "handle_output/3 — architecture gate settlement" do
    setup do
      project = make_project("External Verdict Project #{System.unique_integer([:positive])}")
      task = make_task(project.id, title: "External Verdict Task", status: "planning")
      plan = make_plan(task.id, status: "pending_review")
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, gated} = Tasks.open_architecture_gate(plan, "external-architect")
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      %{task: task, plan: gated, stage: stage, space: space}
    end

    defp verdict_row(plan_id), do: Repo.get!(Plan, plan_id).architecture_verdict

    defp architect_messages(space_id) do
      space_id
      |> Platform.Chat.list_messages()
      |> Enum.filter(&(is_binary(&1.content) and String.contains?(&1.content, "[architect]")))
    end

    # PAIRED GUARD. Both halves in one test: the fenced-JSON half alone
    # would pass against a parser that resolved the gate on ANY output,
    # and the prose half alone would pass against one that resolved it on
    # NONE. The pair pins the discrimination.
    #
    # VACUITY CONTROL, MEASURED: replacing `parse_verdict/2`'s body with
    # `{:error, :unparseable}` makes half 1 fail (state `dispatch_failed`,
    # not `passed`) and half 2 pass. Replacing it with a constant
    # `{:ok, %{resolution: :pass, ...}}` makes half 2 fail. Neither half
    # is vacuous.
    test "a fenced-JSON verdict resolves the gate; prose falls open — and both post the annotation",
         ctx do
      fenced = """
      Reviewed the plan against the four constraints. Nothing crosses one.

      ```json
      {"verdict": "pass", "summary": "No new module, context, table or cross-context call."}
      ```
      """

      assert :ok =
               ArchitectureReviewPlan.handle_output(responsibility(), fenced, %{
                 task_id: ctx.task.id,
                 plan_id: ctx.plan.id
               })

      verdict = verdict_row(ctx.plan.id)
      assert verdict["state"] == "passed"
      assert verdict["summary"] =~ "No new module"
      refute Tasks.architecture_gate_open?(ctx.plan.id)

      assert [msg] = architect_messages(ctx.space.id)
      assert msg.content =~ "Reviewed the plan"

      # ── half 2: prose, on a fresh gate ──────────────────────────────
      task2 = make_task(ctx.task.project_id, title: "Prose Verdict Task", status: "planning")
      plan2 = make_plan(task2.id, status: "pending_review")
      {:ok, gated2} = Tasks.open_architecture_gate(plan2, "external-architect")
      {:ok, space2} = ExecutionSpace.find_or_create(task2.id)

      assert :ok =
               ArchitectureReviewPlan.handle_output(
                 responsibility(),
                 "Looks fine to me, no concerns worth raising.",
                 %{task_id: task2.id, plan_id: gated2.id}
               )

      verdict2 = verdict_row(gated2.id)

      # FALL OPEN. A model that answered in prose must not be able to
      # park a task forever (ADR-0046 decision 7).
      assert verdict2["state"] == "dispatch_failed"
      assert verdict2["summary"] =~ "unparseable_verdict"
      refute Tasks.architecture_gate_open?(gated2.id)

      # …AND the human-readable trace still happened. The gate and the
      # annotation must not be able to take each other down.
      assert [msg2] = architect_messages(space2.id)
      assert msg2.content =~ "Looks fine to me"
    end

    test "falling open records the architecture planning step as failed", ctx do
      # ADR-0046:83's conflation in miniature: "the plan proceeded" and
      # "the architect answered" must stay distinguishable. The recording
      # lives inside `resolve_architecture_gate/3`, so this asserts the
      # external path actually routes through it rather than writing its
      # own verdict.
      assert :ok =
               ArchitectureReviewPlan.handle_output(responsibility(), "no json here", %{
                 task_id: ctx.task.id,
                 plan_id: ctx.plan.id
               })

      outcomes = Repo.get!(Platform.Tasks.Task, ctx.task.id).planning_step_outcomes || %{}
      assert get_in(outcomes, ["architecture", "outcome"]) == "failed"
    end

    test "a reject with a valid finding resolves the gate as rejected", ctx do
      output = %{
        "comments" => [
          %{
            "content" =>
              ~s({"verdict":"reject","summary":"Boundary violation.","findings":[{"stage_id":"#{ctx.stage.id}","constraint":"module_boundary","detail":"Move the query behind the context."}]})
          }
        ]
      }

      assert :ok =
               ArchitectureReviewPlan.handle_output(responsibility(), output, %{
                 task_id: ctx.task.id,
                 plan: ctx.plan
               })

      verdict = verdict_row(ctx.plan.id)
      assert verdict["state"] == "rejected"
      assert [%{"constraint" => "module_boundary"}] = verdict["findings"]
    end

    # THE CLOSED VOCABULARY, ON THE SECOND SURFACE. The tool refuses a
    # style objection outright; this path has no caller to refuse to, so
    # it drops the unrepresentable finding — and a reject that reduces to
    # nothing actionable becomes no verdict at all rather than an
    # objection the planner cannot act on.
    test "a reject whose only finding is a style objection falls open, it does not store it",
         ctx do
      output =
        ~s({"verdict":"reject","summary":"Naming.","findings":[{"stage_id":"#{ctx.stage.id}","constraint":"naming","detail":"Rename it."}]})

      assert :ok =
               ArchitectureReviewPlan.handle_output(responsibility(), output, %{
                 task_id: ctx.task.id,
                 plan_id: ctx.plan.id
               })

      verdict = verdict_row(ctx.plan.id)
      assert verdict["state"] == "dispatch_failed"
      assert verdict["findings"] == []

      # PAIRED CONTROL: the identical payload with an allowed constraint
      # DOES store a rejection — see the reject test above, which uses the
      # same stage and detail with `module_boundary`.
    end

    test "a reject naming another plan's stage falls open rather than storing a foreign id",
         ctx do
      other_task = make_task(ctx.task.project_id, title: "Other Plan", status: "planning")
      other_plan = make_plan(other_task.id)
      {:ok, foreign} = Tasks.create_stage(%{plan_id: other_plan.id, position: 1, name: "F1"})

      output =
        ~s({"verdict":"reject","summary":"x","findings":[{"stage_id":"#{foreign.id}","constraint":"data_model","detail":"Widen it."}]})

      assert :ok =
               ArchitectureReviewPlan.handle_output(responsibility(), output, %{
                 task_id: ctx.task.id,
                 plan_id: ctx.plan.id
               })

      assert verdict_row(ctx.plan.id)["state"] == "dispatch_failed"
    end

    test "a duplicate reply is harmless — the gate is one-shot at this surface too", ctx do
      pass = ~s({"verdict":"pass","summary":"Clean."})
      meta = %{task_id: ctx.task.id, plan_id: ctx.plan.id}

      assert :ok = ArchitectureReviewPlan.handle_output(responsibility(), pass, meta)
      first = verdict_row(ctx.plan.id)

      # PRECONDITION, and it is load-bearing. Without it the equality
      # below holds trivially against code that never writes a verdict at
      # all — the row simply stays `pending` across both calls. Measured:
      # reverting the handler leaves this test GREEN without this line.
      assert first["state"] == "passed"

      reject =
        ~s({"verdict":"reject","summary":"Changed my mind.","findings":[{"stage_id":"#{ctx.stage.id}","constraint":"data_model","detail":"Widen it."}]})

      assert :ok = ArchitectureReviewPlan.handle_output(responsibility(), reject, meta)

      assert verdict_row(ctx.plan.id) == first
    end

    # NO-REGRESSION CONTROL, NOT A DETECTOR — declared as such. Against
    # the pre-stage handler this passes, because that handler also
    # returned `:ok` and posted the annotation. Its job is to prove the
    # verdict path did not break the trigger shape that has no plan to
    # settle, which is the shape `handle_output/2` and every pre-ADR-0046
    # dispatch takes.
    test "a trigger with no plan_id still posts the annotation and returns :ok", ctx do
      assert :ok =
               ArchitectureReviewPlan.handle_output(responsibility(), "bare note", %{
                 task_id: ctx.task.id
               })

      assert verdict_row(ctx.plan.id)["state"] == "pending"
      assert [msg] = architect_messages(ctx.space.id)
      assert msg.content =~ "bare note"
    end
  end

  describe "parse_verdict/2" do
    test "tolerates a bare object, a fenced block, and prose either side of one" do
      for body <- [
            ~s({"verdict":"pass","summary":"ok"}),
            "```json\n{\"verdict\":\"pass\",\"summary\":\"ok\"}\n```",
            "Here is my verdict.\n\n{\"verdict\":\"pass\",\"summary\":\"ok\"}\n\nHope that helps.",
            "```\n{\"verdict\":\"PASS\",\"summary\":\"ok\"}\n```"
          ] do
        assert {:ok, %{resolution: :pass, summary: "ok"}} =
                 ArchitectureReviewPlan.parse_verdict(body),
               "failed to parse: #{inspect(body)}"
      end
    end

    test "refuses prose, a non-pass/reject verdict word, and a findings-free reject" do
      for body <- [
            "The plan looks reasonable.",
            ~s({"verdict":"maybe","summary":"unsure"}),
            ~s({"verdict":"reject","summary":"bad"}),
            ~s({"summary":"no verdict key"}),
            ""
          ] do
        assert {:error, :unparseable} = ArchitectureReviewPlan.parse_verdict(body),
               "should not have parsed: #{inspect(body)}"
      end
    end
  end

  # ── ADR-0046 member 5 stage 4: the prompt, and why it has a guard ─────────
  #
  # THE ONE THAT MATTERS. Prompt-template content has no other guard in
  # this repo: a stale prompt would silently disable the whole feature
  # while every other test in the suite stayed green — the same class as
  # the escaped prompt-template mutation recorded on 2026-07-25. The
  # absence half and the positive half live in ONE test so a body that
  # merely deleted the old sentences without adding the new contract
  # cannot pass.

  describe "the architecture.review_plan.v1 body carries the gate contract" do
    setup do
      :ok = PromptTemplates.seed_defaults()

      project = make_project("Prompt Guard Project #{System.unique_integer([:positive])}")
      task = make_task(project.id, title: "Prompt Guard Task", status: "planning")
      plan = make_plan(task.id)

      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      %{rendered: rendered, shipped: shipped_body(), plan: plan}
    end

    # TWO SOURCES, AND THE DETONATION IS WHY.
    #
    # `render_instruction/1` reads the DB ROW; `default_content_for_slug/1`
    # is what the CODE ships (and the fallback a boot with no row uses).
    # Reverting this stage's `prompt_templates.ex` and re-running these
    # guards left them GREEN, because the force-update migration had
    # already written the new body into the test database and
    # `seed_defaults/0` is INSERT-only, so nothing put the old text back.
    # A guard that only reads the rendered output is guarding whatever is
    # in the database, not what the repository ships.
    #
    # Both halves earn their keep and neither is redundant: the shipped
    # half detonates on a code revert, the rendered half is the only one
    # that would catch a migration that never ran or an operator edit
    # that reverted the row in a live environment.
    defp shipped_body, do: PromptTemplates.default_content_for_slug("architecture.review_plan.v1")

    test "names all four constraints and the verdict tool, and NO LONGER claims it is additive",
         %{rendered: rendered, shipped: shipped} do
      for body <- [shipped, rendered] do
        for constraint <- Plan.architecture_constraints() do
          assert body =~ constraint,
                 "the prompt and the validator must speak one vocabulary — #{constraint} missing"
        end

        assert body =~ "plan_architecture_verdict"

        # The two sentences stage 3 made false. Both would actively train
        # the architect out of using the gate that now holds the plan.
        refute body =~ "additive, not a blocker"
        refute body =~ "regardless of what you find"
      end
    end

    test "carries the authority, the not-for-style reason, the fast-pass default and a bad example",
         %{rendered: rendered, shipped: shipped} do
      # Matched against a whitespace-normalised copy: the template is
      # hard-wrapped at ~90 columns, so a phrase assertion written
      # verbatim breaks the moment somebody re-wraps a paragraph. The
      # CLAIM is that the sentence is present, not where its newlines
      # fall. Both sources, for the reason above the previous test — they
      # are NOT compared to each other (the rendered copy has the four
      # `{{variable}}` slots substituted), they are each checked for the
      # same static prose.
      for flat <- [
            String.replace(shipped, ~r/\s+/, " "),
            String.replace(rendered, ~r/\s+/, " ")
          ] do
        # 1. AUTHORITY.
        assert flat =~ "it is held at `pending_review` until you answer"
        assert flat =~ "You must answer"

        # 3. NOT for taste/naming/style, WITH the reason — a model that
        #    understands the reason generalises where one following a
        #    rule does not.
        assert flat =~ "Explicitly NOT for taste, naming, or stylistic preference"
        assert flat =~ "gets switched off within a week"
        assert flat =~ "worse than no gate at all"

        # 4. FAST PASS, stated concretely rather than as an exhortation.
        assert flat =~ "no new module, no new context, no new table"
        assert flat =~ "a wrong reject costs a full replan cycle"

        # 5. The bad worked example, verbatim from the stage brief.
        assert flat =~ "This is unsound"
        assert flat =~ "WHAT TO CHANGE"
      end
    end

    test "states the deadline, and the number it states matches the code" do
      # A hardcoded number in a prompt is a claim about the system. Pin
      # the two together so a timeout change cannot silently make the
      # architect's mental model wrong.
      minutes = div(Tasks.architecture_gate_timeout_ms(), 60_000)

      body = PromptTemplates.default_content_for_slug("architecture.review_plan.v1")

      assert body =~ "**#{minutes} minutes**",
             "the prompt's stated deadline drifted from Tasks.architecture_gate_timeout_ms/0"

      assert body =~ "silence falls open"
    end

    test "the rendered prompt carries the plan_id and stage ids a finding needs", %{plan: plan} do
      # The reject contract requires a `stage_id` that belongs to the
      # plan, and `plan_architecture_verdict` refuses a foreign one. An
      # external architect has no tool with which to look ids up, so an
      # id that never reaches the prompt is an id it has to invent.
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Guarded stage"})

      rendered =
        %{plan: plan}
        |> ArchitectureReviewPlan.gather_context()
        |> ArchitectureReviewPlan.render_instruction()

      assert rendered =~ "plan_id: #{plan.id}"
      assert rendered =~ "stage_id: #{stage.id}"
    end
  end

  # ── the force-update migration actually moves a live row ──────────────────
  #
  # `20260708123000_force_update_architect_review_plan_template.exs` and
  # `20260726210000_..._citation_guidance.exs` have NO behavioural test —
  # they appear only in `context_t4_e2e_test.exs`'s migration allow-list,
  # which asserts the file exists, not that it does anything. Stated here
  # rather than left implicit, per the stage brief. This is the coverage.

  describe "20260726051455_force_update_architect_review_plan_gate_contract" do
    @migration_path Path.join([
                      __ENV__.file
                      |> Path.dirname()
                      |> Path.dirname()
                      |> Path.dirname()
                      |> Path.dirname()
                      |> Path.dirname(),
                      "priv/repo/migrations/20260726051455_force_update_architect_review_plan_gate_contract.exs"
                    ])

    @migration_module Platform.Repo.Migrations.ForceUpdateArchitectReviewPlanGateContract

    setup do
      unless Code.ensure_loaded?(@migration_module) do
        Code.require_file(@migration_path)
      end

      :ok = PromptTemplates.seed_defaults()
      :ok
    end

    test "overwrites an existing row still carrying the pre-gate body" do
      slug = "architecture.review_plan.v1"
      template = PromptTemplates.get_template_by_slug(slug)
      assert template, "seed_defaults/0 should have created the row"

      old_body = """
      You are the Architect. A plan just entered `pending_review`. You are
      **additive, not a blocker** — the architect annotates; it does NOT block plan
      approval. The plan advances to `pending_review` regardless of what you find.
      """

      {:ok, _} =
        PromptTemplates.update_template(template, %{
          content: old_body,
          description: "Output is additive — it does NOT block plan approval."
        })

      # Precondition — the row really is stale before the migration runs.
      assert PromptTemplates.get_template_by_slug(slug).content =~ "additive, not a blocker"

      assert :ok = apply(@migration_module, :up, [])

      refreshed = PromptTemplates.get_template_by_slug(slug)

      refute refreshed.content =~ "additive, not a blocker"
      refute refreshed.content =~ "regardless of what you find"
      assert refreshed.content =~ "plan_architecture_verdict"
      assert refreshed.description =~ "HELD"

      # `seed_defaults/0` is INSERT-only — this is the whole reason the
      # migration exists. Re-seeding must NOT restore the new body, or the
      # force-update would be redundant and this test would prove nothing.
      {:ok, _} = PromptTemplates.update_template(refreshed, %{content: old_body})
      :ok = PromptTemplates.seed_defaults()

      assert PromptTemplates.get_template_by_slug(slug).content =~ "additive, not a blocker",
             "seed_defaults/0 turned out to be an upsert — the force-update migration is unnecessary"
    end

    test "skips cleanly when the row does not exist" do
      case PromptTemplates.get_template_by_slug("architecture.review_plan.v1") do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end

      assert :ok = apply(@migration_module, :up, [])
      assert is_nil(PromptTemplates.get_template_by_slug("architecture.review_plan.v1"))
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
