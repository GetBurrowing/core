defmodule Platform.Responsibilities.Handlers.SecurityDeployAuditTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.SecurityDeployAudit` —
  the registration-only placeholder for the Security Guard deploy-audit
  responsibility (task `019f3e8e-4406` stage 1). Runtime lands in
  stage 4. See ADR-0043.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.SecurityDeployAudit
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: SecurityDeployAudit.key(),
      feature: "security",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => SecurityDeployAudit.topic()},
      scope: "per_org",
      context_provided: [],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns one spec with the canonical shape + null topic" do
      specs = SecurityDeployAudit.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "security.deploy_audit"
      assert spec.feature == "security"
      assert spec.trigger_kind == "event_topic"
      assert spec.trigger_config == %{"topic" => "platform.security.sweeper_only"}
      assert spec.scope == "per_org"
      assert spec.context_provided == []
      assert spec.default_prompt_template == nil
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values" do
      [spec] = SecurityDeployAudit.register()
      assert spec.output_contract == %{"findings" => "list[map]"}
    end

    test "metadata carries the placeholder marker + cadence" do
      [spec] = SecurityDeployAudit.register()

      assert spec.metadata["owner"] == "platform.security"
      assert spec.metadata["role"] == "security_guard"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["executor"] == "platform.security.sweeper"
      assert spec.metadata["cadence"] == "0 3 * * 1"
    end
  end

  describe "gather_context/2" do
    test "returns an empty context map" do
      assert {:ok, ctx} = SecurityDeployAudit.gather_context(responsibility(), %{})
      assert ctx == %{}
    end
  end

  describe "handle_output/3" do
    test "logs the placeholder line and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok =
                   SecurityDeployAudit.handle_output(
                     responsibility(),
                     %{"findings" => []},
                     %{kind: :event_topic}
                   )
        end)

      assert log =~ "[security.deploy_audit]"
      assert log =~ "placeholder handler"
      assert log =~ "019f3e8e-4406"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3" do
      log =
        capture_log(fn ->
          assert :ok = SecurityDeployAudit.handle_output(responsibility(), %{"findings" => []})
        end)

      assert log =~ "[security.deploy_audit]"
    end
  end

  describe "key/0 + topic/0" do
    test "key/0 matches the registered spec key" do
      [spec] = SecurityDeployAudit.register()
      assert SecurityDeployAudit.key() == spec.key
      assert SecurityDeployAudit.key() == "security.deploy_audit"
    end

    test "topic/0 matches the registered null topic" do
      assert SecurityDeployAudit.topic() == "platform.security.sweeper_only"
    end
  end
end
