defmodule Platform.Execution.Runner do
  @moduledoc """
  Behaviour implemented by concrete execution providers.

  First-party providers planned in ADR 0011:

    * `local`  — OS process execution for bare-metal installs
    * `docker` — isolated runner containers managed by a companion service

  The platform owns control-plane state. Providers own the mechanics of starting,
  stopping, killing, and describing the underlying worker.
  """

  alias Platform.Execution.{ContextSession, Run}

  @type provider_ref :: map()
  @type result :: :ok | {:ok, map()} | {:error, term()}

  @callback spawn_run(Run.t(), keyword()) :: {:ok, provider_ref()} | {:error, term()}
  @callback request_stop(Run.t(), keyword()) :: result()
  @callback force_stop(Run.t(), keyword()) :: result()
  @callback describe_run(Run.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback push_context(Run.t(), ContextSession.t(), keyword()) :: result()
end
