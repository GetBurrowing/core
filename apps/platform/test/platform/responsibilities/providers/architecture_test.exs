defmodule Platform.Responsibilities.Providers.ArchitectureTest do
  @moduledoc """
  Tests for the task 019f9b28 stage 1 shim
  `Platform.Responsibilities.Providers.Architecture` — the seam that lets
  the M6 Router's `provider_module_for("architecture")` lookup find a
  handler for `architecture.review_plan`, `architecture.audit_diff`, and
  `architecture.cron_sweep` even though the per-key handlers live at
  `Handlers.ArchitectureReviewPlan`, `Handlers.ArchitectureAuditDiff`,
  and `Handlers.ArchitectureCronSweep`.

  ## Verification label: this file is a GUARD, not proof of the fix

  Every assertion here is about the new module's *shape* — it asserts
  the dispatch table, the delegation, and the `build_prompt/1` return
  contract. None of it can exist without the fix, and none of it
  observes the architect's answer actually landing in an execution
  space. The fix detector is stage 5's
  `architecture_dispatch_test.exs`, which fires the real row through
  `Router.fire_trigger/3` and asserts the `[architect]` annotation.

  Kept DB-free (`async: true`, plain `ExUnit.Case`) on purpose: every
  path exercised below either stops inside the shim or lands in a
  handler branch that returns a static map. In particular
  `architecture.cron_sweep`'s `gather_context/2` is never invoked here —
  it shells out to `gh`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Responsibilities.Handlers
  alias Platform.Responsibilities.Handlers.ArchitectureAuditDiff
  alias Platform.Responsibilities.Handlers.ArchitectureCronSweep
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Providers.Architecture, as: ArchitectureProvider
  alias Platform.Responsibilities.Responsibility

  # Built from the handlers' own `key/0` accessors rather than string
  # literals so a key rename breaks these tests instead of silently
  # re-orphaning the handler — which is the exact failure this whole
  # task exists to kill.
  defp review_plan_responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: ArchitectureReviewPlan.key(),
      feature: "architecture",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "plan.submitted"},
      scope: "per_task",
      context_provided: ["plan_payload"],
      enabled: true
    }
  end

  defp audit_diff_responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: ArchitectureAuditDiff.key(),
      feature: "architecture",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "stage.completed"},
      scope: "per_task",
      context_provided: ["stage_diff"],
      enabled: true
    }
  end

  defp cron_sweep_responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: ArchitectureCronSweep.key(),
      feature: "architecture",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 3 * * 1"},
      scope: "per_project",
      context_provided: ["repo_sweep"],
      enabled: true
    }
  end

  defp bogus_responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: "architecture.brand_new_thing",
      feature: "architecture",
      trigger_kind: "cron",
      trigger_config: %{"expression" => "0 1 * * *"},
      scope: "per_project",
      enabled: true
    }
  end

  describe "register/0" do
    test "aggregates the per-handler register specs" do
      specs = ArchitectureProvider.register()
      keys = Enum.map(specs, & &1.key)

      assert ArchitectureReviewPlan.key() in keys
      assert ArchitectureAuditDiff.key() in keys
      assert ArchitectureCronSweep.key() in keys
      assert length(keys) == 3
    end

    test "every registered spec claims the architecture feature" do
      # The Router resolves the provider module from `feature`, so a spec
      # that declared anything else would route away from this shim.
      for spec <- ArchitectureProvider.register() do
        assert spec.feature == "architecture"
      end
    end
  end

  describe "handler_for/1" do
    test "resolves each Architect key to its handler module" do
      assert ArchitectureProvider.handler_for(ArchitectureReviewPlan.key()) ==
               Handlers.ArchitectureReviewPlan

      assert ArchitectureProvider.handler_for(ArchitectureAuditDiff.key()) ==
               Handlers.ArchitectureAuditDiff

      assert ArchitectureProvider.handler_for(ArchitectureCronSweep.key()) ==
               Handlers.ArchitectureCronSweep
    end

    test "resolves via a Responsibility struct too" do
      assert ArchitectureProvider.handler_for(review_plan_responsibility()) ==
               Handlers.ArchitectureReviewPlan

      assert ArchitectureProvider.handler_for(audit_diff_responsibility()) ==
               Handlers.ArchitectureAuditDiff

      assert ArchitectureProvider.handler_for(cron_sweep_responsibility()) ==
               Handlers.ArchitectureCronSweep
    end

    test "resolves via a bare map carrying a :key" do
      assert ArchitectureProvider.handler_for(%{key: ArchitectureReviewPlan.key()}) ==
               Handlers.ArchitectureReviewPlan

      assert ArchitectureProvider.handler_for(%{key: ArchitectureAuditDiff.key()}) ==
               Handlers.ArchitectureAuditDiff
    end

    test "returns nil for the deliberately unwired security.* keys" do
      # security.* is superseded by Platform.Security.Sweeper's own
      # scanner dispatch table; this shim must not adopt those keys.
      assert ArchitectureProvider.handler_for("security.cve_scan") == nil
      assert ArchitectureProvider.handler_for("security.secret_leak") == nil
    end

    test "returns nil for unknown keys and garbage" do
      assert ArchitectureProvider.handler_for("architecture.brand_new_thing") == nil
      assert ArchitectureProvider.handler_for(bogus_responsibility()) == nil
      assert ArchitectureProvider.handler_for(nil) == nil
      assert ArchitectureProvider.handler_for(:architecture) == nil
      assert ArchitectureProvider.handler_for(%{}) == nil
    end

    test "every mapped handler exports the callbacks the Router probes for" do
      # `router.ex` probes `handle_output/3` before invoking output
      # handling and `build_prompt/1` before rendering the prompt. A
      # module that resolved but failed either probe would land right
      # back on the silent-fallback paths this shim exists to close.
      for key <- [
            ArchitectureReviewPlan.key(),
            ArchitectureAuditDiff.key(),
            ArchitectureCronSweep.key()
          ] do
        handler = ArchitectureProvider.handler_for(key)

        assert Code.ensure_loaded?(handler)
        assert function_exported?(handler, :handle_output, 3), "#{key} lacks handle_output/3"
        assert function_exported?(handler, :build_prompt, 1), "#{key} lacks build_prompt/1"
      end
    end
  end

  describe "gather_context/2" do
    test "delegates to the matching handler" do
      log =
        capture_log(fn ->
          assert {:ok, ctx} =
                   ArchitectureProvider.gather_context(review_plan_responsibility(), %{})

          # The review-plan handler's own empty-payload shape — proof the
          # call reached the handler rather than a generic fallback.
          assert Map.has_key?(ctx, :plan_payload)
          assert Map.has_key?(ctx, :adr_index)
        end)

      assert log =~ "[architecture.review_plan]"
    end

    test "returns unknown_architecture_responsibility for unmapped keys" do
      log =
        capture_log(fn ->
          assert {:error, :unknown_architecture_responsibility} =
                   ArchitectureProvider.gather_context(bogus_responsibility(), %{})
        end)

      assert log =~ "[architecture provider]"
      assert log =~ "unknown responsibility key"
    end
  end

  describe "handle_output/3" do
    test "returns {:error, :unknown_architecture_responsibility} for unmapped keys" do
      log =
        capture_log(fn ->
          assert {:error, :unknown_architecture_responsibility} =
                   ArchitectureProvider.handle_output(
                     bogus_responsibility(),
                     %{"comment" => "hi"},
                     %{kind: :event_topic}
                   )
        end)

      assert log =~ "[architecture provider]"
      assert log =~ "unknown responsibility key"
    end
  end

  describe "handle_output/2" do
    test "returns {:error, :unknown_architecture_responsibility} for unmapped keys" do
      log =
        capture_log(fn ->
          assert {:error, :unknown_architecture_responsibility} =
                   ArchitectureProvider.handle_output(bogus_responsibility(), %{
                     "comment" => "hi"
                   })
        end)

      assert log =~ "[architecture provider]"
    end
  end

  describe "build_prompt/1 return contract" do
    # The Router reads {:error, :no_build_prompt} as "fall back to the
    # legacy template render" but reads ANY other {:error, _} as a
    # refusal that short-circuits the dispatch and never fires the LLM
    # call. So these assert the exact atom, not merely an error tuple.

    test "returns exactly {:error, :no_build_prompt} with no :__responsibility__" do
      assert ArchitectureProvider.build_prompt(%{}) == {:error, :no_build_prompt}
    end

    test "returns exactly {:error, :no_build_prompt} for an unmapped responsibility" do
      context = %{__responsibility__: bogus_responsibility()}

      assert ArchitectureProvider.build_prompt(context) == {:error, :no_build_prompt}
    end

    test "returns exactly {:error, :no_build_prompt} for a non-map argument" do
      assert ArchitectureProvider.build_prompt(nil) == {:error, :no_build_prompt}
    end

    test "the refusal atom is never some other error term" do
      # Guards the failure mode that would be worse than the bug: a
      # routing miss silently converted into a dropped dispatch.
      for context <- [
            %{},
            %{__responsibility__: nil},
            %{__responsibility__: bogus_responsibility()}
          ] do
        assert {:error, reason} = ArchitectureProvider.build_prompt(context)
        assert reason == :no_build_prompt
      end
    end
  end
end
