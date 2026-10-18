defmodule Platform.Tasks.TaskAccess do
  @moduledoc """
  Task authorization — the single rule for "may this principal touch this
  task?" (task 019fb581, stage 1).

  One door, one resolver:

      fetch_for_actor(task_id, actor, opts) ::
        {:ok, %Task{}, grant} | {:error, :forbidden} | {:error, :not_found}

  Stage 1 ships the primitive with NO callers wired, so the whole rule can be
  read in one file before behaviour changes anywhere. Stages 3 and 4 put it in
  front of `task_attach_canvas`, `task_detach_canvas` and
  `task_list_canvases`.

  ## Flat, deliberately — this is not `Platform.Chat.CanvasAccess`'s shape

  `CanvasAccess` has two doors and a level lattice. That lattice is
  load-bearing there only because `fetch_for_writer/2` REJECTS two of its
  three levels (canvas_access.ex:242-245). Copying it here would give every
  grant acceptance at every door, so the lattice would encode zero decisions
  and the next person adding a grant path would have no rule telling them
  which door it belongs in.

  Mirroring it would also import a read/write asymmetry that does not exist
  for agent principals. An unearned asymmetry has nothing to pin in a test:
  someone adds a read-only path later, it is silently a write grant too, and
  nothing goes red.

  So `grant` is a TELEMETRY LABEL. Nothing branches on it. Add the second door
  the day a user principal actually reaches a write surface here, with a test
  pinning what it rejects.

  ## Actors

  `t:actor/0` is `Platform.Tasks`'s existing triple (tasks.ex:4636), which is
  itself `Platform.Audit.Event`'s actor taxonomy:

      {:user, user_id} | {:agent, agent_id} | :system

  `:system` is the explicit, caller-asserted opt-out for platform-initiated
  work. `nil` and any unrecognised shape are NO PRINCIPAL and deny; there is
  deliberately no clause promoting an unknown shape to `:system`, because a
  silent bypass on an authorization path is worse than an outage.

  Unlike `CanvasAccess`, a bare `%{id: _}` map (i.e. a `%Platform.Accounts.User{}`)
  is NOT accepted as shorthand. Three modules sharing one taxonomy is the
  point; a caller holding a user struct tags it `{:user, user.id}`.

  ## Six grant paths, evaluated in order — any one is sufficient

    1. `:system` — the caller-asserted opt-out.
    2. `:assignee` — actor id AND kind match `tasks.assignee_type` /
       `assignee_id`.
    3. `:phase_assignee` — actor id and kind match any entry in
       `tasks.phase_assignees` (planning / execution / review), read through
       `Platform.Tasks.assignee_for_phase/2` rather than re-derived here. That
       reuse is the point: `Tasks.per_phase_assignee/2` treats a bare
       `%{"assignee_id" => id}` with no explicit type as an AGENT, and a
       second traversal that disagreed would silently widen or narrow the
       gate. `assignee_for_phase/2` falls back to the top-level assignee when
       a phase entry is empty, which overlaps path 2 exactly — harmless,
       because path 2 is evaluated first and the label stays `:assignee`.
    4. `:space_member` — the actor participates in the task's execution space
       (`ExecutionSpace.find_by_task_id/1`, then `Chat.get_agent_participant/2`
       for agents and `Chat.participant?/2` for users).
    5. `:sponsor` — `{:user, id}` matches `tasks.sponsor_user_id`.
    6. `:project_member` — `{:user, id}` belongs to the task's project org.

  ## Agent principals short-circuit after path 4

  Paths 5 and 6 are never reached for `{:agent, _}`, and the stop is on
  principal SHAPE rather than on a failed lookup. This is TYPING, not policy:
  `Tenancy.member_of?/2`, `external_user?/1` and `root_admin?/1` all query
  `org_memberships.user_id`, the `agents` table carries no `org_id` and no
  membership join at all, and `Accounts.get_user/1` raises
  `Ecto.Query.CastError` on a non-UUID id. An agent id handed to a
  user-shaped predicate is not "denied" — it is meaningless, or it crashes.

  Do not add an org path for agents without first giving agents org
  membership.

  ## `:not_found` swallows absent, malformed AND soft-deleted

  The id is guarded with `Platform.UUID.valid?/1` before any query, matching
  `CanvasAccess.load/1` (canvas_access.ex:257-259): a bare `Ecto.UUID.cast/1`
  accepts any 16-byte binary and would push a non-UUIDv7 value at a strict
  UUIDv7 key, so a 16-character slug would clear the guard and `Repo` would
  raise anyway.

  A soft-deleted task is `:not_found` for EVERYONE, including a grant holder.
  `CanvasAccess` deliberately does the opposite (a member is told their canvas
  was removed rather than that it never existed) because a bookmarked canvas
  is something the viewer can disprove from their own history. No task surface
  renders a "this was deleted" state, so the same courtesy here would only buy
  a denial that is a richer existence oracle than the surface itself.

  ## Denial telemetry

  A denial emits `[:platform, :tasks, :access_denied]` carrying actor_type,
  actor_id, resource_type `"task"`, resource_id, project_id and the attempted
  tool name (`:tool` option). Grants are NOT audited: a denial is the signal
  worth keeping, and auditing the common path would bury it.

  The event is registered in `Platform.Audit.TelemetryHandler`'s explicit
  allowlist. Without that registration `:telemetry.execute/3` here is a silent
  no-op — an emit nobody listens to is a guard that cannot fire.

  One known gap, stated rather than hidden: `audit_events.actor_id` is an
  `Ecto.UUID` column, so a denial naming an agent by SLUG rather than by id
  fails the changeset and is logged instead of persisted. The telemetry event
  still fires. Fixing that means widening the audit column, which is not this
  task's scope.

  ## NON-SCOPE: `task_get` and `task_list` are NOT gated, and that is a decision

  Task 019fb581 puts this module in front of the three canvas-attachment
  tools and stops there. `task_get` (`federation/tool_surface.ex:3839`) and
  `task_list` (`tool_surface.ex:3894-3910`) stay open. Read the rest of this
  section before "fixing" the omission, because gating either one in
  isolation makes things worse rather than better.

  Both return `serialize_task/1` (`tool_surface.ex:9123`), and `task_list`
  maps that same serializer over `Tasks.list_tasks/1` (`tasks.ex:1268`),
  whose three filters (`project_id`, `epic_id`, `status`) are ALL optional. A
  bare `task_list` therefore returns every non-deleted task in the database,
  with payloads byte-identical to what `task_get` returns for each one.

  Gating `task_get` alone closes nothing: the same rows stay one unfiltered
  `task_list` away. It ADDS something, though: a `{:error, :forbidden}` that
  separates "exists, not yours" from "does not exist", which is an
  authorization-and-existence oracle `task_list` does not have. New oracle,
  no protection.

  Gating `task_list` per-actor is the other half, and it breaks live
  behaviour: stack siblings read each other to assemble the rollup PR,
  dependency reads cross assignee boundaries, and reviewers read upstream
  context for tasks they are on no phase of. Meanwhile
  `Platform.Tasks.ContextHydrator` and
  `Platform.Orchestration.ContextAssembler` resolve as `:system` and stay
  green, so the damage lands precisely where the test suite cannot see it.

  "Any agent can read any task in the system" is therefore still true after
  this task ships. Closing it means first deciding WHO should see which tasks
  (the whole board, only their own project, or only the tasks they are on),
  which changes what agents can do. That is a product decision, filed as its
  own ticket rather than smuggled in behind a security fix: Burrow task
  `019fbe15-fa42-7486-a85c-1c4af5f1a504`, unassigned in the backlog with the
  question at the top.

  Gating `task_list_canvases` while these two stay open is coherent, not
  inconsistent: `serialize_task/1` carries no canvas data at all, so the
  attachment list is not a wrapper over `task_get`. The two reads are
  disjoint, and the attachment list names canvases in spaces the reader may
  be nowhere near.

  ### Why the attachment read DENIES rather than returning an empty list

  Stage 4's one open choice, decided here so the next reader inherits the
  reasoning and not just the behaviour. An empty list leaks less in the
  abstract. It was rejected twice over.

  It is indistinguishable from a task that genuinely has no attachments, so
  the designer refused an attach one call earlier reads `[]` and concludes
  her write silently failed. And it makes the tool's own `returns` contract
  false: a caller handed `canvases: []` for a task carrying three attachments
  has been given a wrong answer rather than a withheld one. A refusal that
  lies is worse than a refusal that is legible.

  The usual argument for the empty list, that a refusal is an existence
  oracle, does not hold while `task_get` is open, because the same caller
  learns existence there in one call, for free, from the same capability
  bundle. The denial hands over nothing a `task_get` would not.

  That is a REAL coupling rather than a rhetorical one: gate `task_get` and
  this reasoning expires. `tool_surface_test.exs` pins it with a test
  asserting the actor `task_list_canvases` denies still gets `{:ok, _}` from
  `task_get` for the same id, so whoever closes the read hole is made to
  re-read this section instead of discovering the coupling afterwards.
  """

  alias Platform.Chat
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task
  alias Platform.Tenancy

  @type actor :: {:user, String.t()} | {:agent, String.t()} | :system

  @type grant ::
          :system
          | :assignee
          | :phase_assignee
          | :space_member
          | :sponsor
          | :project_member

  @type result ::
          {:ok, Task.t(), grant()}
          | {:error, :forbidden}
          | {:error, :not_found}

  @denial_event [:platform, :tasks, :access_denied]

  @doc """
  Resolve a task for an actor.

  Returns `{:ok, task, grant}` where `grant` names the path that resolved
  (telemetry label only — nothing branches on it); `{:error, :not_found}` when
  the id is malformed, no row exists, or the row is soft-deleted; and
  `{:error, :forbidden}` when the task is live and no grant path applies.

  ## Options

    * `:tool` — the tool name to record on the denial event. Defaults to
      `nil`. It is a label for the audit stream, never an input to the
      decision.
  """
  @spec fetch_for_actor(binary(), actor(), keyword()) :: result()
  def fetch_for_actor(task_id, actor, opts \\ [])

  def fetch_for_actor(task_id, actor, opts) when is_binary(task_id) do
    case load(task_id) do
      %Task{} = task -> resolve(task, normalize_actor(actor), opts)
      nil -> {:error, :not_found}
    end
  end

  def fetch_for_actor(_task_id, _actor, _opts), do: {:error, :not_found}

  # ── Loading ───────────────────────────────────────────────────────────────

  # `task_id` is a raw MCP tool argument — whatever the caller sent.
  # `Platform.UUID.valid?/1`, not a bare `Ecto.UUID.cast/1`; see the moduledoc.
  defp load(task_id) do
    with true <- Platform.UUID.valid?(task_id),
         %Task{deleted_at: nil} = task <- Repo.get(Task, task_id) do
      task
    else
      _ -> nil
    end
  end

  # ── Actors ────────────────────────────────────────────────────────────────

  # Anything unrecognised normalises to `nil` — no principal, no grant.
  defp normalize_actor(:system), do: :system
  defp normalize_actor({:user, id} = actor) when is_binary(id), do: actor
  defp normalize_actor({:agent, id} = actor) when is_binary(id), do: actor
  defp normalize_actor(_), do: nil

  # ── Grant resolution ──────────────────────────────────────────────────────

  defp resolve(%Task{} = task, actor, opts) do
    case grant(task, actor) do
      nil ->
        emit_denial(task, actor, opts)
        {:error, :forbidden}

      grant ->
        {:ok, task, grant}
    end
  end

  # `actor` here is always the output of `normalize_actor/1`.
  defp grant(%Task{}, :system), do: :system

  defp grant(%Task{} = task, actor) do
    cond do
      assignee?(task, actor) ->
        :assignee

      phase_assignee?(task, actor) ->
        :phase_assignee

      space_member?(task, actor) ->
        :space_member

      # Agent principals stop here: paths 1-4 or nothing. The two paths below
      # query `org_memberships.user_id` and are meaningless for an agent id —
      # see the moduledoc. Checked on principal SHAPE, before either runs.
      match?({:agent, _}, actor) ->
        nil

      is_nil(actor) ->
        nil

      sponsor?(task, actor) ->
        :sponsor

      project_member?(task, actor) ->
        :project_member

      true ->
        nil
    end
  end

  # ── 2. :assignee ──────────────────────────────────────────────────────────

  defp assignee?(%Task{assignee_id: id, assignee_type: type}, {kind, actor_id})
       when is_binary(id) and is_binary(type) and is_binary(actor_id) do
    id == actor_id and type == Atom.to_string(kind)
  end

  defp assignee?(_task, _actor), do: false

  # ── 3. :phase_assignee ────────────────────────────────────────────────────
  #
  # `Tasks.assignee_for_phase/2` is the repo's resolver for this map; calling
  # it is what guarantees agreement with `Tasks.per_phase_assignee/2` on the
  # bare `%{"assignee_id" => id}` shape, which that resolver types as an agent.

  defp phase_assignee?(%Task{} = task, {kind, actor_id}) when is_binary(actor_id) do
    kind = Atom.to_string(kind)

    Enum.any?(Task.phases(), fn phase ->
      Tasks.assignee_for_phase(task, phase) == {actor_id, kind}
    end)
  end

  defp phase_assignee?(_task, _actor), do: false

  # ── 4. :space_member ──────────────────────────────────────────────────────

  defp space_member?(%Task{id: task_id}, actor) do
    case ExecutionSpace.find_by_task_id(task_id) do
      %Chat.Space{id: space_id} -> participant?(space_id, actor)
      nil -> false
    end
  end

  # An agent is a `participant_type == "agent"` row, which `Chat.participant?/2`
  # deliberately does NOT match — hence the two spellings.
  defp participant?(space_id, {:user, user_id}), do: Chat.participant?(space_id, user_id)

  defp participant?(space_id, {:agent, agent_id}) do
    match?(%Chat.Participant{}, Chat.get_agent_participant(space_id, agent_id))
  end

  defp participant?(_space_id, _actor), do: false

  # ── 5. :sponsor ───────────────────────────────────────────────────────────

  defp sponsor?(%Task{sponsor_user_id: sponsor_id}, {:user, user_id})
       when is_binary(sponsor_id) and is_binary(user_id) do
    sponsor_id == user_id
  end

  defp sponsor?(_task, _actor), do: false

  # ── 6. :project_member ────────────────────────────────────────────────────
  #
  # `Tasks.get_project/1` rather than a raw lookup here: `project_id` is read
  # off the `%Task{}` row already loaded, so it is a `tasks.project_id` column
  # value and cannot be malformed. `projects.org_id` is NOT NULL, so there is
  # no org-less-project arm to write; a nil that somehow arrived would still
  # deny, since `Tenancy.member_of?/2` guards on `is_binary/1`.

  defp project_member?(%Task{project_id: project_id}, {:user, user_id})
       when is_binary(project_id) and is_binary(user_id) do
    case Tasks.get_project(project_id) do
      %Project{org_id: org_id} when is_binary(org_id) ->
        Tenancy.member_of?(%{id: user_id}, org_id)

      _ ->
        false
    end
  end

  defp project_member?(_task, _actor), do: false

  # ── Denial telemetry ──────────────────────────────────────────────────────

  defp emit_denial(%Task{} = task, actor, opts) do
    {actor_type, actor_id} = audit_actor(actor)

    :telemetry.execute(
      @denial_event,
      %{system_time: System.system_time()},
      %{
        actor_id: actor_id,
        actor_type: actor_type,
        resource_type: "task",
        resource_id: task.id,
        action: "denied",
        project_id: task.project_id,
        tool: Keyword.get(opts, :tool)
      }
    )

    :ok
  end

  # Derived from the actor tag rather than hardcoded, so an actor kind added
  # later cannot be silently mis-attributed. `"anonymous"` is the audit
  # taxonomy's value for a request with no principal.
  defp audit_actor({:user, id}), do: {"user", id}
  defp audit_actor({:agent, id}), do: {"agent", id}
  defp audit_actor(_), do: {"anonymous", nil}
end
