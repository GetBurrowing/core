defmodule Platform.Tasks.DeployResolverTest do
  @moduledoc "Tests for Platform.Tasks.DeployResolver — deploy target resolution."
  use Platform.DataCase, async: false

  alias Platform.Context
  alias Platform.Execution.CredentialLease
  alias Platform.Tasks
  alias Platform.Tasks.{ContextHydrator, DeployResolver}

  @docker_target %{
    "name" => "production",
    "type" => "docker_compose",
    "config" => %{
      "host" => "dev@192.0.2.234",
      "stack_path" => "~/docker/stacks/my-app",
      "image_registry" => "ghcr.io/org/repo",
      "watchtower" => true
    }
  }

  @fly_target %{
    "name" => "staging",
    "type" => "fly",
    "config" => %{
      "app" => "my-fly-app",
      "region" => "iad"
    }
  }

  defp create_project(deploy_targets \\ [@docker_target, @fly_target]) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Deploy Test #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/org/deploy-test",
        deploy_config: %{"deploy_targets" => deploy_targets}
      })

    project
  end

  # ── resolve/2 ──────────────────────────────────────────────────────────

  describe "resolve/2" do
    test "resolves an existing target by name" do
      project = create_project()
      assert {:ok, target} = DeployResolver.resolve(project, "production")
      assert target["type"] == "docker_compose"
      assert target["config"]["host"] == "dev@192.0.2.234"
    end

    test "resolves a second target" do
      project = create_project()
      assert {:ok, target} = DeployResolver.resolve(project, "staging")
      assert target["type"] == "fly"
    end

    test "returns error for missing target" do
      project = create_project()
      assert {:error, {:target_not_found, "nope"}} = DeployResolver.resolve(project, "nope")
    end

    test "returns error when no targets configured" do
      project = create_project([])

      assert {:error, {:target_not_found, "production"}} =
               DeployResolver.resolve(project, "production")
    end

    test "returns error when deploy_config is nil" do
      {:ok, project} = Tasks.create_project(%{name: "Empty", deploy_config: nil})
      assert {:error, {:target_not_found, "x"}} = DeployResolver.resolve(project, "x")
    end
  end

  # ── to_context_items/1 ─────────────────────────────────────────────────

  describe "to_context_items/1" do
    test "produces base and config items for docker_compose" do
      items = DeployResolver.to_context_items(@docker_target)
      item_map = Map.new(items)

      assert item_map["deploy.target.name"] == "production"
      assert item_map["deploy.target.type"] == "docker_compose"
      assert item_map["deploy.target.config.host"] == "dev@192.0.2.234"
      assert item_map["deploy.target.config.stack_path"] == "~/docker/stacks/my-app"
      assert item_map["deploy.target.config.image_registry"] == "ghcr.io/org/repo"
      assert item_map["deploy.target.config.watchtower"] == "true"
    end

    test "produces items for fly target" do
      items = DeployResolver.to_context_items(@fly_target)
      item_map = Map.new(items)

      assert item_map["deploy.target.name"] == "staging"
      assert item_map["deploy.target.type"] == "fly"
      assert item_map["deploy.target.config.app"] == "my-fly-app"
      assert item_map["deploy.target.config.region"] == "iad"
    end

    test "encodes non-string config values" do
      target = %{
        "name" => "test",
        "type" => "custom",
        "config" => %{"count" => 42, "enabled" => false, "tags" => ["a", "b"]}
      }

      items = DeployResolver.to_context_items(target)
      item_map = Map.new(items)

      assert item_map["deploy.target.config.count"] == "42"
      assert item_map["deploy.target.config.enabled"] == "false"
      assert item_map["deploy.target.config.tags"] == Jason.encode!(["a", "b"])
    end
  end

  # ── to_env/2 ───────────────────────────────────────────────────────────

  describe "to_env/2" do
    test "produces DEPLOY_ prefixed env vars for docker_compose" do
      env = DeployResolver.to_env(@docker_target)

      assert env["DEPLOY_TARGET_NAME"] == "production"
      assert env["DEPLOY_TARGET_TYPE"] == "docker_compose"
      assert env["DEPLOY_HOST"] == "dev@192.0.2.234"
      assert env["DEPLOY_STACK_PATH"] == "~/docker/stacks/my-app"
      assert env["DEPLOY_IMAGE_REGISTRY"] == "ghcr.io/org/repo"
      assert env["DEPLOY_WATCHTOWER"] == "true"
    end

    test "produces env vars for fly target" do
      env = DeployResolver.to_env(@fly_target)

      assert env["DEPLOY_TARGET_NAME"] == "staging"
      assert env["DEPLOY_TARGET_TYPE"] == "fly"
      assert env["DEPLOY_APP"] == "my-fly-app"
      assert env["DEPLOY_REGION"] == "iad"
    end

    test "merges credential lease env vars" do
      {:ok, lease} =
        CredentialLease.lease(:custom,
          run_id: "run-1",
          credentials: [EXTRA_VAR: "secret"]
        )

      env = DeployResolver.to_env(@docker_target, lease)

      # Deploy vars present
      assert env["DEPLOY_HOST"] == "dev@192.0.2.234"
      # Lease vars merged
      assert env["EXTRA_VAR"] == "secret"
    end

    test "without lease, no extra vars" do
      env = DeployResolver.to_env(@docker_target, nil)
      assert env["DEPLOY_HOST"] == "dev@192.0.2.234"
      refute Map.has_key?(env, "GITHUB_TOKEN")
    end
  end

  # ── lease_for_target/3 ────────────────────────────────────────────────

  describe "lease_for_target/3" do
    test "creates a custom credential lease with deploy env vars" do
      assert {:ok, %CredentialLease{} = lease} =
               DeployResolver.lease_for_target(@docker_target, "run-123")

      assert lease.kind == :custom
      assert lease.run_id == "run-123"

      env = CredentialLease.to_env(lease)
      assert env["DEPLOY_HOST"] == "dev@192.0.2.234"
      assert env["DEPLOY_STACK_PATH"] == "~/docker/stacks/my-app"
      assert env["DEPLOY_TARGET_NAME"] == "production"
    end

    test "lease is valid immediately" do
      {:ok, lease} = DeployResolver.lease_for_target(@fly_target, "run-456")
      assert CredentialLease.valid?(lease)
    end
  end

  # ── Integration: hydrate_for_run with deploy_target ────────────────────

  describe "ContextHydrator integration" do
    test "hydrate_for_run with deploy_target pushes deploy items into project context" do
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Deploy integration test",
          description: "Test deploy target hydration"
        })

      run_id = Ecto.UUID.generate()

      assert {:ok, _version} =
               ContextHydrator.hydrate_for_run(task.id, run_id, deploy_target: "production")

      # Verify deploy items in project-scoped context
      project_scope = %{project_id: project.id}

      {:ok, %{items: items}} = Context.snapshot(project_scope)
      item_map = Map.new(items, fn item -> {item.key, item.value} end)

      assert item_map["deploy.target.name"] == "production"
      assert item_map["deploy.target.type"] == "docker_compose"
      assert item_map["deploy.target.config.host"] == "dev@192.0.2.234"
    end

    test "hydrate_for_run without deploy_target does not push deploy items" do
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "No deploy test",
          description: "No deploy target"
        })

      run_id = Ecto.UUID.generate()
      assert {:ok, _version} = ContextHydrator.hydrate_for_run(task.id, run_id)

      project_scope = %{project_id: project.id}
      {:ok, %{items: items}} = Context.snapshot(project_scope)
      item_map = Map.new(items, fn item -> {item.key, item.value} end)

      refute Map.has_key?(item_map, "deploy.target.name")
    end

    test "hydrate_for_run with missing deploy target silently skips" do
      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Missing target test",
          description: "Target does not exist"
        })

      run_id = Ecto.UUID.generate()

      assert {:ok, _version} =
               ContextHydrator.hydrate_for_run(task.id, run_id, deploy_target: "nonexistent")

      project_scope = %{project_id: project.id}
      {:ok, %{items: items}} = Context.snapshot(project_scope)
      item_map = Map.new(items, fn item -> {item.key, item.value} end)

      refute Map.has_key?(item_map, "deploy.target.name")
    end

    test "emits deploy_target_resolved telemetry" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:platform, :tasks, :deploy_target_resolved]
        ])

      project = create_project()

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Telemetry test",
          description: "Test telemetry emission"
        })

      run_id = Ecto.UUID.generate()

      {:ok, _} = ContextHydrator.hydrate_for_run(task.id, run_id, deploy_target: "production")

      assert_received {[:platform, :tasks, :deploy_target_resolved], ^ref, _measurements,
                       metadata}

      assert metadata.project_id == project.id
      assert metadata.target_name == "production"
      assert metadata.target_type == "docker_compose"
    end
  end
end
