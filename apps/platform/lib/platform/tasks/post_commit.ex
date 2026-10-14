defmodule Platform.Tasks.PostCommit do
  @moduledoc """
  Run side effects AFTER the enclosing transaction commits (task 01a136c1
  stage 1).

  `scope/1` wraps a function that owns a `Repo.transaction`. While the scope
  is open, `run_after_commit/2` queues its thunk instead of running it. When
  the wrapped function returns `{:ok, _}` (a committed `Repo.transaction`),
  the queued thunks run IN ORDER; on any other return, or a raise, they are
  DISCARDED, because a side effect of a write that did not commit must not
  happen. Nested scopes defer to the outermost one, so a thunk queued inside
  an inner transaction cannot run before the outer commit.

  `run_after_commit/2` accepts a `:key`. Within one scope, a thunk whose key
  is already queued is DROPPED (the first one queued wins), so one commit
  fires a keyed side effect once however many code paths asked for it.
  Unkeyed thunks are never deduplicated.

  `run_after_commit/2` with NO scope open runs the thunk immediately. That
  keeps every caller outside a scope on its pre-existing behaviour. It also
  means a caller that opens a bare `Repo.transaction` without a scope gets
  NO deferral: the thunk runs inside that transaction, exactly as before.
  Wrap such a transaction in `scope/1` when its side effects read the rows
  it writes.

  ## Why this exists

  `StackDeployer.handle_member_transition/3` spawns the rollup merge as an
  async child (`async: true`, the production default). The child reads
  through its own pool connection. When the trigger fired inside
  `PlanEngine.evaluate_validation/2`'s transaction, the child could not see
  the validation that transaction had just passed, declined the merge as
  `{:stages_pending, n - 1, n}`, and nothing retried it.

  ## Why a process-dictionary scope

  Same reason as the plan engine's broadcast deferral: under the SQL
  sandbox `Repo.in_transaction?/0` is true for the whole test, so it cannot
  tell "inside OUR transaction" from "checked out by the test". An explicit
  scope is decidable in both environments.

  ## Thunk failures

  Each thunk runs under its own rescue/catch. The transaction has already
  committed, so a failing side effect is logged and the remaining thunks
  still run; the caller's committed result is returned unchanged.
  """

  require Logger

  @key :platform_tasks_post_commit_queue

  @doc """
  Run `fun` with post-commit thunks queued. Returns `fun`'s result.
  """
  @spec scope((-> result)) :: result when result: term()
  def scope(fun) when is_function(fun, 0) do
    case Process.get(@key) do
      nil ->
        Process.put(@key, [])

        result =
          try do
            fun.()
          rescue
            e ->
              Process.delete(@key)
              reraise e, __STACKTRACE__
          catch
            kind, reason ->
              Process.delete(@key)
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        queued = Process.get(@key, [])
        # Close the scope BEFORE running the thunks: they run after the
        # commit, so anything they queue themselves must run immediately
        # rather than land in a queue nobody will flush.
        Process.delete(@key)

        case result do
          {:ok, _} -> queued |> Enum.reverse() |> Enum.map(&elem(&1, 1)) |> run_queued()
          _ -> :ok
        end

        result

      _queued ->
        fun.()
    end
  end

  @doc """
  Queue `thunk` to run after the outermost open scope commits, or run it
  now when no scope is open. Returns `:ok` when queued (or dropped as a
  duplicate key), otherwise the thunk's own return value.

  Options:

    * `:key` - dedupe key. A second thunk with a key already queued in the
      open scope is dropped. Ignored when no scope is open.
  """
  @spec run_after_commit((-> term()), keyword()) :: term()
  def run_after_commit(thunk, opts \\ []) when is_function(thunk, 0) and is_list(opts) do
    key = Keyword.get(opts, :key)

    case Process.get(@key) do
      nil ->
        thunk.()

      queued ->
        if is_nil(key) or not List.keymember?(queued, key, 0) do
          Process.put(@key, [{key, thunk} | queued])
        end

        :ok
    end
  end

  @doc false
  # True while a scope is open in this process. For tests and assertions.
  @spec open?() :: boolean()
  def open?, do: Process.get(@key) != nil

  defp run_queued(thunks) do
    Enum.each(thunks, fn thunk ->
      try do
        thunk.()
      rescue
        e ->
          Logger.warning("[PostCommit] post-commit thunk raised: " <> Exception.message(e))
      catch
        kind, reason ->
          Logger.warning("[PostCommit] post-commit thunk #{kind}: #{inspect(reason)}")
      end
    end)
  end
end
