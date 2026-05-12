defmodule Platform.Tasks.Stacks do
  @moduledoc """
  Persistent context for the Task Stacks domain (ADR 0041).

  Task stacks group co-related tasks that ship together as a single rollup PR.
  Members of a stack reuse the existing `tasks.dependencies` machinery to
  govern in-stack execution order, so members with no inter-dependency can
  be implemented in parallel.

  This module exposes the lifecycle surface for stacks themselves; member
  attachment, DAG validation, dispatch helpers, and rollup-status
  recomputation land in subsequent T2 stages.
  """

  import Ecto.Query

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Stack, Task}

  @slug_regex ~r/^[a-z0-9][a-z0-9-]*$/
  @max_slug_length 60

  # ── CRUD ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new stack.

  Validates via `Stack.changeset/2`. Caller is responsible for supplying a
  `rollup_branch` consistent with `rollup_branch_name/1` (typically the
  stack's slug); future stages may auto-derive it.
  """
  @spec create_stack(map()) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def create_stack(attrs) when is_map(attrs) do
    %Stack{}
    |> Stack.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a stack by id. Returns the struct or nil."
  @spec get_stack(binary()) :: Stack.t() | nil
  def get_stack(id) when is_binary(id), do: Repo.get(Stack, id)

  @doc "Fetch a stack by id, raising `Ecto.NoResultsError` if absent."
  @spec get_stack!(binary()) :: Stack.t()
  def get_stack!(id) when is_binary(id), do: Repo.get!(Stack, id)

  @doc """
  List stacks, optionally filtered by `:project_id` and/or `:status`.

  Results are ordered by `inserted_at` descending so the most recent stacks
  come first.
  """
  @spec list_stacks(map()) :: [Stack.t()]
  def list_stacks(filters \\ %{}) when is_map(filters) do
    Stack
    |> filter_by_project(Map.get(filters, :project_id))
    |> filter_by_status(Map.get(filters, :status))
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  defp filter_by_project(query, nil), do: query

  defp filter_by_project(query, project_id) when is_binary(project_id) do
    where(query, [s], s.project_id == ^project_id)
  end

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, status) when is_binary(status) do
    where(query, [s], s.status == ^status)
  end

  @doc "Update a stack via `Stack.changeset/2`."
  @spec update_stack(Stack.t(), map()) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def update_stack(%Stack{} = stack, attrs) when is_map(attrs) do
    stack
    |> Stack.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Terminal transition: mark a stack `abandoned` and record the reason.

  Per ADR 0041 (Lifecycle / Rollback / abandon), the per-member handling on
  abandon is non-trivial: members already merged into the rollup retain
  their status with `stack_id` cleared, while unmerged members return to
  `backlog`. That logic depends on the membership/eject helpers landing in
  stage 2 of this task; for now this function only flips the stack-level
  status and stamps the reason into `description`.
  """
  @spec abandon_stack(Stack.t(), String.t() | nil) ::
          {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def abandon_stack(%Stack{} = stack, reason \\ nil) do
    # TODO(stage 2): per-member handling — clear stack_id on every member;
    # leave already-merged members at their current status, return unmerged
    # members to backlog. Requires `eject_task/2` from the membership stage.
    attrs = %{status: "abandoned", description: abandon_description(stack, reason)}

    stack
    |> Stack.changeset(attrs)
    |> Repo.update()
  end

  defp abandon_description(%Stack{description: existing}, nil), do: existing

  defp abandon_description(%Stack{description: nil}, reason) when is_binary(reason),
    do: "Abandoned: #{reason}"

  defp abandon_description(%Stack{description: existing}, reason) when is_binary(reason),
    do: "#{existing}\n\nAbandoned: #{reason}"

  # ── Membership ───────────────────────────────────────────────────────────

  @doc """
  Attach a task to a stack as a new member.

  Loads the stack and task fresh inside a transaction. Rejects with
  `{:error, :already_in_stack}` if the task is already attached to any
  stack. Computes the next `stack_position` as `max(existing) + 1`
  (starting at 1) and writes via `Platform.Tasks.update_task/2` so the
  existing changeset + broadcast pipeline runs.

  After the write, runs `validate_dag/1` against the augmented member
  set; on `:cycle` or `:cross_stack_dep` the transaction is rolled back
  and the error tuple is returned unchanged. On success, calls
  `recompute_stack_status/1` and returns `{:ok, task}`.
  """
  @spec add_task(Stack.t() | binary(), Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error, :already_in_stack | :stack_not_found | :task_not_found | term()}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
  def add_task(stack_or_id, task_or_id) do
    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             {:ok, %Task{} = task} <- load_task(task_or_id),
             :ok <- ensure_not_in_stack(task),
             position = next_stack_position(stack.id),
             {:ok, updated_task} <-
               Tasks.update_task(task, %{stack_id: stack.id, stack_position: position}),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          updated_task
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # `validate_dag/1`'s richer 3-tuple errors are stuffed into a
    # 2-tuple shape on the way into `Repo.rollback/1` so the `with`
    # chain stays uniform; unpack them here so callers see the
    # original `{:error, :cycle, path}` / `{:error, :cross_stack_dep,
    # payload}` shape without wrapping.
    case txn do
      {:error, {:cycle, path}} -> {:error, :cycle, path}
      {:error, {:cross_stack_dep, payload}} -> {:error, :cross_stack_dep, payload}
      other -> other
    end
  end

  # Bridge `validate_dag/1`'s 3-tuple errors into the `with` chain's
  # 2-tuple convention so they roll back the transaction. Unwrapped
  # back into the original 3-tuple after `Repo.transaction/1` returns.
  defp normalize_dag_result({:ok, levels}), do: {:ok, levels}
  defp normalize_dag_result({:error, :cycle, path}), do: {:error, {:cycle, path}}

  defp normalize_dag_result({:error, :cross_stack_dep, payload}),
    do: {:error, {:cross_stack_dep, payload}}

  @doc """
  Detach a task from its stack.

  Returns `{:error, :not_in_stack}` when the task's `stack_id` does not
  match the supplied stack. Before clearing, computes which other
  members of the stack depend on this task (in-stack edges only) and
  refuses with `{:error, {:has_dependents, [%{id, title}]}}` if any
  exist.

  On a clean eject, clears `stack_id` and `stack_position` via
  `Platform.Tasks.update_task/2`. Per ADR 0041, the member's
  `status` is intentionally left as-is — the caller (or the stack-level
  abandon flow) decides whether to drop it back to backlog. After the
  write, calls `recompute_stack_status/1` and returns `{:ok, task}`.
  """
  @spec eject_task(Stack.t() | binary(), Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error,
             :not_in_stack
             | :stack_not_found
             | :task_not_found
             | {:has_dependents, [%{id: String.t(), title: String.t()}]}
             | term()}
  def eject_task(stack_or_id, task_or_id) do
    Repo.transaction(fn ->
      with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
           {:ok, %Task{} = task} <- load_task(task_or_id),
           :ok <- ensure_in_stack(stack, task),
           :ok <- ensure_no_in_stack_dependents(stack, task),
           {:ok, updated_task} <-
             Tasks.update_task(task, %{stack_id: nil, stack_position: nil}),
           {:ok, _stack} <- recompute_stack_status(stack) do
        updated_task
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  List the (non-deleted) members of a stack, ordered by `stack_position` asc.
  """
  @spec members(Stack.t() | binary()) :: [Task.t()]
  def members(%Stack{id: stack_id}), do: members(stack_id)

  def members(stack_id) when is_binary(stack_id) do
    Task
    |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
    |> order_by([t], asc: t.stack_position)
    |> Repo.all()
  end

  # ── DAG validation / status recompute ────────────────────────────────────

  @doc """
  Validate the in-stack dependency DAG and return execution levels.

  Loads all current members of the stack, derives the dependency edges
  among them (dropping self-references and cross-stack-to-non-stack
  edges per ADR 0041 §"DAG validation"), then runs Kahn's topological
  sort over the in-stack subgraph.

  Returns:

    * `{:ok, levels}` — `levels` is a list of lists of `%Task{}`. Each
      inner list is a "level" of members runnable in parallel; level 0
      members have no in-stack predecessors, level 1 members depend
      only on level 0, and so on.
    * `{:error, :cycle, path}` — the in-stack subgraph contains a
      dependency cycle. `path` is a best-effort list of `%Task{}` along
      one offending cycle (recovered by walking back-edges through the
      residue Kahn could not drain).
    * `{:error, :cross_stack_dep, %{from: from, to_task_id: to_id}}` —
      member `from` declares a dependency on `to_id`, which itself
      belongs to a different (non-nil) stack. Cross-stack edges are
      rejected at v1 because two stacks must be independently
      shippable.
  """
  @spec validate_dag(Stack.t() | binary()) ::
          {:ok, [[Task.t()]]}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
  def validate_dag(%Stack{id: stack_id}), do: validate_dag(stack_id)

  def validate_dag(stack_id) when is_binary(stack_id) do
    members = members(stack_id)

    case build_in_stack_subgraph(members, stack_id) do
      {:ok, edges} ->
        case kahn_levels(members, edges) do
          {:ok, levels} ->
            {:ok, levels}

          {:error, :cycle, residue_ids} ->
            {:error, :cycle, find_cycle(residue_ids, edges, members)}
        end

      {:error, :cross_stack_dep, payload} ->
        {:error, :cross_stack_dep, payload}
    end
  end

  @doc """
  Recompute and persist a stack's rollup status from its members.

  Implements the ADR 0041 §"Status mapping" table:

      done        — all members done
      deploying   — any member deploying, none earlier
      in_review   — all members in_review/deploying/done
      in_progress — any member in_progress
      forming     — any backlog/planning/stack_pending, no member past in_progress

  Stacks already at `abandoned` are terminal and are NEVER auto-recomputed;
  this function returns `{:ok, stack}` for them unchanged. The DB write is
  skipped when the computed status matches the existing status. Members
  whose status falls outside the recognized set are treated conservatively
  as not-yet-past-in_progress.
  """
  @spec recompute_stack_status(Stack.t() | binary()) ::
          {:ok, Stack.t()} | {:error, Ecto.Changeset.t() | :stack_not_found}
  def recompute_stack_status(%Stack{status: "abandoned"} = stack), do: {:ok, stack}

  def recompute_stack_status(%Stack{} = stack) do
    members = members(stack.id)
    new_status = rollup_status_for(members)

    if new_status == stack.status do
      {:ok, stack}
    else
      stack
      |> Stack.changeset(%{status: new_status})
      |> Repo.update()
    end
  end

  def recompute_stack_status(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> recompute_stack_status(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  # Pure rollup of member statuses → stack rollup status. Empty stack
  # stays at `forming` (no members have advanced past `forming` yet).
  defp rollup_status_for([]), do: "forming"

  defp rollup_status_for(members) do
    statuses = Enum.map(members, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 == "done")) -> "done"
      Enum.any?(statuses, &(&1 == "deploying")) -> "deploying"
      Enum.all?(statuses, &(&1 in ["in_review", "deploying", "done"])) -> "in_review"
      Enum.any?(statuses, &(&1 == "in_progress")) -> "in_progress"
      true -> "forming"
    end
  end

  # ── Dispatch helpers ─────────────────────────────────────────────────────

  @doc """
  Return the stack members that have no in-stack dependencies — the
  level-0 "roots" of the in-stack DAG.

  Thin wrapper over `validate_dag/1`. If validation fails (cycle or
  cross-stack edge), returns `[]` so callers don't crash on a stack with
  a transient invalid state.
  """
  @spec executable_members(Stack.t() | binary()) :: [Task.t()]
  def executable_members(stack_or_id) do
    case validate_dag(stack_or_id) do
      {:ok, []} -> []
      {:ok, [roots | _]} -> roots
      {:error, _reason, _detail} -> []
    end
  end

  @doc """
  Check whether a stack member's in-stack dependencies have all crossed the
  ADR 0041 §"Unblock threshold".

  An in-stack dep clears when its status is one of `in_review`, `deploying`,
  or `done` AND its `metadata["merged_into_rollup_at"]` is set. Returns
  `false` for any task whose `stack_id` is nil (non-members are out of
  scope; cross-stack deps to non-members are handled by the existing
  `done`-only sweep elsewhere). Returns `true` for a member with no
  in-stack deps (vacuously unblocked).

  Cross-stack deps (deps pointing at tasks NOT in this stack) are
  ignored here on purpose — they're gated by the existing
  `done`-threshold sweep.
  """
  @spec unblocked_in_stack?(Task.t()) :: boolean()
  def unblocked_in_stack?(%Task{stack_id: nil}), do: false

  def unblocked_in_stack?(%Task{stack_id: stack_id} = task) when is_binary(stack_id) do
    member_ids =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], t.id)
      |> Repo.all()
      |> MapSet.new()

    in_stack_dep_ids =
      task
      |> Tasks.dependency_task_ids()
      |> Enum.reject(&(&1 == task.id))
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(member_ids, &1))

    case in_stack_dep_ids do
      [] ->
        true

      ids ->
        deps =
          from(t in Task, where: t.id in ^ids, select: %{status: t.status, metadata: t.metadata})
          |> Repo.all()

        # If a declared dep id has no row (e.g. soft-deleted out from
        # under us), treat it as unmet — better to stall than to
        # falsely promote.
        length(deps) == length(ids) and
          Enum.all?(deps, &threshold_cleared?/1)
    end
  end

  defp threshold_cleared?(%{status: status, metadata: metadata})
       when status in ["in_review", "deploying", "done"] do
    is_map(metadata) and not is_nil(Map.get(metadata, "merged_into_rollup_at"))
  end

  defp threshold_cleared?(_), do: false

  @doc """
  Given a stack and a member task that just crossed the unblock threshold
  (its `merged_into_rollup_at` was just stamped), return the list of
  current `stack_pending` members that are now unblocked.

  Pure read-side helper: does NOT mutate. The caller (the sweep) is
  responsible for transitioning the returned members to `in_progress`.
  Members already past `stack_pending` are skipped — only `stack_pending`
  rows can be auto-promoted, since they were the ones blocked.
  """
  @spec unblocked_after(Stack.t() | binary(), Task.t()) :: [Task.t()]
  def unblocked_after(stack_or_id, %Task{id: just_merged_id}) do
    stack_id =
      case stack_or_id do
        %Stack{id: id} -> id
        id when is_binary(id) -> id
      end

    stack_id
    |> members()
    |> Enum.filter(fn %Task{} = member ->
      member.status == "stack_pending" and
        just_merged_id in Tasks.dependency_task_ids(member) and
        unblocked_in_stack?(member)
    end)
  end

  # ── Membership internals ─────────────────────────────────────────────────

  # Always reload from the DB so callers can hand us potentially-stale
  # structs without false negatives on membership checks.
  defp load_stack(%Stack{id: id}), do: load_stack(id)

  defp load_stack(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> {:ok, stack}
      nil -> {:error, :stack_not_found}
    end
  end

  defp load_task(%Task{id: id}), do: load_task(id)

  defp load_task(task_id) when is_binary(task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> {:ok, task}
      nil -> {:error, :task_not_found}
    end
  end

  defp ensure_not_in_stack(%Task{stack_id: nil}), do: :ok
  defp ensure_not_in_stack(%Task{}), do: {:error, :already_in_stack}

  defp ensure_in_stack(%Stack{id: stack_id}, %Task{stack_id: stack_id}), do: :ok
  defp ensure_in_stack(_stack, _task), do: {:error, :not_in_stack}

  defp ensure_no_in_stack_dependents(%Stack{id: stack_id}, %Task{id: task_id}) do
    member_ids =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], t.id)
      |> Repo.all()
      |> MapSet.new()

    dependents =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at) and t.id != ^task_id)
      |> Repo.all()
      |> Enum.filter(fn member ->
        task_id in (member
                    |> Tasks.dependency_task_ids()
                    |> Enum.filter(&MapSet.member?(member_ids, &1)))
      end)
      |> Enum.map(fn %Task{id: id, title: title} -> %{id: id, title: title} end)

    case dependents do
      [] -> :ok
      _ -> {:error, {:has_dependents, dependents}}
    end
  end

  defp next_stack_position(stack_id) when is_binary(stack_id) do
    max_pos =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], max(t.stack_position))
      |> Repo.one()

    (max_pos || 0) + 1
  end

  # ── DAG internals ────────────────────────────────────────────────────────

  # Walk every member's declared dependencies and partition each edge:
  #
  #   * self-edges → silently dropped (matches `unmet_dependencies/1`).
  #   * dep target IS a member of THIS stack → retained as an in-stack edge.
  #   * dep target is some other task whose `stack_id` is non-nil and
  #     differs from this stack → reject as `:cross_stack_dep`.
  #   * dep target is unknown or has no stack → silently dropped per ADR
  #     0041 §"DAG validation" point 3 (allowed cross-stack-to-non-stack).
  #
  # The cross-stack lookup hits the DB exactly once: we batch every
  # not-in-stack dep id and ask Postgres for their `stack_id`s.
  @spec build_in_stack_subgraph([Task.t()], String.t()) ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
  defp build_in_stack_subgraph(members, stack_id) do
    member_ids = MapSet.new(members, & &1.id)

    # First pass: filter self-edges, classify each remaining edge as
    # in-stack vs. external (deferred check).
    {in_stack_edges, external_edges, external_ids} =
      Enum.reduce(members, {[], [], MapSet.new()}, fn %Task{id: from_id} = member,
                                                      {in_acc, ext_acc, ext_ids} ->
        member
        |> Tasks.dependency_task_ids()
        |> Enum.reject(&(&1 == from_id))
        |> Enum.uniq()
        |> Enum.reduce({in_acc, ext_acc, ext_ids}, fn dep_id, {ia, ea, ei} ->
          cond do
            MapSet.member?(member_ids, dep_id) ->
              {[{from_id, dep_id} | ia], ea, ei}

            true ->
              {ia, [{member, dep_id} | ea], MapSet.put(ei, dep_id)}
          end
        end)
      end)

    # Second pass: a single DB hit to resolve `stack_id` for every
    # external dep target. Anything with a non-nil stack_id ≠ ours is
    # a cross-stack edge.
    foreign_stack_by_id =
      case MapSet.size(external_ids) do
        0 ->
          %{}

        _ ->
          ids = MapSet.to_list(external_ids)

          from(t in Task,
            where: t.id in ^ids and not is_nil(t.stack_id) and t.stack_id != ^stack_id,
            select: {t.id, t.stack_id}
          )
          |> Repo.all()
          |> Map.new()
      end

    case Enum.find(external_edges, fn {_member, dep_id} ->
           Map.has_key?(foreign_stack_by_id, dep_id)
         end) do
      nil ->
        {:ok, in_stack_edges}

      {from_member, dep_id} ->
        {:error, :cross_stack_dep, %{from: from_member, to_task_id: dep_id}}
    end
  end

  # Kahn's algorithm over the in-stack subgraph.
  #
  # Edges have shape `{from_id, to_id}` meaning "`from` depends on
  # `to`". Execution flows in the reverse direction: `to` must run
  # first, and `from`'s in-degree counts *outgoing* dep edges (number
  # of in-stack tasks `from` waits on).
  #
  # Each level pops every member whose remaining wait-count is zero,
  # then decrements the wait-count of every member that was depending
  # on a popped node. Continues until the graph drains; if any node
  # remains with a non-zero wait-count, returns `{:error, :cycle, ids}`
  # with the residue id list.
  @spec kahn_levels([Task.t()], [{String.t(), String.t()}]) ::
          {:ok, [[Task.t()]]} | {:error, :cycle, [String.t()]}
  defp kahn_levels(members, edges) do
    by_id = Map.new(members, &{&1.id, &1})

    # in_degree[id] = number of in-stack deps `id` is still waiting on.
    in_degree =
      Enum.reduce(members, %{}, fn %Task{id: id}, acc -> Map.put(acc, id, 0) end)
      |> then(fn acc ->
        Enum.reduce(edges, acc, fn {from_id, _to_id}, a ->
          Map.update(a, from_id, 1, &(&1 + 1))
        end)
      end)

    # reverse_adj[to_id] = ids that depend on `to_id`. When `to_id`
    # pops, decrement each of these.
    reverse_adj =
      Enum.reduce(edges, %{}, fn {from_id, to_id}, acc ->
        Map.update(acc, to_id, [from_id], &[from_id | &1])
      end)

    do_kahn_levels(by_id, in_degree, reverse_adj, [])
  end

  defp do_kahn_levels(by_id, in_degree, _reverse_adj, levels) when map_size(in_degree) == 0 do
    {:ok, Enum.reverse(levels) |> Enum.reject(&(&1 == [])) |> hydrate_levels(by_id)}
  end

  defp do_kahn_levels(by_id, in_degree, reverse_adj, levels) do
    {ready_ids, remaining} =
      Enum.split_with(in_degree, fn {_id, deg} -> deg == 0 end)

    case ready_ids do
      [] ->
        # Nothing has zero in-degree → cycle in the residue.
        {:error, :cycle, Enum.map(remaining, fn {id, _} -> id end)}

      _ ->
        ready_ids = Enum.map(ready_ids, fn {id, _} -> id end)
        remaining = Map.new(remaining)

        next_in_degree =
          Enum.reduce(ready_ids, remaining, fn popped_id, acc ->
            popped_id
            |> then(&Map.get(reverse_adj, &1, []))
            |> Enum.reduce(acc, fn dependent_id, a ->
              case Map.get(a, dependent_id) do
                nil -> a
                deg -> Map.put(a, dependent_id, deg - 1)
              end
            end)
          end)

        do_kahn_levels(by_id, next_in_degree, reverse_adj, [ready_ids | levels])
    end
  end

  defp hydrate_levels(levels, by_id) do
    Enum.map(levels, fn ids -> Enum.map(ids, &Map.fetch!(by_id, &1)) end)
  end

  # Best-effort cycle recovery: starting from any node still in the
  # residue, follow outgoing edges (`from → to`, i.e. the dependency
  # arrow) until we revisit a node. The walk is bounded by the residue
  # size, so a cycle must be hit before we run out of frontier — even
  # for diamond-shaped residues every dep chain bottoms out in a back
  # edge by definition (otherwise Kahn would have drained it).
  #
  # Returns the cycle as a list of `%Task{}` in dependency order.
  @spec find_cycle([String.t()], [{String.t(), String.t()}], [Task.t()]) :: [Task.t()]
  defp find_cycle([], _edges, _members), do: []

  defp find_cycle([start | _] = residue_ids, edges, members) do
    by_id = Map.new(members, &{&1.id, &1})
    residue = MapSet.new(residue_ids)

    # Restrict to edges fully inside the residue so we only walk
    # cycle-relevant arrows.
    adj =
      Enum.reduce(edges, %{}, fn {from_id, to_id}, acc ->
        if MapSet.member?(residue, from_id) and MapSet.member?(residue, to_id) do
          Map.update(acc, from_id, [to_id], &[to_id | &1])
        else
          acc
        end
      end)

    walk_cycle(start, adj, [], MapSet.new())
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  # Walks one path through the residue subgraph until it repeats a
  # node, then returns just the cycle (slice from the first occurrence
  # of the repeated node onward). If the path dead-ends (no outgoing
  # adj), returns the visited path as a best-effort.
  defp walk_cycle(node, adj, path, visited) do
    cond do
      MapSet.member?(visited, node) ->
        # Found the cycle — slice `path` from the first occurrence of
        # `node`. `path` is in reverse-walk order (head = most recent).
        ordered = Enum.reverse([node | path])
        idx = Enum.find_index(ordered, &(&1 == node))
        Enum.slice(ordered, idx..-1//1)

      true ->
        case Map.get(adj, node, []) do
          [] -> Enum.reverse([node | path])
          [next | _] -> walk_cycle(next, adj, [node | path], MapSet.put(visited, node))
        end
    end
  end

  # ── Pure helpers ─────────────────────────────────────────────────────────

  @doc """
  Build the canonical rollup-branch name for a slug.

  Mirrors the convention documented in ADR 0041 (Branch model) so callers
  do not assemble the prefix in multiple places.
  """
  @spec rollup_branch_name(String.t()) :: String.t()
  def rollup_branch_name(slug) when is_binary(slug), do: "stack/#{slug}"

  @doc """
  Validate a stack slug.

  Slugs must be lowercase alphanumeric with optional hyphens, must start
  with an alphanumeric character, and must be 60 characters or fewer.
  """
  @spec valid_slug?(any()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    String.length(slug) <= @max_slug_length and Regex.match?(@slug_regex, slug)
  end

  def valid_slug?(_), do: false
end
