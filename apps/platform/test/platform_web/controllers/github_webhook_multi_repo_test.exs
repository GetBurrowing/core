defmodule PlatformWeb.GithubWebhookMultiRepoTest do
  @moduledoc """
  A merged PR passes ONLY the `pr_merged` gate belonging to the repository
  that delivered it.

  Before this test's fix, `find_pending_pr_merged_validation/1` selected the
  first pending `pr_merged` on the running stage filtered by task id and
  NOTHING ELSE — the task id itself coming from the BRANCH NAME
  (`Changelog.extract_task_id_from_branch/1`). Neither function read the
  repository, so a merge in ANY repo whose head branch embedded the task id
  passed the task's gate. That is how task `019fa56b` reported a completed
  deploy while `Startup-Suite/claude-code-suite-channel` PR #16 was — and at
  the time of writing still is — open.

  The assertions here are deliberately not "the validation did not pass",
  which is trivially true of a deploy that never ran. They pin the PARTIAL
  state as distinct from BOTH the empty state and the complete one: the
  deploy stage EXISTS and is `running`, the task IS `deploying`, repo A's
  gate DID pass with real evidence, and only then is repo B's gate asserted
  still `pending`. The last test in the first describe block then merges
  repo B and proves the stage opens — a gate that can never pass is not a
  gate, it is a wall.
  """

  use PlatformWeb.ConnCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Validation

  @github_webhook_path "/api/webhooks/github"

  @core "Startup-Suite/core"
  @bridge "Startup-Suite/claude-code-suite-channel"
  @undeclared "Startup-Suite/openclaw-suite-channel"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  # Drives the REAL injection path — `PlanEngine.advance/1` ->
  # `maybe_inject_deploy_or_complete/2` -> `inject_deploy_stage/4` — rather
  # than hand-inserting validation rows, so the gates under test are the ones
  # production would actually mint.
  defp deploying_two_repo_task!(repos, opts \\ []) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Multi-repo Webhook #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/#{@core}"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Lands in two repositories",
        status: "in_progress",
        # Stage-2 deploy-target guard (task 019f42db) refuses `:deploying`
        # transitions without a resolved target.
        deploy_target: "production",
        deploy_strategy: %{
          "type" => "pr_merge",
          "config" => %{"auto_merge" => false},
          "repos" => repos
        }
      })

    # `DeployStageBuilder.validate_strategy/1` refuses an unresolvable
    # `repo_url` at write time, so the only way one exists is a raw write that
    # skips the changeset — which is exactly how the state under test is
    # produced here.
    task =
      case Keyword.get(opts, :force_repos) do
        nil ->
          task

        forced ->
          task
          |> Ecto.Changeset.change(%{
            deploy_strategy: %{
              "type" => "pr_merge",
              "config" => %{"auto_merge" => false},
              "repos" => forced
            }
          })
          |> Repo.update!()
      end

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(s1.id)
    {:ok, plan} = PlanEngine.advance(plan.id)

    deploy_stage = Enum.find(plan.stages, &(&1.name == "Deploy: PR merge"))

    %{
      project: project,
      task: task,
      plan: plan,
      deploy_stage: deploy_stage
    }
  end

  defp deploying_two_repo_task! do
    deploying_two_repo_task!([
      %{"repo_url" => "https://github.com/#{@core}", "ci" => "required"},
      %{"repo_url" => @bridge, "ci" => "none"}
    ])
  end

  # A plan minted BEFORE stage 2 shipped: one `pr_merged` row with no
  # `evaluation_payload` at all. `repos` is what the task's strategy declares
  # today, which is what decides whether that unscoped row is still
  # unambiguous.
  defp legacy_unscoped_task!(opts) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Legacy Webhook #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/#{@core}"
      })

    strategy =
      case Keyword.get(opts, :repos) do
        nil -> %{"type" => "pr_merge", "config" => %{"auto_merge" => false}}
        repos -> %{"type" => "pr_merge", "config" => %{"auto_merge" => false}, "repos" => repos}
      end

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "In flight when the scoping shipped",
        status: "deploying",
        deploy_target: "production",
        deploy_strategy: strategy
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Deploy: PR merge",
        description: "Deploy via PR merge"
      })

    {:ok, _} = Tasks.transition_stage(stage, "running")
    stage = Repo.get!(Stage, stage.id)

    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

    %{project: project, task: task, plan: plan, stage: stage, validation: validation}
  end

  # GitHub sends the delivering repository BOTH on `pull_request.base.repo`
  # and on the top-level `repository` object. Real deliveries carry both;
  # the controller reads the former and falls back to the latter.
  defp merged_pr_payload(task, repo_full_name) do
    number = System.unique_integer([:positive])

    %{
      "action" => "closed",
      "repository" => %{"full_name" => repo_full_name},
      "pull_request" => %{
        "merged" => true,
        "title" => "feat: scope pr_merged to the delivering repo",
        "number" => number,
        "html_url" => "https://github.com/#{repo_full_name}/pull/#{number}",
        "merge_commit_sha" => "sha#{number}",
        "merged_at" => "2026-07-27T01:00:00Z",
        "body" => "Body for #{repo_full_name}.",
        "user" => %{"login" => "dev-user"},
        "head" => %{"ref" => "task/#{task.id}"},
        "base" => %{"ref" => "main", "repo" => %{"full_name" => repo_full_name}}
      }
    }
  end

  defp validations(stage_id) do
    stage_id
    |> Tasks.list_validations()
    |> Enum.filter(&(&1.kind == "pr_merged"))
  end

  defp gate_for(stage_id, repo) do
    Enum.find(validations(stage_id), fn v ->
      get_in(v.evaluation_payload || %{}, ["repo"]) == repo
    end)
  end

  defp reload(%Validation{id: id}), do: Repo.get!(Validation, id)
  defp reload(%Stage{id: id}), do: Repo.get!(Stage, id)

  # ── Partial deploy ───────────────────────────────────────────────────────

  describe "a merge in one repository of a two-repo deploy" do
    test "passes only that repository's gate and leaves the deploy running", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = deploying_two_repo_task!()

      # ANTI-VACUITY: the deploy DID run. Everything below is about a live
      # deploy stage, not about a task that never reached one.
      assert deploy_stage, "expected a deploy stage to be injected"
      assert deploy_stage.status == "running"
      assert Tasks.get_task_record(task.id).status == "deploying"

      assert Enum.map(validations(deploy_stage.id), & &1.evaluation_payload["repo"]) == [
               @core,
               @bridge
             ]

      # Repo A merges.
      conn =
        signed_github_post(conn, @github_webhook_path, merged_pr_payload(task, @core))

      assert conn.status == 201

      core_gate = gate_for(deploy_stage.id, @core)
      bridge_gate = gate_for(deploy_stage.id, @bridge)

      # ANTI-VACUITY: repo A really did merge and really was recorded.
      assert core_gate.status == "passed"
      assert core_gate.evidence["pr_url"] =~ @core
      assert core_gate.evaluated_by == "github_webhook"

      # THE DEFECT. Before the fix the core merge passed whichever gate the
      # query happened to return first and `advance_stage/1` flipped the whole
      # deploy stage to `passed`, reporting a two-repo deploy as complete off
      # one merged PR.
      assert bridge_gate.status == "pending"
      assert reload(deploy_stage).status == "running"
      assert Tasks.get_task_record(task.id).status == "deploying"
    end

    # The order-independent form of the same claim, and the one that actually
    # fails against the unscoped query. `find_pending_pr_merged_validation/1`
    # returns the FIRST pending row on the running stage, so when the SECOND
    # repo delivers first the merge is attributed to the FIRST repo: the
    # bridge PR merging marks CORE as merged. A test that always delivers
    # repo A first would pass against the defect by coincidence.
    test "attributes the merge to the repository that delivered it, not the first gate",
         %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = deploying_two_repo_task!()

      conn =
        signed_github_post(conn, @github_webhook_path, merged_pr_payload(task, @bridge))

      assert conn.status == 201

      bridge_gate = gate_for(deploy_stage.id, @bridge)
      core_gate = gate_for(deploy_stage.id, @core)

      assert bridge_gate.status == "passed"
      assert bridge_gate.evidence["pr_url"] =~ @bridge

      assert core_gate.status == "pending",
             "the bridge repo's merge must not mark core as merged"

      assert reload(deploy_stage).status == "running"
    end

    test "the stage opens once the second repository merges too", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = deploying_two_repo_task!()

      conn = signed_github_post(conn, @github_webhook_path, merged_pr_payload(task, @core))
      assert conn.status == 201

      conn =
        signed_github_post(
          build_conn(),
          @github_webhook_path,
          merged_pr_payload(task, @bridge)
        )

      assert conn.status == 201

      assert gate_for(deploy_stage.id, @core).status == "passed"
      assert gate_for(deploy_stage.id, @bridge).status == "passed"
      assert reload(deploy_stage).status == "passed"
      assert Tasks.get_task_record(task.id).status == "done"
    end

    test "matches the delivering repo across spellings (URL vs bare owner/name)",
         %{conn: conn} do
      # `project.repo_url` stores `https://github.com/Owner/Name`; the webhook
      # delivers the bare `Owner/Name`, and GitHub treats owner/name as
      # case-insensitive. `RepoRef.same?/2` is the one place that knows this.
      %{task: task, deploy_stage: deploy_stage} = deploying_two_repo_task!()

      conn =
        signed_github_post(
          conn,
          @github_webhook_path,
          merged_pr_payload(task, "startup-suite/CORE")
        )

      assert conn.status == 201
      assert gate_for(deploy_stage.id, @core).status == "passed"
      assert gate_for(deploy_stage.id, @bridge).status == "pending"
    end
  end

  # ── Undeclared delivering repository ─────────────────────────────────────

  describe "a merge delivered from a repository the task never declared" do
    test "passes nothing and is recorded as an unmatched delivery", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = deploying_two_repo_task!()

      conn =
        signed_github_post(
          conn,
          @github_webhook_path,
          merged_pr_payload(task, @undeclared)
        )

      # The changelog entry is still written — a merged PR is a changelog fact
      # regardless of which repo it landed in.
      assert conn.status == 201

      assert gate_for(deploy_stage.id, @core).status == "pending"
      assert gate_for(deploy_stage.id, @bridge).status == "pending"
      assert reload(deploy_stage).status == "running"
      assert Tasks.get_task_record(task.id).status == "deploying"

      # Not a pass, but not silence either: the delivery is real and leaves a
      # named trace on the first pending gate.
      [delivery] = gate_for(deploy_stage.id, @core).evidence["unmatched_repo_deliveries"]

      assert delivery["repo"] == @undeclared
      assert delivery["pr_url"] =~ @undeclared
      assert {:ok, _, _} = DateTime.from_iso8601(delivery["observed_at"])
    end

    test "emits :unmatched_repo telemetry naming the delivering and expected repos",
         %{conn: conn} do
      %{task: task} = deploying_two_repo_task!()

      handler_id = "unmatched-repo-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:platform, :tasks, :pr_merged, :unmatched_repo],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:unmatched_repo, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      signed_github_post(conn, @github_webhook_path, merged_pr_payload(task, @undeclared))

      assert_receive {:unmatched_repo, %{count: 1}, metadata}
      assert metadata.task_id == task.id
      assert metadata.delivering_repo == @undeclared
      assert metadata.expected_repos == [@core, @bridge]
    end

    test "a declared repo that does not resolve keeps a gate nothing can match",
         %{conn: conn} do
      # `Tasks.resolve_deploy_repos/1` KEEPS an unresolvable declared entry
      # with a nil slug rather than dropping it. Dropping would shrink the
      # repo set back to the bug this exists to fix; keeping makes the task
      # hang, which is visible and fixable.
      %{task: task, deploy_stage: deploy_stage} =
        deploying_two_repo_task!(
          [
            %{"repo_url" => "https://github.com/#{@core}", "ci" => "required"},
            %{"repo_url" => @bridge, "ci" => "none"}
          ],
          force_repos: [
            %{"repo_url" => "https://github.com/#{@core}", "ci" => "required"},
            %{"repo_url" => "not a repository at all", "ci" => "none"}
          ]
        )

      assert Enum.map(validations(deploy_stage.id), & &1.evaluation_payload["repo"]) == [
               @core,
               nil
             ]

      conn = signed_github_post(conn, @github_webhook_path, merged_pr_payload(task, @core))
      assert conn.status == 201

      assert gate_for(deploy_stage.id, @core).status == "passed"
      assert gate_for(deploy_stage.id, nil).status == "pending"
      assert reload(deploy_stage).status == "running"

      # And nothing can satisfy it — not even a delivery whose repo is
      # equally unresolvable, because `RepoRef.same?/2` never answers true on
      # a nil side.
      signed_github_post(
        build_conn(),
        @github_webhook_path,
        merged_pr_payload(task, "not a repository at all")
      )

      assert gate_for(deploy_stage.id, nil).status == "pending"
      assert reload(deploy_stage).status == "running"
    end
  end

  # ── Plans minted before the gates carried a repository ───────────────────

  describe "a legacy unscoped pr_merged row" do
    test "still passes on a task that resolves to exactly one repository", %{conn: conn} do
      %{task: task, validation: validation, stage: stage} = legacy_unscoped_task!([])

      conn = signed_github_post(conn, @github_webhook_path, merged_pr_payload(task, @core))
      assert conn.status == 201

      assert reload(validation).status == "passed"
      assert reload(stage).status == "passed"
    end

    test "does not pass when the delivering repo is not the one repo it resolves to",
         %{conn: conn} do
      %{task: task, validation: validation, stage: stage} = legacy_unscoped_task!([])

      conn =
        signed_github_post(conn, @github_webhook_path, merged_pr_payload(task, @undeclared))

      assert conn.status == 201
      assert reload(validation).status == "pending"
      assert reload(stage).status == "running"
    end

    test "does not pass on a task that now resolves to two repositories", %{conn: conn} do
      # An unscoped gate on a two-repo task is AMBIGUOUS — it cannot say which
      # of the two merges it is waiting for. An ambiguous gate must not pass.
      %{task: task, validation: validation, stage: stage} =
        legacy_unscoped_task!(
          repos: [
            %{"repo_url" => "https://github.com/#{@core}", "ci" => "required"},
            %{"repo_url" => @bridge, "ci" => "none"}
          ]
        )

      conn = signed_github_post(conn, @github_webhook_path, merged_pr_payload(task, @core))

      assert conn.status == 201
      assert reload(validation).status == "pending"
      assert reload(stage).status == "running"
      assert reload(validation).evidence["unmatched_repo_deliveries"] != nil
    end
  end
end
