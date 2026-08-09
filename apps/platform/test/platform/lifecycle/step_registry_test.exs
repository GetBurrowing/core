defmodule Platform.Lifecycle.StepRegistryTest do
  use ExUnit.Case, async: true

  alias Platform.Lifecycle.StepRegistry

  setup context do
    name = :"step_registry_#{:erlang.phash2(context.test)}"
    start_supervised!({StepRegistry, name: name})
    %{registry: name}
  end

  describe "built-in seeding" do
    test "all/1 at boot equals built_in_steps/0", %{registry: registry} do
      # Drift guard: the shipped allowlist has exactly one source of
      # truth (the @built_in_steps attribute). If someone adds a second
      # registration site, this fails.
      assert StepRegistry.all(registry) == StepRegistry.built_in_steps()
    end

    test "every built-in resolves to a real arity-1 function" do
      for %{mfa: {mod, fun, 1}} <- StepRegistry.built_in_steps() do
        Code.ensure_loaded!(mod)
        assert function_exported?(mod, fun, 1), "#{inspect(mod)}.#{fun}/1 is not exported"
      end
    end
  end

  describe "fetch/2" do
    test "returns {:ok, entry} with an {m, f, 1} mfa for a built-in", %{registry: registry} do
      %{name: name} = hd(StepRegistry.built_in_steps())

      assert {:ok, entry} = StepRegistry.fetch(name, registry)
      assert %{name: ^name, kind: :deterministic} = entry
      assert {mod, fun, 1} = entry.mfa
      assert is_atom(mod) and is_atom(fun)
    end

    test "returns {:error, :unknown_step} for an unregistered name", %{registry: registry} do
      assert {:error, :unknown_step} = StepRegistry.fetch("no-such-step", registry)
    end

    test "does not fall back to a module-shaped name", %{registry: registry} do
      # A step name from configuration must never be resolved as code.
      assert {:error, :unknown_step} = StepRegistry.fetch("Elixir.System", registry)
      assert {:error, :unknown_step} = StepRegistry.fetch("Platform.Lifecycle.Steps", registry)
    end
  end

  describe "register/2" do
    test "is idempotent on name", %{registry: registry} do
      entry = %{
        name: "custom",
        mfa: {Platform.Lifecycle.Steps, :notify, 1},
        kind: :deterministic
      }

      before = length(StepRegistry.all(registry))

      assert :ok = StepRegistry.register(entry, registry)
      assert :ok = StepRegistry.register(entry, registry)

      assert length(StepRegistry.all(registry)) == before + 1
      assert {:ok, ^entry} = StepRegistry.fetch("custom", registry)
    end
  end

  describe "webhook_host_allowed?/1" do
    setup do
      previous = Application.get_env(:platform, :lifecycle_allowed_webhook_hosts)

      Application.put_env(:platform, :lifecycle_allowed_webhook_hosts, ["hooks.example.com"])

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:platform, :lifecycle_allowed_webhook_hosts)
          value -> Application.put_env(:platform, :lifecycle_allowed_webhook_hosts, value)
        end
      end)

      :ok
    end

    test "true for a host inside the injected allowlist" do
      assert StepRegistry.webhook_host_allowed?("hooks.example.com")
    end

    test "false for a host outside the injected allowlist" do
      refute StepRegistry.webhook_host_allowed?("evil.example.net")
      refute StepRegistry.webhook_host_allowed?("")
      refute StepRegistry.webhook_host_allowed?(nil)
    end
  end

  test "the compiled-in host allowlist ships empty (public repo, fail-closed)" do
    assert StepRegistry.default_allowed_webhook_hosts() == []
  end
end
