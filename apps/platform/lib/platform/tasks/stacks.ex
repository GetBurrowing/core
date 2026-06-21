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

  require Logger

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{ReviewRequests, Stack, StackDeployer, Task}

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
  Look up a non-abandoned stack by its rollup-branch name.

  Used by the GitHub webhook controller (T6) to detect whether a merged
  PR's head branch corresponds to a stack rollup branch, so the
  `pr_merged` validation can be fanned out across all member tasks.
  Abandoned stacks are excluded; if a stale stack/<slug> branch survives
  in the repo, its webhook should fall through to the no-op path rather
  than re-pass member validations.

  Returns the `%Stack{}` or `nil`. `nil` for any non-binary input so
  callers don't have to pre-filter `head_branch == nil`.
  """
  @spec get_stack_by_rollup_branch(String.t() | nil) :: Stack.t() | nil
  def get_stack_by_rollup_branch(rollup_branch) when is_binary(rollup_branch) do
    Stack
    |> where([s], s.rollup_branch == ^rollup_branch and s.status != "abandoned")
    |> limit(1)
    |> Repo.one()
  end

  def get_stack_by_rollup_branch(_), do: nil

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
  Terminal transition for the rollup-PR merge path (T6 stage 2).

  Marks `stack` as `done` and records the rollup-merge summary into
  `stack.metadata["rollup_merge"]`. Existing metadata keys are
  preserved (deep merge at the top level; the `rollup_merge` subtree
  is replaced wholesale because each rollup-PR merge produces a single
  canonical summary).

  Expected `attrs` shape:

      %{
        passed_member_ids: [task_id, ...],
        anomalies: [%{"task_id" => id, "reason" => "...", "recorded_at" => iso8601}, ...],
        merge_commit_sha: sha,
        merged_at: %DateTime{} | iso8601_string
      }

  When `passed_member_ids` is empty (every member was an anomaly), the
  resulting `metadata["rollup_merge"]["degraded"]` flag is set to
  `true` and the caller is expected to emit an ERROR log alongside.
  The stack still transitions to `done` so the rollup-PR's deploy
  surface accurately reflects what happened on GitHub; the degraded
  flag signals that no member validations were actually flipped here
  and operator triage is warranted.

  Idempotency: a stack already at `done` with `metadata["rollup_merge"]`
  populated is left untouched; the function returns `{:ok, stack}`
  with the existing metadata so a replayed webhook does NOT clobber
  the original history.
  """
  @spec complete_rollup_merge(Stack.t(), %{
          optional(:passed_member_ids) => [String.t()],
          optional(:anomalies) => [map()],
          optional(:merge_commit_sha) => String.t() | nil,
          optional(:merged_at) => DateTime.t() | String.t() | nil
        }) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def complete_rollup_merge(%Stack{} = stack, attrs) when is_map(attrs) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    if stack.status == "done" and Map.has_key?(base_meta, "rollup_merge") do
      {:ok, stack}
    else
      passed = Map.get(attrs, :passed_member_ids, [])
      anomalies = Map.get(attrs, :anomalies, [])
      sha = Map.get(attrs, :merge_commit_sha)
      merged_at = format_merged_at(Map.get(attrs, :merged_at))

      rollup_merge =
        %{
          "merged_at" => merged_at,
          "merge_commit_sha" => sha,
          "members_passed" => passed,
          "anomalies" => anomalies
        }
        |> maybe_set_degraded(passed)

      new_meta = Map.put(base_meta, "rollup_merge", rollup_merge)

      stack
      |> Stack.changeset(%{status: "done", metadata: new_meta})
      |> Repo.update()
    end
  end

  defp maybe_set_degraded(rollup_merge, []), do: Map.put(rollup_merge, "degraded", true)
  defp maybe_set_degraded(rollup_merge, _passed), do: rollup_merge

  defp format_merged_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_merged_at(str) when is_binary(str), do: str
  defp format_merged_at(_), do: nil

  @doc """
  Status cascade for `stack_start`: transition a `forming` stack to
  `in_progress` and fan its members out per ADR 0041 §"Status cascade —
  entering a stack".

  Behavior:

    * Stack must be at `forming` to start — any other status returns
      `{:error, :invalid_stack_status}`.
    * Compute `executable_members/1` (level-0 roots in the in-stack DAG).
    * Transition every root currently at `backlog` to `in_progress` via
      `Tasks.transition_task/2`. Roots already past `backlog` are left
      alone — the cascade is additive, not destructive.
    * Transition every non-root member currently at `backlog` to
      `stack_pending` via `Tasks.transition_task/2`. Same backlog-only
      filter so we never overwrite committed work.
    * Flip the stack-level status from `forming` to `in_progress`.

  Returns `{:ok, %{stack: stack, started: roots, parked: pending}}` on
  success. Per-member transition failures (e.g. a root with no
  approved plan) are surfaced in the returned shape as
  `{:partial, %{stack: stack, started: ok_roots, parked: ok_pending,
  errors: errors}}` so the caller can choose to halt-and-fix or
  proceed.
  """
  @spec start_stack(Stack.t() | binary()) ::
          {:ok, %{stack: Stack.t(), started: [Task.t()], parked: [Task.t()]}}
          | {:partial,
             %{
               stack: Stack.t(),
               started: [Task.t()],
               parked: [Task.t()],
               errors: [%{task_id: String.t(), target_status: String.t(), reason: term()}]
             }}
          | {:error, :invalid_stack_status | :stack_not_found | term()}
  def start_stack(%Stack{status: status}) when status != "forming",
    do: {:error, :invalid_stack_status}

  def start_stack(%Stack{} = stack) do
    members = members(stack)
    roots = executable_members(stack)
    root_ids = MapSet.new(roots, & &1.id)

    {started, root_errors} =
      Enum.reduce(roots, {[], []}, fn member, {ok, errors} ->
        cascade_member(member, "in_progress", ok, errors)
      end)

    non_roots = Enum.reject(members, &MapSet.member?(root_ids, &1.id))

    {parked, pending_errors} =
      Enum.reduce(non_roots, {[], []}, fn member, {ok, errors} ->
        cascade_member(member, "stack_pending", ok, errors)
      end)

    case Stack.changeset(stack, %{status: "in_progress"}) |> Repo.update() do
      {:ok, updated} ->
        # Stage 1 of T5: kick off rollup-branch creation as soon as the
        # stack flips into `in_progress`. The deployer runs async so
        # the cascade returns quickly, and any failure is logged via
        # `Logger.warning` rather than crashing the cascade. We invoke
        # via Stacks for testability — handle_stack_transition is the
        # public seam and is itself a no-op when `from`/`to` don't
        # match.
        _ = StackDeployer.handle_stack_transition(updated, :forming, :in_progress)

        result = %{
          stack: updated,
          started: Enum.reverse(started),
          parked: Enum.reverse(parked)
        }

        case root_errors ++ pending_errors do
          [] -> {:ok, result}
          errors -> {:partial, Map.put(result, :errors, Enum.reverse(errors))}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def start_stack(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> start_stack(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  # Only members at `backlog` are dragged forward by the cascade — anything
  # already past backlog is treated as committed work that the operator
  # explicitly advanced, and we don't overwrite it.
  defp cascade_member(%Task{status: "backlog"} = member, target, ok, errors) do
    case Tasks.transition_task(member, target) do
      {:ok, updated} ->
        {[updated | ok], errors}

      {:error, reason} ->
        {ok, [%{task_id: member.id, target_status: target, reason: reason} | errors]}
    end
  end

  defp cascade_member(_member, _target, ok, errors), do: {ok, errors}

  @doc """
  Stack-level "Start Planning": fan the planning lifecycle action out to
  every constituent member.

  Mirrors `start_stack/1`'s cascade machinery, but as a backlog-only
  fan-out into `planning`:

    * Loads `members/1` and, for every member currently at `backlog`,
      transitions it `backlog -> planning` via `Tasks.transition_task/2`
      using the same `cascade_member/4` reducer. Members already past
      `backlog` (`planning`, `stack_pending`, `in_progress`, …) are left
      untouched — never illegally re-transitioned.
    * Does NOT itself write the stack status: `Tasks.transition_task/2`
      already runs `maybe_recompute_stack/1`, and a stack of all-`planning`
      members correctly rolls up to `forming` per `rollup_status_for/1`.

  Returns `{:ok, %{stack: stack, planning: [Task.t()]}}` on full success
  (an empty stack returns `planning: []`), `{:partial, %{stack: stack,
  planning: [...], errors: [...]}}` when some members fail to transition,
  and `{:error, :stack_not_found}` for an unknown id.
  """
  @spec start_planning(Stack.t() | binary()) ::
          {:ok, %{stack: Stack.t(), planning: [Task.t()]}}
          | {:partial,
             %{
               stack: Stack.t(),
               planning: [Task.t()],
               errors: [%{task_id: String.t(), target_status: String.t(), reason: term()}]
             }}
          | {:error, :stack_not_found | term()}
  def start_planning(%Stack{} = stack) do
    members = members(stack)

    {planning, errors} =
      Enum.reduce(members, {[], []}, fn member, {ok, errs} ->
        cascade_member(member, "planning", ok, errs)
      end)

    result = %{stack: stack, planning: Enum.reverse(planning)}

    case errors do
      [] -> {:ok, result}
      errs -> {:partial, Map.put(result, :errors, Enum.reverse(errs))}
    end
  end

  def start_planning(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> start_planning(stack)
      nil -> {:error, :stack_not_found}
    end
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

  @doc """
  Terminal transition: mark a stack `done`.

  Only allowed when every member task is already `done`. The natural close
  for a stack whose work has fully shipped — including the manual-ship lane
  where members merged via individual PRs rather than the rollup branch,
  which `recompute_stack_status/1` doesn't recognize as completion.

  Returns `{:error, :members_not_done, %{pending: [%{id, title, status}]}}`
  when any member is still in flight. Returns `{:error, changeset}` on a
  schema-level write failure. Returns `{:ok, stack}` on success.
  """
  @spec complete_stack(Stack.t(), String.t() | nil) ::
          {:ok, Stack.t()}
          | {:error, :members_not_done, %{pending: [map()]}}
          | {:error, Ecto.Changeset.t()}
  def complete_stack(%Stack{} = stack, note \\ nil) do
    case pending_members(stack.id) do
      [] ->
        attrs = %{status: "done", description: complete_description(stack, note)}

        stack
        |> Stack.changeset(attrs)
        |> Repo.update()

      [_ | _] = pending ->
        {:error, :members_not_done, %{pending: pending}}
    end
  end

  defp pending_members(stack_id) do
    Task
    |> where([t], t.stack_id == ^stack_id and t.status != "done")
    |> select([t], %{id: t.id, title: t.title, status: t.status})
    |> Repo.all()
  end

  defp complete_description(%Stack{description: existing}, nil), do: existing

  defp complete_description(%Stack{description: nil}, note) when is_binary(note),
    do: "Completed: #{note}"

  defp complete_description(%Stack{description: existing}, note) when is_binary(note),
    do: "#{existing}\n\nCompleted: #{note}"

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

  ## Stack-level assignment inheritance (ADR 0041)

  If the stack has a stack-level `phase_assignees` map AND the joining
  task is NOT individually overridden (`task.metadata["assignee_override"]`
  is not `true`), the stack default is applied to the new member via
  `Platform.Tasks.set_phase_assignees/2` inside this transaction (after
  the `stack_id` write, before `recompute_stack_status/1`). A task that
  carries its own `assignee_override` flag keeps its own assignment.
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
             {:ok, attached_task} <-
               Tasks.update_task(task, %{stack_id: stack.id, stack_position: position}),
             {:ok, updated_task} <- maybe_inherit_stack_assignees(stack, attached_task),
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
        # `eject_task` predates the 3-tuple `:not_in_stack` shape and its
        # callers (incl. existing tests + the `stack_eject` MCP envelope at
        # tool_surface.ex:2776) match on the bare 2-tuple. Collapse here so
        # the new shape stays scoped to the dependency-edge surfaces.
        {:error, :not_in_stack, _task_id} -> Repo.rollback(:not_in_stack)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Add an in-stack dependency edge from `from_task_id` to `to_task_id`.

  Mirrors the `add_task/2` shape: loads the stack and both endpoint tasks
  fresh inside a `Repo.transaction`, runs membership/self guards
  up-front, delegates to `Platform.Tasks.add_dependency/3` (stage 1 of
  this skill) for the JSONB read-modify-write, then runs
  `validate_dag/1` against the now-augmented edge set so multi-hop
  cycles get caught and the dep write is rolled back atomically when
  they're found.

  `opts` accepts `:kind` (default `"blocks"`).

  ## Up-front guards

    * `{:error, :stack_not_found}` — the stack id has no row
    * `{:error, :task_not_found}` — either endpoint id has no row
    * `{:error, :self_edge}` — `from_task_id == to_task_id`
    * `{:error, :not_in_stack, offending_task_id}` — one endpoint's
      `stack_id` does not match the supplied stack id (covers both "not
      in any stack" and "member of a different stack" — `validate_dag/1`
      would also flag cross-stack deps, but the explicit membership
      check is a cleaner up-front signal for an explicitly stack-scoped
      tool). The id of the offending endpoint is threaded out so MCP
      callers can render it in error envelopes without a follow-up
      lookup.

  ## Errors bubbled from stage 1 unchanged

    * `{:error, :duplicate_edge}` — the same `(to_task_id, kind)` pair
      already exists on `from_task`
    * `{:error, :self_edge}` — same condition as the up-front guard,
      defensively repeated by `Tasks.add_dependency/3`

  ## Errors from DAG validation (transaction rolled back)

    * `{:error, :cycle, path}` — the new edge introduces a cycle in the
      in-stack subgraph; the dep write is undone before returning.

  Returns `{:ok, %{from_task_id, to_task_id, kind, executable_now}}` on
  success, where `executable_now` is the recomputed
  `executable_members/1` id list so callers don't need a follow-up
  `stack_get` to see the new ready set.
  """
  @spec add_dependency_edge(Stack.t() | binary(), binary(), binary(), keyword()) ::
          {:ok,
           %{
             from_task_id: binary(),
             to_task_id: binary(),
             kind: String.t(),
             executable_now: [binary()]
           }}
          | {:error, :stack_not_found | :task_not_found | :self_edge}
          | {:error, :not_in_stack, binary()}
          | {:error, :duplicate_edge}
          | {:error, :cycle, [Task.t()]}
          | {:error, term()}
  def add_dependency_edge(stack_or_id, from_task_id, to_task_id, opts \\ [])
      when is_binary(from_task_id) and is_binary(to_task_id) do
    kind = Keyword.get(opts, :kind, "blocks")

    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             :ok <- ensure_distinct_endpoints(from_task_id, to_task_id),
             {:ok, %Task{} = from_task} <- load_task(from_task_id),
             {:ok, %Task{} = to_task} <- load_task(to_task_id),
             :ok <- ensure_in_stack(stack, from_task),
             :ok <- ensure_in_stack(stack, to_task),
             {:ok, _updated_from} <- Tasks.add_dependency(from_task, to_task_id, kind),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          %{
            from_task_id: from_task_id,
            to_task_id: to_task_id,
            kind: kind,
            executable_now: stack |> executable_members() |> Enum.map(& &1.id)
          }
        else
          {:error, :not_in_stack, task_id} -> Repo.rollback({:not_in_stack, task_id})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case txn do
      {:error, {:cycle, path}} -> {:error, :cycle, path}
      {:error, {:cross_stack_dep, payload}} -> {:error, :cross_stack_dep, payload}
      {:error, {:not_in_stack, task_id}} -> {:error, :not_in_stack, task_id}
      other -> other
    end
  end

  @doc """
  Remove an in-stack dependency edge from `from_task_id` to `to_task_id`.

  Mirrors `add_dependency_edge/4` — same membership/self guards,
  delegates to `Platform.Tasks.remove_dependency/3` for the JSONB
  read-modify-write, and runs `validate_dag/1` defensively (removal
  cannot create a cycle, but the cheap re-validation keeps the
  recomputed-status path identical to the add side).

  `opts` accepts `:kind` (default `"blocks"`).

  Returns `{:error, :not_an_edge}` when no `(to_task_id, kind)` entry
  exists on `from_task` (so callers can disambiguate an idempotent
  re-remove from a successful one). All other guards match the add
  side.

  Returns `{:ok, %{from_task_id, to_task_id, kind, executable_now}}` on
  success.
  """
  @spec remove_dependency_edge(Stack.t() | binary(), binary(), binary(), keyword()) ::
          {:ok,
           %{
             from_task_id: binary(),
             to_task_id: binary(),
             kind: String.t(),
             executable_now: [binary()]
           }}
          | {:error, :stack_not_found | :task_not_found | :self_edge}
          | {:error, :not_in_stack, binary()}
          | {:error, :not_an_edge}
          | {:error, term()}
  def remove_dependency_edge(stack_or_id, from_task_id, to_task_id, opts \\ [])
      when is_binary(from_task_id) and is_binary(to_task_id) do
    kind = Keyword.get(opts, :kind, "blocks")

    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             :ok <- ensure_distinct_endpoints(from_task_id, to_task_id),
             {:ok, %Task{} = from_task} <- load_task(from_task_id),
             {:ok, %Task{} = to_task} <- load_task(to_task_id),
             :ok <- ensure_in_stack(stack, from_task),
             :ok <- ensure_in_stack(stack, to_task),
             {:ok, _updated_from} <- Tasks.remove_dependency(from_task, to_task_id, kind),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          %{
            from_task_id: from_task_id,
            to_task_id: to_task_id,
            kind: kind,
            executable_now: stack |> executable_members() |> Enum.map(& &1.id)
          }
        else
          {:error, :not_in_stack, task_id} -> Repo.rollback({:not_in_stack, task_id})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case txn do
      {:error, {:cycle, path}} -> {:error, :cycle, path}
      {:error, {:cross_stack_dep, payload}} -> {:error, :cross_stack_dep, payload}
      {:error, {:not_in_stack, task_id}} -> {:error, :not_in_stack, task_id}
      other -> other
    end
  end

  defp ensure_distinct_endpoints(id, id) when is_binary(id), do: {:error, :self_edge}
  defp ensure_distinct_endpoints(_from, _to), do: :ok

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

  @doc """
  List all open (pending) review requests across every member of a stack.

  Composes over `members/1` and reuses
  `Platform.Tasks.ReviewRequests.list_pending_for_task/1` so the per-task
  scoping rules (status `"pending"`, items preloaded) stay in one place.
  Resolved requests and tasks not in the stack are excluded by
  construction.

  Returns a flat list of `%ReviewRequest{}` structs ordered by
  `inserted_at` descending (newest first), matching the per-task ordering
  from `list_pending_for_task/1`.
  """
  @spec list_open_review_requests(Stack.t() | binary()) :: [
          Platform.Tasks.ReviewRequest.t()
        ]
  def list_open_review_requests(%Stack{id: stack_id}),
    do: list_open_review_requests(stack_id)

  def list_open_review_requests(stack_id) when is_binary(stack_id) do
    stack_id
    |> members()
    |> Enum.flat_map(&ReviewRequests.list_pending_for_task(&1.id))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Count open (pending) review requests across every member of a stack.

  Convenience wrapper around `list_open_review_requests/1` for callers
  (e.g. the stack-detail chrome pill) that only need a number.
  """
  @spec count_pending_reviews(Stack.t() | binary()) :: non_neg_integer()
  def count_pending_reviews(stack), do: length(list_open_review_requests(stack))

  @doc """
  List stacks with the precomputed board-card display data the kanban view
  needs to render a collapsed stack card and its inline expansion (ADR 0041
  §"UI surface — Board view"; T7 stage 1).

  Returns a list of `{%Stack{}, board_data}` tuples ordered by
  `updated_at` descending. `board_data` is a map with:

    * `:members` — list of member task structs ordered by `stack_position`
      ascending. Each member is a regular `%Task{}` (no extra preloads;
      the existing detail-panel flow handles deep loads).
    * `:member_count` — `length(members)`.
    * `:dep_edge_count` — count of dependency edges among members
      restricted to the in-stack subgraph (deps from a member pointing
      at another member of the same stack). Self-edges are dropped
      defensively.
    * `:ready_count` — members whose status is in `~w(in_review
      deploying done)`, matching ADR 0041's "ready" threshold for the
      `3/4 ready` rollup-progress text.

  Filters mirror `list_stacks/1` (`:project_id`, `:status`). Excluded
  statuses (`abandoned`) are NOT filtered here — callers may want to
  show abandoned stacks for audit; the tasks-live board passes through
  the same project filter the task list uses and accepts whatever
  statuses the backing data carries.

  Implementation note: two-query fetch (stacks, then all member tasks
  for those stacks) followed by an in-memory group_by. The kanban
  board typically renders single-digit stack counts per project, so
  N+1 over `members/1` would also be acceptable, but the two-query
  form keeps the page-load cost flat as project size grows.
  """
  @spec list_stacks_with_members(map() | keyword()) :: [{Stack.t(), map()}]
  def list_stacks_with_members(filters \\ %{})

  def list_stacks_with_members(filters) when is_list(filters) do
    list_stacks_with_members(Map.new(filters))
  end

  def list_stacks_with_members(filters) when is_map(filters) do
    stacks =
      Stack
      |> filter_by_project(Map.get(filters, :project_id))
      |> filter_by_status(Map.get(filters, :status))
      |> order_by([s], desc: s.updated_at)
      |> Repo.all()

    case stacks do
      [] ->
        []

      stacks ->
        stack_ids = Enum.map(stacks, & &1.id)

        # `:plans` preload is required by Tasks.needs_human_action_reason/2's
        # `:plan_pending_review` branch (task 019e2c25 stage 4 — mobile
        # stack-member badge). Members are otherwise rendered against the
        # board's `@review_counts` map, but the plan-pending-review check
        # reads `task.plans` directly (predicate returns false when not
        # preloaded rather than triggering a lazy query). Adding the
        # preload here keeps the board view (only caller) consistent with
        # the desktop stack-detail panel, which already preloads `:plans`
        # via `load_stack_member_panel_data/1` in TasksLive.
        members_by_stack =
          Task
          |> where([t], t.stack_id in ^stack_ids and is_nil(t.deleted_at))
          |> order_by([t], asc: t.stack_position)
          |> preload(:plans)
          |> Repo.all()
          |> Enum.group_by(& &1.stack_id)

        Enum.map(stacks, fn stack ->
          members = Map.get(members_by_stack, stack.id, [])
          {stack, build_board_data(members)}
        end)
    end
  end

  # Public-ish (private) helper exposed for tests that want to build the
  # board-data map from a hand-seeded member list without touching the DB.
  @doc false
  def build_board_data(members) when is_list(members) do
    member_ids_set = MapSet.new(members, & &1.id)

    dep_edge_count =
      Enum.reduce(members, 0, fn %Task{id: from_id} = m, acc ->
        in_stack_deps =
          m
          |> Tasks.dependency_task_ids()
          |> Enum.reject(&(&1 == from_id))
          |> Enum.filter(&MapSet.member?(member_ids_set, &1))
          |> Enum.uniq()

        acc + length(in_stack_deps)
      end)

    ready_count = Enum.count(members, &(&1.status in ~w(in_review deploying done)))

    %{
      members: members,
      member_count: length(members),
      dep_edge_count: dep_edge_count,
      ready_count: ready_count
    }
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

    result =
      if new_status == stack.status do
        {:ok, stack}
      else
        stack
        |> Stack.changeset(%{status: new_status})
        |> Repo.update()
      end

    # Piggy-back: any state change that re-rolls up the stack should also
    # re-attempt the rollup PR open. The deployer's `maybe_open_stack_pr/1`
    # is idempotent — it noops when the rollup PR is already open or when
    # not all members are ready — so calling it on every recompute is safe.
    # Failures here are logged but never propagated; the recompute return
    # value is the source of truth for callers.
    case result do
      {:ok, %Stack{} = updated} -> trigger_pr_open(updated)
      _ -> :ok
    end

    result
  end

  def recompute_stack_status(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> recompute_stack_status(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  # Wrap `StackDeployer.maybe_open_stack_pr/1` so a deployer crash or
  # `{:error, _}` return is logged but never propagates back into the
  # recompute return value. The deployer's gate is internally idempotent
  # (`:already_open` / `:not_ready`), so re-firing on every recompute is
  # safe.
  defp trigger_pr_open(%Stack{} = stack) do
    try do
      case StackDeployer.maybe_open_stack_pr(stack) do
        {:ok, _outcome} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Stacks] recompute_stack_status piggy-back: maybe_open_stack_pr " <>
              "failed for stack #{stack.id}: #{inspect(reason)}"
          )

          :ok
      end
    rescue
      e ->
        Logger.warning(
          "[Stacks] recompute_stack_status piggy-back: maybe_open_stack_pr " <>
            "raised for stack #{stack.id}: #{Exception.message(e)}"
        )

        :ok
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
  Return the stack members flattened into the order they should be merged
  into the rollup branch — foundational members first.

  On success this is `validate_dag/1`'s level structure flattened in level
  order (level 0 roots, then level 1, …), i.e. a topological ordering of the
  in-stack DAG. Members WITHIN a level are independent (parallel), so we
  sort each level by `stack_position` for a deterministic, creation-ordered
  tiebreak. A stack with members but ZERO declared edges collapses to a
  single level, so the result is exactly `stack_position` (creation) order.

  Fallback semantics: when the DAG is invalid (a dependency cycle or a
  cross-stack edge), `validate_dag/1` returns `{:error, ...}`; we fall back
  to `members/1`, which orders by `stack_position` (creation) order, so this
  function never crashes on a cyclic stack.
  """
  @spec members_in_merge_order(Stack.t() | binary()) :: [Task.t()]
  def members_in_merge_order(stack_or_id) do
    case validate_dag(stack_or_id) do
      {:ok, levels} ->
        Enum.flat_map(levels, fn level ->
          Enum.sort_by(level, & &1.stack_position)
        end)

      {:error, _reason, _detail} ->
        members(stack_or_id)
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

  This function is the dispatch gate's contract: the dispatcher
  (`Platform.Orchestration.TaskRouterWatcher`) intentionally excludes
  `stack_pending` from its active-status set so a `stack_pending` task
  is invisible to dispatch. `unblocked_in_stack?/1` answers the
  separate question of whether the task is ready to be promoted out of
  `stack_pending` and become visible to the dispatcher — see
  `try_promote/1` below.
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
  Promote a `stack_pending` member to `in_progress` iff its in-stack deps
  have all cleared the ADR 0041 §"Unblock threshold".

  Behavior:

    * Task is not in any stack (`stack_id` nil) → `:noop`.
    * Task is in a stack but not at `stack_pending` → `:noop`.
    * Task is at `stack_pending` and deps NOT cleared → `:noop`.
    * Task is at `stack_pending` and deps cleared → transitions
      `stack_pending` → `in_progress` via `Tasks.transition_task/2`. That
      call emits the standard `{:task_updated, task}` board broadcast which
      `TaskRouterWatcher` already consumes, so the dispatcher picks the
      promoted task up on the next event.

  Returns `{:ok, task}` on a successful transition, `:noop` for any
  case that should leave the task untouched, or `{:error, reason}` if
  the transition itself fails.
  """
  @spec try_promote(Task.t() | binary()) ::
          {:ok, Task.t()} | :noop | {:error, term()}
  def try_promote(%Task{stack_id: nil}), do: :noop

  def try_promote(%Task{status: "stack_pending"} = task) do
    if unblocked_in_stack?(task) do
      case Tasks.transition_task(task, "in_progress") do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    else
      :noop
    end
  end

  def try_promote(%Task{}), do: :noop

  def try_promote(task_id) when is_binary(task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> try_promote(task)
      nil -> {:error, :task_not_found}
    end
  end

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

  @doc """
  Stack-internal dependent sweep — the second of the two unblock paths
  in the engine.

  Keyed on a stack member's `metadata["merged_into_rollup_at"]` being
  newly set (typically by the deployer when a member's branch is merged
  into the stack rollup branch). Finds every other stack member whose
  status is `stack_pending` and whose dependency list includes the
  just-merged task, then promotes any whose in-stack deps have now all
  cleared the unblock threshold via `try_promote/1`.

  Partition with the existing cross-stack sweep (`tasks.ex` ~L1031,
  `sweep_unblocked_dependents/1`): that sweep matches `status==blocked`
  and uses the `done`-threshold; this sweep matches `status==stack_pending`
  and uses the rollup-merge threshold. They do NOT overlap — distinct
  source-task statuses, distinct candidate-task statuses, distinct
  thresholds.

  Returns `{:ok, promoted}` where `promoted` is the list of `{:ok, task}`
  results from successful promotions (failures are dropped, mirroring
  the existing sweep's permissive behavior). A non-stack-member task or
  a stack member without `merged_into_rollup_at` set is a no-op
  returning `{:ok, []}`.
  """
  @spec sweep_stack_dependents(Task.t()) :: {:ok, [Task.t()]}
  def sweep_stack_dependents(%Task{stack_id: nil}), do: {:ok, []}

  def sweep_stack_dependents(%Task{metadata: metadata}) when not is_map(metadata),
    do: {:ok, []}

  def sweep_stack_dependents(%Task{stack_id: stack_id, metadata: metadata} = task)
      when is_binary(stack_id) do
    if is_nil(Map.get(metadata, "merged_into_rollup_at")) do
      {:ok, []}
    else
      promoted =
        stack_id
        |> unblocked_after(task)
        |> Enum.reduce([], fn member, acc ->
          case try_promote(member) do
            {:ok, updated} -> [updated | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, promoted}
    end
  end

  # ── Regression handling (ADR 0041 §"Status divergence handling") ─────────

  # Ordering for regression detection only — higher index == "further
  # along the lifecycle". `stack_pending`/`blocked`/`backlog`/`planning`
  # are intentionally treated as the same conceptual rung; the only
  # comparison that matters is whether the new rung is strictly LOWER
  # than the old rung among the execution-phase statuses.
  @status_progression %{
    "backlog" => 0,
    "planning" => 0,
    "blocked" => 0,
    "stack_pending" => 0,
    "in_progress" => 1,
    "in_review" => 2,
    "deploying" => 3,
    "done" => 4
  }

  @doc """
  Detect whether `prev_status -> new_status` is a regression in the
  ADR 0041 lifecycle order (a backward step among the execution-phase
  rungs).

  Returns `true` for transitions like `in_review -> in_progress`,
  `deploying -> in_review`, `in_progress -> stack_pending`. Returns
  `false` for forward transitions or no-ops.
  """
  @spec regression?(String.t(), String.t()) :: boolean()
  def regression?(prev, new) when is_binary(prev) and is_binary(new) do
    Map.get(@status_progression, new, 0) < Map.get(@status_progression, prev, 0)
  end

  @doc """
  Handle a stack member regressing (status moving backward).

  Per ADR 0041 §"Status divergence handling":

    1. Recompute the stack rollup status. (No-op here — already wired
       into `Tasks.maybe_finalize_transition/3`'s tail via
       `maybe_recompute_stack/1`, so we don't double-recompute.)
    2. For every downstream member (another stack member listing this
       task in its dependencies) currently at `in_progress`:
       - If the downstream has NOT committed work (heuristic: no plan
         stage has reached `status: "passed"`) AND its unblock
         threshold is no longer met → revert it to `stack_pending` via
         `Tasks.transition_task/2`.
       - Otherwise leave its status alone and stamp
         `metadata["stack_dep_regressed_at"]` with the current
         timestamp so the UI / operator can see that an upstream dep
         regressed.

  Cross-stack regressions are silenced: a task without a `stack_id`
  short-circuits with `:ok` (the existing done-threshold sweep is the
  cross-stack path and is NOT modified by this handler).

  Returns `{:ok, %{reverted: [Task.t()], flagged: [Task.t()]}}` on
  success.
  """
  @spec handle_member_regression(Task.t(), String.t()) ::
          :ok | {:ok, %{reverted: [Task.t()], flagged: [Task.t()]}}
  def handle_member_regression(%Task{stack_id: nil}, _prev_status), do: :ok

  def handle_member_regression(%Task{stack_id: stack_id} = task, _prev_status)
      when is_binary(stack_id) do
    members = members(stack_id)
    member_ids = MapSet.new(members, & &1.id)

    downstream =
      members
      |> Enum.reject(&(&1.id == task.id))
      |> Enum.filter(fn member ->
        task.id in (member
                    |> Tasks.dependency_task_ids()
                    |> Enum.filter(&MapSet.member?(member_ids, &1)))
      end)

    Enum.reduce(downstream, {[], []}, fn member, {reverted, flagged} ->
      cond do
        member.status != "in_progress" ->
          {reverted, flagged}

        unblocked_in_stack?(member) ->
          # Threshold still met — no need to revert. Don't flag either,
          # since nothing was actually invalidated.
          {reverted, flagged}

        committed_work?(member) ->
          # Threshold no longer met but work exists — record the regression
          # marker without disrupting the in-flight task.
          case mark_dep_regressed(member) do
            {:ok, updated} -> {reverted, [updated | flagged]}
            _ -> {reverted, flagged}
          end

        true ->
          case Tasks.transition_task(member, "stack_pending") do
            {:ok, updated} -> {[updated | reverted], flagged}
            _ -> {reverted, flagged}
          end
      end
    end)
    |> then(fn {reverted, flagged} ->
      {:ok, %{reverted: Enum.reverse(reverted), flagged: Enum.reverse(flagged)}}
    end)
  end

  # "Committed work" heuristic: any stage on any plan for this task has
  # reached `status: "passed"` (the engine's stage_complete signal).
  defp committed_work?(%Task{id: task_id}) do
    Repo.exists?(
      from(s in Platform.Tasks.Stage,
        join: p in Platform.Tasks.Plan,
        on: s.plan_id == p.id,
        where: p.task_id == ^task_id and s.status == "passed"
      )
    )
  end

  defp mark_dep_regressed(%Task{} = member) do
    metadata = member.metadata || %{}
    stamp = DateTime.utc_now() |> DateTime.to_iso8601()
    merged = Map.put(metadata, "stack_dep_regressed_at", stamp)
    Tasks.update_task(member, %{metadata: merged})
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
  defp ensure_in_stack(_stack, %Task{id: task_id}), do: {:error, :not_in_stack, task_id}
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
  Return the normalized stack-level `phase_assignees` map from a stack's
  metadata (ADR 0041 stack-level agent assignment).

  Mirrors `Platform.Tasks.Task.validate_phase_assignees/1`: unknown phase
  keys are dropped, and malformed per-phase entries (anything that is not
  a map with at least an `"assignee_id"`) are dropped. Defaults to `%{}`
  for a stack with no metadata, non-map metadata, or no `"phase_assignees"`
  key. The `@phases` list is reused from `Platform.Tasks.Task` rather than
  redefined here.

  Returned shape: `%{phase => %{"assignee_id" => uuid, "assignee_type" => type}}`.
  """
  @spec stack_phase_assignees(Stack.t() | map() | nil) :: map()
  def stack_phase_assignees(%Stack{metadata: metadata}), do: stack_phase_assignees(metadata)

  def stack_phase_assignees(metadata) when is_map(metadata) do
    case Map.get(metadata, "phase_assignees") do
      pa when is_map(pa) ->
        pa
        |> Map.take(Task.phases())
        |> Enum.flat_map(fn {phase, entry} ->
          case normalize_phase_entry(entry) do
            nil -> []
            normalized -> [{phase, normalized}]
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  def stack_phase_assignees(_), do: %{}

  # A valid per-phase entry is a map carrying a non-nil `"assignee_id"`.
  # `"assignee_type"` defaults to `"agent"` (matching `Tasks.assignee_for_phase/2`).
  defp normalize_phase_entry(%{"assignee_id" => nil}), do: nil

  defp normalize_phase_entry(%{"assignee_id" => id} = entry) when is_binary(id) do
    %{"assignee_id" => id, "assignee_type" => Map.get(entry, "assignee_type") || "agent"}
  end

  defp normalize_phase_entry(_), do: nil

  @doc """
  Return `{assignee_id, assignee_type}` for the stack-level default in the
  given phase, or `{nil, nil}` if no stack-level assignee is configured for
  that phase.

  Mirrors `Platform.Tasks.assignee_for_phase/2`, but reads from the stack's
  `metadata["phase_assignees"]` (via `stack_phase_assignees/1`) instead of a
  task's `phase_assignees`.
  """
  @spec stack_assignee_for_phase(Stack.t() | map() | nil, String.t()) ::
          {String.t() | nil, String.t() | nil}
  def stack_assignee_for_phase(stack_or_metadata, phase) when is_binary(phase) do
    case stack_phase_assignees(stack_or_metadata) |> Map.get(phase) do
      %{"assignee_id" => id, "assignee_type" => type} -> {id, type}
      _ -> {nil, nil}
    end
  end

  # ── Stack-level agent assignment (ADR 0041) ──────────────────────────────

  @doc """
  Set the stack-level `phase_assignees` default and percolate it to every
  member that is not individually overridden.

  `attrs_by_phase` is a map keyed by phase (`"planning"` | `"execution"` |
  `"review"`) with values `%{"assignee_id" => id, "assignee_type" => type}`,
  identical to the shape `Platform.Tasks.set_phase_assignees/2` accepts.

  In a single `Repo.transaction`:

    1. The normalized map is merged into `stack.metadata["phase_assignees"]`
       and persisted via `update_stack/2`. Other metadata keys are
       preserved; the `phase_assignees` subtree is merged phase-by-phase so
       a partial update (e.g. only `"execution"`) leaves the other phases
       intact.
    2. For every member returned by `members/1` whose
       `metadata["assignee_override"]` is NOT `true`, the merged
       stack-level map is applied via `Platform.Tasks.set_phase_assignees/2`.
       That reuses the existing changeset + `maybe_apply_phase_assignee`
       re-derivation + board broadcast, so the task router and every read
       path see the new current-phase assignee.

  Members flagged `assignee_override` are skipped entirely — a stack-level
  reassignment must never clobber an individually-assigned member.

  Returns `{:ok, %{stack: stack, percolated: [task], skipped: [task]}}` on
  success, where `percolated` are the members that received the new
  default and `skipped` are the overridden members left untouched.
  """
  @spec set_stack_phase_assignees(Stack.t() | binary(), map()) ::
          {:ok, %{stack: Stack.t(), percolated: [Task.t()], skipped: [Task.t()]}}
          | {:error, :stack_not_found | term()}
  def set_stack_phase_assignees(stack_or_id, attrs_by_phase) when is_map(attrs_by_phase) do
    Repo.transaction(fn ->
      with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
           merged_map = merge_stack_phase_assignees(stack, attrs_by_phase),
           new_metadata = Map.put(stack.metadata || %{}, "phase_assignees", merged_map),
           {:ok, updated_stack} <- update_stack(stack, %{metadata: new_metadata}) do
        {percolated, skipped} =
          updated_stack
          |> members()
          |> Enum.split_with(&(not member_overridden?(&1)))

        percolated_tasks =
          Enum.map(percolated, fn member ->
            case Tasks.set_phase_assignees(member, merged_map) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        %{stack: updated_stack, percolated: percolated_tasks, skipped: skipped}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Return the current stack-level `phase_assignees` default merged with a
  partial `attrs_by_phase` update.

  The merge is phase-by-phase: phases present in `attrs_by_phase` replace
  the stored phase entry; phases absent from `attrs_by_phase` are carried
  through from the existing stack-level map. The result is normalized via
  `stack_phase_assignees/1` semantics (unknown keys / malformed entries
  dropped) so the persisted map is always well-formed.
  """
  @spec merge_stack_phase_assignees(Stack.t() | map() | nil, map()) :: map()
  def merge_stack_phase_assignees(stack_or_metadata, attrs_by_phase)
      when is_map(attrs_by_phase) do
    current = stack_phase_assignees(stack_or_metadata)

    incoming =
      attrs_by_phase
      |> Map.new(fn {phase, entry} -> {to_string(phase), entry} end)
      |> Map.take(Task.phases())
      |> Enum.flat_map(fn {phase, entry} ->
        case normalize_phase_entry(entry) do
          nil -> [{phase, :clear}]
          normalized -> [{phase, normalized}]
        end
      end)
      |> Map.new()

    Enum.reduce(incoming, current, fn
      {phase, :clear}, acc -> Map.delete(acc, phase)
      {phase, entry}, acc -> Map.put(acc, phase, entry)
    end)
  end

  @doc """
  Whether a stack member is individually overridden — i.e. its
  `metadata["assignee_override"]` is `true`.

  An overridden member is excluded from stack-level fan-out: its assignment
  was set by hand and stack-level reassignment must not touch it.
  """
  @spec member_overridden?(Task.t() | map() | nil) :: boolean()
  def member_overridden?(%Task{metadata: metadata}), do: member_overridden?(metadata)

  def member_overridden?(metadata) when is_map(metadata),
    do: Map.get(metadata, "assignee_override") == true

  def member_overridden?(_), do: false

  @doc """
  Clear a member's individual override and return it to inheriting the
  stack-level default.

  Unsets `task.metadata["assignee_override"]` and, if the member's stack
  has a stack-level `phase_assignees` map, re-applies that default via
  `Platform.Tasks.set_phase_assignees/2`. Runs in a single transaction.

  Returns `{:ok, task}` (the re-inheriting member), `{:error, :not_in_stack}`
  for a task with no `stack_id`, `{:error, :task_not_found}` /
  `{:error, :stack_not_found}` for missing rows, or `{:error, reason}` if a
  write fails.
  """
  @spec clear_member_override(Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error, :not_in_stack | :task_not_found | :stack_not_found | term()}
  def clear_member_override(task_or_id) do
    Repo.transaction(fn ->
      with {:ok, %Task{} = task} <- load_task(task_or_id),
           :ok <- ensure_has_stack(task),
           {:ok, %Stack{} = stack} <- load_stack(task.stack_id),
           cleared_metadata = Map.delete(task.metadata || %{}, "assignee_override"),
           {:ok, cleared_task} <- Tasks.update_task(task, %{metadata: cleared_metadata}) do
        stack_map = stack_phase_assignees(stack)

        if stack_map == %{} do
          cleared_task
        else
          case Tasks.set_phase_assignees(cleared_task, stack_map) do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Apply the stack-level default to a freshly-attached member, unless the
  # member is individually overridden or the stack has no stack-level map.
  # Used inside `add_task/2`'s transaction.
  defp maybe_inherit_stack_assignees(%Stack{} = stack, %Task{} = task) do
    stack_map = stack_phase_assignees(stack)

    cond do
      stack_map == %{} -> {:ok, task}
      member_overridden?(task) -> {:ok, task}
      true -> Tasks.set_phase_assignees(task, stack_map)
    end
  end

  defp ensure_has_stack(%Task{stack_id: nil}), do: {:error, :not_in_stack}
  defp ensure_has_stack(%Task{stack_id: stack_id}) when is_binary(stack_id), do: :ok

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
