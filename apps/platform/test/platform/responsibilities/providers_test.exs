defmodule Platform.Responsibilities.ProvidersTest do
  @moduledoc """
  Unit guards for the explicit provider registry (task 019f9b28 stage 2).

  VERIFICATION LABEL: **guards**. They pin the three-way return that makes
  "no provider was written" distinguishable from "this feature deliberately
  has none" — the property the old camelize-and-`ensure_loaded?` scheme
  could not express. They are not the task's fix detector; that is stage 5.
  """
  use ExUnit.Case, async: false

  alias Platform.Responsibilities.Providers

  describe "feature_provider/1" do
    test "resolves every compiled feature to a loaded module exporting handle_output/3" do
      for {feature, module} <- Providers.all() do
        assert {:ok, ^module} = Providers.feature_provider(feature)

        assert Code.ensure_loaded?(module),
               "#{inspect(module)} is registered for #{inspect(feature)} but does not load"

        # This arity, not mere module existence, is what the Router
        # actually probes. Asserting the weaker thing is how a shim that
        # forgot handle_output/3 would slip through.
        assert function_exported?(module, :handle_output, 3)
      end
    end

    test "returns {:retired, reason} for a deliberately unwired feature" do
      assert {:retired, reason} = Providers.feature_provider("security")
      assert is_binary(reason)

      # The reason has to say who owns the keys instead, or it is just a
      # skip list with extra steps.
      assert reason =~ "Sweeper"
    end

    test "returns :error for a feature nobody registered" do
      assert :error = Providers.feature_provider("governance")
      assert :error = Providers.feature_provider("test_feature_1")
    end

    test "returns :error rather than raising for empty, nil, and non-binary features" do
      # The fire sites live inside a plan-submit path and an Ecto
      # transaction; a raise here would be worse than the bug this
      # module replaces.
      assert :error = Providers.feature_provider("")
      assert :error = Providers.feature_provider(nil)
      assert :error = Providers.feature_provider(:meetings)
      assert :error = Providers.feature_provider(%{})
    end

    test "the retired and registered maps are disjoint" do
      overlap =
        Providers.all()
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.intersection(MapSet.new(Map.keys(Providers.retired())))

      assert MapSet.size(overlap) == 0,
             "features cannot be both registered and retired: #{inspect(MapSet.to_list(overlap))}"
    end
  end

  describe "override seam" do
    setup do
      previous = Application.get_env(:platform, :responsibility_provider_overrides)

      on_exit(fn ->
        if previous do
          Application.put_env(:platform, :responsibility_provider_overrides, previous)
        else
          Application.delete_env(:platform, :responsibility_provider_overrides)
        end
      end)

      :ok
    end

    test "an explicitly registered override resolves, an unregistered one still errors" do
      Application.put_env(
        :platform,
        :responsibility_provider_overrides,
        %{"governance" => __MODULE__}
      )

      assert {:ok, __MODULE__} == Providers.feature_provider("governance")

      # The seam is an explicit registration, not a name convention: a
      # feature nobody registered stays `:error`, so the distinguishability
      # the registry exists to create survives the escape hatch.
      assert :error = Providers.feature_provider("governance_other")
    end

    test "an override wins over the compiled entry" do
      Application.put_env(
        :platform,
        :responsibility_provider_overrides,
        %{"meetings" => __MODULE__}
      )

      assert {:ok, __MODULE__} == Providers.feature_provider("meetings")
    end

    test "a garbage override value falls through to the compiled registry" do
      Application.put_env(
        :platform,
        :responsibility_provider_overrides,
        %{"meetings" => "not a module"}
      )

      assert {:ok, Platform.Responsibilities.Providers.Meetings} ==
               Providers.feature_provider("meetings")
    end

    test "all/0 and retired/0 report the compiled maps only, never overrides" do
      Application.put_env(
        :platform,
        :responsibility_provider_overrides,
        %{"governance" => __MODULE__}
      )

      # Drift detection (stage 3 boot check, stage 4 coverage test) must
      # reason about what the release ships, not about runtime state a
      # test or an operator injected.
      refute Map.has_key?(Providers.all(), "governance")
      refute Map.has_key?(Providers.retired(), "governance")
    end
  end
end
