defmodule Platform.Tasks.StageTest do
  use Platform.DataCase, async: true

  alias Platform.Tasks

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Stage Project"})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Stage Task"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    %{plan: plan}
  end

  describe "create_stage/1" do
    test "creates a stage with valid attrs", %{plan: plan} do
      assert {:ok, stage} =
               Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      assert stage.name == "Build"
      assert stage.position == 1
      assert stage.status == "pending"
    end

    test "fails without required fields" do
      assert {:error, changeset} = Tasks.create_stage(%{})
      errors = errors_on(changeset)
      assert errors[:plan_id]
      assert errors[:position]
      assert errors[:name]
    end

    # ADR-0046 member 9 stage 4 replaces the three 019f5d47 round-trip tests
    # that lived here with the two guards below. Stage-level responsibility is
    # retired: designer involvement comes from the pre-plan design step.
    test "the responsibility field is gone from the schema", %{plan: _plan} do
      fields = Platform.Tasks.Stage.__schema__(:fields)

      refute :responsibility in fields

      # POSITIVE CONTROL. Without this the refute above passes just as well
      # against a typo'd module name or an empty field list — it proves the
      # `__schema__(:fields)` call is really reaching this schema and that a
      # field which IS present is reported.
      assert :expected_artifacts in fields
    end

    test "the responsibility COLUMN is gone from the stages table" do
      # The schema refute above is satisfiable by editing `stage.ex` alone and
      # skipping the migration entirely — the column would still be on the
      # table. This is the persist-side half of the same claim: one assertion
      # per side of the schema/persist boundary.
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Platform.Repo,
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'stages'",
          []
        )

      columns = List.flatten(rows)

      refute "responsibility" in columns

      # POSITIVE CONTROL for the query itself: a typo'd table name returns an
      # empty result set and the refute passes vacuously.
      assert "expected_artifacts" in columns
    end

    test "tolerates an un-updated caller still passing responsibility", %{plan: plan} do
      # `cast/3` drops unknown keys, so an internal caller that has not caught
      # up does not crash — it just loses the value. Mirrors the MCP-surface
      # tolerance decided in stage 3.
      assert {:ok, stage} =
               Tasks.create_stage(%{
                 plan_id: plan.id,
                 position: 1,
                 name: "Build",
                 responsibility: "designer"
               })

      assert stage.name == "Build"
      refute Map.has_key?(stage, :responsibility)
    end
  end

  describe "list_stages/1" do
    test "returns stages ordered by position", %{plan: plan} do
      {:ok, _} = Tasks.create_stage(%{plan_id: plan.id, position: 2, name: "Test"})
      {:ok, _} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})

      stages = Tasks.list_stages(plan.id)
      assert Enum.map(stages, & &1.name) == ["Build", "Test"]
    end

    # Ticket 01a089e6, site 2. `list_stages/1` is the public read behind the
    # `stage_list` MCP tool, so its order is visible to every agent on the
    # board. `asc: :position` alone is only a total order if positions are
    # distinct, and nothing enforces that — see the `preload_order` comment
    # on `Platform.Tasks.Plan` and the `plan_test.exs` fixture this one
    # copies for the full argument: no unique index on `(plan_id, position)`,
    # no uniqueness validation in `Stage.changeset/2`, and "Stages must have
    # unique positions" living only in a tool description.
    #
    # THE FIXTURE, same two conditions as every other site on this ticket:
    #
    #   1. Two stages must SHARE a `position` — with distinct positions the
    #      tiebreak is never consulted.
    #   2. Their PHYSICAL (heap) order must disagree with their `id` order —
    #      otherwise a bare `ORDER BY position` returns id order by
    #      accident. `Tasks.create_stage/1` cannot produce (2): it mints
    #      each id as it inserts, so id order and heap order always agree.
    #      The rows go in directly, with pre-chosen ids, HIGHEST FIRST, so
    #      heap order is the exact reverse of id order.
    #
    # Read three times and assert the ID ORDER each time, rather than that
    # the reads agree with each other — a single lucky scan satisfies
    # agreement, and the claim here is stronger than that: the order is
    # TOTAL and STABLE across independent reads, not merely self-consistent.
    test "a position tie is broken by id, identically on every read", %{plan: plan} do
      [low, high] =
        Enum.sort([Platform.Types.UUIDv7.generate(), Platform.Types.UUIDv7.generate()])

      insert_tied = fn id, name ->
        %Platform.Tasks.Stage{}
        |> Platform.Tasks.Stage.changeset(%{plan_id: plan.id, position: 1, name: name})
        |> Ecto.Changeset.put_change(:id, id)
        |> Platform.Repo.insert!()
      end

      # HIGHEST ID FIRST: heap order becomes the exact reverse of id order.
      insert_tied.(high, "Later")
      insert_tied.(low, "Earlier")

      # The tie is asserted, not assumed — and doubles as the standing proof
      # that the schema accepts two stages at one position.
      assert 2 ==
               Platform.Repo.aggregate(
                 from(s in Platform.Tasks.Stage,
                   where: s.plan_id == ^plan.id and s.position == 1
                 ),
                 :count
               )

      for _ <- 1..3 do
        stages = Tasks.list_stages(plan.id)
        assert Enum.map(stages, & &1.id) == [low, high]
        assert Enum.map(stages, & &1.name) == ["Earlier", "Later"]
      end
    end
  end

  describe "transition_stage/2" do
    test "pending → running → passed", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

      assert {:ok, stage} = Tasks.transition_stage(stage, "running")
      assert stage.status == "running"
      assert stage.started_at != nil

      assert {:ok, stage} = Tasks.transition_stage(stage, "passed")
      assert stage.status == "passed"
      assert stage.completed_at != nil
    end

    test "running → failed → running (retry)", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      {:ok, stage} = Tasks.transition_stage(stage, "running")
      {:ok, stage} = Tasks.transition_stage(stage, "failed")
      assert stage.status == "failed"

      assert {:ok, stage} = Tasks.transition_stage(stage, "running")
      assert stage.status == "running"
    end

    test "pending → skipped", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      assert {:ok, stage} = Tasks.transition_stage(stage, "skipped")
      assert stage.status == "skipped"
    end

    test "rejects invalid transitions", %{plan: plan} do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
      assert {:error, :invalid_transition} = Tasks.transition_stage(stage, "passed")
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
