defmodule Platform.Responsibilities.ProviderCoverageTest do
  @moduledoc """
  Every responsibility key the platform ships must resolve to a handler
  module the Router can actually reach (task 019f9b28 stage 4).

  ## What this file asserts

  For each module in `Platform.Responsibilities.BuiltIns.providers/0`, and
  for each spec that module's own `register/0` declares, one of exactly two
  things must be true:

    * `Providers.feature_provider(spec.feature)` returns `{:ok, provider}`,
      and that provider is *reachable*: it loads, it exposes
      `handler_for/1`, `handler_for(spec.key)` returns the declaring module
      itself, and it exports `handle_output/3`.
    * `Providers.feature_provider(spec.feature)` returns `{:retired, _}`,
      and the retirement is **verified against reality** rather than taken
      on trust — see below.

  `:error` is never acceptable for a built-in. That value is what
  `architecture.*` silently returned for months: every fire dispatched,
  every answer was discarded, and the log line was identical to the one
  `security.*` emits on purpose.

  ## Why `handle_output/3` and not merely "the module exists"

  `Router.invoke_handle_output/3` probes
  `function_exported?(provider_module, :handle_output, 3)` before calling
  it. A shim that resolved but omitted that arity would fall into the same
  dead arm as no shim at all, so asserting mere module existence would not
  have caught it.

  ## Why `feature_provider/1` and not `Providers.all/0`

  `all/0` is override-free on purpose — boot-time drift detection
  (`Registry.log_provider_coverage/1`) must reason about what the release
  ships. This test instead asks the same question the Router asks, through
  the same seam the Router uses, so a feature bound via
  `:responsibility_provider_overrides` counts as covered here exactly as it
  would at dispatch time.

  ## Why the security exemption checks the Sweeper's real table

  `security.*` legitimately has no provider: `Platform.Security.Sweeper`
  owns those four keys through its own `@default_scanner_modules` dispatch
  table. An exemption that merely *listed* them would be a second place for
  the same bug to hide — retire `security.secret_leak` from the Sweeper and
  the key black-holes again while this file stays green. So the
  `{:retired, _}` branch asserts membership in
  `Sweeper.default_scanner_modules/0`, and goes red if that stops being
  true.

  ## Verification label

  This file is a **guard**, not the task's fix detector. With stage 1
  merged it passes; it would have failed on unfixed code only because
  `architecture` was absent from the registry. Its negative verification is
  stage 5's e2e case 2 — inject a handler with an unmapped `governance`
  feature into `BuiltIns.providers/0` and confirm this file goes red naming
  that feature and key. The security half, by contrast, *is* detonatable in
  place: drop a key from `@default_scanner_modules` and this file names it.
  """
  use ExUnit.Case, async: true

  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Providers
  alias Platform.Security.Sweeper

  describe "BuiltIns provider coverage" do
    for handler <- BuiltIns.providers() do
      @handler handler

      test "#{inspect(handler)} — every key it registers reaches a provider" do
        specs = @handler.register()

        assert is_list(specs) and length(specs) >= 1,
               "#{inspect(@handler)} is in BuiltIns.providers/0 but register/0 returned " <>
                 "#{inspect(specs)} — a provider that declares nothing cannot be covered " <>
                 "or drifted, so it does not belong in the list."

        Enum.each(specs, &assert_spec_covered(@handler, &1))
      end
    end

    test "the walk is not vacuous" do
      handlers = BuiltIns.providers()

      assert length(handlers) >= 20,
             "BuiltIns.providers/0 returned #{length(handlers)} modules — this whole file " <>
               "is a loop over that list, so a shrunken list silently weakens the guard."

      specs = Enum.flat_map(handlers, & &1.register())

      assert length(specs) >= length(handlers),
             "#{length(handlers)} providers declared only #{length(specs)} specs between them."
    end
  end

  describe "the security exemption" do
    test "names the exempt keys instead of silently filtering them" do
      registered_security_keys =
        for handler <- BuiltIns.providers(),
            spec <- handler.register(),
            spec.feature == "security",
            do: spec.key

      sweeper_keys = Map.keys(Sweeper.default_scanner_modules())

      assert Enum.sort(registered_security_keys) == Enum.sort(sweeper_keys),
             "The security.* keys BuiltIns registers " <>
               "(#{inspect(Enum.sort(registered_security_keys))}) no longer match the keys " <>
               "Platform.Security.Sweeper actually dispatches " <>
               "(#{inspect(Enum.sort(sweeper_keys))}). One side moved; the Router provides " <>
               "no provider for either, so the difference is a set of keys nothing handles."
    end

    test "is recorded as a retirement, not as an absence" do
      assert {:retired, reason} = Providers.feature_provider("security")

      assert reason =~ "Sweeper",
             "The retirement reason for \"security\" should name the owner that supersedes " <>
               "the Router, so a future reader gets an answer instead of an ambiguity. Got: " <>
               inspect(reason)
    end
  end

  describe "the registered provider modules themselves" do
    test "every module in Providers.all/0 is reachable" do
      Enum.each(Providers.all(), fn {feature, provider} ->
        assert Code.ensure_loaded?(provider),
               "Providers.all/0 maps feature #{inspect(feature)} to #{inspect(provider)}, " <>
                 "which does not load."

        assert function_exported?(provider, :handler_for, 1),
               "#{inspect(provider)} (feature #{inspect(feature)}) has no public " <>
                 "handler_for/1. That accessor is the convention every shim follows and " <>
                 "the seam this coverage test walks."

        assert function_exported?(provider, :handle_output, 3),
               "#{inspect(provider)} (feature #{inspect(feature)}) does not export " <>
                 "handle_output/3 — the exact arity Router.invoke_handle_output/3 probes."
      end)
    end

    test "no feature is both registered and retired" do
      overlap =
        Providers.all()
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.intersection(Providers.retired() |> Map.keys() |> MapSet.new())

      assert MapSet.size(overlap) == 0,
             "#{inspect(MapSet.to_list(overlap))} appear in both @feature_providers and " <>
               "@retired. feature_provider/1 resolves the registered entry first, so the " <>
               "retirement note would be a lie a reader could not detect."
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp assert_spec_covered(handler, %{key: key, feature: feature}) do
    case Providers.feature_provider(feature) do
      {:ok, provider} ->
        assert_provider_reaches(handler, provider, key, feature)

      {:retired, _reason} ->
        assert_retirement_is_real(handler, key, feature)

      :error ->
        flunk("""
        No provider is registered for feature #{inspect(feature)}.

          responsibility key: #{key}
          declared by:        #{inspect(handler)}

        Platform.Responsibilities.Router.provider_module_for/1 will resolve nil for
        this row, so gather_context falls back to the generic gatherer, build_prompt
        falls to the legacy template, and handle_output is never invoked — the
        responsibility fires, the model answers, and the answer is discarded.

        Fix: add #{inspect(feature)} to @feature_providers in
        apps/platform/lib/platform/responsibilities/providers.ex (pointing at a
        Providers.* shim), or — if the Router is genuinely not meant to fire this
        key — add it to @retired there with the module that owns it instead, and
        teach this test how to verify that claim.
        """)
    end
  end

  defp assert_provider_reaches(handler, provider, key, feature) do
    assert Code.ensure_loaded?(provider),
           "Feature #{inspect(feature)} resolves to #{inspect(provider)}, which does not " <>
             "load. Key #{key} (declared by #{inspect(handler)}) is unreachable."

    assert function_exported?(provider, :handler_for, 1),
           "#{inspect(provider)} has no public handler_for/1, so key #{key} cannot be " <>
             "checked for reachability at all."

    assert provider.handler_for(key) == handler,
           "#{inspect(provider)}.handler_for(#{inspect(key)}) returned " <>
             "#{inspect(provider.handler_for(key))}, but #{inspect(handler)} is the module " <>
             "that registers that key. The shim's dispatch table has drifted from " <>
             "BuiltIns.providers/0."

    assert function_exported?(provider, :handle_output, 3),
           "#{inspect(provider)} does not export handle_output/3. " <>
             "Router.invoke_handle_output/3 probes exactly that arity, so key #{key} would " <>
             "log \"no output handler\" and drop the model's answer despite the shim existing."
  end

  defp assert_retirement_is_real(handler, key, feature) do
    assert feature == "security",
           "Feature #{inspect(feature)} (key #{key}, declared by #{inspect(handler)}) is " <>
             "marked retired in Platform.Responsibilities.Providers, but \"security\" is the " <>
             "only retirement this test knows how to verify. A retirement nobody can check " <>
             "is indistinguishable from the black hole this task exists to close — add the " <>
             "verification here alongside the @retired entry."

    scanner_keys = Map.keys(Sweeper.default_scanner_modules())

    assert key in scanner_keys,
           "#{key} (declared by #{inspect(handler)}) resolves to {:retired, _} because " <>
             "feature \"security\" is exempt on the grounds that Platform.Security.Sweeper " <>
             "dispatches it — but #{key} is not in Sweeper.default_scanner_modules/0, which " <>
             "holds #{inspect(Enum.sort(scanner_keys))}. Nothing handles this key: the " <>
             "Router is told to stay away and the Sweeper no longer picks it up."
  end
end
