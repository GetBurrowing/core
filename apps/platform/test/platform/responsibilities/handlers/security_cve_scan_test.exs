defmodule Platform.Responsibilities.Handlers.SecurityCveScanTest do
  @moduledoc """
  Tests for `Platform.Responsibilities.Handlers.SecurityCveScan` — the
  registration-only placeholder that gives the Security Guard role
  (task `019f3e8e-4406`) a real responsibility row to bind to. Runtime
  lands in stage 3; this file locks the spec shape + no-op behaviour
  so downstream stages catch drift. See ADR-0043 for design rationale.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers.SecurityCveScan
  alias Platform.Responsibilities.Responsibility

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: SecurityCveScan.key(),
      feature: "security",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => SecurityCveScan.topic()},
      scope: "per_org",
      context_provided: [],
      enabled: true
    }
  end

  describe "register/0" do
    test "returns exactly one spec with the canonical key + feature + null topic" do
      specs = SecurityCveScan.register()

      assert length(specs) == 1
      [spec] = specs

      assert spec.key == "security.cve_scan"
      assert spec.feature == "security"
      assert spec.trigger_kind == "event_topic"

      # Null topic — no publisher ever broadcasts to it. The Router
      # subscribes as usual (so no special-case) but the subscription is
      # a genuine no-op. Sweeper (stage 2+) drives the cadence.
      assert spec.trigger_config == %{"topic" => "platform.security.sweeper_only"}

      assert spec.scope == "per_org"
      assert spec.context_provided == []
      assert spec.default_prompt_template == nil
      assert spec.cost_profile == "low_freq_capable"
    end

    test "output_contract is a map of string values — satisfies the M1 schema invariant" do
      [spec] = SecurityCveScan.register()

      Enum.each(spec.output_contract, fn {key, value} ->
        assert is_binary(key)
        assert is_binary(value), "#{inspect(key)}=#{inspect(value)} must be a string type name"
      end)

      assert spec.output_contract == %{"findings" => "list[map]"}
    end

    test "metadata carries the placeholder marker, owner, role, executor, and cadence" do
      [spec] = SecurityCveScan.register()

      assert spec.metadata["owner"] == "platform.security"
      assert spec.metadata["role"] == "security_guard"
      assert spec.metadata["status"] == "placeholder"
      assert spec.metadata["executor"] == "platform.security.sweeper"
      # Weekly Monday 03:00 UTC — Sweeper (stage 2+) reads this via
      # Platform.Responsibilities.Cron to figure out when to fire.
      assert spec.metadata["cadence"] == "0 3 * * 1"
    end
  end

  describe "gather_context/2" do
    test "returns an empty context map — scanner runtime gathers its own lockfile context" do
      assert {:ok, ctx} = SecurityCveScan.gather_context(responsibility(), %{})
      assert ctx == %{}
    end
  end

  describe "handle_output/3" do
    test "logs the placeholder line and returns :ok" do
      log =
        capture_log(fn ->
          assert :ok =
                   SecurityCveScan.handle_output(
                     responsibility(),
                     %{"findings" => []},
                     %{kind: :event_topic}
                   )
        end)

      assert log =~ "[security.cve_scan]"
      assert log =~ "placeholder handler"
      assert log =~ "019f3e8e-4406"
    end
  end

  describe "handle_output/2" do
    test "arity-2 delegates to arity-3" do
      log =
        capture_log(fn ->
          assert :ok = SecurityCveScan.handle_output(responsibility(), %{"findings" => []})
        end)

      assert log =~ "[security.cve_scan]"
      assert log =~ "placeholder handler"
    end
  end

  describe "key/0 + topic/0" do
    test "key/0 matches the registered spec key" do
      [spec] = SecurityCveScan.register()
      assert SecurityCveScan.key() == spec.key
      assert SecurityCveScan.key() == "security.cve_scan"
    end

    test "topic/0 matches the registered null topic" do
      [spec] = SecurityCveScan.register()
      assert SecurityCveScan.topic() == spec.trigger_config["topic"]
      assert SecurityCveScan.topic() == "platform.security.sweeper_only"
    end
  end
end
