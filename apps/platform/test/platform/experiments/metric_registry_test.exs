defmodule Platform.Experiments.MetricRegistryTest do
  @moduledoc """
  Tests the metric registry in `Platform.Experiments.Metrics` (task
  019fec53, ADR-0048).

  The failure this file exists to catch is silent in every direction: a slug
  that a picker offers but nothing can compute renders `:no_metric` forever
  and raises nothing, and a metric module added to disk without a registry
  entry is simply invisible. Neither shows up in any other test.
  """

  use ExUnit.Case, async: true

  alias Platform.Experiments.Metrics

  describe "the registry has ONE source" do
    test "the web module returns the same list as the context" do
      # Anti-drift. The web copy was the original home of this list; a test
      # asserting only the context list would pass while `ExperimentResults`
      # kept a stale second copy, which is exactly how a metric becomes
      # selectable-but-uncomputable.
      assert Metrics.known_metrics() == PlatformWeb.ExperimentResults.known_metrics()
      assert Metrics.known_metrics() != []
    end

    test "the web module resolves every slug to the same module as the context" do
      for slug <- Metrics.known_metrics() do
        assert PlatformWeb.ExperimentResults.metric_module(slug) == Metrics.metric_module(slug)
      end
    end
  end

  describe "catalog/0" do
    test "is sorted by slug and its slugs are exactly known_metrics/0" do
      slugs = Enum.map(Metrics.catalog(), & &1.slug)

      assert slugs == Enum.sort(slugs)
      assert slugs == Metrics.known_metrics()
    end

    test "every entry carries a label, a description and a known direction" do
      for entry <- Metrics.catalog() do
        assert is_binary(entry.label) and entry.label != ""
        assert is_binary(entry.description) and entry.description != ""
        assert entry.direction in [:lower_is_better, :higher_is_better, :neutral]
      end
    end

    test "stages_per_plan is neutral, and the lower-is-better metrics are not" do
      by_slug = Map.new(Metrics.catalog(), &{&1.slug, &1.direction})

      # Settled by the ticket: more stages per plan is neither a win nor a
      # loss, and the UI must not imply one. Pinned here so a later edit has
      # to argue with the test rather than with nothing.
      assert by_slug["stages_per_plan"] == :neutral

      for slug <- ~w(cycle_time validation_failure_rate plan_revision_count time_in_phase) do
        assert by_slug[slug] == :lower_is_better, "expected #{slug} to be :lower_is_better"
      end
    end

    test "every catalog slug resolves to a LOADED module exporting compute/2" do
      for %{slug: slug} <- Metrics.catalog() do
        module = Metrics.metric_module(slug)
        refute is_nil(module), "#{slug} has no module"

        # `function_exported?/3` is FALSE for a module that has not been
        # loaded, so without this ensure_loaded the assertion below would
        # fail spuriously in one direction and — if inverted — pass
        # vacuously in the other.
        assert {:module, ^module} = Code.ensure_loaded(module)
        assert function_exported?(module, :compute, 2), "#{inspect(module)} lacks compute/2"
      end
    end

    test "slug and module agree — validation_failure_rate is not failure_rate" do
      # The file is `metrics/failure_rate.ex`; the SLUG stored in
      # `experiments.primary_metric` is `validation_failure_rate`. Picking
      # the file name as the slug produces a selectable metric that resolves
      # to nil, so pin the pair.
      assert Metrics.metric_module("validation_failure_rate") ==
               Platform.Experiments.Metrics.ValidationFailureRate

      assert Metrics.metric_module("failure_rate") == nil
    end
  end

  describe "registration is exhaustive" do
    test "there is exactly one catalog entry per metric module implementing the behaviour" do
      on_disk =
        :platform
        |> Application.spec(:modules)
        |> Enum.filter(fn module ->
          module
          |> Atom.to_string()
          |> String.starts_with?("Elixir.Platform.Experiments.Metrics.") and
            implements_metric?(module)
        end)
        |> MapSet.new()

      registered =
        Metrics.known_metrics()
        |> Enum.map(&Metrics.metric_module/1)
        |> MapSet.new()

      # Adding a metric module without registering it must FAIL here — an
      # unregistered metric is one nobody can ever select.
      assert MapSet.equal?(on_disk, registered),
             "unregistered: #{inspect(MapSet.difference(on_disk, registered))}; " <>
               "registered but absent: #{inspect(MapSet.difference(registered, on_disk))}"

      assert MapSet.size(on_disk) > 1
    end
  end

  defp implements_metric?(module) do
    Code.ensure_loaded?(module) and
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
      |> Enum.member?(Platform.Experiments.Metric)
  end

  test "an unrecognised or nil slug resolves to nil rather than raising" do
    assert Metrics.metric_module("not-a-metric") == nil
    assert Metrics.metric_module(nil) == nil
    assert Metrics.metric_module(:cycle_time) == nil
  end
end
