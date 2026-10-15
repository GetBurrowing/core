defmodule Platform.Orchestration.PhaseRuntime do
  @moduledoc """
  The one place that answers "which runtime owns this task RIGHT NOW".

  `resolve/1` maps a task to the federated runtime behind
  `phase_assignees[current_phase(task)]`, falling back to the flat
  `assignee_id` pointer through `Tasks.assignee_for_phase/2`'s own
  resolution order.

  ## Why this module exists (task 019fb977)

  Before it, two halves of orchestration disagreed about who owned a task:

    * `TaskRouterWatcher` decided eligibility and redispatch from the task's
      FLAT `assignee_id` pointer, re-read on every board event.
    * `TaskRouter` dispatched to a FROZEN copy captured in `start_link/1` and
      never refreshed, and `grep -rn assignee_for_phase apps/platform/lib`
      returned only `tasks.ex` and `stacks.ex` — the router never consulted
      the per-phase map at all.

  So a task assigned agent A for `planning` and agent B for `execution`
  dispatched every post-planning prompt to A, silently, for the life of the
  router. `redispatch_for_runtime/1` could even poke a router on behalf of
  runtime B and watch it send to runtime A. After this module both sides ask
  one function.

  ## Why this is not task 019f42fd again

  019f42fd made the WRITER correct: it re-derived the flat pointer after a
  status write. This makes the READER correct. The discriminator is case 3 of
  `test/platform/orchestration/task_router_phase_assignee_test.exs`, which
  forces the flat pointer stale by construction AFTER the phase assignment —
  `phase_assignees` intact, `current_phase == "execution"`, pointer back at
  the planning agent. No amount of writer-side pointer hygiene can satisfy
  that case; only a phase-aware reader can. That is also why this module
  cannot be deleted once the single-write fold lands: the fold keeps the
  pointer fresh at write time, and case 3 makes it stale at READ time.

  ## Six refusals, six causes, six atoms

  `{:error, reason}` is never a shrug. Each atom names exactly one cause, and
  callers branch on them differently — `TaskRouter` SUPPRESSES a dispatch on
  `:user_assignee` (there is no runtime to send to, and falling back to the
  previously-held agent is the original bug wearing a different hat) and on
  `:owner_denied` (sending anyway would be the bypass the refusal closes),
  and FAILS OPEN on every other reason (a transient resolution failure costs one
  dispatch to a possibly-stale runtime; failing closed strands the task).
  Collapsing any two of these into one atom silently merges those two
  behaviours.

    * `:no_assignee` — `assignee_for_phase/2` found neither a phase entry nor
      a flat pointer.
    * `:user_assignee` — the phase is owned by a HUMAN. See
      `task_router_watcher.ex:704-710` for why a user-assigned task
      deliberately gets no router at all.
    * `:agent_not_found` — an agent id that resolves to no row (including a
      malformed id; see the `Platform.UUID.valid?/1` guard below).
    * `:no_runtime` — a real `Agent` row with `runtime_id: nil`, i.e. an
      agent that was never linked to a federated runtime.
    * `:sandbox_unowned` — test-only, from the `rescue`/`catch` seams moved
      here verbatim from `TaskRouterWatcher.resolve_runtime_for_task/1`.
      NOT reachable from a healthy `DataCase`, so
      `phase_runtime_test.exs` asserts its presence by CONSTRUCTION
      (the clauses exist and are reachable only from those seams) rather
      than faking a fixture that pretends to produce it. See the caveat
      above `resolve/1` before treating those seams as protective — task
      019fb978 measured this guarding pattern as TOCTOU-racy.
    * `:owner_denied` — the runtime was found, but `Platform.Access.check/3`
      refuses `tasks.read` on `{:task, id}` for the runtime's OWNER
      (`Scope.for_user/1`) or for the agent's own grants
      (`Scope.for_runtime/1`), through `Platform.Access.AgentWake.check_agent/4`
      (task 01a1386e-45a5 stage 2, RBAC stack member 7). With no grants
      reachable from either principal the check is `:ok`, so this atom
      never occurs on an install without grants. A runtime with no
      `owner_user_id` skips the owner half. A bare-map task (the
      `phase_assignee(%{assignee_id: ...})` clause) carries no task id the
      check could address, so it skips both halves and resolves as before.
  """

  alias Platform.Access.AgentWake
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @type assignee :: %{type: :federated, id: String.t()}
  @type reason ::
          :no_assignee
          | :user_assignee
          | :agent_not_found
          | :no_runtime
          | :sandbox_unowned
          | :owner_denied

  # The registry's read permission for a task (`Platform.Access.Registry`).
  @tasks_read "tasks.read"

  @doc """
  Resolve the federated runtime that owns `task`'s CURRENT phase.

  Returns `{:ok, %{type: :federated, id: runtime_id}}` or `{:error, reason}`
  with one of the six atoms documented on this module.
  """
  #
  # PROVENANCE OF THE `rescue` / `catch` CLAUSES BELOW, AND A CAVEAT ON THEM.
  #
  # They were carried over VERBATIM (comments included) from
  # `TaskRouterWatcher.resolve_runtime_for_task/1`, whose body this function
  # replaced (task 019fb977). They are reproduced rather than rewritten so the
  # move is a pure relocation and any behaviour change is attributable.
  #
  # DO NOT read their presence as evidence that this pattern works. Sibling
  # task 019fb978 measured the suite and found the opposite: 212
  # sandbox-ownership violations per full-suite run, 145 of them originating in
  # `TaskRouterWatcher`, and `Platform.Orchestration.SandboxGuard` appearing in
  # 289 violation stacks WITHOUT preventing them. The mechanism it identified is
  # TOCTOU: the guard's own preconditions are themselves Repo calls
  # (`connection_owned?/0` does a `Repo.checkout`, the `row_visible?` helpers do
  # `Repo.exists?`), so a `rescue` runs only after Postgrex has already torn the
  # connection down. Their conclusion, verbatim: MORE GUARDING WORSENS IT.
  #
  # What that means here: these clauses convert a would-be crash into a tagged
  # refusal on the paths that reach them, which is strictly better than an
  # unguarded `Repo.get` in the same position — but they are NOT a fix for the
  # ownership violations themselves, and adding more of them elsewhere is
  # measured to make things worse. Fixing that is 019fb978's scope, not this
  # module's. If you are here because you are chasing the flake, go read that
  # ticket's measurement first.
  @spec resolve(TaskSchema.t() | map()) :: {:ok, assignee()} | {:error, reason()}
  def resolve(task) do
    task
    |> phase_assignee()
    |> resolve_assignee(task_id(task))
  rescue
    DBConnection.OwnershipError ->
      # The watcher is a globally-supervised singleton receiving
      # `{:task_created, ...}` / `{:task_updated, ...}` PubSub broadcasts.
      # In an `async: true` DataCase test the sandbox is in MANUAL mode
      # (`data_case.ex` calls `Sandbox.start_owner!(Repo, shared: not
      # tags[:async])`), so those broadcasts arrive on the watcher's own
      # process, which is NOT part of the sandbox owner chain — the
      # `Repo.get` below raises. Reporting a distinct error tag lets
      # `evaluate_task/1` short-circuit rather than crash the GenServer.
      #
      # Under `async: false` the sandbox is SHARED and the watcher can use
      # the connection, so this clause is unreachable there — that case is
      # the `catch` below, not this `rescue`. The mode qualifier is
      # load-bearing and is enforced by
      # test/platform/regression/boot_telemetry_handler_detach_audit_test.exs
      # (task 019f9d80 stage 4): the unconditional version of this claim
      # was measured false in stage 3.
      {:error, :sandbox_unowned}
  catch
    # Same singleton-vs-sandbox race, but the OTHER shape: when a test that
    # HAS allowed the watcher onto its shared connection exits while this
    # `Repo.get` is mid-flight, the sandbox connection is torn down and the
    # query fails as a `DBConnection.ConnectionError` delivered as an EXIT
    # ("owner #PID exited"), which the `rescue` above does not catch. These
    # task-board broadcasts fire on nearly every task insert/update across
    # the suite, so on an unlucky interleaving the watcher crashes several
    # times inside Platform.Supervisor's restart window and takes sibling
    # Platform.Repo down — the same cascade `boot_reconcile/0` guards.
    # "owner exited" is a sandbox-only condition (production has no sandbox
    # owner), and degrading to `{:error, ...}` just skips starting the router
    # this cycle — the next task event or reconcile tick retries — so
    # production behaviour is unchanged.
    :exit, _reason ->
      {:error, :sandbox_unowned}
  end

  # A real `%Task{}` can answer the phase question. `Tasks.assignee_for_phase/2`
  # already encodes the resolution order (phase entry, then flat pointer, then
  # `{nil, nil}`), so this is the whole of the phase-awareness.
  defp phase_assignee(%TaskSchema{} = task) do
    Tasks.assignee_for_phase(task, Tasks.current_phase(task))
  end

  # A bare map cannot: `Tasks.current_phase/1` has no clause for one and
  # `assignee_for_phase/2` returns `{nil, nil}` for it. The public delegate
  # `Platform.Orchestration.resolve_runtime_for_task/1` advertises `map()`,
  # so degrade to the flat pointer rather than raising FunctionClauseError on
  # a caller this module cannot see.
  defp phase_assignee(%{assignee_id: assignee_id} = task) do
    {assignee_id, Map.get(task, :assignee_type)}
  end

  defp phase_assignee(_other), do: {nil, nil}

  # Only a real `%Task{}` names a task the access check can address; a bare
  # map degrades to the flat pointer above and skips the check (see the
  # `:owner_denied` entry in the moduledoc).
  defp task_id(%TaskSchema{id: id}) when is_binary(id), do: id
  defp task_id(_other), do: nil

  defp resolve_assignee({nil, _type}, _task_id), do: {:error, :no_assignee}

  defp resolve_assignee({_id, "user"}, _task_id), do: {:error, :user_assignee}

  # GUARD, not decoration: unlike the flat `tasks.assignee_id` column (a
  # `Platform.Types.UUIDv7` cast at write time), a phase entry's
  # `"assignee_id"` lives inside the `phase_assignees` JSONB map, and
  # `Task.validate_phase_assignees/1` (`tasks/task.ex:348`) validates only the
  # PHASE KEYS — never the id shape. An MCP `task_update` carrying
  # `%{"execution" => %{"assignee_id" => "higgins", ...}}` therefore reaches
  # here as a raw agent-supplied string, and an unguarded `Repo.get/2` raises
  # `Ecto.Query.CastError` inside the router's dispatch path. See
  # `test/platform/repo_lookup_boundary_test.exs`, where this site is
  # classified `:must_cast` for exactly that provenance.
  defp resolve_assignee({assignee_id, _type}, task_id) when is_binary(assignee_id) do
    if Platform.UUID.valid?(assignee_id) do
      resolve_agent(assignee_id, task_id)
    else
      {:error, :agent_not_found}
    end
  end

  defp resolve_assignee(_other, _task_id), do: {:error, :no_assignee}

  defp resolve_agent(agent_id, task_id) do
    case Repo.get(Agent, agent_id) do
      nil ->
        {:error, :agent_not_found}

      %Agent{} = agent ->
        case Federation.get_runtime_for_agent(agent) do
          nil -> {:error, :no_runtime}
          runtime -> authorize_wake(agent, runtime, task_id)
        end
    end
  end

  # Task 01a1386e-45a5 stage 2. Conjunctive with everything above: the
  # runtime is already resolved, and this only decides whether it may be
  # woken onto the task.
  defp authorize_wake(_agent, runtime, nil),
    do: {:ok, %{type: :federated, id: runtime.runtime_id}}

  defp authorize_wake(agent, runtime, task_id) do
    case AgentWake.check_agent(agent, runtime, @tasks_read, {:task, task_id}) do
      :ok -> {:ok, %{type: :federated, id: runtime.runtime_id}}
      {:error, :denied} -> {:error, :owner_denied}
    end
  end
end
