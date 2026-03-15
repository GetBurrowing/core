defmodule Platform.Context do
  @moduledoc """
  Runner-facing context plane for the Execution domain.

  Provides the public API for the context-plane substrate that backs
  `Platform.Execution`: scoped snapshots, versioned deltas, acknowledgements,
  and deterministic eviction.

  ## Scope hierarchy

  Context is always associated with a four-level scope:

      project_id / epic_id / task_id / run_id

  A run snapshot inherits from all enclosing scopes (project → epic → task →
  run).  Narrower scopes may shadow broader ones.

  ## Versioning

  Every mutation produces a new monotonically-increasing integer version.
  `required_version` is the version a runner must acknowledge before its run
  is considered current.  Runs that do not acknowledge within the SLA are
  marked stale by `Platform.Execution.RunServer`.

  ## Hot cache

  All live context items are stored in an ETS table (`Platform.Context.Cache`)
  for O(1) lookup.  ETS is the source of truth for running sessions; the
  Postgres layer is written asynchronously for persistence and audit.

  ## Public API quick-reference

      # Create / get a scoped session
      Platform.Context.ensure_session(scope)
      Platform.Context.get_session(scope)

      # Snapshots
      Platform.Context.snapshot(scope)

      # Mutations (return new version)
      Platform.Context.put_item(scope, key, value, opts)
      Platform.Context.delete_item(scope, key)

      # Delta fanout
      Platform.Context.apply_delta(scope, delta)
      Platform.Context.latest_delta(scope, since_version)

      # Acknowledgements
      Platform.Context.ack(scope, run_id, version)
      Platform.Context.ack_status(scope, run_id)

      # Eviction
      Platform.Context.evict(scope)
  """

  alias Platform.Context.{Cache, Session, Supervisor, Item, Delta}

  # ---------------------------------------------------------------------------
  # Session management
  # ---------------------------------------------------------------------------

  @doc """
  Ensures a context session exists for `scope` and returns it.

  `scope` must be a `%Platform.Context.Session.Scope{}` or a keyword/map with
  at least `:task_id`.
  """
  @spec ensure_session(Session.scope_input()) :: {:ok, Session.t()} | {:error, term()}
  def ensure_session(scope) do
    Supervisor.ensure_session(scope)
  end

  @doc "Returns the live session for `scope`, or `{:error, :not_found}`."
  @spec get_session(Session.scope_input()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(scope) do
    with {:ok, key} <- Session.scope_key(scope) do
      Cache.get_session(key)
    end
  end

  # ---------------------------------------------------------------------------
  # Snapshots
  # ---------------------------------------------------------------------------

  @doc """
  Returns a point-in-time snapshot of all context items for `scope`.

  Inherits from enclosing scopes (project → epic → task → run).
  """
  @spec snapshot(Session.scope_input()) ::
          {:ok, %{items: [Item.t()], version: non_neg_integer()}} | {:error, term()}
  def snapshot(scope) do
    with {:ok, key} <- Session.scope_key(scope),
         {:ok, session} <- Cache.get_session(key) do
      items = Cache.all_items(key)
      {:ok, %{items: items, version: session.version}}
    end
  end

  # ---------------------------------------------------------------------------
  # Item mutations
  # ---------------------------------------------------------------------------

  @doc """
  Upserts a context item within `scope`.

  Returns `{:ok, new_version}` on success.
  Options:
    - `:kind` — item kind atom, e.g. `:task_description`, `:env_var` (default `:generic`)
    - `:meta` — arbitrary metadata map
    - `:ttl_ms` — optional TTL; item is evicted from cache after this many ms
  """
  @spec put_item(Session.scope_input(), String.t(), term(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def put_item(scope, key, value, opts \\ []) do
    with {:ok, scope_key} <- Session.scope_key(scope),
         {:ok, _session} <- Cache.get_session(scope_key) do
      Cache.put_item(scope_key, key, value, opts)
    end
  end

  @doc "Removes a context item from `scope`. Returns `{:ok, new_version}`."
  @spec delete_item(Session.scope_input(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def delete_item(scope, key) do
    with {:ok, scope_key} <- Session.scope_key(scope),
         {:ok, _session} <- Cache.get_session(scope_key) do
      Cache.delete_item(scope_key, key)
    end
  end

  # ---------------------------------------------------------------------------
  # Deltas
  # ---------------------------------------------------------------------------

  @doc """
  Applies a `%Platform.Context.Delta{}` to `scope` and fans it out to
  subscribers.  Returns `{:ok, new_version}`.
  """
  @spec apply_delta(Session.scope_input(), Delta.t() | map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def apply_delta(scope, delta) do
    with {:ok, scope_key} <- Session.scope_key(scope),
         {:ok, _session} <- Cache.get_session(scope_key),
         {:ok, delta_struct} <- Delta.new(delta) do
      Cache.apply_delta(scope_key, delta_struct)
    end
  end

  @doc """
  Returns all deltas since `since_version` (exclusive) for `scope`.
  """
  @spec latest_delta(Session.scope_input(), non_neg_integer()) ::
          {:ok, [Delta.t()]} | {:error, term()}
  def latest_delta(scope, since_version \\ 0) do
    with {:ok, scope_key} <- Session.scope_key(scope) do
      {:ok, Cache.deltas_since(scope_key, since_version)}
    end
  end

  # ---------------------------------------------------------------------------
  # Acknowledgements
  # ---------------------------------------------------------------------------

  @doc """
  Records that `run_id` has acknowledged context version `version` for `scope`.
  """
  @spec ack(Session.scope_input(), String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def ack(scope, run_id, version) do
    with {:ok, scope_key} <- Session.scope_key(scope) do
      Cache.record_ack(scope_key, run_id, version)
    end
  end

  @doc """
  Returns the current acknowledgement status for `run_id` within `scope`.

  Returns `{:ok, %{acked_version: n, required_version: n, status: atom}}`.
  """
  @spec ack_status(Session.scope_input(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def ack_status(scope, run_id) do
    with {:ok, scope_key} <- Session.scope_key(scope),
         {:ok, session} <- Cache.get_session(scope_key) do
      acked = Cache.get_ack(scope_key, run_id)
      required = session.required_version

      status =
        cond do
          is_nil(acked) -> :pending
          acked >= required -> :current
          true -> :stale
        end

      {:ok, %{acked_version: acked, required_version: required, status: status}}
    end
  end

  # ---------------------------------------------------------------------------
  # Eviction
  # ---------------------------------------------------------------------------

  @doc """
  Evicts all in-memory state for `scope`.

  Called when a run terminates or a task/epic is closed.
  """
  @spec evict(Session.scope_input()) :: :ok
  def evict(scope) do
    with {:ok, scope_key} <- Session.scope_key(scope) do
      Cache.evict(scope_key)
    else
      _ -> :ok
    end
  end
end
