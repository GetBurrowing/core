defmodule Platform.Execution.ContextSession do
  @moduledoc """
  Bridges `Platform.Execution.Run` with `Platform.Context`.

  Responsibilities:

    1. **Open** — create (or re-join) a scoped context session when a run starts
    2. **Snapshot** — return the current context snapshot for a run
    3. **Push** — allow a run to push new items into its context session
    4. **Ack** — record the runner's acknowledgement of a required version
    5. **Require** — bump `required_version` so running runners must ack
    6. **Close** — evict the run-scoped session on terminal state

  All heavy lifting is delegated to `Platform.Context`.

  ## Session scoping

  A run's context session inherits from the task → epic → project hierarchy.
  When `open/1` is called it ensures all ancestor sessions exist:

      project_id  →  epic_id  →  task_id  →  run_id

  Each ancestor session may carry items that are visible in the run snapshot
  (aggregated by `Platform.Context.snapshot/1`).

  In MVP, ancestor sessions are only created if IDs are provided; the run-level
  session is always created.
  """

  alias Platform.Context
  alias Platform.Context.{Cache, Session}
  alias Platform.Execution.Run, as: Run

  # ---------------------------------------------------------------------------
  # Session lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Opens context sessions for the run and all ancestor scopes.

  Returns `{:ok, %{scope_key: String.t(), version: integer}}`.
  """
  @spec open(Run.t()) :: {:ok, map()} | {:error, term()}
  def open(%Run{} = run) do
    with :ok <- ensure_ancestors(run),
         {:ok, session} <- Context.ensure_session(run_scope(run)) do
      {:ok, %{scope_key: Run.context_scope_key(run), version: session.version}}
    end
  end

  @doc """
  Returns the aggregated context snapshot for the run.

  The snapshot merges items from:
    project_id / epic_id / task_id / run_id  (nearest wins on key collision).

  Returns `{:ok, %{items: [...], version: n, required_version: n}}`.
  """
  @spec snapshot(Run.t()) :: {:ok, map()} | {:error, term()}
  def snapshot(%Run{} = run) do
    scope = run_scope(run)

    case Context.snapshot(scope) do
      {:ok, %{items: items, version: version}} ->
        # Merge in ancestor items (broader scopes first, run scope wins)
        ancestor_items = collect_ancestor_items(run)
        merged = merge_items(ancestor_items, items)

        # Pull required_version from live session
        required = required_version(scope)

        {:ok,
         %{
           items: merged,
           version: version,
           required_version: required
         }}

      error ->
        error
    end
  end

  @doc """
  Pushes a map of `key => value` items into the run's context session.

  Returns `{:ok, new_version}`.
  """
  @spec push(Run.t(), map(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def push(%Run{} = run, items, opts \\ []) when is_map(items) do
    scope = run_scope(run)
    kind = Keyword.get(opts, :kind, :generic)
    source = Keyword.get(opts, :source)

    delta_puts =
      Map.new(items, fn {k, v} ->
        {to_string(k), {v, [kind: kind]}}
      end)

    delta = %{
      puts: delta_puts,
      deletes: [],
      source: source
    }

    Context.apply_delta(scope, delta)
  end

  @doc """
  Records that the runner has acknowledged `version` for this run.

  Also reconciles `ctx_acked_version` on the run struct and returns
  an updated run.
  """
  @spec ack(Run.t(), non_neg_integer()) :: {:ok, Run.t()} | {:error, term()}
  def ack(%Run{} = run, version) do
    scope = run_scope(run)

    with :ok <- Context.ack(scope, run.id, version) do
      %Run{} = updated_run = reconcile_ctx_status(%Run{run | ctx_acked_version: version})
      {:ok, updated_run}
    end
  end

  @doc """
  Bumps the required version for the run's context session to its current
  write version, and returns the new `required_version`.

  After this call any runner with an older ack is considered stale.
  """
  @spec require_current(Run.t()) :: {:ok, non_neg_integer(), Run.t()} | {:error, term()}
  def require_current(%Run{} = run) do
    scope_key = Run.context_scope_key(run)

    case Cache.get_session(scope_key) do
      {:ok, %Session{} = session} ->
        new_required = session.version
        updated_session = %Session{session | required_version: new_required}
        :ets.insert(:ctx_sessions, {scope_key, updated_session})

        updated_run = %Run{
          run
          | ctx_required_version: new_required,
            ctx_status: recompute_ctx_status(run.ctx_acked_version, new_required)
        }

        {:ok, new_required, updated_run}

      error ->
        error
    end
  end

  @doc """
  Closes (evicts) the run-scoped context session.

  Only evicts the run-level scope; ancestor scopes (task/epic/project) are
  managed independently.
  """
  @spec close(Run.t()) :: :ok
  def close(%Run{} = run) do
    Context.evict(run_scope(run))
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp run_scope(%Run{} = run) do
    %Session.Scope{
      project_id: run.project_id,
      epic_id: run.epic_id,
      task_id: run.task_id,
      run_id: run.id
    }
  end

  defp ensure_ancestors(%Run{} = run) do
    scopes =
      [
        run.project_id && %Session.Scope{project_id: run.project_id},
        run.epic_id &&
          %Session.Scope{project_id: run.project_id, epic_id: run.epic_id},
        %Session.Scope{
          project_id: run.project_id,
          epic_id: run.epic_id,
          task_id: run.task_id
        }
      ]
      |> Enum.reject(&is_nil/1)

    results =
      Enum.map(scopes, fn scope ->
        Context.ensure_session(scope)
      end)

    if Enum.all?(results, fn
         {:ok, _} -> true
         _ -> false
       end) do
      :ok
    else
      errors =
        results
        |> Enum.filter(fn
          {:ok, _} -> false
          _ -> true
        end)

      {:error, {:ancestor_session_failed, errors}}
    end
  end

  defp collect_ancestor_items(%Run{} = run) do
    ancestor_scopes =
      [
        run.project_id && %Session.Scope{project_id: run.project_id},
        run.epic_id &&
          %Session.Scope{project_id: run.project_id, epic_id: run.epic_id},
        %Session.Scope{
          project_id: run.project_id,
          epic_id: run.epic_id,
          task_id: run.task_id
        }
      ]
      |> Enum.reject(&is_nil/1)

    Enum.flat_map(ancestor_scopes, fn scope ->
      case Session.scope_key(scope) do
        {:ok, key} -> Cache.all_items(key)
        _ -> []
      end
    end)
  end

  defp merge_items(ancestor_items, run_items) do
    # Build a map from ancestor items; run items win on key collision
    ancestor_map = Map.new(ancestor_items, fn item -> {item.key, item} end)
    run_map = Map.new(run_items, fn item -> {item.key, item} end)

    ancestor_map
    |> Map.merge(run_map)
    |> Map.values()
    |> Enum.sort_by(& &1.key)
  end

  defp required_version(scope) do
    case Session.scope_key(scope) do
      {:ok, key} ->
        case Cache.get_session(key) do
          {:ok, session} -> session.required_version
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp reconcile_ctx_status(%Run{} = run) do
    new_status = recompute_ctx_status(run.ctx_acked_version, run.ctx_required_version)
    %Run{run | ctx_status: new_status}
  end

  defp recompute_ctx_status(nil, required) when required > 0, do: :stale
  defp recompute_ctx_status(nil, _), do: :current
  defp recompute_ctx_status(acked, required) when acked >= required, do: :current
  defp recompute_ctx_status(_, _), do: :stale
end
