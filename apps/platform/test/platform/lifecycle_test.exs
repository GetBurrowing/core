defmodule Platform.LifecycleTest do
  use Platform.DataCase, async: true

  import Platform.TenancyFixtures

  alias Platform.Lifecycle
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Tasks
  alias Platform.Tasks.Project

  @edge "planning.entered"

  setup context do
    name = :"lifecycle_registry_#{:erlang.phash2(context.test)}"
    start_supervised!({StepRegistry, name: name})

    previous = Application.get_env(:platform, :lifecycle_step_registry)
    Application.put_env(:platform, :lifecycle_step_registry, name)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :lifecycle_step_registry)
        value -> Application.put_env(:platform, :lifecycle_step_registry, value)
      end
    end)

    :ok
  end

  defp step(name), do: %{"step" => name, "await" => false, "can_divert" => false}

  describe "resolve_pipeline/1" do
    test "returns the pipeline map stored under the project's config key" do
      pipeline = %{@edge => [step("notify")]}

      {:ok, project} =
        Tasks.create_project(%{name: "Has Pipeline", config: %{"lifecycle_pipeline" => pipeline}})

      assert Lifecycle.resolve_pipeline(project) == pipeline
    end

    test "returns %{} — not nil — for a project of a persisted org with no pipeline" do
      org_id = tenant_org_id("soylent")
      {:ok, project} = Tasks.create_project(%{name: "No Pipeline", org_id: org_id})

      # Single-source resolution: the project row is the only thing
      # consulted. The org exists and is persisted; it contributes
      # nothing, because there is no org tier to contribute from.
      assert project.org_id == org_id
      assert Lifecycle.resolve_pipeline(project) == %{}
      refute is_nil(Lifecycle.resolve_pipeline(project))
    end

    test "returns %{} when config carries unrelated keys" do
      {:ok, project} =
        Tasks.create_project(%{name: "Other Config", config: %{"unrelated" => "value"}})

      assert Lifecycle.resolve_pipeline(project) == %{}
    end

    test "returns %{} for a malformed non-map pipeline value" do
      project = %Project{config: %{"lifecycle_pipeline" => "nope"}}
      assert Lifecycle.resolve_pipeline(project) == %{}
    end
  end

  describe "resolve_steps/2" do
    test "returns the steps for an edge in DECLARED ORDER" do
      first = step("notify")
      second = Map.put(step("notify"), "label", "second")
      third = Map.put(step("notify"), "label", "third")

      {:ok, project} =
        Tasks.create_project(%{
          name: "Ordered",
          config: %{"lifecycle_pipeline" => %{@edge => [first, second, third]}}
        })

      # Explicit list equality: order is the pipeline's semantics, so a
      # set-membership assertion would not be testing the thing.
      assert Lifecycle.resolve_steps(project, @edge) == [first, second, third]
    end

    test "returns [] for an unconfigured edge and for a project with no pipeline" do
      {:ok, configured} =
        Tasks.create_project(%{
          name: "One Edge",
          config: %{"lifecycle_pipeline" => %{@edge => [step("notify")]}}
        })

      {:ok, bare} = Tasks.create_project(%{name: "Bare"})

      assert Lifecycle.resolve_steps(configured, "some.other.edge") == []
      assert Lifecycle.resolve_steps(bare, @edge) == []
    end
  end

  describe "config_key/0" do
    test "names the key the project row stores the pipeline under" do
      assert Lifecycle.config_key() == "lifecycle_pipeline"
    end
  end
end
