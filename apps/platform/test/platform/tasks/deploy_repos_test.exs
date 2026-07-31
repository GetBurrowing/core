defmodule Platform.Tasks.DeployReposTest do
  @moduledoc """
  `Tasks.resolve_deploy_repos/1` and `Tasks.resolve_deploy_strategy_with_repos/1`.

  The property this stage is built to protect: a task that declares
  nothing resolves to EXACTLY the single repository it resolves to today
  (`project.repo_url`), so no existing plan changes shape.
  """
  use Platform.DataCase, async: true

  alias Platform.Tasks

  @core "https://github.com/Startup-Suite/core"
  @channel "https://github.com/Startup-Suite/claude-code-suite-channel"

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Repo Set Project", repo_url: @core})
    %{project: project}
  end

  defp task_with(project, attrs) do
    {:ok, task} =
      Tasks.create_task(Map.merge(%{project_id: project.id, title: "T"}, attrs))

    task
  end

  describe "resolve_deploy_repos/1 — no declared repo set" do
    test "falls back to the project's single repo", %{project: project} do
      task = task_with(project, %{})

      assert [
               %{
                 repo_url: @core,
                 slug: "Startup-Suite/core",
                 ci: "required",
                 role: :primary,
                 config: %{}
               }
             ] = Tasks.resolve_deploy_repos(task)
    end

    test "carries the strategy-level config onto the fallback entry", %{project: project} do
      task =
        task_with(project, %{
          deploy_strategy: %{"type" => "pr_merge", "config" => %{"merge_method" => "squash"}}
        })

      assert [%{config: %{"merge_method" => "squash"}, slug: "Startup-Suite/core"}] =
               Tasks.resolve_deploy_repos(task)
    end

    test "blank project.repo_url resolves to no repos (not an error)" do
      {:ok, blank} = Tasks.create_project(%{name: "No Repo", repo_url: ""})
      task = task_with(blank, %{})

      assert Tasks.resolve_deploy_repos(task) == []
    end

    test "missing project.repo_url resolves to no repos" do
      {:ok, blank} = Tasks.create_project(%{name: "Nil Repo"})
      task = task_with(blank, %{})

      assert Tasks.resolve_deploy_repos(task) == []
    end

    # `example.invalid` is the fixture convention for "this project has no
    # real repository"; `real_repo_url?/1` in HeartbeatScheduler draws the
    # same line. Guessing a slug out of it would mint a gate watching a
    # repository that does not exist.
    test "non-GitHub project.repo_url resolves to no repos" do
      {:ok, fake} =
        Tasks.create_project(%{name: "Fake Repo", repo_url: "https://example.invalid/a/b"})

      task = task_with(fake, %{})

      assert Tasks.resolve_deploy_repos(task) == []
    end
  end

  describe "resolve_deploy_repos/1 — declared repo set" do
    # The single-repo-WRONG-repo case: the work lives in the channel repo,
    # not the project's repo. One-entry `repos` says so, and every
    # downstream consumer stops reading `project.repo_url`.
    test "a one-entry set overrides project.repo_url", %{project: project} do
      task =
        task_with(project, %{
          deploy_strategy: %{
            "type" => "pr_merge",
            "repos" => [%{"repo_url" => @channel, "ci" => "none"}]
          }
        })

      assert [
               %{
                 repo_url: @channel,
                 slug: "Startup-Suite/claude-code-suite-channel",
                 ci: "none",
                 role: :primary
               }
             ] = Tasks.resolve_deploy_repos(task)
    end

    test "a two-entry set resolves in declaration order with one primary", %{project: project} do
      task =
        task_with(project, %{
          deploy_strategy: %{
            "type" => "pr_merge",
            "repos" => [
              %{"repo_url" => @core},
              %{"repo_url" => "Startup-Suite/openclaw-suite-channel", "ci" => "none"}
            ]
          }
        })

      assert [first, second] = Tasks.resolve_deploy_repos(task)

      assert first.slug == "Startup-Suite/core"
      assert first.ci == "required"
      assert first.role == :primary

      assert second.slug == "Startup-Suite/openclaw-suite-channel"
      assert second.ci == "none"
      assert second.role == :secondary
    end

    test "the bare owner/name spelling is accepted and normalized", %{project: project} do
      task =
        task_with(project, %{
          deploy_strategy: %{
            "type" => "pr_merge",
            "repos" => [%{"repo_url" => "Startup-Suite/core"}]
          }
        })

      assert [%{slug: "Startup-Suite/core"}] = Tasks.resolve_deploy_repos(task)
    end

    test "per-entry config overrides strategy-level config", %{project: project} do
      task =
        task_with(project, %{
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{"auto_merge" => true, "merge_method" => "squash"},
            "repos" => [
              %{"repo_url" => @core},
              %{
                "repo_url" => @channel,
                "ci" => "none",
                "config" => %{"auto_merge" => false}
              }
            ]
          }
        })

      assert [core, channel] = Tasks.resolve_deploy_repos(task)

      assert core.config == %{"auto_merge" => true, "merge_method" => "squash"}
      # Strategy-level keys still inherit; only the overridden key changes.
      assert channel.config == %{"auto_merge" => false, "merge_method" => "squash"}
    end

    test "task-level repos win over the project default strategy" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Defaulted",
          repo_url: @core,
          deploy_config: %{
            "default_strategy" => %{
              "type" => "pr_merge",
              "repos" => [%{"repo_url" => @core}]
            }
          }
        })

      task =
        task_with(project, %{
          deploy_strategy: %{
            "type" => "pr_merge",
            "repos" => [%{"repo_url" => @channel, "ci" => "none"}]
          }
        })

      assert [%{slug: "Startup-Suite/claude-code-suite-channel"}] =
               Tasks.resolve_deploy_repos(task)
    end

    test "a project default repo set resolves when the task declares none" do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Project Set",
          repo_url: @core,
          deploy_config: %{
            "default_strategy" => %{
              "type" => "pr_merge",
              "repos" => [
                %{"repo_url" => @core},
                %{"repo_url" => @channel, "ci" => "none"}
              ]
            }
          }
        })

      task = task_with(project, %{})

      assert [%{slug: "Startup-Suite/core"}, %{slug: "Startup-Suite/claude-code-suite-channel"}] =
               Tasks.resolve_deploy_repos(task)
    end
  end

  describe "resolve_deploy_strategy_with_repos/1" do
    test "attaches the normalized repo set", %{project: project} do
      task =
        task_with(project, %{
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{"merge_method" => "squash"},
            "repos" => [%{"repo_url" => @channel, "ci" => "none"}]
          }
        })

      strategy = Tasks.resolve_deploy_strategy_with_repos(task)

      assert strategy["type"] == "pr_merge"

      assert strategy["repos"] == [
               %{
                 "repo_url" => @channel,
                 "slug" => "Startup-Suite/claude-code-suite-channel",
                 "config" => %{"merge_method" => "squash"},
                 "ci" => "none",
                 "role" => "primary"
               }
             ]
    end

    test "an undeclared task gets a one-entry set from project.repo_url", %{project: project} do
      task = task_with(project, %{deploy_strategy: %{"type" => "pr_merge"}})

      assert [%{"slug" => "Startup-Suite/core", "role" => "primary", "ci" => "required"}] =
               Tasks.resolve_deploy_strategy_with_repos(task)["repos"]
    end

    # An empty `"repos"` list would read downstream as "one gate per repo,
    # of which there are none" — a deploy stage with zero validations,
    # which auto-passes. Absent means "nothing declared", which is the
    # state every pre-existing task is in.
    test "omits the key entirely when no repo resolves" do
      {:ok, blank} = Tasks.create_project(%{name: "No Repo At All"})
      task = task_with(blank, %{deploy_strategy: %{"type" => "pr_merge"}})

      strategy = Tasks.resolve_deploy_strategy_with_repos(task)

      refute Map.has_key?(strategy, "repos")
      assert strategy["type"] == "pr_merge"
    end

    test "leaves a non-pr_merge strategy's other keys intact", %{project: project} do
      task =
        task_with(project, %{
          deploy_strategy: %{"type" => "docker_deploy", "config" => %{"host" => "moon"}}
        })

      strategy = Tasks.resolve_deploy_strategy_with_repos(task)

      assert strategy["type"] == "docker_deploy"
      assert strategy["config"] == %{"host" => "moon"}
    end
  end
end
