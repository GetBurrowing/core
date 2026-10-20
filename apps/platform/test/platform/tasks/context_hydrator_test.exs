defmodule Platform.Tasks.ContextHydratorTest do
  @moduledoc "Tests for Platform.Tasks.ContextHydrator — context cascade hydration."
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Context
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tasks.ContextHydrator

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp create_project(attrs \\ %{}) do
    {:ok, project} =
      Tasks.create_project(
        Map.merge(
          %{
            name: "Hydrator Project #{System.unique_integer([:positive])}",
            repo_url: "https://github.com/org/hydrator-test",
            tech_stack: %{"language" => "elixir", "framework" => "phoenix"},
            deploy_config: %{"target" => "fly"}
          },
          attrs
        )
      )

    project
  end

  defp create_epic(project, attrs \\ %{}) do
    {:ok, epic} =
      Tasks.create_epic(
        Map.merge(
          %{
            project_id: project.id,
            name: "Auth Epic",
            description: "Implement authentication",
            acceptance_criteria: "Users can log in and out"
          },
          attrs
        )
      )

    epic
  end

  defp create_task(project, epic \\ nil, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(
          %{
            project_id: project.id,
            epic_id: epic && epic.id,
            title: "Implement login",
            description: "Build the login flow",
            priority: "high",
            dependencies: [%{"task_id" => Ecto.UUID.generate(), "kind" => "blocks"}]
          },
          attrs
        )
      )

    task
  end

  defp create_approved_plan(task) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, stage1} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Code",
        description: "Write the code"
      })

    {:ok, stage2} =
      Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test", description: "Run tests"})

    {:ok, _v1} = Tasks.create_validation(%{stage_id: stage1.id, kind: "lint_pass"})
    {:ok, _v2} = Tasks.create_validation(%{stage_id: stage2.id, kind: "test_pass"})

    {:ok, plan} = Tasks.submit_plan_for_review(plan)
    {:ok, plan} = Tasks.approve_plan(plan, Ecto.UUID.generate())

    plan
  end

  defp snapshot_items(scope) do
    case Context.snapshot(scope) do
      {:ok, %{items: items}} -> items
      _ -> []
    end
  end

  defp item_map(items) do
    Map.new(items, fn item -> {item.key, item} end)
  end

  # ── Tests ────────────────────────────────────────────────────────────────

  describe "hydrate_for_run/2 with full hierarchy" do
    test "hydrates project + epic + task + plan items" do
      project = create_project()
      epic = create_epic(project)
      task = create_task(project, epic)
      _plan = create_approved_plan(task)

      run_id = Ecto.UUID.generate()
      assert {:ok, version} = ContextHydrator.hydrate_for_run(task.id, run_id)
      assert version > 0

      # Verify project-scoped items
      project_scope = %{project_id: project.id}
      project_items = snapshot_items(project_scope) |> item_map()

      assert project_items["project.name"].value == project.name
      assert project_items["project.repo_url"].value == project.repo_url
      assert project_items["project.name"].kind == :project_config

      # Verify epic-scoped items
      epic_scope = %{project_id: project.id, epic_id: epic.id}
      epic_items = snapshot_items(epic_scope) |> item_map()

      assert epic_items["epic.name"].value == epic.name
      assert epic_items["epic.description"].value == epic.description
      assert epic_items["epic.acceptance_criteria"].value == epic.acceptance_criteria
      assert epic_items["epic.name"].kind == :epic_context

      # Verify task-scoped items
      task_scope = %{project_id: project.id, epic_id: epic.id, task_id: task.id}
      task_items = snapshot_items(task_scope) |> item_map()

      assert task_items["task.title"].value == task.title
      assert task_items["task.description"].value == task.description
      assert task_items["task.priority"].value == "high"
      assert task_items["task.title"].kind == :task_description

      # Verify plan stage items in task scope
      assert task_items["plan.stage.1.title"].value == "Code"
      assert task_items["plan.stage.1.description"].value == "Write the code"
      assert task_items["plan.stage.2.title"].value == "Test"
      assert task_items["plan.stage.1.title"].kind == :task_metadata

      # Verify validations are serialized
      v1 = Jason.decode!(task_items["plan.stage.1.validations"].value)
      assert "lint_pass" in v1

      v2 = Jason.decode!(task_items["plan.stage.2.validations"].value)
      assert "test_pass" in v2
    end
  end

  describe "hydrate_for_run/2 without epic" do
    test "hydrates project + task directly (no epic session)" do
      project = create_project()
      task = create_task(project, nil)

      run_id = Ecto.UUID.generate()
      assert {:ok, version} = ContextHydrator.hydrate_for_run(task.id, run_id)
      assert version > 0

      # Project items exist
      project_scope = %{project_id: project.id}
      project_items = snapshot_items(project_scope) |> item_map()
      assert project_items["project.name"].value == project.name

      # Task items exist (scope has nil epic_id)
      task_scope = %{project_id: project.id, task_id: task.id}
      task_items = snapshot_items(task_scope) |> item_map()
      assert task_items["task.title"].value == task.title
    end
  end

  describe "hydrate_for_run/2 without plan" do
    test "hydrates project + epic + task context only" do
      project = create_project()
      epic = create_epic(project)
      task = create_task(project, epic)

      run_id = Ecto.UUID.generate()
      assert {:ok, version} = ContextHydrator.hydrate_for_run(task.id, run_id)
      assert version > 0

      # Task items exist but no plan items
      task_scope = %{project_id: project.id, epic_id: epic.id, task_id: task.id}
      task_items = snapshot_items(task_scope) |> item_map()

      assert task_items["task.title"].value == task.title
      refute Map.has_key?(task_items, "plan.stage.1.title")
    end
  end

  describe "hydrate_for_run/2 error cases" do
    test "returns error for non-existent task" do
      assert {:error, :task_not_found} =
               ContextHydrator.hydrate_for_run(Ecto.UUID.generate(), Ecto.UUID.generate())
    end
  end

  describe "hydrate_for_run/2 with attached canvases (task_attach_canvas stage 4)" do
    test "pushes task.canvas.<n>.{title,id,note} into the task-scoped session" do
      project = create_project()
      task = create_task(project, nil)

      {:ok, space} =
        Chat.create_space(%{
          name: "Hydrator Canvas Space",
          slug: "hydrator-canvas-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "user",
          participant_id: Ecto.UUID.generate(),
          display_name: "Author",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Hydrated sketch"
        })

      {:ok, _} =
        CanvasAttachments.attach_canvas(Platform.Access.Scope.system(), task.id, canvas.id,
          note: "render this",
          attached_by: %{kind: "user", id: participant.id}
        )

      run_id = Ecto.UUID.generate()
      assert {:ok, _version} = ContextHydrator.hydrate_for_run(task.id, run_id)

      task_scope = %{project_id: project.id, task_id: task.id}
      task_items = snapshot_items(task_scope) |> item_map()

      assert task_items["task.canvas.0.title"].value == "Hydrated sketch"
      assert task_items["task.canvas.0.id"].value == canvas.id
      assert task_items["task.canvas.0.note"].value == "render this"
      assert task_items["task.canvas.0.title"].kind == :task_metadata
    end
  end

  describe "telemetry" do
    test "emits [:platform, :tasks, :context_hydrated] event" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :tasks, :context_hydrated]
        ])

      project = create_project()
      task = create_task(project, nil)

      {:ok, _version} = ContextHydrator.hydrate_for_run(task.id, Ecto.UUID.generate())

      assert_received {[:platform, :tasks, :context_hydrated], ^ref, _measurements, metadata}
      assert metadata.task_id == task.id
    end
  end

  # ── stage ordering under a duplicate position (ticket 01a089e6) ──────────
  describe "hydrate_for_run/2 with two stages at one position" do
    # `current_approved_plan/1` preloads stages with a QUERY-LEVEL preload,
    # which REPLACES `Plan.has_many(:stages)`'s `preload_order` rather than
    # merging with it — so the association's tiebreak does not reach here and
    # has to be repeated. `asc: :position` alone is not a total order:
    # `position` is not unique (no unique index on `(plan_id, position)`, no
    # uniqueness validation; "Stages must have unique positions" lives only in
    # prose in `plan_create`'s tool description).
    #
    # The consequence is sharper here than at most read sites, because
    # `push_plan_items/2` keys every item on the stage's POSITION and
    # `push_items/3` calls `Context.put_item/4` in list order. Two stages at
    # one position therefore COLLIDE on `plan.stage.1.*` and the LAST write
    # wins — so the order of the preload decides which stage's description the
    # executing agent is hydrated with. Without a tiebreak that is whatever
    # order the scan produced, and two runs of the same plan can disagree.
    #
    # WHICH of the two wins is not the property being asserted (ascending id
    # plus last-write-wins makes it the higher id, and that is a consequence,
    # not a design goal). The property is that it is the SAME one every time.
    #
    # THE FIXTURE MINTS THE DUPLICATE'S ID BEFORE THE PLAN EXISTS and inserts
    # the row AFTER it, because two conditions have to hold at once or this
    # test passes with or without the tiebreak:
    #
    #   1. Two stages must SHARE a `position`.
    #   2. Their PHYSICAL order must disagree with their `id` order —
    #      otherwise a bare `ORDER BY position` returns id order by accident.
    #      Minting first and inserting last is what produces the
    #      disagreement; `Tasks.create_stage/1` cannot, since it mints each id
    #      as it inserts and the two always agree there.
    test "the colliding plan.stage item is resolved the same way on every hydration" do
      # Minted FIRST, so it is the LOWEST id of the three stages...
      duplicate_id = Platform.Types.UUIDv7.generate()

      project = create_project()
      task = create_task(project)
      plan = create_approved_plan(task)

      [code_stage | _] = Tasks.list_stages(plan.id)
      assert code_stage.name == "Code"
      assert code_stage.position == 1

      # ...asserted rather than assumed, since the whole test turns on it.
      assert duplicate_id < code_stage.id

      # ...and inserted LAST, so heap order is the reverse of id order for the
      # tied pair.
      %Platform.Tasks.Stage{}
      |> Platform.Tasks.Stage.changeset(%{
        plan_id: plan.id,
        position: 1,
        name: "Duplicate",
        description: "the legacy duplicate at position 1"
      })
      |> Ecto.Changeset.put_change(:id, duplicate_id)
      |> Platform.Repo.insert!()

      # The tie is asserted, not assumed — and doubles as the standing proof
      # that the schema accepts two stages at one position.
      assert 2 ==
               Platform.Repo.aggregate(
                 from(s in Platform.Tasks.Stage,
                   where: s.plan_id == ^plan.id and s.position == 1
                 ),
                 :count
               )

      task_scope = %{project_id: project.id, epic_id: nil, task_id: task.id}

      # Hydrated three times, asserting the VALUE each time rather than that
      # the runs agree with each other: one lucky scan satisfies "they agree".
      for _ <- 1..3 do
        assert {:ok, _} = ContextHydrator.hydrate_for_run(task.id, Ecto.UUID.generate())

        items = task_scope |> snapshot_items() |> item_map()

        assert items["plan.stage.1.title"].value == "Code"
        assert items["plan.stage.1.description"].value == "Write the code"
        assert items["plan.stage.2.title"].value == "Test"
      end
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  describe "UUID boundary: hydrate_for_run/2 task_id comes off a dispatch payload" do
    test "a malformed task id reports :task_not_found rather than raising" do
      assert {:error, :task_not_found} =
               ContextHydrator.hydrate_for_run("higginshigginsxx", Ecto.UUID.generate())

      assert {:error, :task_not_found} =
               ContextHydrator.hydrate_for_run("higgins", Ecto.UUID.generate())
    end
  end
end
