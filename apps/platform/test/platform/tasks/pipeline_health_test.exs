defmodule Platform.Tasks.PipelineHealthTest do
  @moduledoc """
  What `PipelineHealth` must REFUSE to say, since the aggregate is the layer
  where an honest per-task decomposition turns into a confident chart:

    * an uninstrumented task is counted in the cohort and excluded from the
      aggregates — visibly, as two different numbers;
    * a phase nobody visited is `nil`, never `0.0`;
    * median and mean are reported together, and the fixture is skewed enough
      that a bug returning one for the other reddens;
    * a task that re-enters a phase sums across visits.

  Fixtures write transition rows at CHOSEN timestamps rather than driving
  live transitions with sleeps: the skew that matters here spans weeks, and a
  fixture whose numbers all land within milliseconds of each other cannot
  distinguish a median from a mean.
  """

  use Platform.DataCase

  alias Platform.Agents.Agent
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransition, PipelineHealth}

  @since ~U[2026-01-01 00:00:00.000000Z]
  @until ~U[2026-03-01 00:00:00.000000Z]
  @window %{since: @since, until: @until}

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Pipeline Health Project"})
    %{project: project}
  end

  # A task created inside the window that has reached `done`. `inserted_at` is
  # forced because cohort membership keys off it and the window is historical.
  defp done_task(project, created_at, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: Keyword.get(opts, :title, "Pipeline Task")
      })

    {1, _} =
      Platform.Tasks.Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(set: [status: "done", inserted_at: created_at])

    Repo.get!(Platform.Tasks.Task, task.id)
  end

  # `steps` is a list of `{to_status, occurred_at}` — the from_status of each
  # is the previous to_status, so the chain starts at "backlog" and
  # `decompose/2` reports `complete?: true`.
  defp record_chain(task, steps, actor_kind \\ "agent") do
    Enum.reduce(steps, "backlog", fn {to_status, occurred_at}, from_status ->
      Repo.insert!(%PhaseTransition{
        task_id: task.id,
        from_status: from_status,
        to_status: to_status,
        occurred_at: occurred_at,
        actor_kind: actor_kind
      })

      to_status
    end)
  end

  defp at(day, hour \\ 0), do: DateTime.add(@since, day * 86_400 + hour * 3_600, :second)

  # A task whose whole life is planning -> in_progress -> done, taking
  # `hours` in `in_progress`.
  defp simple_task(project, day, hours) do
    task = done_task(project, at(day))

    record_chain(task, [
      {"planning", at(day, 1)},
      {"in_progress", at(day, 2)},
      {"done", at(day, 2 + hours)}
    ])

    task
  end

  describe "cohort/1" do
    test "counts an uninstrumented task in the window and excludes it from decomposable",
         %{project: project} do
      simple_task(project, 1, 1)
      simple_task(project, 2, 1)

      # No transition rows at all: predates instrumentation.
      done_task(project, at(3), title: "Uninstrumented")

      # Rows, but the first one starts mid-flight, so the anchor interval
      # would absorb an unknown amount of pre-instrumentation time.
      midflight = done_task(project, at(4), title: "Mid-flight")

      Repo.insert!(%PhaseTransition{
        task_id: midflight.id,
        from_status: "in_progress",
        to_status: "done",
        occurred_at: at(4, 5),
        actor_kind: "agent"
      })

      cohort = PipelineHealth.cohort(@window)

      # The two numbers must DIFFER, or this assertion cannot fail.
      assert cohort.tasks_in_window == 4
      assert cohort.decomposable == 2
      refute cohort.tasks_in_window == cohort.decomposable
    end

    test "reports when instrumentation began", %{project: project} do
      simple_task(project, 5, 1)

      assert %DateTime{} = PipelineHealth.cohort(@window).instrumented_from
    end

    test "excludes tasks outside the window", %{project: project} do
      simple_task(project, 1, 1)
      done_task(project, ~U[2025-06-01 00:00:00.000000Z], title: "Before window")

      assert PipelineHealth.cohort(@window).tasks_in_window == 1
    end
  end

  describe "phase_breakdown/1" do
    test "a phase no task visited is nil seconds and zero tasks, never 0.0",
         %{project: project} do
      # Every task goes in_progress -> deploying: nothing enters in_review,
      # so awaiting_manual_approval never happened.
      for day <- 1..3 do
        task = done_task(project, at(day))

        record_chain(task, [
          {"planning", at(day, 1)},
          {"in_progress", at(day, 2)},
          {"deploying", at(day, 5)},
          {"done", at(day, 6)}
        ])
      end

      breakdown = PipelineHealth.phase_breakdown(@window)
      review = Enum.find(breakdown, &(&1.phase == "awaiting_manual_approval"))

      assert review.p50_seconds == nil
      assert review.p75_seconds == nil
      assert review.tasks == 0

      # A visited phase in the same cohort proves the nil above is a real
      # absence rather than the whole breakdown being empty.
      deploying = Enum.find(breakdown, &(&1.phase == "deploying"))
      assert deploying.tasks == 3
      assert deploying.p50_seconds == 3_600.0
    end

    test "returns the five phases in pipeline order", %{project: project} do
      simple_task(project, 1, 1)

      assert Enum.map(PipelineHealth.phase_breakdown(@window), & &1.phase) == [
               "planning",
               "awaiting_plan_approval",
               "in_progress",
               "awaiting_manual_approval",
               "deploying"
             ]
    end

    test "a task that re-enters a phase sums across visits", %{project: project} do
      task = done_task(project, at(1))

      # in_progress twice: 2h, then back from review for 3h. 5h total, and a
      # last-visit-only bug would report 3h.
      record_chain(task, [
        {"planning", at(1, 1)},
        {"in_progress", at(1, 2)},
        {"in_review", at(1, 4)},
        {"in_progress", at(1, 5)},
        {"done", at(1, 8)}
      ])

      in_progress =
        PipelineHealth.phase_breakdown(@window)
        |> Enum.find(&(&1.phase == "in_progress"))

      assert in_progress.p50_seconds == 18_000.0
      assert in_progress.tasks == 1
    end

    test "attributes a phase closed by a user as human wait", %{project: project} do
      task = done_task(project, at(1))

      Enum.reduce(
        [
          {"planning", at(1, 1), "agent"},
          {"in_progress", at(1, 2), "agent"},
          {"done", at(1, 10), "user"}
        ],
        "backlog",
        fn {to_status, occurred_at, kind}, from_status ->
          Repo.insert!(%PhaseTransition{
            task_id: task.id,
            from_status: from_status,
            to_status: to_status,
            occurred_at: occurred_at,
            actor_kind: kind
          })

          to_status
        end
      )

      breakdown = PipelineHealth.phase_breakdown(@window)

      # `in_progress` was ended by a person, `planning` by the engine.
      assert Enum.find(breakdown, &(&1.phase == "in_progress")).human
      refute Enum.find(breakdown, &(&1.phase == "planning")).human
    end
  end

  describe "cycle_time_distribution/1" do
    test "returns median and mean together, and they differ on a skewed cohort",
         %{project: project} do
      # Five sub-hour tasks plus one three-week outlier: mean must land far
      # above median, so a bug returning one for the other reddens.
      for day <- 1..5, do: simple_task(project, day, 0)
      long = done_task(project, at(10), title: "Outlier")

      record_chain(long, [
        {"planning", at(10, 1)},
        {"in_progress", at(10, 2)},
        {"done", at(31, 2)}
      ])

      dist = PipelineHealth.cycle_time_distribution(@window)

      assert dist.n == 6
      assert is_float(dist.median_seconds)
      assert is_float(dist.mean_seconds)
      assert dist.mean_seconds > dist.median_seconds * 2
      refute dist.median_seconds == dist.mean_seconds
      assert dist.p25 && dist.p75 && dist.p90
    end

    test "bins are log-spaced with an explicit >7d overflow bucket", %{project: project} do
      long = done_task(project, at(1), title: "Very long")

      record_chain(long, [
        {"planning", at(1, 1)},
        {"in_progress", at(1, 2)},
        {"done", at(21, 2)}
      ])

      dist = PipelineHealth.cycle_time_distribution(@window)

      assert Enum.map(dist.buckets, & &1.label) == [
               "<1h",
               "1-4h",
               "4-12h",
               "12h-1d",
               "1-3d",
               "3-7d",
               ">7d"
             ]

      assert Enum.find(dist.buckets, &(&1.label == ">7d")).count == 1
      assert Enum.find(dist.buckets, &(&1.label == "<1h")).count == 0
    end

    test "an empty cohort has no median and no mean, rather than zero" do
      dist = PipelineHealth.cycle_time_distribution(@window)

      assert dist.n == 0
      assert dist.median_seconds == nil
      assert dist.mean_seconds == nil
    end
  end

  describe "throughput/1" do
    test "divides by active days only, and keeps empty days in the series",
         %{project: project} do
      # Two completions on day 1, one on day 4. Three calendar days between,
      # but only two ACTIVE days: 1.5 per active day, not 0.75 per calendar
      # day.
      simple_task(project, 1, 1)
      simple_task(project, 1, 2)
      simple_task(project, 4, 1)

      throughput = PipelineHealth.throughput(@window)

      assert throughput.per_active_day == 1.5
      assert throughput.best_day == 2
      assert Enum.map(throughput.series, & &1.count) == [2, 1]

      assert Enum.map(throughput.series, & &1.date) == [
               Date.new!(2026, 1, 2),
               Date.new!(2026, 1, 5)
             ]
    end

    test "an empty window reports zero rather than dividing by zero" do
      assert PipelineHealth.throughput(@window) == %{
               per_active_day: 0.0,
               series: [],
               best_day: 0
             }
    end
  end

  # --- agent activity fixtures --------------------------------------------

  defp agent(name) do
    n = System.unique_integer([:positive])
    Repo.insert!(%Agent{slug: "ph-#{n}", name: name, status: "active"})
  end

  # A done task whose CURRENT execution slot is held by `agent`. The window
  # keys off `inserted_at`, exactly as `done_task/3` does.
  defp done_task_for(project, agent, created_at) do
    task = done_task(project, created_at, title: "Task for #{agent.name}")

    {1, _} =
      Platform.Tasks.Task
      |> where([t], t.id == ^task.id)
      |> Repo.update_all(
        set: [
          phase_assignees: %{
            "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
          }
        ]
      )

    task
  end

  defp blocker(task, reported_by, needs_human, opts \\ []) do
    Repo.insert!(%RuntimeEvent{
      task_id: task.id,
      phase: "execution",
      runtime_id: "tool-surface",
      event_type: Keyword.get(opts, :event_type, "execution.blocked"),
      occurred_at: Keyword.get(opts, :occurred_at, at(10)),
      idempotency_key: "blocker-#{System.unique_integer([:positive])}",
      payload: %{
        "description" => "stuck",
        "needs_human" => needs_human,
        "reported_by" => reported_by,
        "stage_id" => Ecto.UUID.generate()
      }
    })
  end

  describe "agent_activity/1" do
    test "counts completions and blockers per agent, sorted by completions then name", %{
      project: project
    } do
      a = agent("Agent A")
      b = agent("Agent B")
      c = agent("Agent C")

      a1 = done_task_for(project, a, at(3))
      done_task_for(project, a, at(4))
      b1 = done_task_for(project, b, at(5))

      blocker(a1, a.id, true)
      blocker(b1, b.id, true)
      blocker(b1, b.id, false)
      blocker(b1, c.id, false)

      assert [
               %{
                 agent_id: a_id,
                 agent_name: "Agent A",
                 completions: 2,
                 blockers_needs_human: 1,
                 blockers_no_human: 0,
                 blockers_per_completion: 0.5
               },
               %{
                 agent_id: b_id,
                 agent_name: "Agent B",
                 completions: 1,
                 blockers_needs_human: 1,
                 blockers_no_human: 1,
                 blockers_per_completion: 2.0
               },
               %{
                 agent_id: c_id,
                 agent_name: "Agent C",
                 completions: 0,
                 blockers_needs_human: 0,
                 blockers_no_human: 1,
                 blockers_per_completion: nil
               }
             ] = PipelineHealth.agent_activity(@window)

      assert {a_id, b_id, c_id} == {a.id, b.id, c.id}
    end

    test "a done task outside the window and a non-blocked event are not counted", %{
      project: project
    } do
      a = agent("Agent A")

      inside = done_task_for(project, a, at(3))
      done_task_for(project, a, DateTime.add(@until, 86_400, :second))

      blocker(inside, a.id, true)
      blocker(inside, a.id, true, event_type: "execution.progress")
      blocker(inside, a.id, false, occurred_at: DateTime.add(@since, -1, :second))

      assert [
               %{
                 completions: 1,
                 blockers_needs_human: 1,
                 blockers_no_human: 0,
                 blockers_per_completion: 1.0
               }
             ] = PipelineHealth.agent_activity(@window)
    end

    test "a done task without an agent execution assignee is in nobody's row", %{
      project: project
    } do
      done_task(project, at(3))
      assert PipelineHealth.agent_activity(@window) == []
    end

    test "a blocker whose reported_by is not an agent id lands in the unattributed row", %{
      project: project
    } do
      a = agent("Agent A")
      task = done_task_for(project, a, at(3))
      blocker(task, "agent", false)

      assert [
               %{agent_name: "Agent A", completions: 1, blockers_no_human: 0},
               %{
                 agent_id: "unattributed",
                 agent_name: "unattributed",
                 completions: 0,
                 blockers_no_human: 1,
                 blockers_per_completion: nil
               }
             ] = PipelineHealth.agent_activity(@window)
    end

    test "an unknown agent id falls back to its first eight characters", %{project: project} do
      ghost = Ecto.UUID.generate()
      task = done_task(project, at(3))
      blocker(task, ghost, true)

      assert [%{agent_id: ^ghost, agent_name: name}] = PipelineHealth.agent_activity(@window)
      assert name == String.slice(ghost, 0, 8)
    end
  end

  describe "no reconstruction" do
    test "the module source never reads the last-modified column" do
      source = File.read!("lib/platform/tasks/pipeline_health.ex")

      refute source =~ "updated_at"
    end
  end
end
