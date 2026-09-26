defmodule Platform.Responsibilities.Handlers.TaskTriageTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.TaskTriage` — the
  Triage Officer bundle's registration-only placeholder that fills out
  the `tasks.triage` responsibility row so `Platform.Roles.Seeds` no
  longer references a key with no matching `responsibilities` row.

  Runtime lands in a follow-up ticket; this test file locks the spec
  shape + no-op behaviour so downstream stages catch drift.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.TaskTriage
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
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
    test "returns exactly one spec with the canonical key + feature" do
      specs = TaskTriage.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "tasks.triage"
      assert spec.feature == "tasks"
      assert spec.trigger_kind == "cron"
      assert spec.trigger_config == %{"expression" => "0 9 * * 1-5"}
      assert spec.scope == "per_project"
      assert spec.context_provided == ["org_identity"]
      assert spec.default_prompt_template == "tasks.triage.v1"
      assert spec.cost_profile == "high_freq_low_cost"
    end

    test "output_contract is a map of string values — satisfies the M1 schema invariant" do
      [spec] = TaskTriage.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)
    end

    test "metadata flags the placeholder + names the owner + role" do
      [spec] = TaskTriage.register()

      assert spec.metadata["owner"] == "platform.tasks"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["role"] == "triage_officer"
      # Task 01a0b4d1: retired from dispatch via the Router's inert gate.
      assert spec.metadata["dispatch"] == "inert"
    end
  end

  describe "gather_context/2" do
    test "returns a missing? slot for org_identity" do
      assert {:ok, ctx} = TaskTriage.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :org_identity)
      assert ctx.org_identity.missing? == true
    end
  end

  describe "handle_output/3" do
    test "logs the placeholder line and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok =
                   TaskTriage.handle_output(
                     responsibility(),
                     %{"triage" => []},
                     %{kind: :cron}
                   )
        end)

      assert log =~ "[tasks.triage]"
      assert log =~ "placeholder handler"
      assert log =~ "tasks.triage.v1"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3" do
      log =
        capture_log(fn ->
          assert :ok = TaskTriage.handle_output(responsibility(), %{"triage" => []})
        end)

      assert log =~ "[tasks.triage]"
      assert log =~ "placeholder handler"
    end
  end

  describe "key/0 and template_slug/0" do
    test "key/0 matches the registered spec key" do
      [spec] = TaskTriage.register()
      assert TaskTriage.key() == spec.key
      assert TaskTriage.key() == "tasks.triage"
    end

    test "template_slug/0 matches the registered default_prompt_template" do
      [spec] = TaskTriage.register()
      assert TaskTriage.template_slug() == spec.default_prompt_template
      assert TaskTriage.template_slug() == "tasks.triage.v1"
    end
  end
end
