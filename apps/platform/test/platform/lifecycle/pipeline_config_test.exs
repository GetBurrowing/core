defmodule Platform.Lifecycle.PipelineConfigTest do
  # NOT async. These cases set application-global lifecycle config keys
  # (:lifecycle_step_registry, :lifecycle_allowed_webhook_hosts) so that a
  # changeset validator, which has nowhere to thread a server argument, can
  # find a per-case registry. Application env is VM-global: run concurrently,
  # one case's on_exit cleanup lands inside another's assertion and the
  # registry lookup falls back to the boot singleton, which is disabled in
  # test env. Measured at 1 failure in 5 runs on a clean tree, with a
  # ROTATING failing test name. Serialising these files is the fix; making
  # the key process-local is not possible while the seam is Application env.
  use ExUnit.Case, async: false

  alias Platform.Lifecycle.EdgeInventory
  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.PipelineConfig
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Tasks

  @edge "planning.entered"
  @no_gate_edge "backlog.created"

  setup context do
    name = :"pipeline_config_registry_#{:erlang.phash2(context.test)}"
    start_supervised!({StepRegistry, name: name})

    # A webhook step type, registered per case so the url rules have
    # something to hang off without widening the shipped allowlist.
    :ok =
      StepRegistry.register(
        %{name: "webhook", mfa: {Platform.Lifecycle.Steps, :notify, 1}, kind: :deterministic},
        name
      )

    previous = Application.get_env(:platform, :lifecycle_allowed_webhook_hosts)
    Application.put_env(:platform, :lifecycle_allowed_webhook_hosts, ["hooks.example.com"])

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :lifecycle_allowed_webhook_hosts)
        value -> Application.put_env(:platform, :lifecycle_allowed_webhook_hosts, value)
      end
    end)

    %{registry: name}
  end

  defp step(overrides \\ %{}) do
    Map.merge(%{"step" => "notify", "await" => false, "can_divert" => false}, overrides)
  end

  defp pipeline(step), do: %{@edge => [step]}

  describe "valid pipelines (anti-vacuity control)" do
    test "a well-formed pipeline validates", %{registry: registry} do
      assert :ok = PipelineConfig.validate(pipeline(step()), registry)
    end

    test "a gate step with await and can_divert true validates", %{registry: registry} do
      assert :ok =
               PipelineConfig.validate(
                 pipeline(step(%{"await" => true, "can_divert" => true})),
                 registry
               )
    end

    test "an empty pipeline and an empty edge validate", %{registry: registry} do
      assert :ok = PipelineConfig.validate(%{}, registry)
      assert :ok = PipelineConfig.validate(%{@edge => []}, registry)
    end
  end

  describe "step name resolution" do
    test "unknown step name is rejected with its own message", %{registry: registry} do
      assert {:error, reason} =
               PipelineConfig.validate(pipeline(step(%{"step" => "no-such-step"})), registry)

      assert reason =~ "unknown step"
      assert reason =~ "no-such-step"
    end

    test "a module that EXISTS and is loaded is still rejected", %{registry: registry} do
      # The registry is an allowlist, not an existence check. Enum is
      # loaded in this VM; a validator that admitted it would be doing
      # module resolution on agent-authored config, which is the RCE.
      assert Code.ensure_loaded?(Enum)

      for name <- ["Enum", "Elixir.Enum", "Platform.Lifecycle.Steps", "Platform.Repo"] do
        assert {:error, reason} =
                 PipelineConfig.validate(pipeline(step(%{"step" => name})), registry),
               "#{name} was admitted as a step"

        assert reason =~ "names a module"
      end
    end

    test "the module message is distinct from the unknown-name message", %{registry: registry} do
      {:error, module_reason} =
        PipelineConfig.validate(pipeline(step(%{"step" => "Enum"})), registry)

      {:error, unknown_reason} =
        PipelineConfig.validate(pipeline(step(%{"step" => "typo"})), registry)

      refute module_reason == unknown_reason
    end

    test "a missing or non-string step key is rejected", %{registry: registry} do
      assert {:error, missing} =
               PipelineConfig.validate(pipeline(Map.delete(step(), "step")), registry)

      assert missing =~ "missing the required \"step\" key"

      assert {:error, wrong_type} =
               PipelineConfig.validate(pipeline(step(%{"step" => 42})), registry)

      assert wrong_type =~ "must be a string name"
    end
  end

  describe "webhook host allowlist" do
    test "a webhook to an allowlisted host validates", %{registry: registry} do
      assert :ok =
               PipelineConfig.validate(
                 pipeline(
                   step(%{"step" => "webhook", "url" => "https://hooks.example.com/lifecycle"})
                 ),
                 registry
               )
    end

    test "a webhook to a host outside the allowlist is rejected", %{registry: registry} do
      assert {:error, reason} =
               PipelineConfig.validate(
                 pipeline(step(%{"step" => "webhook", "url" => "https://evil.example.net/x"})),
                 registry
               )

      assert reason =~ "not allowlisted"
      assert reason =~ "evil.example.net"
    end

    test "a url with no parseable host has its own message", %{registry: registry} do
      assert {:error, reason} =
               PipelineConfig.validate(
                 pipeline(step(%{"step" => "webhook", "url" => "/relative/path"})),
                 registry
               )

      assert reason =~ "no parseable host"
    end

    test "a non-string url is rejected", %{registry: registry} do
      assert {:error, reason} =
               PipelineConfig.validate(
                 pipeline(step(%{"step" => "webhook", "url" => %{"host" => "x"}})),
                 registry
               )

      assert reason =~ "\"url\" must be a string"
    end
  end

  describe "await / can_divert are required booleans" do
    test "missing await has its own message", %{registry: registry} do
      assert {:error, reason} =
               PipelineConfig.validate(pipeline(Map.delete(step(), "await")), registry)

      assert reason =~ "\"await\" is required"
    end

    test "await = \"true\" is rejected, not coerced", %{registry: registry} do
      assert {:error, reason} =
               PipelineConfig.validate(pipeline(step(%{"await" => "true"})), registry)

      assert reason =~ "\"await\" must be a boolean"
      assert reason =~ "not coerced"
    end

    test "missing can_divert has its own message", %{registry: registry} do
      assert {:error, reason} =
               PipelineConfig.validate(pipeline(Map.delete(step(), "can_divert")), registry)

      assert reason =~ "\"can_divert\" is required"
    end

    test "can_divert = 1 is rejected", %{registry: registry} do
      assert {:error, reason} =
               PipelineConfig.validate(pipeline(step(%{"can_divert" => 1})), registry)

      assert reason =~ "\"can_divert\" must be a boolean"
    end

    test "the four flag messages are pairwise distinct", %{registry: registry} do
      reasons =
        for p <- [
              Map.delete(step(), "await"),
              step(%{"await" => "true"}),
              Map.delete(step(), "can_divert"),
              step(%{"can_divert" => 1})
            ] do
          {:error, reason} = PipelineConfig.validate(pipeline(p), registry)
          reason
        end

      assert length(Enum.uniq(reasons)) == 4
    end
  end

  describe "structural errors" do
    test "a non-map pipeline is rejected", %{registry: registry} do
      assert {:error, reason} = PipelineConfig.validate([], registry)
      assert reason =~ "pipeline must be a map"
    end

    test "a non-list edge value is rejected", %{registry: registry} do
      assert {:error, reason} = PipelineConfig.validate(%{@edge => step()}, registry)
      assert reason =~ "steps must be a list"
    end

    test "a non-map step is rejected", %{registry: registry} do
      assert {:error, reason} = PipelineConfig.validate(%{@edge => ["notify"]}, registry)
      assert reason =~ "step must be a map"
    end

    test "a non-string edge name is rejected", %{registry: registry} do
      assert {:error, reason} = PipelineConfig.validate(%{1 => [step()]}, registry)
      assert reason =~ "edge name must be a string"
    end
  end

  describe "atom keys are not accepted (jsonb round-trip)" do
    test "an atom-keyed step does not validate", %{registry: registry} do
      atom_step = %{step: "notify", await: false, can_divert: false}
      assert {:error, _reason} = PipelineConfig.validate(%{@edge => [atom_step]}, registry)
    end
  end

  describe "backlog.created accepts no gates (ADR-0046 Amendment 1 decision 6)" do
    test "a notify on backlog.created validates", %{registry: registry} do
      assert :ok = PipelineConfig.validate(%{"backlog.created" => [step()]}, registry)
    end

    test "an awaiting or diverting step on backlog.created is rejected", %{registry: registry} do
      for override <- [%{"await" => true}, %{"can_divert" => true}] do
        assert {:error, reason} =
                 PipelineConfig.validate(%{"backlog.created" => [step(override)]}, registry)

        assert reason =~ "effects and notifies only"
      end
    end

    test "the rejection is a SPECIFIC term, not just an error", %{registry: registry} do
      # "errored" also matches a typo'd edge name, a missing flag, and an
      # unknown step. Assert the exact term or this test cannot tell the
      # prohibition from any other rule in the module.
      for override <- [%{"await" => true}, %{"can_divert" => true}] do
        assert PipelineConfig.check(%{@no_gate_edge => [step(override)]}, registry) ==
                 {:error, {:gates_prohibited, @no_gate_edge}}
      end
    end

    test "a gate is defined by its DECLARATION, not its position", %{registry: registry} do
      # The gate sits LAST. A rule that inspected only the head of the list
      # would pass this pipeline, and a rule that blacklisted the edge
      # wholesale would fail the effect-only control below.
      pipeline = %{
        @no_gate_edge => [
          step(),
          step(),
          step(%{"can_divert" => true})
        ]
      }

      assert PipelineConfig.check(pipeline, registry) ==
               {:error, {:gates_prohibited, @no_gate_edge}}
    end

    test "CONTROL: effects and notifies on the same edge load fine", %{registry: registry} do
      # Proves the rejection discriminates by step KIND rather than
      # rejecting the edge wholesale. Without this, a validator that
      # refused every backlog.created pipeline would pass the test above.
      pipeline = %{
        @no_gate_edge => [
          step(),
          step(%{"step" => "webhook", "url" => "https://hooks.example.com/x"})
        ]
      }

      assert PipelineConfig.check(pipeline, registry) == :ok
      assert PipelineConfig.validate(pipeline, registry) == :ok
    end

    test "CONTROL: a gate on any OTHER edge still loads", %{registry: registry} do
      # The prohibition is scoped to one edge. If it had disabled gates
      # globally, every declared gate in the system would silently stop
      # loading and the two assertions above would still be green.
      gate = step(%{"await" => true, "can_divert" => true})

      for edge <- [@edge | Enum.take(EdgeInventory.status_edges(), 5)] do
        assert PipelineConfig.check(%{edge => [gate]}, registry) == :ok,
               "a gate on #{edge} was rejected; the prohibition is not scoped"
      end
    end

    test "validate/2 keeps its BINARY contract for the changeset", %{registry: registry} do
      # `Platform.Tasks.Project`'s config validator pipes the
      # reason straight into `add_error/3`, which requires a binary. If
      # `check/2`'s tuple leaked through, project creation would raise
      # rather than return a changeset error.
      assert {:error, reason} =
               PipelineConfig.validate(%{@no_gate_edge => [step(%{"await" => true})]}, registry)

      assert is_binary(reason)
      assert reason =~ "agent-paced and bursty"
    end
  end

  describe "the declarable edge set is derived from the transition table" do
    test "every task-status transition is declarable and resolvable", %{registry: registry} do
      # DERIVED on both sides: the expectation is computed from
      # `Platform.Tasks.valid_task_transitions/0`, not transcribed. A
      # transcribed list would agree with a stale implementation forever.
      expected =
        Tasks.valid_task_transitions()
        |> Enum.flat_map(fn {from, tos} -> Enum.map(tos, &"#{from}->#{&1}") end)
        |> Enum.sort()

      assert EdgeInventory.status_edges() == expected

      # ANTI-VACUITY: an empty table would make the equality above trivially
      # true. Pin the shape and two edges the ticket's original framing
      # omitted.
      refute expected == []
      assert "in_progress->done" in expected
      assert "in_review->done" in expected
      assert "in_progress->deploying" in expected

      # `blocked` is enterable from SIX states.
      inbound_blocked = Enum.filter(expected, &String.ends_with?(&1, "->blocked"))
      assert length(inbound_blocked) == 6

      # `cancelled` is terminal: no outbound edge exists to declare.
      assert Enum.filter(expected, &String.starts_with?(&1, "cancelled->")) == []

      # Declarable AND resolvable: each edge validates as a config key and
      # reads back the steps it was given.
      for edge <- expected do
        pipeline = %{edge => [step()]}
        assert PipelineConfig.check(pipeline, registry) == :ok
        assert PipelineConfig.steps_for(pipeline, edge) == [step()]
        assert EdgeInventory.declarable?(edge)
      end
    end

    test "the non-status edges are declarable too" do
      assert EdgeInventory.declarable?(@no_gate_edge)
      assert EdgeInventory.declarable?(Edges.designer_edge())
      assert EdgeInventory.declarable?(Edges.architect_edge())
      refute EdgeInventory.declarable?("no.such.edge")
      refute EdgeInventory.declarable?(:not_a_binary)
    end
  end

  describe "steps_for/2" do
    test "returns the ordered step list for an edge" do
      first = step(%{"step" => "notify"})
      second = step(%{"step" => "webhook", "url" => "https://hooks.example.com/x"})

      assert PipelineConfig.steps_for(%{@edge => [first, second]}, @edge) == [first, second]
    end

    test "returns [] for an absent edge, a non-list value, or a non-map pipeline" do
      assert PipelineConfig.steps_for(%{}, @edge) == []
      assert PipelineConfig.steps_for(%{@edge => "nope"}, @edge) == []
      assert PipelineConfig.steps_for(nil, @edge) == []
    end
  end
end
