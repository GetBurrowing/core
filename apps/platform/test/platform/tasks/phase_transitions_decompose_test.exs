defmodule Platform.Tasks.PhaseTransitionsDecomposeTest do
  @moduledoc """
  `decompose/1` is the payoff of the phase-transition instrumentation, and the
  properties worth defending are mostly about what it REFUSES to say:

    * a task with no rows gets an empty decomposition, never one reconstructed
      from `inserted_at` / `updated_at`;
    * a phase that never happened is an absent key, never `0.0`;
    * a phase entered twice reports both visits, never just the last.

  Every fixture drives REAL transitions through `Platform.Tasks`, so the tests
  exercise the stage-2 choke point rather than a hand-written row that happens
  to have the shape the query wants.
  """

  use Platform.DataCase

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{PhaseTransitions, Plan, ReviewRequest, Stage, Validation}

  # Long enough that every interval is distinguishable at microsecond
  # resolution and non-zero, short enough to stay off the suite's critical
  # path.
  @tick 15

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Decompose Project"})
    %{project: project}
  end

  defp user_fixture do
    n = System.unique_integer([:positive])

    Repo.insert!(%Platform.Accounts.User{
      name: "Decompose User #{n}",
      email: "decompose-#{n}@example.com",
      oidc_sub: "decompose-sub-#{n}"
    })
  end

  defp task_fixture(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(Map.merge(%{project_id: project.id, title: "Decompose Task"}, attrs))

    task
  end

  defp step(task, status, actor \\ :system) do
    Process.sleep(@tick)
    {:ok, task} = Tasks.transition_task(task, status, actor)
    task
  end

  # The first `in_progress` visit, measured straight off the raw rows.
  defp first_in_progress_seconds(task_id) do
    [r1, r2 | _] = PhaseTransitions.list_for_task(task_id)
    DateTime.diff(r2.occurred_at, r1.occurred_at, :microsecond) / 1_000_000
  end

  defp decompose!(task_id) do
    {:ok, decomposition} = PhaseTransitions.decompose(task_id)
    decomposition
  end

  # Plans, stages, validations and review requests are not transitions, so
  # they are inserted directly — the choke point has nothing to say about them.
  defp plan_fixture(task, attrs) do
    Repo.insert!(
      struct(
        %Plan{
          task_id: task.id,
          version: 1,
          status: "approved",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  defp review_request_fixture(task, attrs) do
    plan = plan_fixture(task, %{version: System.unique_integer([:positive])})

    stage =
      Repo.insert!(%Stage{
        plan_id: plan.id,
        position: 1,
        name: "Review",
        status: "running",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

    validation =
      Repo.insert!(%Validation{
        stage_id: stage.id,
        kind: "manual_approval",
        status: "pending",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

    Repo.insert!(
      struct(
        %ReviewRequest{
          validation_id: validation.id,
          task_id: task.id,
          status: "pending",
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end

  describe "the happy multi-phase path" do
    setup %{project: project} do
      user = user_fixture()

      task =
        task_fixture(project, %{sponsor_user_id: user.id, deploy_target: "production"})

      task = step(task, "planning")
      # The user actor is deliberately on the transition that ENDS planning:
      # `by_actor` attributes an interval to whoever closed it.
      task = step(task, "in_progress", {:user, user.id})
      task = step(task, "in_review")
      task = step(task, "deploying")
      task = step(task, "done")

      %{task: task, user: user}
    end

    test "every visited phase is reported with a positive duration", %{task: task} do
      %{phases: phases, complete?: complete?, instrumented_from: from} = decompose!(task.id)

      assert complete?
      assert from == Repo.get!(Platform.Tasks.Task, task.id).inserted_at

      assert Map.keys(phases) |> Enum.sort() ==
               ~w(backlog deploying in_progress in_review planning)

      for {phase, %{total_seconds: seconds, visits: visits, open?: open?}} <- phases do
        assert seconds > 0, "#{phase} should have measured time"
        assert visits == 1
        refute open?
      end
    end

    test "the terminal status is not a phase — it has no measured duration", %{task: task} do
      refute Map.has_key?(decompose!(task.id).phases, "done")
    end

    test "by_actor credits the interval to whoever TERMINATED it", %{task: task} do
      %{by_actor: by_actor, phases: phases} = decompose!(task.id)

      # The user closed the `planning` interval, so the planning wait — and
      # nothing else — is attributed to them.
      assert_in_delta by_actor["user"], phases["planning"].total_seconds, 0.000_001
      assert by_actor["agent"] == 0.0
      assert by_actor["unknown"] == 0.0
      assert by_actor["system"] > 0.0

      total = phases |> Map.values() |> Enum.map(& &1.total_seconds) |> Enum.sum()
      assert_in_delta by_actor["user"] + by_actor["system"], total, 0.000_001
    end
  end

  describe "phases visited more than once" do
    test "durations sum across visits and the count is reported", %{project: project} do
      user = user_fixture()
      task = task_fixture(project, %{sponsor_user_id: user.id})

      task = step(task, "in_progress", {:user, user.id})
      task = step(task, "in_review")
      task = step(task, "in_progress")
      task = step(task, "in_review")
      task = step(task, "done")

      %{phases: phases} = decompose!(task.id)

      assert phases["in_progress"].visits == 2
      assert phases["in_review"].visits == 2

      # The summed total must exceed a single visit. A helper that reported
      # only the last visit would pass a bare `> 0` assertion, so anchor on
      # the raw rows instead.
      [_first, r2, r3, r4 | _] = PhaseTransitions.list_for_task(task.id)
      one_visit = DateTime.diff(r3.occurred_at, r2.occurred_at, :microsecond) / 1_000_000
      assert phases["in_review"].total_seconds > one_visit

      second_visit = DateTime.diff(r4.occurred_at, r3.occurred_at, :microsecond) / 1_000_000

      assert_in_delta phases["in_progress"].total_seconds,
                      first_in_progress_seconds(task.id) + second_visit,
                      0.000_001
    end
  end

  describe "phases that never happened" do
    test "a task that skips in_review has NO in_review key, not a zero one", %{project: project} do
      user = user_fixture()

      task =
        task_fixture(project, %{sponsor_user_id: user.id, deploy_target: "production"})

      task = step(task, "in_progress", {:user, user.id})
      task = step(task, "deploying")
      task = step(task, "done")

      %{phases: phases} = decompose!(task.id)

      refute Map.has_key?(phases, "in_review")
      refute Map.has_key?(phases, "planning")
      assert Map.has_key?(phases, "in_progress")
      assert Map.has_key?(phases, "deploying")
    end

    test "the stack-member path (in_review -> done) skips deploying", %{project: project} do
      user = user_fixture()
      task = task_fixture(project, %{sponsor_user_id: user.id})

      task = step(task, "in_progress", {:user, user.id})
      task = step(task, "in_review")
      task = step(task, "done")

      refute Map.has_key?(decompose!(task.id).phases, "deploying")
    end
  end

  describe "a task with no transition rows" do
    setup %{project: project} do
      task = task_fixture(project)
      assert PhaseTransitions.list_for_task(task.id) == []
      %{task: task}
    end

    test "returns nothing rather than a plausible-looking reconstruction", %{task: task} do
      decomposition = decompose!(task.id)

      assert decomposition.complete? == false
      assert decomposition.phases == %{}

      assert decomposition.waits == %{
               awaiting_plan_approval: :none,
               awaiting_manual_approval: :none
             }

      assert decomposition.by_actor == %{
               "user" => 0.0,
               "agent" => 0.0,
               "system" => 0.0,
               "unknown" => 0.0
             }
    end

    # This is the assertion that stops a future contributor "helpfully"
    # filling the gap from the timestamps that happen to be lying around.
    test "an aged updated_at does not become a fabricated backlog duration", %{task: task} do
      long_ago = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)

      Repo.update_all(
        from(t in Platform.Tasks.Task, where: t.id == ^task.id),
        set: [inserted_at: long_ago, updated_at: DateTime.utc_now()]
      )

      decomposition = decompose!(task.id)

      assert decomposition.phases == %{}
      refute decomposition.complete?
      # `instrumented_from` reports the fact; it does not become a duration.
      assert DateTime.compare(decomposition.instrumented_from, long_ago) == :eq
    end
  end

  describe "a task still in flight" do
    test "the final interval runs to now and is marked open?", %{project: project} do
      user = user_fixture()
      task = task_fixture(project, %{sponsor_user_id: user.id})

      task = step(task, "in_progress", {:user, user.id})
      Process.sleep(@tick)

      %{phases: phases} = decompose!(task.id)

      assert phases["in_progress"].open?
      assert phases["in_progress"].total_seconds > 0
      refute phases["backlog"].open?

      # It keeps growing, because it has not ended.
      before = phases["in_progress"].total_seconds
      Process.sleep(@tick)
      assert decompose!(task.id).phases["in_progress"].total_seconds > before
    end
  end

  describe "awaiting_plan_approval" do
    setup %{project: project} do
      user = user_fixture()
      task = task_fixture(project, %{sponsor_user_id: user.id})
      task = step(task, "planning")
      %{task: task, user: user}
    end

    test "is :none when the task has no approved plan", %{task: task} do
      plan_fixture(task, %{status: "draft", approved_at: nil, auto_approved_at: nil})

      assert decompose!(task.id).waits.awaiting_plan_approval == :none
    end

    test "human: true when approved_at is set and auto_approved_at is nil", %{task: task} do
      now = DateTime.utc_now()
      plan_fixture(task, %{inserted_at: DateTime.add(now, -5, :second), approved_at: now})

      assert %{seconds: seconds, human: true} = decompose!(task.id).waits.awaiting_plan_approval
      assert seconds > 0
    end

    test "human: false when the engine auto-approved", %{task: task} do
      now = DateTime.utc_now()

      plan_fixture(task, %{
        inserted_at: DateTime.add(now, -5, :second),
        approved_at: now,
        auto_approved_at: now
      })

      assert %{human: false} = decompose!(task.id).waits.awaiting_plan_approval
    end

    test "the wait is clamped to the task's entry into planning", %{task: task} do
      now = DateTime.utc_now()

      # A plan row whose inserted_at predates the task even entering planning
      # must not charge that hour to the approval wait.
      plan_fixture(task, %{inserted_at: DateTime.add(now, -3600, :second), approved_at: now})

      assert %{seconds: seconds} = decompose!(task.id).waits.awaiting_plan_approval
      assert seconds < 60, "expected the wait clamped to planning entry, got #{seconds}s"
    end
  end

  describe "awaiting_manual_approval" do
    setup %{project: project} do
      user = user_fixture()
      task = task_fixture(project, %{sponsor_user_id: user.id})
      task = step(task, "in_progress", {:user, user.id})
      task = step(task, "in_review")
      %{task: task}
    end

    test "is :none when the task has no review requests", %{task: task} do
      assert decompose!(task.id).waits.awaiting_manual_approval == :none
    end

    test "an unresolved request accrues against the open in_review interval", %{task: task} do
      review_request_fixture(task, %{resolved_at: nil})
      Process.sleep(@tick)

      assert %{seconds: seconds, requests: 1} =
               decompose!(task.id).waits.awaiting_manual_approval

      assert seconds > 0
      assert seconds <= decompose!(task.id).phases["in_review"].total_seconds + 0.05
    end

    test "requests counts every request for the task", %{task: task} do
      review_request_fixture(task, %{resolved_at: nil})
      review_request_fixture(task, %{resolved_at: DateTime.utc_now()})

      assert %{requests: 2} = decompose!(task.id).waits.awaiting_manual_approval
    end

    test "time outside the in_review intervals is not counted", %{task: task} do
      # A request opened an hour before the task ever reached in_review can
      # only contribute the part that overlaps.
      review_request_fixture(task, %{
        inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        resolved_at: nil
      })

      assert %{seconds: seconds} = decompose!(task.id).waits.awaiting_manual_approval
      assert seconds < 60, "expected intersection with in_review only, got #{seconds}s"
    end
  end

  describe "unknown tasks" do
    test "return an explicit error rather than an empty decomposition" do
      assert PhaseTransitions.decompose(Ecto.UUID.generate()) == {:error, :task_not_found}
    end
  end
end
