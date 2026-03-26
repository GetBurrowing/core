defmodule PlatformWeb.GithubWebhookControllerTest do
  use PlatformWeb.ConnCase, async: true

  alias Platform.Changelog
  alias Platform.Tasks

  @github_webhook_path "/api/webhooks/github"

  defp create_task! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Webhook Test #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/repo"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Fix something"
      })

    task
  end

  defp merged_pr_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "action" => "closed",
        "pull_request" => %{
          "merged" => true,
          "title" => "feat: add changelog module",
          "number" => System.unique_integer([:positive]),
          "html_url" => "https://github.com/test/repo/pull/1",
          "merge_commit_sha" => "abc123def456",
          "merged_at" => "2026-03-25T01:00:00Z",
          "body" => "Added the changelog module for tracking changes.",
          "user" => %{"login" => "dev-user"},
          "head" => %{"ref" => "feat/changelog"}
        }
      },
      overrides
    )
  end

  describe "POST #{@github_webhook_path}" do
    test "creates a changelog entry for a merged PR", %{conn: conn} do
      payload = merged_pr_payload()

      conn = post(conn, @github_webhook_path, payload)

      assert %{"status" => "created", "id" => id} = json_response(conn, 201)
      assert is_binary(id)

      entry = Changelog.get_entry(id)
      assert entry.title == "add changelog module"
      assert entry.tags == ["feature"]
      assert entry.author == "dev-user"
    end

    test "ignores non-merged closed PRs", %{conn: conn} do
      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => false,
            "title" => "not merged",
            "number" => 999
          }
        })

      conn = post(conn, @github_webhook_path, payload)
      assert %{"status" => "ignored"} = json_response(conn, 200)
    end

    test "ignores non-pull_request events", %{conn: conn} do
      conn = post(conn, @github_webhook_path, %{"action" => "opened", "issue" => %{}})
      assert %{"status" => "ignored"} = json_response(conn, 200)
    end

    test "links to task when branch contains task ID", %{conn: conn} do
      task = create_task!()

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "fix: resolve the thing",
            "number" => System.unique_integer([:positive]),
            "html_url" => "https://github.com/test/repo/pull/2",
            "merge_commit_sha" => "def456",
            "merged_at" => "2026-03-25T02:00:00Z",
            "body" => "",
            "user" => %{"login" => "agent-bot"},
            "head" => %{"ref" => "task/#{task.id}"}
          }
        })

      conn = post(conn, @github_webhook_path, payload)

      assert %{"status" => "created", "id" => id} = json_response(conn, 201)
      entry = Changelog.get_entry(id)
      assert entry.task_id == task.id
      assert entry.tags == ["fix"]
    end

    test "deduplicates by PR number", %{conn: conn} do
      pr_number = System.unique_integer([:positive])

      payload =
        merged_pr_payload(%{
          "pull_request" => %{
            "merged" => true,
            "title" => "feat: first",
            "number" => pr_number,
            "html_url" => "https://github.com/test/repo/pull/#{pr_number}",
            "merge_commit_sha" => "aaa",
            "merged_at" => "2026-03-25T01:00:00Z",
            "body" => "",
            "user" => %{"login" => "dev"},
            "head" => %{"ref" => "feat/thing"}
          }
        })

      conn1 = post(conn, @github_webhook_path, payload)
      assert %{"status" => "created"} = json_response(conn1, 201)

      conn2 = post(conn, @github_webhook_path, payload)
      assert %{"status" => "error"} = json_response(conn2, 422)
    end
  end
end
