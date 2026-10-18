defmodule Platform.Security.Scanners.DeployAuditConfigTest do
  @moduledoc """
  `deploy_audit_core_ops_root` has no code default (task 01a14b9e stage 2):
  config.exs ships `nil`, and runtime.exs sets it only from
  DEPLOY_AUDIT_CORE_OPS_ROOT. Reads the real config files with
  `Config.Reader`, so a default reintroduced in either file fails here.
  """
  # Mutates the OS environment, which is process-global.
  use ExUnit.Case, async: false

  @config_dir Path.expand("../../../../config", __DIR__)
  @env "DEPLOY_AUDIT_CORE_OPS_ROOT"

  setup do
    previous = System.get_env(@env)

    on_exit(fn ->
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
    end)

    :ok
  end

  defp runtime_root do
    @config_dir
    |> Path.join("runtime.exs")
    |> Config.Reader.read!(env: :test)
    |> get_in([:platform, Platform.Security])
    |> Kernel.||([])
    |> Keyword.fetch(:deploy_audit_core_ops_root)
  end

  test "config.exs ships no core-ops root" do
    config = Config.Reader.read!(Path.join(@config_dir, "config.exs"), env: :prod)

    assert Keyword.fetch!(config[:platform][Platform.Security], :deploy_audit_core_ops_root) ==
             nil
  end

  test "runtime.exs sets the root from DEPLOY_AUDIT_CORE_OPS_ROOT" do
    System.put_env(@env, "/srv/acme-ops")
    assert runtime_root() == {:ok, "/srv/acme-ops"}

    System.put_env(@env, "  /srv/acme-ops  ")
    assert runtime_root() == {:ok, "/srv/acme-ops"}
  end

  test "runtime.exs leaves the root alone when DEPLOY_AUDIT_CORE_OPS_ROOT is unset or blank" do
    System.delete_env(@env)
    assert runtime_root() == :error

    System.put_env(@env, "   ")
    assert runtime_root() == :error
  end
end
