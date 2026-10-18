defmodule Platform.Security.SweeperTest do
  @moduledoc """
  Tests for `Platform.Security.Sweeper` (task `019f3e8e-4406` stage
  2, ADR-0043).

  The load-bearing invariant proved here is the
  progressive-enhancement contract: with no `security_guard` role
  assignment in place, `sweep_now/1` files zero tasks, invokes zero
  scanner modules, and emits `[:platform, :responsibility, :unfilled]`
  telemetry once per key. Stages 3-5 add real scanner bodies; those
  bodies do NOTHING until an operator pins an agent to
  `security_guard` in Control Center → Roles.

  Runs `async: false` because it attaches telemetry handlers
  globally, mutates responsibility rows in the sandbox, and starts a
  supervised sweeper GenServer whose spawned scanner tasks need
  `Sandbox.mode({:shared, _})` to reach the test's DB connection.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers
  alias Platform.Roles
  alias Platform.Security
  alias Platform.Security.Sweeper
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @unfilled_event [:platform, :responsibility, :unfilled]
  @sweep_tick_event [:platform, :security, :sweep_tick]

  @all_keys ~w(security.cve_scan security.code_audit security.deploy_audit security.secret_leak)

  # ── stub scanner + supervision helpers ────────────────────────────────

  defmodule StubScanner do
    @moduledoc false

    def run_scan(_responsibility, _trigger_meta) do
      pid = Process.whereis(:security_sweeper_scanner_stub) || self()
      send(pid, {:stub_scanner_invoked, self()})
      {:ok, 0}
    end
  end

  defmodule RaisingScanner do
    @moduledoc false

    def run_scan(_responsibility, _trigger_meta) do
      raise "deliberate scanner crash for isolation test"
    end
  end

  # ── setup: seed the four responsibility rows + role ───────────────────

  setup do
    # Stage 1's seed migration inserts the `security_guard` role row
    # and its 4-key bundle IF the migration has run in the current
    # test DB. Sibling worktrees on the shared `platform_test` DB may
    # be at a different migration state, so we belt-and-braces upsert
    # the role + bundle directly here — idempotent via `on_conflict:
    # :nothing`.
    seed_security_guard_role!()

    # The responsibility rows are declared by the four
    # `Handlers.Security*` providers, wired into the Registry — but
    # `:start_responsibilities_registry` is `false` in
    # `config/test.exs`, so the DataCase sandbox is empty on entry.
    # Upsert the four rows via the same code path the boot Registry
    # uses so the sweeper's `Responsibilities.get_by_key/1` lookups
    # resolve.
    {:ok, _results} =
      Responsibilities.register_all([
        Handlers.SecurityCveScan,
        Handlers.SecurityCodeAudit,
        Handlers.SecurityDeployAudit,
        Handlers.SecuritySecretLeak
      ])

    :ok
  end

  # Idempotent role + bundle seed, callable from any test setup that
  # needs `Roles.assign_role("security_guard", ...)` to resolve. Uses
  # `on_conflict: :nothing` on both `roles` and `role_responsibilities`
  # inserts so the seed migration (which may or may not have been run
  # in the shared test DB) and this helper stay compatible.
  defp seed_security_guard_role! do
    %Platform.Roles.Role{}
    |> Platform.Roles.Role.changeset(%{
      key: "security_guard",
      name: "Security Guard",
      description:
        "Periodic scans for CVEs, code patterns, deploy config drift, and leaked secrets",
      icon: "hero-shield-check"
    })
    |> Platform.Repo.insert!(on_conflict: :nothing, conflict_target: :key)

    for key <- @all_keys do
      %Platform.Roles.RoleResponsibility{}
      |> Platform.Roles.RoleResponsibility.changeset(%{
        role_key: "security_guard",
        responsibility_key: key
      })
      |> Platform.Repo.insert!(
        on_conflict: :nothing,
        conflict_target: [:role_key, :responsibility_key]
      )
    end

    :ok
  end

  # Attach a telemetry recorder that forwards events to the test PID
  # so `assert_receive` can shape assertions. Detached on `on_exit`.
  defp attach_recorder(test_pid, events) when is_list(events) do
    handler_id = "sweeper-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _cfg ->
        send(test_pid, {:sweeper_telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  defp unique_name do
    Module.concat([Sweeper, "Inst#{System.unique_integer([:positive])}"])
  end

  defp start_sweeper(opts \\ []) do
    name = unique_name()

    opts =
      opts
      |> Keyword.put(:name, name)
      |> Keyword.put_new(:check_interval_ms, 60_000)
      |> Keyword.put_new(:respect_cadence, false)

    _pid = start_supervised!({Sweeper, opts})
    name
  end

  defp insert_agent!(overrides \\ %{}) do
    suffix = System.unique_integer([:positive])

    attrs =
      %{
        slug: "sweeper-test-#{suffix}",
        name: "Sweeper Test #{suffix}",
        status: "active",
        kind: "native"
      }
      |> Map.merge(overrides)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Platform.Repo.insert!()
  end

  defp assign_security_guard! do
    agent = insert_agent!()
    {:ok, _} = Roles.assign_role("security_guard", agent.id)
    agent
  end

  defp count_tasks do
    Platform.Repo.aggregate(TaskSchema, :count, :id)
  end

  # ── progressive-enhancement contract (the load-bearing test) ───────────

  describe "sweep_now/1 with no security_guard assignment" do
    test "is a genuine no-op — no tasks, no scanner invocations, unfilled telemetry per key" do
      attach_recorder(self(), [@unfilled_event, @sweep_tick_event])

      # Make the scanner map point at a stub that would send us a
      # message IF invoked. It shouldn't be invoked at all.
      scanner_modules =
        Map.new(@all_keys, fn key -> {key, StubScanner} end)

      Process.register(self(), :security_sweeper_scanner_stub)

      name = start_sweeper(scanner_modules: scanner_modules)

      # Test env clamps Logger to :warning; bump for this case so the
      # sweeper's `[SecuritySweeper] unfilled …` info line is
      # capturable. Reset on exit to avoid leaking state.
      prev_level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: prev_level) end)

      pre_count = count_tasks()

      log =
        capture_log([level: :info], fn ->
          assert {:ok, results} = Sweeper.sweep_now(name)

          # One result per key, all unfilled, in the ADR-0043 order.
          assert Enum.map(results, & &1.key) == @all_keys

          for result <- results do
            assert result.assigned? == false
            assert result.findings_filed == 0
            assert result.fired? == false
            assert result.reason == :unfilled
          end
        end)

      # Unfilled telemetry fired exactly once per key.
      for key <- @all_keys do
        assert_receive {:sweeper_telemetry, @unfilled_event, _measurements, %{key: ^key}}, 500
      end

      # Sweep-tick telemetry NEVER fires — that event is emitted only
      # when a scanner actually runs.
      refute_receive {:sweeper_telemetry, @sweep_tick_event, _, _}, 200

      # Stub scanner was never invoked.
      refute_receive {:stub_scanner_invoked, _pid}, 200

      # No tasks were filed.
      assert count_tasks() == pre_count

      # Log lines Alex grep for in prod.
      for key <- @all_keys do
        assert log =~ "[SecuritySweeper] unfilled responsibility=#{key}"
      end

      Process.unregister(:security_sweeper_scanner_stub)
    end
  end

  # ── firing path (with a role assignment + stub scanners) ───────────────

  describe "sweep_now/1 with a security_guard assignment" do
    test "walks all four keys and emits sweep_tick telemetry per invocation" do
      _agent = assign_security_guard!()
      attach_recorder(self(), [@unfilled_event, @sweep_tick_event])

      scanner_modules =
        Map.new(@all_keys, fn key -> {key, StubScanner} end)

      Process.register(self(), :security_sweeper_scanner_stub)

      name = start_sweeper(scanner_modules: scanner_modules)

      capture_log(fn ->
        assert {:ok, results} = Sweeper.sweep_now(name)

        # All four keys fired with the stub's 0-finding return.
        assert Enum.map(results, & &1.key) == @all_keys

        for result <- results do
          assert result.assigned? == true
          assert result.fired? == true
          assert result.reason == :fired
          assert result.findings_filed == 0
        end
      end)

      # Sweep-tick telemetry landed once per key.
      for key <- @all_keys do
        assert_receive {:sweeper_telemetry, @sweep_tick_event, measurements, metadata},
                       500,
                       "expected sweep_tick telemetry for key=#{key}"

        assert measurements.findings_filed == 0
        assert metadata.key == key
        assert metadata.assigned? == true
        assert metadata.scanner == StubScanner
      end

      # Stub scanner was invoked exactly four times (one per key).
      for _key <- @all_keys do
        assert_receive {:stub_scanner_invoked, _pid}, 500
      end

      refute_receive {:stub_scanner_invoked, _pid}, 100

      # Unfilled telemetry NEVER fires when the role is assigned.
      refute_receive {:sweeper_telemetry, @unfilled_event, _, _}, 100

      Process.unregister(:security_sweeper_scanner_stub)
    end

    test "isolates a raising scanner — sweeper survives, other keys still fire" do
      _agent = assign_security_guard!()
      attach_recorder(self(), [@sweep_tick_event])

      Process.register(self(), :security_sweeper_scanner_stub)

      scanner_modules =
        @all_keys
        |> Enum.with_index()
        |> Map.new(fn
          {"security.cve_scan", _} -> {"security.cve_scan", RaisingScanner}
          {key, _} -> {key, StubScanner}
        end)

      name = start_sweeper(scanner_modules: scanner_modules)

      log =
        capture_log(fn ->
          assert {:ok, results} = Sweeper.sweep_now(name)

          # cve_scan crashed → 0 findings, but the sweep still walked it.
          [cve | rest] = results
          assert cve.key == "security.cve_scan"
          assert cve.findings_filed == 0
          assert cve.fired? == true

          # The other three still fired via the stub.
          for result <- rest do
            assert result.findings_filed == 0
            assert result.fired? == true
          end
        end)

      # Sweeper survived the raise + is still callable.
      assert Process.alive?(Process.whereis(name))

      # Log line proves the isolation kicked in.
      assert log =~ "scanner"
      assert log =~ "security.cve_scan"

      Process.unregister(:security_sweeper_scanner_stub)
    end
  end

  # ── missing responsibility row ────────────────────────────────────────

  describe "sweep_now/1 when a responsibility row is missing" do
    test "logs warn + returns :no_row for the missing key without crashing" do
      # Delete one row to simulate stage-1 seed drift.
      {1, _} =
        Platform.Repo.delete_all(
          from(r in Responsibilities.Responsibility,
            where: r.key == "security.cve_scan"
          )
        )

      attach_recorder(self(), [@sweep_tick_event])

      name = start_sweeper()

      log =
        capture_log(fn ->
          assert {:ok, results} = Sweeper.sweep_now(name)

          [cve | _] = results
          assert cve.key == "security.cve_scan"
          assert cve.reason == :no_row
          assert cve.fired? == false
        end)

      assert log =~ "responsibility row missing"
      assert log =~ "security.cve_scan"
    end
  end

  # ── list_responsibility_keys / sweep_now integration surface ──────────

  describe "public API surface" do
    test "Security.list_responsibility_keys/0 returns the ADR-0043 roster in order" do
      assert Security.list_responsibility_keys() == @all_keys
    end

    test "Security.sweep_now/0 returns :sweeper_not_started when default name isn't running" do
      assert {:error, :sweeper_not_started} = Security.sweep_now()
    end

    test "Sweeper.sweep_now/1 with an unknown name returns :sweeper_not_started" do
      assert {:error, :sweeper_not_started} =
               Sweeper.sweep_now(:definitely_no_such_sweeper_name)
    end
  end

  # ── task-count invariant (defence in depth for the no-op contract) ────

  describe "task-count invariant" do
    test "unassigned sweep produces zero task rows even across N ticks" do
      attach_recorder(self(), [@unfilled_event])

      name = start_sweeper()

      pre_count = count_tasks()

      capture_log(fn ->
        for _ <- 1..3 do
          assert {:ok, _} = Sweeper.sweep_now(name)
        end
      end)

      # Zero delta after three sweeps.
      assert count_tasks() == pre_count

      # Twelve unfilled telemetry events landed (4 keys × 3 sweeps).
      Enum.each(1..12, fn _ ->
        assert_receive {:sweeper_telemetry, @unfilled_event, _measurements, _metadata}, 500
      end)

      # A thirteenth would be a bug.
      refute_receive {:sweeper_telemetry, @unfilled_event, _, _}, 100

      # Explicit reference to avoid an unused-alias warning; Tasks is
      # exercised via `count_tasks/0` above.
      _ = Tasks
    end
  end
end
