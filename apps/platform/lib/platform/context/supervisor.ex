defmodule Platform.Context.Supervisor do
  @moduledoc """
  Supervision tree for the context-plane runtime.

  Children (in start order):

    1. `Platform.Context.Cache`   — ETS-backed hot-cache GenServer

  Future children (added in later stages):
    - `Platform.Context.StaleSweeper` — periodic stale-ack detection
  """

  use Supervisor

  alias Platform.Context.{Cache, Session}

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Cache
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ---------------------------------------------------------------------------
  # Convenience — ensure session
  # ---------------------------------------------------------------------------

  @doc """
  Ensures a context session exists for `scope`.

  Delegates to `Cache.create_session/1` (idempotent).
  Returns `{:ok, session}` or `{:error, reason}`.
  """
  @spec ensure_session(Session.scope_input()) :: {:ok, Session.t()} | {:error, term()}
  def ensure_session(scope) do
    with {:ok, resolved_scope} <- Session.to_scope(scope) do
      Cache.create_session(resolved_scope)
    end
  end
end
