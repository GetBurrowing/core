defmodule Platform.Context.EvictionPolicy do
  @moduledoc """
  Deterministic eviction rules for context items, tied to run/task/epic/project
  lifecycle events.

  ## Design

  Context items carry a `kind` atom that determines their *eviction scope*.
  When a lifecycle boundary is crossed, `EvictionPolicy` decides which scopes
  to evict and which ancestor sessions to touch.

  ## Eviction scopes (inner → outer)

      :run     — evicted when the run terminates (any terminal status)
      :task    — evicted when the task is closed / all runs for the task end
      :epic    — evicted when the epic is closed
      :project — evicted when the project session is torn down

  ## Eviction cascade

  Lifecycle events trigger only the matching scope and no inner ones (inner
  scopes were already evicted by their own lifecycle events):

      run_terminated/1    → evict run-scoped session
      task_closed/1       → evict task-scoped items from the task session
      epic_closed/1       → evict epic-scoped items from the epic session
      project_closed/1    → evict the project session entirely

  ## Promotion on run end

  Run-scoped items with `kind: :artifact_ref` are *promoted* to the task
  session before the run session is evicted, so the task can reference
  produced artifacts.  All other run-scoped items are discarded silently.

  The promotion is idempotent (uses the same key in the task session).
  """

  alias Platform.Context
  alias Platform.Context.{Cache, Item, Item.Kind, Session}

  # ---------------------------------------------------------------------------
  # Lifecycle hooks
  # ---------------------------------------------------------------------------

  @doc """
  Called when a run terminates (completed, failed, or cancelled).

  Actions:
    1. Promote `:artifact_ref` items to the task session (if task session exists)
    2. Evict the run-scoped context session

  Returns `:ok`.
  """
  @spec run_terminated(map()) :: :ok
  def run_terminated(%{run_id: run_id, task_id: task_id} = scope_info) do
    run_scope = build_scope(scope_info, :run)
    task_scope = build_scope(scope_info, :task)

    with {:ok, run_scope_key} <- Session.scope_key(run_scope),
         {:ok, task_scope_key} <- Session.scope_key(task_scope) do
      promote_artifacts(run_scope_key, task_scope_key)
    end

    Context.evict(run_scope)

    _ = run_id
    _ = task_id
    :ok
  end

  @doc """
  Called when a task is closed (all runs done; task moved to terminal state).

  Evicts all task-scoped items from the task session.  The task session
  itself is also evicted since it is no longer needed.

  Returns `:ok`.
  """
  @spec task_closed(map()) :: :ok
  def task_closed(%{task_id: _task_id} = scope_info) do
    task_scope = build_scope(scope_info, :task)
    Context.evict(task_scope)
    :ok
  end

  @doc """
  Called when an epic is closed.

  Evicts all epic-scoped items from the epic session.  The epic session itself
  is evicted.

  Returns `:ok`.
  """
  @spec epic_closed(map()) :: :ok
  def epic_closed(%{epic_id: _epic_id} = scope_info) do
    epic_scope = build_scope(scope_info, :epic)
    Context.evict(epic_scope)
    :ok
  end

  @doc """
  Called when a project session is torn down.

  Evicts the project session entirely.

  Returns `:ok`.
  """
  @spec project_closed(map()) :: :ok
  def project_closed(%{project_id: _project_id} = scope_info) do
    project_scope = build_scope(scope_info, :project)
    Context.evict(project_scope)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Eviction by kind
  # ---------------------------------------------------------------------------

  @doc """
  Returns the list of item keys in `scope_key` that should be evicted for
  the given `eviction_scope`.

  Useful for targeted eviction (e.g. drop only `:env_var` items from a task
  session without evicting the whole session).
  """
  @spec keys_to_evict(String.t(), :run | :task | :epic | :project) :: [String.t()]
  def keys_to_evict(scope_key, eviction_scope) do
    Cache.all_items(scope_key)
    |> Enum.filter(fn %Item{kind: kind} ->
      Kind.eviction_scope(kind) == eviction_scope
    end)
    |> Enum.map(& &1.key)
  end

  @doc """
  Removes all items from `scope_key` that match `eviction_scope`, without
  evicting the whole session.

  Returns `{:ok, removed_count}`.
  """
  @spec evict_by_scope(String.t(), :run | :task | :epic | :project) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def evict_by_scope(scope_key, eviction_scope) do
    keys = keys_to_evict(scope_key, eviction_scope)

    results =
      Enum.map(keys, fn key ->
        Cache.delete_item(scope_key, key)
      end)

    errors =
      Enum.filter(results, fn
        {:ok, _} -> false
        _ -> true
      end)

    if errors == [] do
      {:ok, length(keys)}
    else
      {:error, {:partial_eviction, errors}}
    end
  end

  # ---------------------------------------------------------------------------
  # Promotion
  # ---------------------------------------------------------------------------

  @doc """
  Promotes `:artifact_ref` items from `from_scope_key` into `to_scope_key`.

  The target session must already exist.  Items are upserted (same key, same
  value) so the operation is idempotent.

  Returns `{:ok, promoted_count}`.
  """
  @spec promote_artifacts(String.t(), String.t()) :: {:ok, non_neg_integer()}
  def promote_artifacts(from_scope_key, to_scope_key) do
    artifact_items =
      Cache.all_items(from_scope_key)
      |> Enum.filter(fn %Item{kind: kind} -> kind == :artifact_ref end)

    results =
      Enum.map(artifact_items, fn %Item{key: key, value: value, meta: meta} ->
        Cache.put_item(to_scope_key, key, value, kind: :artifact_ref, meta: meta)
      end)

    promoted =
      Enum.count(results, fn
        {:ok, _} -> true
        _ -> false
      end)

    {:ok, promoted}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_scope(info, :run) do
    %Session.Scope{
      project_id: Map.get(info, :project_id),
      epic_id: Map.get(info, :epic_id),
      task_id: Map.get(info, :task_id),
      run_id: Map.get(info, :run_id)
    }
  end

  defp build_scope(info, :task) do
    %Session.Scope{
      project_id: Map.get(info, :project_id),
      epic_id: Map.get(info, :epic_id),
      task_id: Map.get(info, :task_id)
    }
  end

  defp build_scope(info, :epic) do
    %Session.Scope{
      project_id: Map.get(info, :project_id),
      epic_id: Map.get(info, :epic_id)
    }
  end

  defp build_scope(info, :project) do
    %Session.Scope{
      project_id: Map.get(info, :project_id)
    }
  end
end
