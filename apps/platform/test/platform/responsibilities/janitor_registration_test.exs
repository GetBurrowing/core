defmodule Platform.Responsibilities.JanitorRegistrationTest do
  @moduledoc """
  Registration, schedule, assignment gating, and reachability of the
  `janitor` role and its `janitor.cron_drain` responsibility (task
  `019fa1ac-6685` stage 1).

  ## Against unfixed code (the stack tip before this stage, 0adb37899)

  Measured on test_host: all 11 tests fail there, because no `janitor` role,
  handler, provider or template exists. Two of those failures say less than
  they look like:

    * The unassigned no-op test fails only because its setup cannot
      register the row. Its ASSERTIONS ("zero dispatcher calls, zero task
      writes") would pass against any janitor that never dispatches at all,
      so it is NOT a fix detector. It is paired, in the same describe block
      and over the same fixture, with the assigned positive control, which
      must dispatch.
    * The "architect sweep stays at Monday 04:00" test fails only because it
      also reads the janitor's expression. Its architect half is a guard
      against someone moving the sweep to nightly, not a fix detector.

  ## Canonical detonation

  Remove `"janitor"` from `Platform.Responsibilities.Providers.@feature_providers`
  and leave `providers/janitor.ex` in place. Measured on test_host: 4 failures
  across this file and `provider_coverage_test.exs`. Then:

    * two reachability tests fail (`feature_provider("janitor")` is
      `:error`), and so does `provider_coverage_test.exs`'s walk for
      `JanitorCronDrain`. The third reachability test ("owns no key it
      cannot route") still passes: it calls `Providers.Janitor` directly and
      does not consult the registry;
    * the assigned-dispatch test fails on BEHAVIOUR: the Router still
      dispatches, but through the legacy template render, so the signal's
      prompt lacks `JanitorCronDrain.system_prompt/0`, which only the
      provider's `build_prompt/1` adds.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Cron
  alias Platform.Responsibilities.Handlers.ArchitectureCronSweep
  alias Platform.Responsibilities.Handlers.JanitorCronDrain
  alias Platform.Responsibilities.Providers
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Roles.Seeds
  alias Platform.Tasks.Task, as: TaskSchema

  @key "janitor.cron_drain"
  @test_pid_key :janitor_registration_test_pid

  defmodule CapturingNativeDispatcher do
    @moduledoc false
    # Forwards every native hand-off to the test process. Counting the
    # messages is how "zero dispatcher calls" is measured.
    def maybe_dispatch(signal) do
      case Application.get_env(:platform, :janitor_registration_test_pid) do
        pid when is_pid(pid) -> send(pid, {:native_dispatch, signal})
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CapturingNativeDispatcher, :maybe_dispatch}
    )

    Application.put_env(:platform, @test_pid_key, self())

    on_exit(fn ->
      Application.delete_env(:platform, @test_pid_key)

      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end
    end)

    :ok
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  # The row comes from the handler's OWN register/0, so a drifted spec goes
  # red here instead of being restated by hand.
  defp upsert_janitor_row! do
    [spec] = JanitorCronDrain.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    row
  end

  defp seed_janitor_role! do
    :ok = Seeds.seed_defaults(only_keys: ["janitor"])
  end

  defp native_agent! do
    %Agent{}
    |> Agent.changeset(%{
      slug: "janitor-reg-native-#{System.unique_integer([:positive])}",
      name: "Janitor Registration Native",
      status: "active",
      kind: "native",
      workspace_id: nil
    })
    |> Repo.insert!()
  end

  defp task_count, do: Repo.aggregate(TaskSchema, :count)

  defp max_task_updated_at do
    Repo.one(from(t in TaskSchema, select: max(t.updated_at)))
  end

  defp fire!(row) do
    capture_log([level: :info], fn ->
      send(self(), {:fire_result, Router.fire_trigger(row, %{kind: :cron}, %{})})
    end)

    assert_received {:fire_result, result}
    result
  end

  # ── role + bundle ────────────────────────────────────────────────────────

  describe "the fixed janitor role and bundle" do
    test "is a closed-roster key with a one-key bundle" do
      assert "janitor" in Role.valid_keys()

      janitor = Enum.find(Seeds.default_roles(), &(&1.key == "janitor"))
      assert janitor, "janitor must be present in the canonical seed roster"
      assert janitor.name == "Janitor"
      assert janitor.icon == "hero-wrench-screwdriver"
      assert janitor.bundle == [@key]
    end

    test "the migrated database already holds the role, its bundle row, and its template" do
      # Rows come from `20261009060918_add_janitor_role.exs`, which `mix test`
      # runs; nothing in this test inserts them.
      assert %Role{name: "Janitor"} = Repo.get(Role, "janitor")

      assert Repo.exists?(
               from(rr in RoleResponsibility,
                 where: rr.role_key == "janitor" and rr.responsibility_key == ^@key
               )
             )

      assert PromptTemplates.get_template_by_slug(JanitorCronDrain.template_slug())
    end

    test "seeding is idempotent" do
      seed_janitor_role!()
      seed_janitor_role!()

      assert Repo.aggregate(from(r in Role, where: r.key == "janitor"), :count) == 1

      assert Repo.aggregate(
               from(rr in RoleResponsibility, where: rr.role_key == "janitor"),
               :count
             ) == 1

      assert Roles.bundle_for("janitor") == [@key]
    end
  end

  # ── schedule ─────────────────────────────────────────────────────────────

  describe "the cron registration" do
    test "janitor.cron_drain is a global cron row firing Monday 06:00 UTC" do
      assert [spec] = JanitorCronDrain.register()

      assert spec.key == @key
      assert spec.feature == "janitor"
      assert spec.trigger_kind == "cron"
      assert spec.trigger_config == %{"expression" => "0 6 * * 1"}
      assert spec.scope == "global"
      assert spec.default_prompt_template == "janitor.cron_drain.v1"

      {:ok, cron} = Cron.parse(spec.trigger_config["expression"])
      # Sunday 2026-10-11 12:00 UTC -> next fire Monday 2026-10-12 06:00 UTC.
      assert {:ok, next_fire} = Cron.next_fire_after(~U[2026-10-11 12:00:00Z], cron)
      assert DateTime.compare(next_fire, ~U[2026-10-12 06:00:00Z]) == :eq
    end

    test "the architect sweep stays weekly at Monday 04:00 UTC, two hours earlier" do
      [sweep] = ArchitectureCronSweep.register()
      assert sweep.trigger_config == %{"expression" => "0 4 * * 1"}

      {:ok, sweep_cron} = Cron.parse(sweep.trigger_config["expression"])
      {:ok, drain_cron} = Cron.parse(JanitorCronDrain.cron_expression())

      from = ~U[2026-10-11 12:00:00Z]
      {:ok, sweep_at} = Cron.next_fire_after(from, sweep_cron)
      {:ok, drain_at} = Cron.next_fire_after(from, drain_cron)

      assert DateTime.diff(drain_at, sweep_at, :hour) == 2
    end

    test "it is a platform built-in" do
      assert JanitorCronDrain in BuiltIns.providers()
    end
  end

  # ── assignment gating (paired) ───────────────────────────────────────────

  describe "assignment gating" do
    setup do
      seed_janitor_role!()
      %{row: upsert_janitor_row!()}
    end

    # POSITIVE CONTROL. Fails against unfixed code (no row, no role, no
    # provider); fails under the canonical detonation on the prompt assertion.
    test "an assigned janitor is dispatched once, with the provider's own prompt", %{row: row} do
      agent = native_agent!()
      {:ok, _} = Roles.assign_role("janitor", agent.id)
      assert Roles.assignee_for(@key).id == agent.id

      assert {:ok, :dispatched} = fire!(row)

      assert_received {:native_dispatch, signal}
      refute_received {:native_dispatch, _}

      assert signal.metadata.responsibility_key == @key
      assert signal.metadata.feature == "janitor"
      assert signal.metadata.agent_id == agent.id
      assert signal.metadata.prompt_status == :rendered

      prompt = signal.metadata.prompt

      assert is_binary(prompt) and String.contains?(prompt, JanitorCronDrain.system_prompt()),
             "the dispatched prompt does not carry JanitorCronDrain.system_prompt/0, so " <>
               "Providers.Janitor.build_prompt/1 never ran (legacy template fallback). " <>
               "Got: #{inspect(prompt)}"

      # The cap reaches the model as a number, not an unfilled placeholder.
      assert prompt =~ "at most 3"
      refute prompt =~ "{{"
    end

    # NOT A FIX DETECTOR ON ITS OWN: passes trivially against a janitor that
    # never dispatches. Meaningful only beside the positive control above.
    test "an unassigned janitor is a no-op: zero dispatcher calls, zero task writes",
         %{row: row} do
      assert Roles.assignee_for(@key) == nil

      tasks_before = task_count()
      updated_before = max_task_updated_at()

      assert {:ok, :unfilled} = fire!(row)

      refute_received {:native_dispatch, _}
      assert task_count() == tasks_before
      assert max_task_updated_at() == updated_before
    end
  end

  # ── reachability ─────────────────────────────────────────────────────────

  describe "reachability of janitor.cron_drain" do
    test "the explicit registry resolves the janitor feature to a loaded provider" do
      assert {:ok, Providers.Janitor} = Providers.feature_provider("janitor")
      assert Map.fetch!(Providers.all(), "janitor") == Providers.Janitor
      refute Map.has_key?(Providers.retired(), "janitor")
    end

    test "the built-in walk reaches the key and lands on the live handler" do
      # Discovered from BuiltIns, never named as a module literal: this is the
      # same walk provider_coverage_test.exs runs, narrowed to one key.
      [{handler, spec}] =
        for handler <- BuiltIns.providers(),
            spec <- handler.register(),
            spec.key == @key,
            do: {handler, spec}

      assert {:ok, provider} = Providers.feature_provider(spec.feature)
      assert Code.ensure_loaded?(provider)
      assert provider.handler_for(@key) == handler
      assert function_exported?(provider, :handle_output, 3)
      assert function_exported?(provider, :build_prompt, 1)
      assert function_exported?(handler, :gather_context, 2)
    end

    test "the provider owns no key it cannot route" do
      for handler <- Providers.Janitor.handlers(),
          spec <- handler.register() do
        assert Providers.Janitor.handler_for(spec.key) == handler
      end

      assert Providers.Janitor.handler_for("janitor.not_a_key") == nil
    end
  end
end
