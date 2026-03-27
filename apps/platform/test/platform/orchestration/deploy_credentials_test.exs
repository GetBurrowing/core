defmodule Platform.Orchestration.DeployCredentialsTest do
  @moduledoc """
  Tests for deploy credential injection via ContextAssembler and
  credential lifecycle (leasing, revocation).
  """
  use Platform.DataCase, async: true

  alias Platform.Execution.CredentialLease
  alias Platform.Orchestration.ContextAssembler
  alias Platform.Tasks
  alias Platform.Tasks.DeployResolver

  setup do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Deploy Cred Test #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/deploy-creds",
        deploy_config: %{
          "default_strategy" => %{
            "type" => "docker_deploy",
            "config" => %{
              "target" => "production",
              "host" => "dev@192.0.2.234",
              "image" => "ghcr.io/org/app:latest"
            }
          },
          "deploy_targets" => [
            %{
              "name" => "production",
              "type" => "docker_compose",
              "config" => %{
                "host" => "dev@192.0.2.234",
                "stack_path" => "~/docker/stacks/app"
              }
            }
          ]
        }
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Deploy cred test task"
      })

    {:ok, plan} =
      Tasks.create_plan(%{
        task_id: task.id,
        status: "approved"
      })

    {:ok, deploy_stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Deploy: Docker deploy",
        description: "Docker deploy with credentials"
      })

    {:ok, _} = Tasks.transition_stage(deploy_stage, "running")

    {:ok, ci_validation} =
      Tasks.create_validation(%{
        stage_id: deploy_stage.id,
        kind: "ci_passed"
      })

    %{
      project: project,
      task: task,
      plan: plan,
      deploy_stage: deploy_stage,
      ci_validation: ci_validation
    }
  end

  describe "ContextAssembler.build/2 with deploy_lease" do
    test "includes deploy_credentials when a valid lease is provided", %{task: task} do
      {:ok, lease} =
        CredentialLease.lease(:custom,
          run_id: "test-run",
          credentials: [
            DEPLOY_HOST: "dev@192.0.2.234",
            DEPLOY_SSH_KEY: "ssh-rsa AAAA..."
          ]
        )

      context = ContextAssembler.build(task.id, lease)

      assert context != nil
      assert context.deploy_credentials != nil
      assert context.deploy_credentials["DEPLOY_HOST"] == "dev@192.0.2.234"
      assert context.deploy_credentials["DEPLOY_SSH_KEY"] == "ssh-rsa AAAA..."
    end

    test "omits deploy_credentials when no lease is provided", %{task: task} do
      context = ContextAssembler.build(task.id)
      refute Map.has_key?(context, :deploy_credentials)
    end

    test "omits deploy_credentials when nil lease is provided", %{task: task} do
      context = ContextAssembler.build(task.id, nil)
      refute Map.has_key?(context, :deploy_credentials)
    end

    test "omits deploy_credentials when lease is expired", %{task: task} do
      {:ok, lease} =
        CredentialLease.lease(:custom,
          run_id: "test-run",
          ttl: 0,
          credentials: [DEPLOY_HOST: "host"]
        )

      # Wait a moment for expiry
      Process.sleep(10)

      context = ContextAssembler.build(task.id, lease)
      refute Map.has_key?(context, :deploy_credentials)
    end

    test "omits deploy_credentials when lease is revoked", %{task: task} do
      {:ok, lease} =
        CredentialLease.lease(:custom,
          run_id: "test-run",
          credentials: [DEPLOY_HOST: "host"]
        )

      {:ok, revoked} = CredentialLease.revoke(lease)
      context = ContextAssembler.build(task.id, revoked)
      refute Map.has_key?(context, :deploy_credentials)
    end
  end

  describe "DeployResolver.lease_for_target/3 integration" do
    test "creates a custom lease with deploy target env vars", %{project: project} do
      {:ok, target} = DeployResolver.resolve(project, "production")

      {:ok, lease} = DeployResolver.lease_for_target(target, "task-123:stage-456", ttl: 900)

      assert lease.kind == :custom
      assert lease.run_id == "task-123:stage-456"
      assert CredentialLease.valid?(lease)

      env = CredentialLease.to_env(lease)
      assert env["DEPLOY_TARGET_NAME"] == "production"
      assert env["DEPLOY_TARGET_TYPE"] == "docker_compose"
      assert env["DEPLOY_HOST"] == "dev@192.0.2.234"
      assert env["DEPLOY_STACK_PATH"] == "~/docker/stacks/app"
    end

    test "lease can be revoked", %{project: project} do
      {:ok, target} = DeployResolver.resolve(project, "production")
      {:ok, lease} = DeployResolver.lease_for_target(target, "run-1")

      assert CredentialLease.valid?(lease)

      {:ok, revoked} = CredentialLease.revoke(lease)
      refute CredentialLease.valid?(revoked)
    end
  end

  describe "credential lifecycle" do
    test "lease respects TTL", %{project: project} do
      {:ok, target} = DeployResolver.resolve(project, "production")
      {:ok, lease} = DeployResolver.lease_for_target(target, "run-ttl", ttl: 0)

      Process.sleep(10)
      refute CredentialLease.valid?(lease)
    end

    test "resolve returns error for unknown target", %{project: project} do
      assert {:error, {:target_not_found, "nonexistent"}} =
               DeployResolver.resolve(project, "nonexistent")
    end
  end
end
