defmodule Platform.GameStream.Application do
  @moduledoc """
  Play's own OTP application (ADR 0055, task 01a0ee08 stage 3). It starts
  Play's process tree and reads Play's runtime settings; core does neither.

  ## Ordering

  `:game_stream` depends on `:platform`, so OTP starts it AFTER core's
  Endpoint and stops it BEFORE it. A runtime socket can therefore deliver a
  play frame before `Platform.GameStream.Supervisor` exists, and a runtime
  channel can terminate after it is gone. `Platform.GameStream.Extension`
  answers both without raising
  (`docs/decisions/0055-extension-contract-and-build-time-modules.md § 3. Supervision is the module's own`).

  ## Runtime settings

  `Platform.GameStream.RuntimeConfig.read/1` turns the OS environment into
  Play's app env (`:game_stream, :enabled` and `:game_stream, :turn`) here,
  at boot, in every build: a release's runtime config is core's
  `config/runtime.exs`, which no longer names Play, so the module cannot rely
  on any config file to carry them.
  """

  use Application

  @impl true
  def start(_type, _args) do
    Platform.GameStream.RuntimeConfig.apply(System.get_env())

    Supervisor.start_link([Platform.GameStream.Supervisor],
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end
end
