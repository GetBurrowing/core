defmodule Platform.Goals.RuntimeConfig do
  @moduledoc """
  Goals' runtime settings, read from the OS environment at boot by
  `Platform.Goals.Application.start/2` (ADR 0055, task 01a1dfc0), the way
  `Platform.GameStream.RuntimeConfig` reads Play's. No config file reads them:
  a release runs core's `config/runtime.exs`, which never names a module
  (`docs/decisions/0055-extension-contract-and-build-time-modules.md § 8. Configuration that belongs to a module`).

  ## `GOALS_ENABLED`

  `"true"` or `"1"` turns Goals on; anything else, including unset, leaves it
  off. OFF BY DEFAULT IN EVERY ENVIRONMENT, dev included. Off, the module
  registers no permission, so `goals.use` is unknown to the install. This is
  the only place in the repository that reads the variable.
  """

  @doc """
  The settings `env` (an OS-environment map, `System.get_env/0`'s shape)
  describes, as `[enabled: boolean]`. Pure.
  """
  @spec read(%{optional(String.t()) => String.t()}) :: keyword()
  def read(env) when is_map(env) do
    [enabled: Map.get(env, "GOALS_ENABLED") in ["true", "1"]]
  end

  @doc "Reads `env` and puts the result in the `:goals` app env."
  @spec apply(%{optional(String.t()) => String.t()}) :: :ok
  def apply(env) do
    settings = read(env)
    Application.put_env(:goals, :enabled, Keyword.fetch!(settings, :enabled))
  end
end
