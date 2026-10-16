defmodule Platform.Chat.CanvasAccess do
  @moduledoc """
  Canvas authorization — the single rule shared by the standalone
  `/canvases/:id` page, the chat pane, and the MCP surface (task 019e2c4b,
  stages 1 and 2).

  Two doors, one resolver:

    * `fetch_for_viewer/3` — READ (stage 1). Any grant path is sufficient.
    * `fetch_for_writer/2` — WRITE (stage 2). Only `:member` and `:system`.

  `Platform.Chat.get_canvas/2` stays the UNAUTHORIZED primitive: it applies no
  membership check, and MCP / system callers depend on that pass-through while
  `Platform.Chat.ExternalScope.visible_space_id?/2` already carries the external
  floor. Authorization layers on top *here*, in one place, so three surfaces
  cannot drift into three rules.

  `Platform.Chat.Canvas.Server.apply_patches/3,4` stays unauthorized for the
  same reason, one level down: it is the rebase/concurrency engine, it has
  system callers (`Platform.Meetings.Triage`) and a LiveView caller that
  authorizes at navigation time, and running authz inside that serialized
  GenServer would put a database round-trip on the critical section. Write
  authorization happens at the handler seam above it.

  ## Actors

  `t:actor/0` is the repo's standard triple, mirroring
  `Platform.Tasks`'s `actor` type and `Platform.Audit.Event`'s actor taxonomy:

      {:user, user_id} | {:agent, agent_id} | :system

  A bare `%{id: _}` map (i.e. a `%Platform.Accounts.User{}`) is accepted as
  shorthand for `{:user, id}`, which is what the LiveView holds. Anything else
  — including `nil` — is *no principal* and never resolves a grant.

  `:system` is the explicit opt-out for callers that have no principal to
  offer: migrations, internal jobs, and platform-initiated writes. It is
  caller-asserted, never inferred. A missing or unrecognised actor denies; it
  does NOT fall back to `:system`, because a silent bypass on an
  authorization path is worse than an outage.

  **Agents get no ORG-derived grant.** They never reach `:task_reader` or
  `:org_reader`, and this is not a policy preference — it is the only
  well-typed answer. `Tenancy.member_of?/2`, `external_user?/1` and
  `root_admin?/1` all query `org_memberships.user_id`; an agent id passed to
  them is not "denied", it is meaningless. Do not "fix" this by adding an org
  path for agents without first giving agents org membership.

  What agents DO get is a TASK-derived grant, `:task_agent` (task 019fb01b
  stage 2), which queries `tasks` and `chat_participants` — both of which
  carry first-class agent rows, so the question it asks is answerable for an
  agent id in a way the org questions are not.

  **Never promote a runtime's `owner_user_id` into `{:user, id}`.**
  `Platform.Agents.AgentRuntime` has a nullable `agent_id` and a required
  `owner_user_id` (agent_runtime.ex:23-24), so rescuing a nil-agent runtime by
  falling back to its owner looks like a small robustness fix. It would hand a
  remote process its human owner's org-wide `:task_reader` and `:org_reader`
  reach. A runtime with no agent has no principal here, and denies.

  ## Four grant paths, evaluated in order — any one is sufficient

    1. `:member` — the viewer is a participant of the canvas's parent space
       (`Chat.participant?/2` for users, `Chat.get_agent_participant/2` for
       agents). Today's in-chat behavior, unchanged.

    2. `:task_agent` — AGENT principals only. The canvas is attached to at
       least one live task, and the calling agent id appears in that task's
       `phase_assignees` map (`Platform.Tasks.Task`, task.ex:113) in any slot
       explicitly typed `"agent"`. Keyed on the per-phase MAP, never on the
       flat `assignee_id` pair: the flat pair is the CURRENT-phase assignee and
       rotates planning → execution → review, so a grant keyed on it would
       blink out mid-task. Not `owner_id` either (political ownership, per
       task.ex:12-30), and not the attachment row's `attached_by_id`
       (attribution is not authorization, stated verbatim at
       design_task_direction.ex:580-581).

    3. `:task_reader` — USER principals only. The canvas is attached to at
       least one live task whose project org the viewer belongs to. This is the
       path that fixes the reported incident: the audit canvas lived in an
       **execution** space, which `Chat.space_accessible?/1` correctly excludes,
       but it was attached to the spike task and the humans reviewing that task
       can read the task. Agent deliverables become reachable without opening
       execution spaces wholesale.

    4. `:org_reader` — USER principals only. The parent space passes
       `Chat.space_accessible?/1` (exists, not archived, not an execution
       space) AND `kind == "channel"` AND `org_id` is non-nil AND the viewer is
       `Tenancy.root_admin?/1` or `Tenancy.member_of?/2` that org.

  ## Deliberate inversions and exclusions

  **A null `org_id` DENIES.** `PlatformWeb.FileBlobController` (:83-103) treats
  a null org as a legacy artifact and *allows* it. In chat, null `org_id` is
  every DM and every group — `create_dm_space/3` and
  `do_create_group_conversation/2` never set it — so that arm is inverted here.
  The explicit `kind == "channel"` allowlist means a future `org_id` backfill
  cannot silently open DM canvases either.

  **No `parent_org_id` walk.** Nothing in `apps/platform/lib` walks
  `parent_org_id` for authorization. Root-org membership implying descendant-org
  reach would be a brand-new privilege granted as a side effect of a share-link
  route, so `:org_reader` copies the existing `root_admin? or member_of?` shape
  at `file_blob_controller.ex:83-103` — the closest analogue in the tree.

  **`root_admin?/1` appears in `:org_reader` only, not `:task_reader`.** A root-org
  admin therefore does NOT get a blanket read of execution-space canvases via
  the task path; `:task_reader` is strict org membership, per plan. Execution
  spaces stay closed by every route.

  **External users get `:member` only.** `Tenancy.external_user?/1` short-circuits
  both org-reach paths, preserving the rbac-external-users M6/M7 boundary rather
  than punching through it.

  ## PRECONDITION on the attachment-derived grants

  `:task_reader` and `:task_agent` both derive a read grant from a
  `task_canvas_attachments` row, so an unauthorized attach is a self-service
  grant of read on someone else's canvas.
  `Platform.Tasks.CanvasAttachments.attach_canvas/4` therefore takes an actor
  and calls `fetch_for_viewer/3` on the attacher before the row is written: you
  cannot confer a read grant on a canvas you could not read.

  Keep that gate in place. Anything that reintroduces an unauthenticated attach
  reopens both as a privilege-escalation path.

  Only the CANVAS half of that precondition is closed. `task_attach_canvas`
  (`Platform.Federation.ToolSurface`) never authorizes the caller against the
  TASK, because no such primitive exists in `apps/platform/lib/platform/tasks/`
  yet. Filed as task `019fb581-8a1f-7c49-ba42-72f4ab29e758`; see the comment on
  the `:task_agent` arm below for what that means and why it was accepted.

  ## `:not_found` and `:forbidden` are distinct, and that is the point

  The standalone page renders visually different states for "this canvas does
  not exist" and "this canvas exists and you cannot see it". A context that
  collapses them makes that distinction unimplementable, which is the defect
  this task exists to fix. The cost is a weak existence oracle on canvas ids;
  ids are UUIDv7 so it yields little, and external users still collapse to a
  uniform denial via `ExternalUserScope`.

  ## Soft-deleted canvases

  Grant is evaluated FIRST, then deletion decides the shape of the answer:

    * grant + `deleted_at` → `{:ok, canvas, level}`. The canvas struct carries
      `deleted_at`, so `PlatformWeb.Chat.CanvasRenderer`'s existing
      `render_removed` branch fires and a member who bookmarked a since-deleted
      canvas is told it was removed. Telling them "does not exist" would be a
      lie they can disprove from their own history.
    * no grant + `deleted_at` → `{:error, :not_found}`. A deleted canvas must
      not even yield a distinguishable 403; absence is the honest and the
      leak-free answer for someone with no claim on it.

  ## Audit

  A successful `:task_agent`, `:task_reader` or `:org_reader` resolution emits
  `[:platform, :chat, :canvas_read]` — a non-member reading a canvas is exactly
  the sensitive read the audit stream exists for. `:member` reads are NOT
  audited; they are already in-space and would bury the signal. `:task_agent`
  rows carry `actor_type: "agent"`, which `Platform.Audit.Event` already
  allows (audit/event.ex:39).

  The event is registered in `Platform.Audit.TelemetryHandler`'s explicit
  allowlist. Without that registration `:telemetry.execute/3` here is a silent
  no-op.

  Its mirror is `[:platform, :chat, :canvas_read_denied]`, emitted from
  `Platform.Chat.Canvas.ToolAccess` on a forbidden MCP read (task 019fb01b
  stage 5) and registered in the same allowlist. It is deliberately NOT emitted
  from here: this module also answers the LiveView, where a denial is a human
  hitting a page they may not see, and mixing the two would cost the signal
  its meaning. Denials decided on this door for non-MCP callers are not
  covered by either event.

  LiveView remounts on reconnect, so callers that mount repeatedly for one
  human sitting on one page should pass `audit: false` on the remount rather
  than minting a row per socket. The default is `audit: true`.
  """

  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tasks.Project
  alias Platform.Tasks.Task
  alias Platform.Tenancy

  import Ecto.Query, only: [from: 2]

  @type level :: :member | :task_agent | :task_reader | :org_reader | :system

  @typedoc """
  Acting principal. Mirrors `Platform.Tasks`'s `actor` triple and
  `Platform.Audit.Event`'s actor taxonomy rather than inventing a parallel one.
  A bare `%{id: _}` (a `%Platform.Accounts.User{}`) is accepted as `{:user, id}`.
  """
  @type actor :: {:user, binary()} | {:agent, binary()} | :system | map() | nil

  @type result ::
          {:ok, Canvas.t(), level()}
          | {:error, :forbidden}
          | {:error, :not_found}

  @type write_result ::
          {:ok, Canvas.t()}
          | {:error, :forbidden}
          | {:error, :not_found}

  @audit_event [:platform, :chat, :canvas_read]

  @doc """
  Resolve a canvas for a viewer.

  Returns `{:ok, canvas, level}` where `level` is `:member`, `:task_reader` or
  `:org_reader`; `{:error, :not_found}` when no canvas row exists (or the row
  is soft-deleted and the viewer has no grant on it); `{:error, :forbidden}`
  when the canvas exists and no grant path applies.

  `viewer` is a `t:actor/0`: `{:user, id}`, `{:agent, id}`, `:system`, or a
  `%Platform.Accounts.User{}` (accepted as `{:user, id}` — the shape the
  LiveView holds). A `nil` or unrecognised viewer holds no grant and never
  resolves.

  ## Options

    * `:access_scope` — an optional `%Platform.Access.Scope{}`. A canvas a
      `canvas.read` deny covers returns `{:error, :not_found}`, the same as a
      missing one. Absent, or with no grant naming `canvas.read`, nothing
      changes.
    * `:audit` — emit the `[:platform, :chat, :canvas_read]` telemetry event on
      a `:task_reader` / `:org_reader` resolution. Defaults to `true`. Pass
      `false` from a LiveView remount so a reconnect does not mint a duplicate
      audit row for the same human on the same page.
  """
  @spec fetch_for_viewer(binary(), actor(), keyword()) :: result()
  def fetch_for_viewer(canvas_id, viewer, opts \\ [])

  def fetch_for_viewer(canvas_id, viewer, opts) when is_binary(canvas_id) do
    case load(canvas_id) do
      %Canvas{} = canvas ->
        if denied_by_scope?(canvas, Keyword.get(opts, :access_scope)),
          do: {:error, :not_found},
          else: resolve_grant(canvas, normalize_actor(viewer), opts)

      nil ->
        {:error, :not_found}
    end
  end

  def fetch_for_viewer(_canvas_id, _viewer, _opts), do: {:error, :not_found}

  # Task 01a1386d-e528 stage 3, the `fetch_for_viewer/3` seam row of
  # `0058-rbac-v2-roles-scopes-and-agent-capping.md § Permission model`: with `:access_scope`, a canvas a
  # `canvas.read` deny covers (on the canvas, its space, or a project above
  # it) answers EXACTLY like a missing row, before any grant path runs, so no
  # audit event is minted for a refused read. The grant paths below stay the
  # existing check: `Access.within?/4` is asked with `true` because an allow
  # adds nothing here (it cannot mint a `level`), only a deny narrows.
  defp denied_by_scope?(%Canvas{id: id}, %Platform.Access.Scope{} = scope),
    do: not Platform.Access.within?(scope, "canvas.read", {:canvas, id}, true)

  defp denied_by_scope?(_canvas, _scope), do: false

  @doc """
  Resolve a canvas for a viewer who intends to WRITE it (task 019e2c4b,
  stage 2).

  Returns `{:ok, canvas}` when `actor` holds space participation (`:member`) or
  is the explicit `:system` actor; `{:error, :forbidden}` otherwise;
  `{:error, :not_found}` when no live canvas row exists.

  ## Read levels do not confer write

  `:task_agent`, `:task_reader` and `:org_reader` are READ grants and are
  rejected here. That asymmetry is the entire point of the function: without
  it, the moment the standalone route hands a URL to org-wide readers or to a
  task's agents, read silently becomes write.

  ## Soft-deleted canvases are `:not_found` here, even for a member

  `fetch_for_viewer/3` deliberately RETURNS soft-deleted canvases to
  grant-holders so the renderer can say "this was removed" instead of lying.
  A writer has no such need, and every pre-existing write path reached its
  canvas through `Chat.get_canvas/2`, which filters `deleted_at`. Reusing the
  reader's soft-delete behaviour here would newly permit writes to deleted
  canvases — a regression dressed as code reuse.

  No audit event is emitted: this resolves write intent, not a read, and the
  write itself is what downstream audit records.
  """
  @spec fetch_for_writer(binary(), actor()) :: write_result()
  def fetch_for_writer(canvas_id, actor) when is_binary(canvas_id) do
    case load(canvas_id) do
      nil ->
        {:error, :not_found}

      %Canvas{deleted_at: deleted_at} when not is_nil(deleted_at) ->
        {:error, :not_found}

      %Canvas{} = canvas ->
        case grant_level(canvas, normalize_actor(actor)) do
          level when level in [:member, :system] -> {:ok, canvas}
          _ -> {:error, :forbidden}
        end
    end
  end

  def fetch_for_writer(_canvas_id, _actor), do: {:error, :not_found}

  # ── Loading ───────────────────────────────────────────────────────────────

  # `canvas_id` is a URL segment / raw MCP tool argument — whatever the caller
  # sent. `Platform.UUID.valid?/1`, not a bare `Ecto.UUID.cast/1`: a bare cast
  # accepts any 16-byte binary and would push a non-UUIDv7 value into a query
  # against a strict UUIDv7 key.
  defp load(canvas_id) do
    if Platform.UUID.valid?(canvas_id), do: Repo.get(Canvas, canvas_id)
  end

  # ── Actors ────────────────────────────────────────────────────────────────

  # Anything unrecognised normalises to `nil` — no principal, no grant. There
  # is deliberately no clause that promotes an unknown shape to `:system`.
  defp normalize_actor(:system), do: :system
  defp normalize_actor({:user, id} = actor) when is_binary(id), do: actor
  defp normalize_actor({:agent, id} = actor) when is_binary(id), do: actor
  defp normalize_actor(%{id: id}) when is_binary(id), do: {:user, id}
  defp normalize_actor(_), do: nil

  # ── Grant resolution ──────────────────────────────────────────────────────

  defp resolve_grant(%Canvas{} = canvas, viewer, opts) do
    case grant_level(canvas, viewer) do
      nil ->
        # Deletion outranks forbidden for the ungranted: a soft-deleted canvas
        # must not be distinguishable from one that never existed.
        if canvas.deleted_at, do: {:error, :not_found}, else: {:error, :forbidden}

      level ->
        maybe_audit(level, canvas, viewer, opts)
        {:ok, canvas, level}
    end
  end

  # `viewer` here is always the output of `normalize_actor/1`.
  defp grant_level(%Canvas{}, :system), do: :system

  defp grant_level(%Canvas{} = canvas, viewer) do
    cond do
      member?(canvas, viewer) ->
        :member

      # Agent principals stop here: `:member`, `:task_agent`, or nothing. The
      # org-reach paths below query `org_memberships.user_id` and are
      # meaningless for an agent id — see the moduledoc. Checked on principal
      # SHAPE, before the external-user check, which is itself user-shaped.
      match?({:agent, _}, viewer) ->
        agent_grant(canvas, viewer)

      # Both org-reach paths are closed to external users. Checked once, here,
      # rather than inside each arm — one place to read, one place to change.
      is_nil(viewer) or Tenancy.external_user?(user_map(viewer)) ->
        nil

      task_reader?(canvas, user_map(viewer)) ->
        :task_reader

      org_reader?(canvas, user_map(viewer)) ->
        :org_reader

      true ->
        nil
    end
  end

  # `Tenancy.*` predicates all pattern-match `%{id: _}`. Wrapping at this
  # boundary is the established adaptation — `Chat.external_principal?/1` does
  # exactly this for `{:user, uid}`.
  defp user_map({:user, id}), do: %{id: id}
  defp user_map(_), do: nil

  # ── 1. :member ────────────────────────────────────────────────────────────

  defp member?(%Canvas{space_id: space_id}, {:user, user_id})
       when is_binary(space_id) and is_binary(user_id) do
    Chat.participant?(space_id, user_id)
  end

  # An agent is a `participant_type == "agent"` row, which `Chat.participant?/2`
  # deliberately does NOT match. Without this clause every MCP canvas write
  # would deny — including the agent that created the canvas.
  defp member?(%Canvas{space_id: space_id}, {:agent, agent_id})
       when is_binary(space_id) and is_binary(agent_id) do
    match?(%Chat.Participant{}, Chat.get_agent_participant(space_id, agent_id))
  end

  defp member?(_canvas, _viewer), do: false

  # ── 2. :task_agent ────────────────────────────────────────────────────────
  #
  # Task 019fb01b stage 2. The canvas is attached to a live task and the
  # calling agent is bound to that task by `phase_assignees`.
  #
  # ACCEPTED RESIDUAL RISK, filed as task
  # `019fb581-8a1f-7c49-ba42-72f4ab29e758` and knowingly accepted at plan time
  # — this must not be rediscovered later as a surprise. `task_attach_canvas`
  # never authorizes its caller against the TASK (no such primitive exists in
  # `apps/platform/lib/platform/tasks/` yet), so an agent holding read on
  # canvas C can staple C onto any task and hand it to that task's agents.
  # `:task_agent` widens who that reaches from "humans in the task's project
  # org" to "those humans plus every agent in `phase_assignees`". It is a PUSH,
  # not a pull: the attacher must already be able to read C, so it cannot
  # exfiltrate a canvas it cannot see. 019fb581 closes the task half.

  defp agent_grant(%Canvas{} = canvas, {:agent, agent_id}) when is_binary(agent_id) do
    if task_agent?(canvas, agent_id), do: :task_agent
  end

  defp agent_grant(_canvas, _viewer), do: nil

  # `list_canvas_tasks/1` already drops soft-deleted tasks to `task: nil`
  # (canvas_attachments.ex:291-308), so a grant cannot outlive the task that
  # conferred it — the same property `:task_reader` relies on. The envelope is
  # deliberately thin (`id`, `title`, `status`, `project_id`), so the assignee
  # map is fetched in one follow-up query keyed on the live task ids.
  defp task_agent?(%Canvas{id: canvas_id}, agent_id) do
    canvas_id
    |> CanvasAttachments.list_canvas_tasks()
    |> Enum.map(fn %{task: task} -> task && task.id end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> task_phase_assignees()
    |> Enum.any?(&agent_in_phase_assignees?(&1, agent_id))
  end

  defp task_phase_assignees([]), do: []

  defp task_phase_assignees(task_ids) do
    Repo.all(from(t in Task, where: t.id in ^task_ids, select: t.phase_assignees))
  end

  # Kept as a NAMED predicate with this signature on purpose. Task
  # `019fb581-8a1f-7c49-ba42-72f4ab29e758` (task-side authorization) keys its
  # write gate on the same field and will traverse the same map. Whichever of
  # the two lands second deletes its copy and calls the shared predicate; a
  # traversal inlined into the `cond` above would make that a rewrite instead
  # of a deletion.
  #
  # `"assignee_type" => "agent"` is required EXPLICITLY. `Tasks`'s own
  # `per_phase_assignee/2` defaults a type-less `%{"assignee_id" => id}` slot
  # to "agent"; this does not. An untyped id could be a user id, and an
  # authorization path is the wrong place to guess which.
  @spec agent_in_phase_assignees?(map() | nil, binary()) :: boolean()
  defp agent_in_phase_assignees?(phase_assignees, agent_id) when is_map(phase_assignees) do
    Enum.any?(phase_assignees, fn
      {_phase, %{"assignee_id" => ^agent_id, "assignee_type" => "agent"}} -> true
      {_phase, _slot} -> false
    end)
  end

  defp agent_in_phase_assignees?(_phase_assignees, _agent_id), do: false

  # ── 3. :task_reader ───────────────────────────────────────────────────────
  #
  # Attached to a live task whose project org the viewer belongs to. Strict
  # `member_of?/2` — see the moduledoc on why `root_admin?/1` is not here.
  # `list_canvas_tasks/1` already drops soft-deleted tasks to `task: nil`, so a
  # grant cannot outlive the task that conferred it.

  defp task_reader?(%Canvas{id: canvas_id}, viewer) do
    canvas_id
    |> CanvasAttachments.list_canvas_tasks()
    |> Enum.map(fn %{task: task} -> task && task.project_id end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> project_org_ids()
    |> Enum.any?(&Tenancy.member_of?(viewer, &1))
  end

  # `projects.org_id` is NOT NULL at the database level (unlike `chat_spaces`,
  # where null org is the DM/group norm and has to be denied explicitly), so
  # there is no org-less-project arm to write here. A nil that somehow arrived
  # would still deny: `Tenancy.member_of?/2` guards on `is_binary/1`.
  defp project_org_ids([]), do: []

  defp project_org_ids(project_ids) do
    from(p in Project, where: p.id in ^project_ids, select: p.org_id)
    |> Repo.all()
    |> Enum.uniq()
  end

  # ── 4. :org_reader ────────────────────────────────────────────────────────

  defp org_reader?(%Canvas{space_id: space_id}, viewer) when is_binary(space_id) do
    # `space_accessible?/1` is the documented access gate for cross-space
    # surfaces: exists, not archived, not an execution space.
    Chat.space_accessible?(space_id) and org_readable_space?(space_id, viewer)
  end

  defp org_reader?(_canvas, _viewer), do: false

  defp org_readable_space?(space_id, viewer) do
    case Repo.one(from(s in Space, where: s.id == ^space_id, select: {s.kind, s.org_id})) do
      # Channels only, and only channels that carry an org. A null org_id is
      # every DM and every group conversation — see the moduledoc.
      {"channel", org_id} when is_binary(org_id) ->
        Tenancy.root_admin?(viewer) or Tenancy.member_of?(viewer, org_id)

      _ ->
        false
    end
  end

  # ── Audit ─────────────────────────────────────────────────────────────────

  # In-space reads (`:member`) and platform-initiated reads (`:system`) are not
  # audited: the first is already in-space and would bury the signal, the second
  # has no principal to attribute.
  defp maybe_audit(level, _canvas, _viewer, _opts) when level in [:member, :system], do: :ok

  defp maybe_audit(level, %Canvas{} = canvas, viewer, opts) do
    if Keyword.get(opts, :audit, true) do
      {actor_type, actor_id} = audit_actor(viewer)

      :telemetry.execute(
        @audit_event,
        %{system_time: System.system_time()},
        %{
          actor_id: actor_id,
          actor_type: actor_type,
          resource_type: "canvas",
          resource_id: canvas.id,
          action: "read",
          grant: level,
          space_id: canvas.space_id
        }
      )
    end

    :ok
  end

  # Derived from the actor tag rather than hardcoded. Since task 019fb01b
  # stage 2 this really does mint `"agent"` rows: `:task_agent` is an audited
  # level and agent-shaped. A hardcoded `"user"` here would now be a lie in the
  # audit stream rather than merely a latent one.
  defp audit_actor({:user, id}) when is_binary(id), do: {"user", id}
  defp audit_actor({:agent, id}) when is_binary(id), do: {"agent", id}
  defp audit_actor(_), do: {"user", nil}
end
