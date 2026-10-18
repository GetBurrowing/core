defmodule PlatformWeb.GithubWebhookDeploySkipNoticeTest do
  @moduledoc """
  `Platform.Deploy.SkipNotice`, reached through the real webhook endpoint
  (task 01a0feff stage 2): a `workflow_run.completed` on the deploy branch
  whose conclusion is not `success` posts one message, and nothing else does.

  `async: false` because every test writes `:platform, :deploy_skip_notice`.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Repo
  alias Platform.Tasks

  @github_webhook_path "/api/webhooks/github"
  @repo "acme/notice-repo"

  setup do
    previous = Application.fetch_env(:platform, :deploy_skip_notice)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :deploy_skip_notice, value)
        :error -> Application.delete_env(:platform, :deploy_skip_notice)
      end
    end)

    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Deploy notices #{n}",
        slug: "deploy-notices-#{n}",
        kind: "channel"
      })

    %{space: space}
  end

  defp enable!(space_id, extra \\ []) do
    Application.put_env(
      :platform,
      :deploy_skip_notice,
      Keyword.merge([space_id: space_id, repo: @repo], extra)
    )
  end

  # Mirrors `workflow_run_payload/2` in github_webhook_controller_test.exs,
  # plus the fields the notice reads (run id/attempt/name, repository.full_name).
  defp workflow_run_payload(branch, conclusion, overrides \\ %{}) do
    run =
      Map.merge(
        %{
          "id" => 424_242,
          "run_attempt" => 1,
          "name" => "CI",
          "head_branch" => branch,
          "conclusion" => conclusion,
          "head_sha" => "def4567890abcdef",
          "html_url" => "https://github.com/#{@repo}/actions/runs/424242"
        },
        Map.get(overrides, :run, %{})
      )

    %{
      "action" => "completed",
      "workflow_run" => run,
      "repository" =>
        Map.merge(
          %{"full_name" => @repo, "html_url" => "https://github.com/#{@repo}"},
          Map.get(overrides, :repository, %{})
        )
    }
  end

  defp notices(space_id) do
    from(m in Message,
      where: m.space_id == ^space_id,
      where: fragment("?->>'source' = ?", m.metadata, "deploy_skip_notice"),
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  defp post!(conn, payload), do: signed_github_post(conn, @github_webhook_path, payload)

  describe "posts" do
    test "a failure on main posts exactly one message carrying the run id", %{
      conn: conn,
      space: space
    } do
      enable!(space.id)

      conn = post!(conn, workflow_run_payload("main", "failure"))

      # The response contract of the existing ci_passed path is unchanged:
      # `main` is not a task branch.
      assert %{"status" => "ignored", "reason" => "branch does not match task pattern"} =
               json_response(conn, 200)

      assert [msg] = notices(space.id)
      assert msg.content =~ "Prod did NOT deploy"
      assert msg.content =~ "run 424242 attempt 1"
      assert msg.content =~ "concluded failure"
      assert msg.content =~ "def4567"
      assert msg.content =~ "https://github.com/#{@repo}/actions/runs/424242"

      # Task 01a14b9e stage 2: the remediation names no host.
      assert String.ends_with?(
               msg.content,
               ". this install's deploy hook deploys only on conclusion=success; " <>
                 "a re-run that ends in success deploys. " <>
                 "Otherwise update the install's image by hand."
             )

      refute msg.content =~ "@["
      assert msg.content_type == "text"
      refute msg.log_only

      assert msg.metadata == %{
               "source" => "deploy_skip_notice",
               "run_id" => "424242",
               "run_attempt" => "1",
               "head_sha" => "def4567890abcdef",
               "conclusion" => "failure"
             }
    end

    test "the same delivery twice still gives one message", %{conn: conn, space: space} do
      enable!(space.id)
      payload = workflow_run_payload("main", "failure")

      first = post!(conn, payload)
      second = post!(build_conn(), payload)

      assert json_response(first, 200) == json_response(second, 200)
      assert [_one] = notices(space.id)
    end

    test "the same run_id with attempt 2 posts a second message", %{conn: conn, space: space} do
      enable!(space.id)

      post!(conn, workflow_run_payload("main", "failure"))

      post!(
        build_conn(),
        workflow_run_payload("main", "cancelled", %{run: %{"run_attempt" => 2}})
      )

      assert [a, b] = notices(space.id)
      assert a.metadata["run_attempt"] == "1"
      assert b.metadata["run_attempt"] == "2"
      assert b.content =~ "attempt 2 concluded cancelled"
    end
  end

  describe "does not post" do
    test "on success", %{conn: conn, space: space} do
      enable!(space.id)
      post!(conn, workflow_run_payload("main", "success"))
      assert notices(space.id) == []
    end

    test "on a task branch failure", %{conn: conn, space: space} do
      enable!(space.id)
      post!(conn, workflow_run_payload("task/#{Ecto.UUID.generate()}", "failure"))
      assert notices(space.id) == []
    end

    test "for another workflow (Installer) failing on main", %{conn: conn, space: space} do
      enable!(space.id)
      post!(conn, workflow_run_payload("main", "failure", %{run: %{"name" => "Installer"}}))
      assert notices(space.id) == []
    end

    test "for a different repository", %{conn: conn, space: space} do
      enable!(space.id)

      post!(
        conn,
        workflow_run_payload("main", "failure", %{repository: %{"full_name" => "other/repo"}})
      )

      assert notices(space.id) == []
    end

    test "when unconfigured, and the response is unchanged", %{conn: conn, space: space} do
      payload = workflow_run_payload("main", "failure")

      enable!(space.id)
      enabled = post!(conn, payload) |> json_response(200)
      assert [_] = notices(space.id)

      for cfg <- [[], [space_id: space.id], [repo: @repo]] do
        Application.put_env(:platform, :deploy_skip_notice, cfg)
        disabled = post!(build_conn(), workflow_run_payload("main", "timed_out"))
        assert json_response(disabled, 200) == enabled
      end

      Application.delete_env(:platform, :deploy_skip_notice)
      disabled = post!(build_conn(), workflow_run_payload("main", "timed_out"))
      assert json_response(disabled, 200) == enabled

      # Still only the one message posted while enabled.
      assert [_] = notices(space.id)
    end
  end

  describe "failure paths never change the webhook response" do
    test "a nonexistent space leaves the ci_passed response intact", %{conn: conn} do
      %{task: task, ci_validation: ci_validation} = create_task_with_ci_validation!()
      branch = "task/#{task.id}"

      # Configure the notice to target this task branch so the event QUALIFIES
      # and the notice reaches its space lookup, which fails.
      enable!(Ecto.UUID.generate(), branch: branch, repo: "test/ci-repo")

      payload =
        workflow_run_payload(branch, "failure", %{
          repository: %{
            "full_name" => "test/ci-repo",
            "html_url" => "https://github.com/test/ci-repo"
          }
        })

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = post!(conn, payload)
          send(self(), {:resp, conn.status, json_response(conn, conn.status)})
        end)

      assert_received {:resp, 201, %{"status" => "evaluated", "result" => "failed"}}
      assert log =~ "[DeploySkipNotice] configured space"
      assert Repo.get!(Platform.Tasks.Validation, ci_validation.id).status == "failed"
    end

    test "a missing or malformed space id on main leaves the 200 response unchanged" do
      for space_id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        enable!(space_id)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            conn = post!(build_conn(), workflow_run_payload("main", "failure"))

            assert %{"status" => "ignored", "reason" => "branch does not match task pattern"} =
                     json_response(conn, 200)
          end)

        assert log =~ "[DeploySkipNotice] configured space"
      end
    end
  end

  defp create_task_with_ci_validation! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Notice CI #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/ci-repo"
      })

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Task with CI"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Deploy: PR merge",
        description: "Deploy via PR merge"
      })

    {:ok, _} = Tasks.transition_stage(stage, "running")
    {:ok, ci_validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "ci_passed"})
    {:ok, _pr} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

    %{task: task, ci_validation: ci_validation}
  end
end
