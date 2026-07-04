defmodule Platform.Responsibilities.Handlers.TaskUnblockTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.TaskUnblock` — the
  Triage Officer bundle's registration-only placeholder that fills out
  the `tasks.unblock` responsibility row so `Platform.Roles.Seeds` no
  longer references a key with no matching `responsibilities` row.

  Runtime lands in a follow-up ticket; this test file locks the spec
  shape + no-op behaviour so downstream stages catch drift.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.TaskUnblock
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: TaskUnblock.key(),
      feature: "tasks",
      trigger_kind: "chat_pattern",
      trigger_config: %{"regex" => "(?i)\\b(blocked|blocker|stuck)\\b"},
      scope: "per_space",
      context_provided: ["org_identity"],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature" do
      specs = TaskUnblock.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "tasks.unblock"
      assert spec.feature == "tasks"
      assert spec.trigger_kind == "chat_pattern"
      assert spec.trigger_config == %{"regex" => "(?i)\\b(blocked|blocker|stuck)\\b"}
      assert spec.scope == "per_space"
      assert spec.context_provided == ["org_identity"]
      assert spec.default_prompt_template == "tasks.unblock.v1"
      assert spec.cost_profile == "low_freq_capable"
    end

    test "trigger_config regex compiles and matches the intended verbs" do
      [spec] = TaskUnblock.register()
      regex = spec.trigger_config["regex"]
      {:ok, compiled} = Regex.compile(regex)

      assert Regex.match?(compiled, "I'm blocked on the migration")
      assert Regex.match?(compiled, "this is a hard BLOCKER")
      assert Regex.match?(compiled, "feeling stuck today")
      refute Regex.match?(compiled, "no news to report")
    end

    test "output_contract is a map of string values — satisfies the M1 schema invariant" do
      [spec] = TaskUnblock.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)
    end

    test "metadata flags the placeholder + names the owner + role" do
      [spec] = TaskUnblock.register()

      assert spec.metadata["owner"] == "platform.tasks"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["role"] == "triage_officer"
    end
  end

  describe "gather_context/2" do
    test "returns a missing? slot for org_identity" do
      assert {:ok, ctx} = TaskUnblock.gather_context(responsibility(), %{})
      assert Map.has_key?(ctx, :org_identity)
      assert ctx.org_identity.missing? == true
    end
  end

  describe "handle_output/3" do
    test "logs the placeholder line and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok =
                   TaskUnblock.handle_output(
                     responsibility(),
                     %{"suggestions" => ["ping the reviewer"]},
                     %{kind: :chat_pattern}
                   )
        end)

      assert log =~ "[tasks.unblock]"
      assert log =~ "placeholder handler"
      assert log =~ "tasks.unblock.v1"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3" do
      log =
        capture_log(fn ->
          assert :ok = TaskUnblock.handle_output(responsibility(), %{"suggestions" => []})
        end)

      assert log =~ "[tasks.unblock]"
      assert log =~ "placeholder handler"
    end
  end

  describe "key/0 and template_slug/0" do
    test "key/0 matches the registered spec key" do
      [spec] = TaskUnblock.register()
      assert TaskUnblock.key() == spec.key
      assert TaskUnblock.key() == "tasks.unblock"
    end

    test "template_slug/0 matches the registered default_prompt_template" do
      [spec] = TaskUnblock.register()
      assert TaskUnblock.template_slug() == spec.default_prompt_template
      assert TaskUnblock.template_slug() == "tasks.unblock.v1"
    end
  end
end
