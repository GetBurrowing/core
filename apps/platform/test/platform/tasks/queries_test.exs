defmodule Platform.Tasks.QueriesTest do
  @moduledoc """
  Tests for the memory_search hydration helpers introduced in stage 3 of
  task 019f3dbb: `Platform.Tasks.merged_pr_url/1` and
  `Platform.Tasks.follow_up_task_ids/1`.

  Both helpers power advisory fields on `Platform.Org.Wiki.Search`'s task
  corpus hits. They live in `Platform.Tasks` so any Tasks-domain caller
  (MCP `task_get`, kanban card, future callers) can reach them without
  going through the Search module.
  """

  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Task, Validation}

  ## ─────────────────────────────────────────────────────────────────────
  ## merged_pr_url/1
  ## ─────────────────────────────────────────────────────────────────────

  describe "merged_pr_url/1" do
    test "returns <repo_url>/commit/<merge_sha> for a solo task with passed pr_merged validation" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Merged PR Project",
          repo_url: "https://github.com/example/repo"
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Ship a fix",
          description: "small change"
        })

      merge_sha = "deadbeef1234567890abcdef1234567890abcdef"
      stamp_pr_merged(task, merge_sha)

      assert Tasks.merged_pr_url(task) ==
               "https://github.com/example/repo/commit/#{merge_sha}"
    end

    test "trims trailing slash on repo_url so the resulting URL is well-formed" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Trailing Slash",
          repo_url: "https://github.com/example/repo/"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Ship", description: "d"})

      stamp_pr_merged(task, "cafebabecafebabecafebabecafebabecafebabe")

      assert Tasks.merged_pr_url(task) ==
               "https://github.com/example/repo/commit/cafebabecafebabecafebabecafebabecafebabe"
    end

    test "returns nil when no pr_merged validation is stamped" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "No PR",
          repo_url: "https://github.com/example/repo"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "In flight", description: "wip"})

      assert Tasks.merged_pr_url(task) == nil
    end

    test "returns nil when pr_merged evidence lacks merge_sha" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "No SHA",
          repo_url: "https://github.com/example/repo"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Landed?", description: "x"})

      # Passed but no evidence.merge_sha — record_merge_result never
      # actually produces this shape, but the helper still needs to
      # short-circuit safely rather than crash on nil.
      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy"})

      {:ok, _v} =
        Tasks.evaluate_validation(
          create_validation(stage.id, "pr_merged"),
          "passed",
          %{"merged_by" => "auto_merger"}
        )

      assert Tasks.merged_pr_url(task) == nil
    end

    test "returns nil when pr_merged validation is failed, not passed" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Failed PR",
          repo_url: "https://github.com/example/repo"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Broken", description: "y"})

      {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy"})

      {:ok, _v} =
        Tasks.evaluate_validation(
          create_validation(stage.id, "pr_merged"),
          "failed",
          %{"merge_sha" => "abc"}
        )

      assert Tasks.merged_pr_url(task) == nil
    end

    test "falls back to stack.metadata[\"rollup_pr\"][\"url\"] for stack members" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Stack Project",
          repo_url: "https://github.com/example/repo"
        })

      stack =
        seed_stack(project.id, %{
          "rollup_pr" => %{"url" => "https://github.com/example/repo/pull/42"}
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          stack_id: stack.id,
          title: "Stack member",
          description: "part of a rollup"
        })

      # Per AutoMerger.record_merge_result/2:180, stack-member per-task
      # pr_merged validations are intentionally deferred — status stays
      # pending, evidence is empty. The URL must fall back to the
      # rollup PR.
      assert Tasks.merged_pr_url(task) ==
               "https://github.com/example/repo/pull/42"
    end

    test "prefers per-task pr_merged commit URL over stack rollup URL when both present" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Both Signals",
          repo_url: "https://github.com/example/repo"
        })

      stack =
        seed_stack(project.id, %{
          "rollup_pr" => %{"url" => "https://github.com/example/repo/pull/99"}
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          stack_id: stack.id,
          title: "Prefer commit URL",
          description: "z"
        })

      stamp_pr_merged(task, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

      # Commit URL from the pr_merged evidence takes precedence over the
      # stack rollup URL — it's the more specific signal.
      assert Tasks.merged_pr_url(task) ==
               "https://github.com/example/repo/commit/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end

    test "accepts a task id string" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "By ID",
          repo_url: "https://github.com/example/repo"
        })

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "ID lookup", description: "q"})

      stamp_pr_merged(task, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

      assert Tasks.merged_pr_url(task.id) ==
               "https://github.com/example/repo/commit/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    end

    test "returns nil for an unknown task id" do
      assert Tasks.merged_pr_url(Ecto.UUID.generate()) == nil
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## follow_up_task_ids/1
  ## ─────────────────────────────────────────────────────────────────────

  describe "follow_up_task_ids/1" do
    test "returns ids of open tasks whose descriptions reference the target's UUID" do
      {:ok, project} = Tasks.create_project(%{name: "Follow Ups"})

      {:ok, target} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Original fix",
          description: "the first attempt"
        })

      # Bump `inserted_at` so subsequent tasks are definitely temporally after.
      Process.sleep(20)

      {:ok, follow_up_a} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Retry A",
          description: "Second attempt at #{target.id}",
          status: "in_progress"
        })

      {:ok, follow_up_b} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Retry B",
          description: "Yet another go at #{target.id}"
        })

      ids = Tasks.follow_up_task_ids(target)

      assert Enum.sort(ids) == Enum.sort([follow_up_a.id, follow_up_b.id])
    end

    test "excludes cancelled follow-ups (retracted claims don't count)" do
      {:ok, project} = Tasks.create_project(%{name: "Cancelled FUs"})

      {:ok, target} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Original",
          description: "canonical"
        })

      Process.sleep(20)

      {:ok, active_fu} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Retry",
          description: "fix for #{target.id}",
          status: "in_progress"
        })

      {:ok, cancelled_fu} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Retracted",
          description: "was going to fix #{target.id}",
          status: "in_progress"
        })

      # Move cancelled_fu → cancelled
      {:ok, _} = Tasks.transition_task_status(cancelled_fu, "cancelled")

      ids = Tasks.follow_up_task_ids(target)

      assert active_fu.id in ids
      refute cancelled_fu.id in ids
    end

    test "excludes tasks filed BEFORE the target (temporal invariant)" do
      {:ok, project} = Tasks.create_project(%{name: "Temporal"})

      # Build the target first, then a source-task whose description
      # coincidentally references the target's UUID. We then backdate
      # the source-task's inserted_at so the query filter drops it.
      # This mirrors the stage description's temporal-invariant intent:
      # a task filed BEFORE the target can't be a follow-up.
      {:ok, target} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Target",
          description: "canonical fix"
        })

      Process.sleep(20)

      {:ok, earlier} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Predates target",
          description: "coincidental mention of #{target.id}"
        })

      # Backdate `earlier` so it looks like it existed before target.
      # The task_references row already exists (scanner ran on create),
      # so we don't need to re-run it — only the temporal filter matters.
      _ =
        earlier
        |> Ecto.Changeset.change(%{inserted_at: DateTime.add(target.inserted_at, -60, :second)})
        |> Repo.update!()

      ids = Tasks.follow_up_task_ids(target)

      refute earlier.id in ids
      # Sanity: no rows at all — no later follow-ups seeded.
      assert ids == []
    end

    test "excludes soft-deleted follow-ups" do
      {:ok, project} = Tasks.create_project(%{name: "Deleted FUs"})

      {:ok, target} = Tasks.create_task(%{project_id: project.id, title: "T", description: "d"})
      Process.sleep(20)

      {:ok, fu} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "FU",
          description: "fix #{target.id}"
        })

      {:ok, _} = Tasks.soft_delete_task(fu)

      assert Tasks.follow_up_task_ids(target) == []
    end

    test "returns [] when no tasks reference the target" do
      {:ok, project} = Tasks.create_project(%{name: "Lone"})

      {:ok, task} =
        Tasks.create_task(%{project_id: project.id, title: "Lonely", description: "z"})

      assert Tasks.follow_up_task_ids(task) == []
    end

    test "accepts a task id string" do
      {:ok, project} = Tasks.create_project(%{name: "By ID FU"})

      {:ok, target} = Tasks.create_task(%{project_id: project.id, title: "T", description: "d"})
      Process.sleep(20)

      {:ok, fu} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "FU",
          description: "fix #{target.id}",
          status: "in_progress"
        })

      assert Tasks.follow_up_task_ids(target.id) == [fu.id]
    end

    test "returns [] for an unknown task id" do
      assert Tasks.follow_up_task_ids(Ecto.UUID.generate()) == []
    end
  end

  ## ─────────────────────────────────────────────────────────────────────
  ## Helpers
  ## ─────────────────────────────────────────────────────────────────────

  defp stamp_pr_merged(%Task{} = task, merge_sha) do
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy"})
    validation_id = create_validation(stage.id, "pr_merged")

    {:ok, _} =
      Tasks.evaluate_validation(
        validation_id,
        "passed",
        %{"merge_sha" => merge_sha, "merged_by" => "auto_merger"}
      )

    :ok
  end

  defp create_validation(stage_id, kind) do
    {:ok, %Validation{id: id}} =
      Tasks.create_validation(%{stage_id: stage_id, kind: kind})

    id
  end

  defp seed_stack(project_id, metadata) do
    seq = System.unique_integer([:positive])

    {:ok, stack} =
      %Platform.Tasks.Stack{}
      |> Platform.Tasks.Stack.changeset(%{
        project_id: project_id,
        slug: "stack-#{seq}",
        name: "Test Stack",
        base_branch: "main",
        rollup_branch: "stack/rollup-#{seq}",
        metadata: metadata
      })
      |> Repo.insert()

    stack
  end
end
