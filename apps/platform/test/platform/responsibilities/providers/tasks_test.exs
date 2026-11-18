defmodule Platform.Responsibilities.Providers.TasksTest do
  @moduledoc """
  Tests for the task 019f2455 stage 4 shim
  `Platform.Responsibilities.Providers.Tasks` — the seam that lets the
  M6 Router's `provider_module_for("tasks")` lookup find a handler for
  `tasks.triage` even though the handler lives at `Handlers.TaskTriage`.
  `tasks.unblock` and `tasks.weekly_review` were registration-only stubs
  and were removed in the super agents restructure; they must now resolve
  to no handler.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.TaskTriage
  alias Platform.Responsibilities.Providers.Tasks, as: TasksProvider
  alias Platform.Responsibilities.Responsibility

  defp triage_responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: TaskTriage.key(),
      feature: "tasks",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 9 * * 1-5"},
      scope: "per_project",
      context_provided: ["org_identity"],
      enabled: true
    }
  end

  describe "register/0" do
    test "aggregates the per-handler register specs" do
      specs = TasksProvider.register()
      keys = Enum.map(specs, & &1.key)

      assert keys == ["tasks.triage"]
    end
  end

  describe "handler_for/1" do
    test "resolves tasks.triage and nothing for the removed stub keys" do
      assert TasksProvider.handler_for("tasks.triage") == Handlers.TaskTriage
      assert TasksProvider.handler_for("tasks.unblock") == nil
      assert TasksProvider.handler_for("tasks.weekly_review") == nil
    end

    test "resolves via a Responsibility struct too" do
      assert TasksProvider.handler_for(triage_responsibility()) == Handlers.TaskTriage
    end

    test "returns nil for unknown keys" do
      assert TasksProvider.handler_for("tasks.brand_new_thing") == nil
      assert TasksProvider.handler_for(nil) == nil
    end
  end

  describe "handle_output/3" do
    test "routes tasks.triage to the TaskTriage handler" do
      log =
        capture_log(fn ->
          assert :ok =
                   TasksProvider.handle_output(
                     triage_responsibility(),
                     %{"triage" => []},
                     %{kind: :cron}
                   )
        end)

      assert log =~ "[tasks.triage]"
      assert log =~ "placeholder handler"
    end

    test "returns {:error, :unknown_tasks_responsibility} for unmapped keys" do
      bogus = %Responsibility{
        id: Ecto.UUID.generate(),
        key: "tasks.brand_new_thing",
        feature: "tasks",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "0 1 * * *"},
        scope: "per_project",
        enabled: true
      }

      log =
        capture_log(fn ->
          assert {:error, :unknown_tasks_responsibility} =
                   TasksProvider.handle_output(bogus, %{"triage" => []}, %{kind: :cron})
        end)

      assert log =~ "[tasks provider]"
      assert log =~ "unknown responsibility key"
    end
  end

  describe "handle_output/2" do
    test "delegates the arity-2 form to the matching handler" do
      log =
        capture_log(fn ->
          assert :ok = TasksProvider.handle_output(triage_responsibility(), %{"triage" => []})
        end)

      assert log =~ "[tasks.triage]"
    end
  end

  describe "gather_context/2" do
    test "delegates to the matching handler and merges its slots" do
      assert {:ok, ctx} = TasksProvider.gather_context(triage_responsibility(), %{})
      assert Map.has_key?(ctx, :org_identity)
    end

    test "returns unknown_tasks_responsibility for unmapped keys" do
      bogus = %Responsibility{
        id: Ecto.UUID.generate(),
        key: "tasks.brand_new_thing",
        feature: "tasks",
        trigger_kind: "cron",
        trigger_config: %{"expression" => "0 1 * * *"},
        scope: "per_project",
        enabled: true
      }

      log =
        capture_log(fn ->
          assert {:error, :unknown_tasks_responsibility} =
                   TasksProvider.gather_context(bogus, %{})
        end)

      assert log =~ "[tasks provider]"
    end
  end
end
