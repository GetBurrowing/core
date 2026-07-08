defmodule Platform.Responsibilities.Handlers.ArchitectureAuditDiffTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.ArchitectureAuditDiff` —
  the Architect role bundle's post-executor drift-audit handler
  (ADR-0044 stage 4, task `019f3da3`).

  Stage 1 shipped the registration placeholder. Stage 4 (this test
  file's target) wires the stage-complete hook in
  `Platform.Tasks.PlanEngine.transition_stage/2` and fills in the real
  handler body: `gather_context/2`, `render_instruction/1`,
  `build_prompt/1`, and `handle_output/3`. The v1 limitation (no git
  diff at signal time) is documented in the moduledoc; tests here lock
  the shape the handler produces regardless.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Responsibilities.Handlers.ArchitectureAuditDiff
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: ArchitectureAuditDiff.key(),
      feature: "architecture",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "stage:completed"},
      scope: "per_project",
      context_provided: ["stage_diff", "planned_shape", "org_memory_entries"],
      enabled: true
    }
  end

  defp make_project(name \\ "Audit Diff Project") do
    {:ok, project} = Tasks.create_project(%{name: name})
    project
  end

  defp make_task(project_id, opts) do
    attrs = %{
      project_id: project_id,
      title: Keyword.get(opts, :title, "Audit Diff Task"),
      status: Keyword.get(opts, :status, "in_progress")
    }

    {:ok, task} = Tasks.create_task(attrs)
    task
  end

  defp make_plan(task_id) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task_id})
    plan
  end

  defp make_stage(plan_id, opts) do
    attrs = %{
      plan_id: plan_id,
      position: Keyword.get(opts, :position, 1),
      name: Keyword.get(opts, :name, "Ship the feature"),
      description:
        Keyword.get(
          opts,
          :description,
          "Edit only apps/platform/lib/platform/tasks.ex. Add a helper. Ship tests."
        )
    }

    {:ok, stage} = Tasks.create_stage(attrs)

    stage =
      case Keyword.get(opts, :status) do
        nil ->
          stage

        status ->
          stage
          |> Ecto.Changeset.change(status: status)
          |> Repo.update!()
      end

    stage
  end

  # ── register/0 shape guard ────────────────────────────────────────────────

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = ArchitectureAuditDiff.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "architecture.audit_diff"
      assert spec.feature == "architecture"
      assert spec.trigger_kind == "event_topic"
      assert spec.trigger_config == %{"topic" => "stage:completed"}
      assert spec.scope == "per_project"

      assert spec.context_provided ==
               ["stage_diff", "planned_shape", "org_memory_entries"]

      assert spec.default_prompt_template == "architecture.audit_diff.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values — satisfies the M1 schema invariant" do
      [spec] = ArchitectureAuditDiff.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)
    end

    test "metadata names the owner + role + ADR + active status" do
      [spec] = ArchitectureAuditDiff.register()

      assert spec.metadata["owner"] == "platform.architecture"
      assert spec.metadata["role"] == "architect"
      assert spec.metadata["adr"] == "0044"
      # Stage 4 promotes the row from placeholder → active.
      assert spec.metadata["status"] == "active"
    end
  end

  # ── canonical_memory_flags/0 ─────────────────────────────────────────────

  describe "canonical_memory_flags/0" do
    test "carries the ORG_MEMORY entries the prompt names in-line" do
      flags = ArchitectureAuditDiff.canonical_memory_flags()

      keys = Enum.map(flags, & &1.key) |> MapSet.new()

      # These four are shipped as of stage 4 — regressing any of them
      # silently weakens the audit's usefulness. If Rowan retires one or
      # adds another, update this assertion together with the handler.
      assert MapSet.member?(keys, "ETS for ephemeral state")
      assert MapSet.member?(keys, "Suite ToolSurface smell")
      assert MapSet.member?(keys, "Correctness over shortcuts")
      assert MapSet.member?(keys, "Stack rollup ship")
    end

    test "every flag carries a non-empty note" do
      for %{key: key, note: note} <- ArchitectureAuditDiff.canonical_memory_flags() do
        assert is_binary(key) and key != ""
        assert is_binary(note) and note != "", "#{key} flag must carry a non-empty note"
      end
    end
  end

  # ── gather_context/2 ──────────────────────────────────────────────────────

  describe "gather_context/2" do
    setup do
      project = make_project()
      task = make_task(project.id, title: "Stage-Complete Task", status: "in_progress")
      plan = make_plan(task.id)

      stage =
        make_stage(plan.id,
          position: 3,
          name: "Wire the drift hook",
          description: "Edit only apps/platform/lib/platform/tasks/plan_engine.ex. Add a helper.",
          status: "passed"
        )

      %{project: project, task: task, plan: plan, stage: stage}
    end

    test "populates planned_shape with stage + plan + task metadata", ctx do
      {:ok, gathered} =
        ArchitectureAuditDiff.gather_context(responsibility(), %{
          stage: ctx.stage,
          plan: ctx.plan,
          task: ctx.task
        })

      shape = Map.get(gathered, :planned_shape)

      assert shape.stage_id == ctx.stage.id
      assert shape.stage_name == "Wire the drift hook"
      assert shape.stage_position == 3
      assert shape.stage_description =~ "plan_engine.ex"
      assert shape.plan_id == ctx.plan.id
      assert shape.task_id == ctx.task.id
      assert shape.task_title == "Stage-Complete Task"
      assert shape.project_id == ctx.project.id
    end

    test "stage_diff slot advertises the v1 limitation explicitly", ctx do
      {:ok, gathered} =
        ArchitectureAuditDiff.gather_context(responsibility(), %{
          stage: ctx.stage,
          plan: ctx.plan,
          task: ctx.task
        })

      diff = Map.get(gathered, :stage_diff)

      assert diff.missing? == true
      assert diff.note =~ "v1 limitation"
      assert diff.note =~ "planned shape"
    end

    test "org_memory_entries carries the canonical flag list", ctx do
      {:ok, gathered} =
        ArchitectureAuditDiff.gather_context(responsibility(), %{
          stage: ctx.stage,
          plan: ctx.plan,
          task: ctx.task
        })

      entries = Map.get(gathered, :org_memory_entries)
      assert is_list(entries)
      assert length(entries) == length(ArchitectureAuditDiff.canonical_memory_flags())
    end

    test "resolves stage/plan/task from ids when structs are absent", ctx do
      {:ok, gathered} =
        ArchitectureAuditDiff.gather_context(responsibility(), %{
          stage_id: ctx.stage.id,
          plan_id: ctx.plan.id,
          task_id: ctx.task.id
        })

      shape = Map.get(gathered, :planned_shape)
      assert shape.stage_id == ctx.stage.id
      assert shape.task_id == ctx.task.id
    end

    test "handles missing stage/plan/task without crashing" do
      # Progressive-enhancement contract: no side effect when the trigger
      # meta is malformed; the handler must still return {:ok, ctx}.
      assert {:ok, gathered} = ArchitectureAuditDiff.gather_context(responsibility(), %{})

      assert Map.has_key?(gathered, :planned_shape)
      assert Map.has_key?(gathered, :stage_diff)
      assert Map.has_key?(gathered, :org_memory_entries)
    end
  end

  # ── gather_context/1 (public convenience) ─────────────────────────────────

  describe "gather_context/1" do
    setup do
      project = make_project("Gather1 Audit Project")
      task = make_task(project.id, title: "Gather1 Audit Task", status: "in_progress")
      plan = make_plan(task.id)
      stage = make_stage(plan.id, status: "passed")

      %{stage: stage, plan: plan, task: task}
    end

    test "accepts a bare context map and returns the same shape as arity-2", %{
      stage: stage,
      plan: plan,
      task: task
    } do
      arity_1 = ArchitectureAuditDiff.gather_context(%{stage: stage, plan: plan, task: task})

      assert is_map(arity_1)

      for key <- [:planned_shape, :stage_diff, :org_memory_entries] do
        assert Map.has_key?(arity_1, key)
      end
    end
  end

  # ── render_instruction/1 ──────────────────────────────────────────────────

  describe "render_instruction/1" do
    setup do
      project = make_project("Render Audit Project")
      task = make_task(project.id, title: "Render Audit Task", status: "in_progress")
      plan = make_plan(task.id)

      stage =
        make_stage(plan.id,
          name: "Wire drift hook",
          description: "Edit apps/platform/lib/platform/tasks/plan_engine.ex — add hook helper.",
          status: "passed"
        )

      # Seed the template so the DB-render path is exercised.
      :ok = PromptTemplates.seed_defaults()

      context =
        ArchitectureAuditDiff.gather_context(%{stage: stage, plan: plan, task: task})

      %{context: context, task: task, stage: stage}
    end

    test "produces a non-empty string", %{context: context} do
      rendered = ArchitectureAuditDiff.render_instruction(context)

      assert is_binary(rendered)
      assert rendered != ""
      assert byte_size(rendered) > 200
    end

    test "carries a planned_shape section with the task id + stage name", %{
      context: context,
      task: task,
      stage: stage
    } do
      rendered = ArchitectureAuditDiff.render_instruction(context)

      assert rendered =~ "Planned shape"
      assert rendered =~ task.id
      assert rendered =~ stage.name
    end

    test "names the four concern-check anchors (divergence / new_dep / migration / memory_violation)",
         %{context: context} do
      rendered = ArchitectureAuditDiff.render_instruction(context)

      assert rendered =~ "divergence" or rendered =~ "Divergence"
      assert rendered =~ "new_dep" or rendered =~ "new dep"
      assert rendered =~ "migration" or rendered =~ "Migration"
      assert rendered =~ "memory_violation" or rendered =~ "durable"
    end

    test "surfaces the ORG_MEMORY entry keys the canonical flag list carries", %{context: context} do
      rendered = ArchitectureAuditDiff.render_instruction(context)

      # The prompt template renders each memory entry with `[<key>]` — the
      # handler's formatter guarantees the square-bracketed key appears
      # verbatim so the agent can cite them the same way.
      assert rendered =~ "[ETS for ephemeral state]"
      assert rendered =~ "[Suite ToolSurface smell]"
    end

    test "advertises the v1 diff limitation in the shipped-diff section", %{context: context} do
      rendered = ArchitectureAuditDiff.render_instruction(context)

      assert rendered =~ "v1 limitation" or rendered =~ "planned shape"
    end

    test "renders even when the DB row is missing (fallback path)", %{context: context} do
      # Delete the seeded template row to exercise the fallback.
      case PromptTemplates.get_template_by_slug("architecture.audit_diff.v1") do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end

      rendered = ArchitectureAuditDiff.render_instruction(context)

      assert is_binary(rendered)
      assert rendered != ""
      assert rendered =~ "Architect"
    end
  end

  # ── build_prompt/1 ────────────────────────────────────────────────────────

  describe "build_prompt/1" do
    setup do
      project = make_project("Build Prompt Audit Project")
      task = make_task(project.id, title: "Build Prompt Audit Task", status: "in_progress")
      plan = make_plan(task.id)
      stage = make_stage(plan.id, status: "passed")

      :ok = PromptTemplates.seed_defaults()

      context = ArchitectureAuditDiff.gather_context(%{stage: stage, plan: plan, task: task})

      %{context: context}
    end

    test "returns {:ok, %{system:, user:}} with non-empty strings", %{context: context} do
      assert {:ok, %{system: system, user: user}} =
               ArchitectureAuditDiff.build_prompt(context)

      assert is_binary(system) and system != ""
      assert is_binary(user) and user != ""
    end

    test "system slot names the Architect role + additive contract + drift-audit path", %{
      context: context
    } do
      {:ok, %{system: system}} = ArchitectureAuditDiff.build_prompt(context)

      assert system =~ "Architect"
      assert system =~ "additive"
      assert system =~ "drift-audit" or system =~ "drift"
    end
  end

  # ── handle_output/3 ───────────────────────────────────────────────────────

  describe "handle_output/3" do
    setup do
      project = make_project("Audit Handle Output Project")
      task = make_task(project.id, title: "Audit Handle Output Task", status: "in_progress")
      plan = make_plan(task.id)
      stage = make_stage(plan.id, status: "passed")

      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      %{task: task, plan: plan, stage: stage, space: space}
    end

    test "posts the architect annotation to the task's execution space", ctx do
      output = %{
        "annotations" => [%{"content" => "no drift — shipped stage matches the plan"}]
      }

      trigger_meta = %{
        task_id: ctx.task.id,
        plan_id: ctx.plan.id,
        stage_id: ctx.stage.id,
        stage: ctx.stage,
        plan: ctx.plan,
        task: ctx.task
      }

      assert :ok = ArchitectureAuditDiff.handle_output(responsibility(), output, trigger_meta)

      messages = Platform.Chat.list_messages(ctx.space.id)

      architect_msg =
        Enum.find(messages, fn m ->
          is_binary(m.content) and String.contains?(m.content, "[architect | audit_diff]")
        end)

      assert architect_msg,
             "expected an architect|audit_diff-tagged annotation posted to the execution space"

      assert architect_msg.content =~ "no drift"
    end

    test "accepts a note-shaped annotation payload", ctx do
      output = %{
        "annotations" => [%{"note" => "divergence: touched prompt_templates.ex too"}]
      }

      trigger_meta = %{task_id: ctx.task.id, plan: ctx.plan}

      assert :ok = ArchitectureAuditDiff.handle_output(responsibility(), output, trigger_meta)

      messages = Platform.Chat.list_messages(ctx.space.id)

      assert Enum.any?(messages, fn m ->
               is_binary(m.content) and String.contains?(m.content, "divergence")
             end)
    end

    test "returns :ok without crashing when task has no execution space" do
      project = make_project("No Space Audit Project")
      task = make_task(project.id, title: "No Space Audit Task", status: "in_progress")

      trigger_meta = %{task_id: task.id}
      output = %{"annotations" => [%{"content" => "test"}]}

      assert :ok = ArchitectureAuditDiff.handle_output(responsibility(), output, trigger_meta)
    end

    test "returns :ok when trigger_meta has no task_id", ctx do
      output = %{"annotations" => [%{"content" => "test"}]}

      assert :ok = ArchitectureAuditDiff.handle_output(responsibility(), output, %{})

      messages = Platform.Chat.list_messages(ctx.space.id)

      refute Enum.any?(messages, fn m ->
               is_binary(m.content) and String.contains?(m.content, "[architect | audit_diff]")
             end)
    end

    test "resolves task_id from a plan struct in trigger_meta", ctx do
      output = %{"annotations" => [%{"content" => "resolved via plan"}]}

      trigger_meta = %{plan: ctx.plan}

      assert :ok = ArchitectureAuditDiff.handle_output(responsibility(), output, trigger_meta)

      messages = Platform.Chat.list_messages(ctx.space.id)

      assert Enum.any?(messages, fn m ->
               is_binary(m.content) and String.contains?(m.content, "resolved via plan")
             end)
    end

    test "accepts a bare-string output payload", ctx do
      trigger_meta = %{task_id: ctx.task.id}

      assert :ok =
               ArchitectureAuditDiff.handle_output(
                 responsibility(),
                 "bare annotation",
                 trigger_meta
               )

      messages = Platform.Chat.list_messages(ctx.space.id)

      assert Enum.any?(messages, fn m ->
               is_binary(m.content) and String.contains?(m.content, "bare annotation")
             end)
    end

    test "does not double-prefix an annotation that already carries the architect tag", ctx do
      output = %{
        "annotations" => [%{"content" => "[architect | audit_diff] already-prefixed clean"}]
      }

      trigger_meta = %{task_id: ctx.task.id}

      assert :ok = ArchitectureAuditDiff.handle_output(responsibility(), output, trigger_meta)

      messages = Platform.Chat.list_messages(ctx.space.id)

      architect_msg =
        Enum.find(messages, fn m ->
          is_binary(m.content) and String.contains?(m.content, "already-prefixed")
        end)

      assert architect_msg

      # Prefix should appear exactly once — no `[architect | audit_diff] [architect | audit_diff]`.
      refute architect_msg.content =~ "[architect | audit_diff] [architect | audit_diff]"
    end
  end

  # ── handle_output/2 arity-2 forwards to arity-3 ───────────────────────────

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3 and returns :ok on empty trigger_meta" do
      # No task_id in trigger_meta → logs + returns :ok (contract: never
      # crash the Router).
      assert :ok = ArchitectureAuditDiff.handle_output(responsibility(), %{"annotations" => []})
    end
  end

  # ── key/0 + template_slug/0 ───────────────────────────────────────────────

  describe "key/0 + template_slug/0" do
    test "key/0 matches the registered spec key" do
      [spec] = ArchitectureAuditDiff.register()
      assert ArchitectureAuditDiff.key() == spec.key
      assert ArchitectureAuditDiff.key() == "architecture.audit_diff"
    end

    test "template_slug/0 matches the registered default_prompt_template" do
      [spec] = ArchitectureAuditDiff.register()
      assert ArchitectureAuditDiff.template_slug() == spec.default_prompt_template
      assert ArchitectureAuditDiff.template_slug() == "architecture.audit_diff.v1"
    end
  end
end
