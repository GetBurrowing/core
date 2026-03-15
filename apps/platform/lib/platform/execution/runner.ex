defmodule Platform.Execution.Runner do
  @moduledoc """
  Behaviour implemented by concrete execution providers.

  First-party providers planned in ADR 0011:

    * `local`  — OS process execution for bare-metal installs
    * `docker` — isolated runner containers managed by a companion service

  The platform owns control-plane state. Providers own the mechanics of starting,
  stopping, killing, and describing the underlying worker.

  ## Provider ref

  `spawn_run/2` returns a `provider_ref` map that must contain at minimum the
  fields needed by the other callbacks to re-locate the underlying process or
  container. The control plane stores this ref on the `Run` struct and hands it
  back to the provider on every subsequent call.

  ## Context push

  `push_context/3` delivers a context snapshot map to the runner. Providers
  should forward it to the underlying worker if they have a live channel, or
  store it for the next polling interval. It is fine to return `:ok` if the
  provider has no active context channel.
  """

  alias Platform.Execution.Run

  @type provider_ref :: map()
  @type result :: :ok | {:ok, map()} | {:error, term()}

  @callback spawn_run(Run.t(), keyword()) :: {:ok, provider_ref()} | {:error, term()}
  @callback request_stop(Run.t(), keyword()) :: result()
  @callback force_stop(Run.t(), keyword()) :: result()
  @callback describe_run(Run.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Push a context snapshot to the runner.

  `context` is a plain map containing the serialised context state to deliver
  to the runner. Providers that have no active in-process channel may return `:ok`
  immediately; the control plane retains the authoritative version.
  """
  @callback push_context(Run.t(), map(), keyword()) :: result()
end
