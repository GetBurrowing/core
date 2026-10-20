defmodule Platform.Security.TaskCanvasAttachmentAuthorizationTest do
  @moduledoc """
  The adversarial suite for the canvas-attachment task gate, driven over the
  real `/mcp` transport.

  History. Task 019fb581 put a six-path binding rule (assignee, phase
  assignee, execution-space participant, sponsor, project-org member,
  `:system`) in front of `task_attach_canvas`, `task_detach_canvas` and
  `task_list_canvases`. Task 01a1559a stage 1 deleted that rule and its
  module: the gate is now the rule every Tasks write is held to,
  `Platform.Access.task_target(scope, {:task, id}, "tasks.write")` on the
  caller's `%Platform.Access.Scope{}` (`"tasks.read"` for the list). Over
  federation that Scope is the calling runtime's `Scope.for_runtime/1`,
  fenced by its OWNER's org membership. An agent no longer has to be bound to
  the task to attach to it.

  Every authorization assertion below drives `POST /mcp` with a real runtime
  bearer token, because the context is BUILT by the transport
  (`PlatformWeb.MCPController.build_context/2`) and a test that writes its own
  context map cannot see what the transport actually carries.

  ## What the wire shows that `execute/3` cannot

    * **A foreign task is indistinguishable from a missing one on the two
      writes.** Both are in `@task_write_targets`, so the write intercept
      replaces a task id the caller may not write with a fresh UUID before the
      handler runs: a fenced runtime gets exactly the random-UUID answer
      ("Task not found"), and no denial event. The handler's own
      `:task_forbidden` arm is therefore unreachable over `/mcp` for those two
      tools; it is still live for an in-process caller with no scope, which is
      where the taxonomy sweep drives it.
    * **The read is not intercepted**, so a fenced runtime's
      `task_list_canvases` is refused by the gate itself: `task_forbidden`, as
      a machine-readable `code`, with one denial event. A refusal, never an
      empty list.
    * **The participant row the pre-plan design dispatch mints no longer
      decides anything** on these tools, in either direction (section 6).
    * **A runtime with no `agent_id` passes the task gate on its owner's
      standing** and is refused at the canvas conjunct, which has no principal
      to read the canvas with.

  ## Positive controls

  An absence assertion with nothing proving the probe could have fired passes
  vacuously. Every `refute` / `== []` / `== nil` below is paired, in the same
  test, with a positive control that fires the same probe against a granted
  call.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat
  alias Platform.Chat.Participant
  alias Platform.Design.PreplanStep
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.DesignTaskDirection
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachment
  alias Platform.Tasks.Task, as: TaskSchema
  alias Platform.Tenancy

  @denial_event [:platform, :tasks, :access_denied]

  # A title `Platform.Design.UiSurface.ui_task?/1` reads as a UI task, so the
  # pre-plan design step's annotations take their real branch rather than the
  # degenerate one. Borrowed verbatim from
  # `tool_surface_design_decline_test.exs` so the two files agree about what a
  # design-step task looks like.
  @ui_title "Add an epic-create FAB above the board"
  @decline_reason "The change is not visual; it deletes a deprecated module."

  setup do
    # The audit bridge is VM-global and other files detach it. Without this the
    # denial-row assertions would be testing an emit nobody listens to.
    Platform.TelemetryHelpers.ensure_boot_handler!(Platform.Audit.TelemetryHandler)

    %{org_a: Tenancy.get_org_by_slug!("globex"), org_b: Tenancy.get_org_by_slug!("initech")}
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp n, do: System.unique_integer([:positive])

  defp user! do
    Repo.insert!(%User{
      email: "tcaa-#{n()}@example.com",
      name: "Attachment Auth User",
      oidc_sub: "oidc-tcaa-#{n()}"
    })
  end

  defp agent! do
    Repo.insert!(%Agent{slug: "tcaa-agent-#{n()}", name: "TCAA Agent #{n()}", status: "active"})
  end

  defp project!(org) do
    {:ok, project} = Tasks.create_project(%{name: "TCAA Project #{n()}", org_id: org.id})
    project
  end

  defp task!(project, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(Map.merge(%{project_id: project.id, title: @ui_title}, attrs))

    task
  end

  # `planning_step` is deliberately absent from `Task.changeset/2`'s cast list,
  # so the narrow changeset is the only door onto it.
  defp open_design_step!(task) do
    task
    |> TaskSchema.planning_step_changeset(%{planning_step: "designing"})
    |> Repo.update!()
  end

  # `org` matters for a FENCED caller: the canvas conjunct reads with the
  # caller's Scope as `:access_scope` (task 01a1559a), and a canvas outside the
  # fence reads as not found. Org-less is fine for an unfenced (root-owned)
  # runtime.
  defp canvas_space!(org \\ nil) do
    {:ok, space} =
      Chat.create_space(%{
        name: "TCAA canvas #{n()}",
        slug: "tcaa-canvas-#{n()}",
        kind: "channel",
        org_id: org && org.id
      })

    space
  end

  defp canvas!(space) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Evidence canvas #{n()}"
      })

    canvas
  end

  # An MCP runtime bound to `agent`. By default it is owned by a root admin,
  # so its Scope is unfenced and holds `tasks.write` everywhere: the gate
  # passes and the test reaches whatever it is about. `owner: user` makes it
  # owned by that user instead, so its fence is that user's org membership
  # (see `fenced_token!/2`). `tool_profile` is a LITERAL list rather than
  # `Platform.Access.RuntimeProfiles.valid_modules()`: this file is about
  # authorization, and a capability refusal (`-32001`) would be a different
  # failure wearing the same red.
  defp runtime_token!(agent, bundles \\ ["task", "canvas"], opts \\ []) do
    {_runtime, raw} = runtime_with_token!(agent, bundles, opts)
    raw
  end

  defp runtime_with_token!(agent, bundles, opts) do
    raw = AgentRuntime.generate_token()
    owner = Keyword.get_lazy(opts, :owner, &Platform.TenancyFixtures.root_admin!/0)

    {:ok, runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "tcaa-rt-#{n()}",
        owner_user_id: owner.id,
        agent_id: agent && agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        runtime,
        bundles,
        Platform.Access.RuntimeProfiles.translated_permissions(bundles)
      )

    {runtime, raw}
  end

  # A runtime whose owner is a plain member of `org` and nothing else: fenced
  # to `org` through the runtime's `owner_cap`. Same bundles as the default,
  # so the ONLY thing that can refuse it on another org's task is the fence.
  defp fenced_token!(agent, org) do
    owner = user!()
    Platform.ExternalUserFixtures.plain_member!(owner, org)
    runtime_token!(agent, ["task", "canvas"], owner: owner)
  end

  # THE TRANSPORT. Everything authorization-shaped in this file goes through
  # here rather than through `ToolSurface.execute/3` — see the moduledoc.
  #
  # A FRESH conn per request, deliberately: `Phoenix.ConnTest` does not allow
  # a conn that has already been sent to be reused, and several tests below
  # make three or four calls with the same token.
  defp rpc!(token, method, params) do
    body = %{"jsonrpc" => "2.0", "id" => n(), "method" => method, "params" => params}

    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
    |> json_response(200)
  end

  defp call(_conn, token, tool, args) do
    rpc!(token, "tools/call", %{"name" => tool, "arguments" => args})
  end

  # `{:ok, payload}` / `{:error, envelope}` from a wire response, with the
  # JSON-RPC and content-block layers peeled off. Both arms decode the same
  # way; `isError` is the only discriminator, which is itself the contract
  # `mcp_controller_test.exs` pins.
  defp unwrap(%{"result" => %{"isError" => is_error, "content" => [%{"text" => text}]}}) do
    if is_error, do: {:error, Jason.decode!(text)}, else: {:ok, Jason.decode!(text)}
  end

  defp attach(conn, token, task, canvas, extra \\ %{}) do
    args = Map.merge(%{"task_id" => task.id, "canvas_id" => canvas.id}, extra)
    conn |> call(token, "task_attach_canvas", args) |> unwrap()
  end

  defp detach(conn, token, task, canvas) do
    conn
    |> call(token, "task_detach_canvas", %{"task_id" => task.id, "canvas_id" => canvas.id})
    |> unwrap()
  end

  defp list(conn, token, task_id) do
    conn |> call(token, "task_list_canvases", %{"task_id" => task_id}) |> unwrap()
  end

  # ── grant minting ─────────────────────────────────────────────────────────

  # A participant row in the task's execution space. Since task 01a1559a it
  # grants NOTHING on the canvas-attachment tools (the gate is `tasks.write`
  # in the task's org); kept so section 6 can show exactly that.
  defp grant_space_member!(task, agent) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    {:ok, participant} = Chat.add_agent_participant(space.id, agent)
    {space, participant}
  end

  # The canvas conjunct, which `task_attach_canvas` needs on top of the task
  # one. The two are independent.
  defp grant_canvas_read!(space, agent) do
    {:ok, participant} = Chat.add_agent_participant(space.id, agent)
    participant
  end

  # The answer the same token gets for a fresh random task id, read back as
  # `real_id`: what a refused id must be indistinguishable from.
  defp random_task_answer(conn, token, tool, real_id, extra) do
    random = Ecto.UUID.generate()

    conn
    |> call(token, tool, Map.put(extra, "task_id", random))
    |> unwrap()
    |> swap_id(random, real_id)
  end

  defp swap_id(term, from, to) when is_binary(term), do: String.replace(term, from, to)
  defp swap_id(term, from, to) when is_list(term), do: Enum.map(term, &swap_id(&1, from, to))

  defp swap_id(term, from, to) when is_tuple(term),
    do: term |> Tuple.to_list() |> swap_id(from, to) |> List.to_tuple()

  defp swap_id(term, from, to) when is_map(term),
    do: Map.new(term, fn {k, v} -> {swap_id(k, from, to), swap_id(v, from, to)} end)

  defp swap_id(term, _from, _to), do: term

  # A stack in `project` holding `task` as its only member.
  defp stack_with!(project, task) do
    slug = "tcaa-stack-#{n()}"

    {:ok, stack} =
      Platform.Tasks.Stacks.create_stack(%{
        project_id: project.id,
        slug: slug,
        name: "TCAA Stack",
        rollup_branch: "stack/#{slug}"
      })

    {:ok, _} = Platform.Tasks.Stacks.add_task(stack, task)
    stack
  end

  # ── probes ────────────────────────────────────────────────────────────────

  defp attachment_rows(task_id) do
    Repo.all(from(a in CanvasAttachment, where: a.task_id == ^task_id))
  end

  defp reload(task), do: Repo.get!(TaskSchema, task.id)

  defp responsibility do
    [spec] = DesignTaskDirection.register()
    struct!(Responsibility, Map.put(spec, :id, Ecto.UUID.generate()))
  end

  defp design_entry(task), do: (reload(task).planning_step_outcomes || %{})["design"]

  # Count raw `[:platform, :tasks, :access_denied]` emissions for the duration
  # of `fun`. The RAW event rather than the audit row: a denial naming an agent
  # by slug fails the audit changeset (`audit_events.actor_id` is a UUID) and is
  # logged instead of persisted, so counting rows would make the cardinality
  # assertion depend on a known-lossy sink.
  defp count_denials(fun) do
    id = "tcaa-denials-#{n()}"
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      id,
      @denial_event,
      fn _event, _measure, meta, _cfg -> send(parent, {ref, meta}) end,
      nil
    )

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      :telemetry.detach(id)
    end
  end

  defp drain(ref, acc) do
    receive do
      {^ref, meta} -> drain(ref, [meta | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Swap `Platform.Design.PreplanStep.settle/2` for a recorder. The seam is the
  # one `CanvasAttachments.tap_settle_design_step/1` already reads
  # (`:design_preplan_settler`), so this observes the REAL hook rather than a
  # parallel one. Restored unconditionally — it is application env, i.e. global.
  defp record_settles(fun) do
    parent = self()
    ref = make_ref()

    :persistent_term.put({__MODULE__, :settle_sink}, {parent, ref})
    previous = Application.get_env(:platform, :design_preplan_settler)
    Application.put_env(:platform, :design_preplan_settler, {__MODULE__, :__record_settle__})

    try do
      result = fun.()
      {result, drain(ref, [])}
    after
      if previous do
        Application.put_env(:platform, :design_preplan_settler, previous)
      else
        Application.delete_env(:platform, :design_preplan_settler)
      end

      :persistent_term.erase({__MODULE__, :settle_sink})
    end
  end

  @doc false
  def __record_settle__(task_id, attachment) do
    case :persistent_term.get({__MODULE__, :settle_sink}, nil) do
      {pid, ref} -> send(pid, {ref, {task_id, attachment}})
      nil -> :ok
    end

    # Still run the real settler, so "the step closed" in the positive control
    # is the production behaviour rather than this stub's absence of one.
    PreplanStep.settle(task_id, attachment)
  end

  # `:task_forbidden` on the two WRITES is unreachable over /mcp since task
  # 01a1559a: the write intercept and the handler's gate are the same
  # `tasks.write` rule, and the intercept answers first with the not-found
  # path. The arm is still live for an in-process caller with no scope
  # (the context `ToolSurface` sees when neither `:access_scope` nor
  # `:runtime_id` is set), so it is driven there, through
  # `ToolArguments.dispatch/3`, and the wire half is pinned separately.
  defp in_process_forbidden(tool, args, agent) do
    {:error, envelope} =
      Platform.Federation.ToolArguments.dispatch(tool, args, %{agent_id: agent.id})

    assert envelope.code == :task_forbidden
    :task_forbidden
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 1. The gate reads the runtime's Scope, not the context's keys
  # ══════════════════════════════════════════════════════════════════════════

  describe "the federated gate is the runtime's Scope" do
    # The rule since task 01a1559a stage 1: `tasks.write` on the task in its
    # org, decided on the calling runtime's `Scope.for_runtime/1` (fenced by
    # its owner). The agent need not be bound to the task in any way.
    test "a runtime holding tasks.write in the task's org attaches with no binding at all",
         %{org_a: org_a, conn: conn} do
      task = task!(project!(org_a))
      space = canvas_space!(org_a)
      canvas = canvas!(space)
      agent = agent!()
      grant_canvas_read!(space, agent)

      owner = user!()
      Platform.ExternalUserFixtures.plain_member!(owner, org_a)
      token = runtime_token!(agent, ["task", "canvas"], owner: owner)

      assert task.assignee_id != agent.id
      assert {:ok, exec_space} = ExecutionSpace.find_or_create(task.id)
      assert is_nil(Chat.get_agent_participant(exec_space.id, agent.id))

      assert {:ok, ok} = attach(conn, token, task, canvas)
      assert ok["task_id"] == task.id

      assert [row] = attachment_rows(task.id)
      assert row.attached_by_kind == "agent"
      assert row.attached_by_id == agent.id

      assert {:ok, %{"canvases" => [_]}} = list(conn, token, task.id)
      assert {:ok, %{"detached" => true}} = detach(conn, token, task, canvas)

      # …and the tools say so, rather than advertising the old binding rule.
      for name <- ~w(task_attach_canvas task_detach_canvas task_list_canvases) do
        tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == name))
        refute tool.limitations =~ "sponsor"
        assert tool.limitations =~ "tasks."
      end
    end

    # The Scope, not `agent_id`, is the authorization subject. A runtime with
    # no agent passes the task gate on its owner's standing and is then
    # refused at the canvas conjunct, which has no principal to read with.
    test "a runtime with no agent_id passes the task gate and has no canvas principal",
         %{org_a: org_a, conn: conn} do
      task = task!(project!(org_a))
      space = canvas_space!()
      canvas = canvas!(space)
      token = runtime_token!(nil)

      assert {:error, envelope} = attach(conn, token, task, canvas)
      assert envelope["error"] =~ "cannot read it"
      assert attachment_rows(task.id) == []

      assert {:ok, %{"canvases" => []}} = list(conn, token, task.id)

      assert {:error, %{"error" => "No attachment found" <> _}} =
               detach(conn, token, task, canvas)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. Cross-org: the fence, and a foreign task indistinguishable from none
  # ══════════════════════════════════════════════════════════════════════════

  describe "cross-boundary attach" do
    setup %{org_a: org_a, org_b: org_b} do
      target = task!(project!(org_a))

      # The caller is a fully legitimate agent: assignee of its OWN task in
      # org_b, a reader of the canvas, and its runtime holds tasks.write. Its
      # owner belongs to org_b only, so it is fenced out of org_a.
      agent = agent!()
      own_task = task!(project!(org_b), %{assignee_type: "agent", assignee_id: agent.id})

      space = canvas_space!(org_b)
      canvas = canvas!(space)
      grant_canvas_read!(space, agent)

      %{
        target: target,
        own_task: own_task,
        agent: agent,
        canvas: canvas,
        space: space,
        token: fenced_token!(agent, org_b)
      }
    end

    test "a fenced runtime gets the random-UUID answer for another org's task", ctx do
      args = %{"canvas_id" => ctx.canvas.id}

      for tool <- ~w(task_attach_canvas task_detach_canvas) do
        refused =
          ctx.conn |> call(ctx.token, tool, Map.put(args, "task_id", ctx.target.id)) |> unwrap()

        assert {:error, %{"error" => "Task not found: " <> _}} = refused
        assert refused == random_task_answer(ctx.conn, ctx.token, tool, ctx.target.id, args)
      end

      assert attachment_rows(ctx.target.id) == []

      # POSITIVE CONTROL: the same agent, same token, same canvas, against a
      # task in its own org. Without this the refusal could be a broken caller.
      assert {:ok, ok} = attach(ctx.conn, ctx.token, ctx.own_task, ctx.canvas)
      assert ok["task_id"] == ctx.own_task.id
    end

    # Being the task's assignee does not carry across the fence: the old
    # binding rule would have let this agent in; the one rule does not.
    test "an assignee whose runtime is fenced to another org is refused", ctx do
      bound = task!(project!(ctx.org_a), %{assignee_type: "agent", assignee_id: ctx.agent.id})

      assert {:error, %{"error" => "Task not found: " <> _}} =
               attach(ctx.conn, ctx.token, bound, ctx.canvas)

      assert attachment_rows(bound.id) == []
    end

    test "a runtime holding tasks.write in the org reaches every project in it",
         %{org_a: org_a, conn: conn} do
      agent = agent!()
      owner = user!()
      Platform.ExternalUserFixtures.plain_member!(owner, org_a)
      token = runtime_token!(agent, ["task", "canvas"], owner: owner)

      space = canvas_space!(org_a)
      canvas = canvas!(space)
      grant_canvas_read!(space, agent)

      for project <- [project!(org_a), project!(org_a)] do
        assert {:ok, _} = attach(conn, token, task!(project), canvas)
      end
    end

    # Mutual distinguishability of what an agent CAN act on, and the one pair
    # that must NOT be distinguishable: a foreign task and a missing task.
    test "canvas_forbidden and Task not found are distinct; foreign equals absent", ctx do
      unreadable = canvas!(canvas_space!(ctx.org_b))

      assert {:error, canvas_denied} = attach(ctx.conn, ctx.token, ctx.own_task, unreadable)
      assert {:error, foreign} = attach(ctx.conn, ctx.token, ctx.target, ctx.canvas)

      assert {:error, absent} =
               random_task_answer(ctx.conn, ctx.token, "task_attach_canvas", ctx.target.id, %{
                 "canvas_id" => ctx.canvas.id
               })

      refute Map.has_key?(canvas_denied, "code")
      assert canvas_denied["error"] =~ unreadable.id
      assert canvas_denied["error"] =~ "cannot read it"

      assert foreign["error"] =~ "Task not found"
      assert foreign == absent
      refute canvas_denied["error"] == foreign["error"]
    end

    # THE ORDER IS PART OF THE CONTRACT: the task door runs first, so the
    # attach surface is not an existence oracle for canvases in spaces the
    # caller is nowhere near.
    test "the task door answers before the canvas door", ctx do
      unreadable = canvas!(canvas_space!(ctx.org_b))

      # Both conjuncts fail. The caller must learn about the TASK.
      assert {:error, envelope} = attach(ctx.conn, ctx.token, ctx.target, unreadable)
      assert envelope["error"] =~ "Task not found"
      refute envelope["error"] =~ unreadable.id

      # POSITIVE CONTROL: the canvas half really is unsatisfiable, so the
      # assertion above is about ORDER and not about the canvas being fine.
      assert {:error, %{"error" => canvas_error}} =
               attach(ctx.conn, ctx.token, ctx.own_task, unreadable)

      assert canvas_error =~ "cannot read it"
    end

    # The read is gated with `tasks.read`, and it is not behind the write
    # intercept, so a fenced runtime gets the handler's own REFUSAL.
    test "task_list_canvases refuses a fenced runtime with task_forbidden", ctx do
      assert {:error, envelope} = list(ctx.conn, ctx.token, ctx.target.id)
      assert envelope["code"] == "task_forbidden"
      assert envelope["error"] =~ ctx.target.id

      assert {:ok, %{"canvases" => []}} = list(ctx.conn, ctx.token, ctx.own_task.id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. Side effects of a refusal, each paired with a positive control
  # ══════════════════════════════════════════════════════════════════════════

  describe "a refused attach leaves nothing behind" do
    setup %{org_a: org_a, org_b: org_b} do
      project = project!(org_a)
      space = canvas_space!()
      canvas = canvas!(space)

      stranger = agent!()
      grant_canvas_read!(space, stranger)

      %{
        project: project,
        space: space,
        canvas: canvas,
        stranger: stranger,
        fenced: fenced_token!(stranger, org_b),
        writer: runtime_token!(stranger)
      }
    end

    test "no attachment row is written, and the same probe sees one when granted", ctx do
      denied_task = task!(ctx.project)

      assert {:error, %{"error" => "Task not found" <> _}} =
               attach(ctx.conn, ctx.fenced, denied_task, ctx.canvas)

      assert attachment_rows(denied_task.id) == []

      # POSITIVE CONTROL for the counting probe itself.
      assert {:ok, _} = attach(ctx.conn, ctx.writer, denied_task, ctx.canvas)
      assert [_row] = attachment_rows(denied_task.id)
    end

    # Over /mcp the write intercept answers a fenced attach with the
    # not-found path, which emits nothing (the audit stream must not be an
    # existence oracle). The read is not intercepted, so its refusal is the
    # gate's own and emits exactly one event: the positive control that the
    # probe is attached and firing.
    test "a fenced attach emits no denial event; a fenced list emits exactly one", ctx do
      task = task!(ctx.project)

      {result, none} = count_denials(fn -> attach(ctx.conn, ctx.fenced, task, ctx.canvas) end)
      assert {:error, %{"error" => "Task not found" <> _}} = result
      assert none == []

      {result, denials} = count_denials(fn -> list(ctx.conn, ctx.fenced, task.id) end)
      assert {:error, %{"code" => "task_forbidden"}} = result

      assert [meta] = denials
      assert meta.resource_type == "task"
      assert meta.resource_id == task.id
      assert meta.actor_type == "agent"
      assert meta.actor_id == ctx.stranger.id
      assert meta.tool == "task_list_canvases"
      assert meta.project_id == ctx.project.id

      # And a granted call through the same code path emits nothing.
      {ok_result, quiet} = count_denials(fn -> attach(ctx.conn, ctx.writer, task, ctx.canvas) end)
      assert {:ok, _} = ok_result
      assert quiet == []
    end

    test "the design settler does not run, and runs for a granted attach", ctx do
      denied_task = ctx.project |> task!() |> open_design_step!()

      {result, settles} =
        record_settles(fn -> attach(ctx.conn, ctx.fenced, denied_task, ctx.canvas) end)

      assert {:error, %{"error" => "Task not found" <> _}} = result
      assert settles == []

      # POSITIVE CONTROL: the stub is wired to the REAL seam and does fire.
      granted_task = ctx.project |> task!() |> open_design_step!()

      {ok_result, fired} =
        record_settles(fn -> attach(ctx.conn, ctx.writer, granted_task, ctx.canvas) end)

      assert {:ok, _} = ok_result
      assert [{task_id, %CanvasAttachment{}}] = fired
      assert task_id == granted_task.id
    end

    test "a refused detach leaves the attachment row in place", ctx do
      task = task!(ctx.project)

      assert {:ok, _} = attach(ctx.conn, ctx.writer, task, ctx.canvas)
      assert [_row] = attachment_rows(task.id)

      assert {:error, %{"error" => "Task not found" <> _}} =
               detach(ctx.conn, ctx.fenced, task, ctx.canvas)

      assert [_still_there] = attachment_rows(task.id)

      # POSITIVE CONTROL for the deletion probe: the row IS deletable, by the
      # caller who may.
      assert {:ok, %{"detached" => true}} = detach(ctx.conn, ctx.writer, task, ctx.canvas)
      assert attachment_rows(task.id) == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5. The design step: refused, still open; granted, closed
  # ══════════════════════════════════════════════════════════════════════════

  describe "the pre-plan design step under the tasks.write gate" do
    # Over /mcp `task_attach_canvas` and `task_design_decline` sit behind the
    # SAME `tasks.write` write intercept, so a designer is either able to do
    # both or neither: there is no wire caller left who can decline but not
    # attach. The refused designer's step stays open for its deadline.
    test "a designer fenced out of the task's org is refused attach and decline alike",
         %{org_a: org_a, org_b: org_b, conn: conn} do
      task = org_a |> project!() |> task!() |> open_design_step!()

      space = canvas_space!()
      canvas = canvas!(space)
      designer = agent!()
      grant_canvas_read!(space, designer)
      token = fenced_token!(designer, org_b)

      assert {:error, %{"error" => "Task not found" <> _}} = attach(conn, token, task, canvas)

      assert {:error, _} =
               conn
               |> call(token, "task_design_decline", %{
                 "task_id" => task.id,
                 "reason" => @decline_reason
               })
               |> unwrap()

      # STILL OPEN, both halves: the cursor is unmoved and nothing recorded.
      assert reload(task).planning_step == "designing"
      assert design_entry(task) == nil

      # POSITIVE CONTROL: an in-org designer's decline DOES close a step, so
      # the nil above is an open step rather than a probe reading the wrong key.
      other = org_a |> project!() |> task!() |> open_design_step!()

      assert {:ok, %{"outcome" => "not_applicable"}} =
               conn
               |> call(runtime_token!(designer), "task_design_decline", %{
                 "task_id" => other.id,
                 "reason" => @decline_reason
               })
               |> unwrap()

      assert design_entry(other)["reason"] == "designer_declined"
    end

    test "a granted attach closes the step, with no space binding needed",
         %{org_a: org_a, conn: conn} do
      task = org_a |> project!() |> task!() |> open_design_step!()

      space = canvas_space!()
      canvas = canvas!(space)
      designer = agent!()
      grant_canvas_read!(space, designer)

      assert {:ok, _} = attach(conn, runtime_token!(designer), task, canvas)

      entry = design_entry(task)
      assert entry["outcome"] == "complete"
      refute reload(task).planning_step == "designing"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 6. The pre-plan designer's participant row no longer decides the attach
  # ══════════════════════════════════════════════════════════════════════════

  describe "the pre-plan designer's participant row" do
    # Before task 01a1559a the row `DispatchMembership.ensure_writable/3`
    # mints turned a denial into an attach (the `:space_member` grant). Now
    # the gate is `tasks.write` in the task's org, so the row changes nothing
    # in either direction. Both directions are asserted.
    test "the dispatch invite's row neither grants nor is needed",
         %{org_a: org_a, org_b: org_b, conn: conn} do
      task = org_a |> project!() |> task!() |> open_design_step!()
      space = canvas_space!()
      canvas = canvas!(space)
      designer = agent!()
      grant_canvas_read!(space, designer)
      fenced = fenced_token!(designer, org_b)

      {:ok, exec_space} = ExecutionSpace.find_or_create(task.id)

      assert {:ok, :invited} =
               Platform.Chat.DispatchMembership.ensure_writable(
                 exec_space.id,
                 designer.id,
                 source: :agent_responder
               )

      row = Chat.get_agent_participant(exec_space.id, designer.id)
      assert %Participant{} = row
      assert row.attention_mode == "all"

      # The row does not let a fenced runtime in…
      assert {:error, %{"error" => "Task not found" <> _}} = attach(conn, fenced, task, canvas)
      assert attachment_rows(task.id) == []

      # …and an in-org runtime needs no row (section 1 shows a task with none).
      assert {:ok, _} = attach(conn, runtime_token!(designer), task, canvas)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 7. The two non-MCP paths
  # ══════════════════════════════════════════════════════════════════════════

  describe "the Scope.system/0 responsibility path" do
    # `DesignTaskDirection` attaches with `Scope.system/0` because it creates
    # the canvas itself and the agent it attributes the work to is frequently
    # not a participant of the execution space.
    test "handle_output/3 still delivers a direction canvas end to end",
         %{org_a: org_a} do
      project = project!(org_a)
      task = task!(project)
      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      attributed = agent!()

      assert :ok =
               DesignTaskDirection.handle_output(
                 responsibility(),
                 %{"direction" => "## Direction\n\nOne signature element: the status pill."},
                 %{task_id: task.id, agent_id: attributed.id}
               )

      assert [attachment] = attachment_rows(task.id)
      assert attachment.attached_by_kind == "agent"
      assert attachment.attached_by_id == attributed.id

      canvas = Repo.get!(Platform.Chat.Canvas, attachment.canvas_id)
      assert canvas.space_id == space.id

      # The attributed agent is NOT a participant of that space, so an
      # implementation that authorized the canvas read as that agent instead
      # of `Scope.system/0` would have been refused here.
      assert is_nil(Chat.get_agent_participant(space.id, attributed.id))
    end

    test "Scope.system/0 attaches to a task nobody is bound to", %{org_a: org_a} do
      task = task!(project!(org_a))
      space = canvas_space!()
      canvas = canvas!(space)

      assert {:ok, _} =
               Platform.Tasks.CanvasAttachments.attach_canvas(
                 Platform.Access.Scope.system(),
                 task.id,
                 canvas.id,
                 attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
               )

      # POSITIVE CONTROL: the same call with no scope is refused, so the
      # success above is the system scope doing work rather than the gate
      # being absent.
      other = task!(project!(org_a))

      assert {:error, :task_forbidden} =
               Platform.Tasks.CanvasAttachments.attach_canvas(nil, other.id, canvas.id,
                 attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
               )
    end
  end

  describe "the human LiveView detach path" do
    # `TaskDetailComponent` passes the viewer's `@access_scope`. Driven through
    # the real LiveView rather than by calling `detach_canvas/3` with a
    # hand-made scope, because the assign wiring is the half a context-map
    # test cannot see: a missing assign is a nil scope, which the gate
    # refuses, silently, for every human.
    test "a project-org member can still detach a chip from the board",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      task = task!(project, %{status: "in_progress"})
      space = canvas_space!()
      canvas = canvas!(space)

      {:ok, _} =
        Platform.Tasks.CanvasAttachments.attach_canvas(
          Platform.Access.Scope.system(),
          task.id,
          canvas.id,
          attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
        )

      assert [_row] = attachment_rows(task.id)

      human = user!()
      Platform.ExternalUserFixtures.plain_member!(human, org_a)

      {:ok, view, _html} =
        conn
        |> init_test_session(current_user_id: human.id)
        |> live(~p"/tasks?task_id=#{task.id}")

      render_hook(detail(view), "detail_detach_canvas", %{"canvas-id" => canvas.id})

      assert attachment_rows(task.id) == []
    end

    # The absence half. A logged-in human outside the task's org is refused —
    # the handler ignores the result, so the chip simply comes back.
    test "a logged-in human with no standing on the task does not detach it",
         %{org_a: org_a, org_b: org_b, conn: conn} do
      project = project!(org_a)
      task = task!(project, %{status: "in_progress"})
      space = canvas_space!()
      canvas = canvas!(space)

      {:ok, _} =
        Platform.Tasks.CanvasAttachments.attach_canvas(
          Platform.Access.Scope.system(),
          task.id,
          canvas.id,
          attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
        )

      outsider = user!()
      Platform.ExternalUserFixtures.plain_member!(outsider, org_b)

      {:ok, view, _html} =
        conn
        |> init_test_session(current_user_id: outsider.id)
        |> live(~p"/tasks?task_id=#{task.id}")

      render_hook(detail(view), "detail_detach_canvas", %{"canvas-id" => canvas.id})

      # POSITIVE CONTROL is the test above: the identical hook, driven the
      # identical way, DOES delete the row for a member.
      assert [_still_there] = attachment_rows(task.id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 8. The error-taxonomy contract
  # ══════════════════════════════════════════════════════════════════════════

  describe "GUARD — the closed refusal taxonomy" do
    setup %{org_a: org_a, org_b: org_b} do
      project = project!(org_a)
      space = canvas_space!()
      canvas = canvas!(space)

      # An agent whose runtime holds `tasks.write` and the canvas read, so every
      # refusal below is reached deliberately rather than by tripping the first
      # door every time. `fenced` is the same agent fenced to org_b.
      agent = agent!()
      task = task!(project)
      grant_canvas_read!(space, agent)

      %{
        project: project,
        space: space,
        canvas: canvas,
        agent: agent,
        task: task,
        token: runtime_token!(agent),
        fenced: fenced_token!(agent, org_b)
      }
    end

    test "task_attach_canvas emits exactly its declared set", ctx do
      declared = ToolSurface.canvas_attachment_error_codes()["task_attach_canvas"]
      unreadable = canvas!(canvas_space!())

      cases = [
        {:task_not_found, %{"task_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}},
        {:task_not_found, %{"task_id" => "not-a-uuid", "canvas_id" => ctx.canvas.id}},
        {:canvas_forbidden, %{"task_id" => ctx.task.id, "canvas_id" => unreadable.id}},
        {:canvas_not_found, %{"task_id" => ctx.task.id, "canvas_id" => Ecto.UUID.generate()}},
        {:canvas_not_found, %{"task_id" => ctx.task.id, "canvas_id" => "not-a-uuid"}}
      ]

      wire = drive(ctx.conn, ctx.token, "task_attach_canvas", cases)

      # The foreign task, over the wire, is the not-found path.
      fenced =
        drive(ctx.conn, ctx.fenced, "task_attach_canvas", [
          {:task_not_found, %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id}}
        ])

      forbidden =
        in_process_forbidden(
          "task_attach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          ctx.agent
        )

      observed = wire |> MapSet.union(fenced) |> MapSet.put(forbidden)
      assert observed == MapSet.new(declared), taxonomy_message(observed, declared)

      # PAIRED CONTROL for the whole sweep: a clause that refused EVERYTHING
      # would satisfy every assertion above.
      assert {:ok, _} = attach(ctx.conn, ctx.token, ctx.task, ctx.canvas)
    end

    test "task_detach_canvas emits exactly its declared set", ctx do
      declared = ToolSurface.canvas_attachment_error_codes()["task_detach_canvas"]

      cases = [
        {:task_not_found, %{"task_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}},
        # Task reachable, no such attachment pair.
        {:not_found, %{"task_id" => ctx.task.id, "canvas_id" => Ecto.UUID.generate()}}
      ]

      wire = drive(ctx.conn, ctx.token, "task_detach_canvas", cases)

      forbidden =
        in_process_forbidden(
          "task_detach_canvas",
          %{"task_id" => ctx.task.id, "canvas_id" => ctx.canvas.id},
          ctx.agent
        )

      observed = MapSet.put(wire, forbidden)
      assert observed == MapSet.new(declared), taxonomy_message(observed, declared)

      # PAIRED CONTROL.
      assert {:ok, _} = attach(ctx.conn, ctx.token, ctx.task, ctx.canvas)
      assert {:ok, %{"detached" => true}} = detach(ctx.conn, ctx.token, ctx.task, ctx.canvas)
    end

    test "task_list_canvases emits exactly its declared set", ctx do
      declared = ToolSurface.canvas_attachment_error_codes()["task_list_canvases"]

      wire =
        drive(ctx.conn, ctx.token, "task_list_canvases", [
          {:task_not_found, %{"task_id" => Ecto.UUID.generate()}},
          {:task_not_found, %{"task_id" => "not-a-uuid"}}
        ])

      fenced =
        drive(ctx.conn, ctx.fenced, "task_list_canvases", [
          {:task_forbidden, %{"task_id" => ctx.task.id}}
        ])

      observed = MapSet.union(wire, fenced)
      assert observed == MapSet.new(declared), taxonomy_message(observed, declared)

      # PAIRED CONTROL, and the decision stage 4 recorded: a REFUSAL, never an
      # empty list. `[]` is still the honest answer for a task with nothing
      # attached.
      assert {:ok, %{"canvases" => []}} = list(ctx.conn, ctx.token, ctx.task.id)
    end

    # Task 01a1559a stage 2: the stack pair. The fenced caller reaches the
    # not-found arm through the `@task_write_targets` swap, as on the task
    # tools, so `:task_forbidden` is driven in-process.
    test "stack_attach_canvas emits exactly its declared set", ctx do
      declared = ToolSurface.canvas_attachment_error_codes()["stack_attach_canvas"]
      stack = stack_with!(ctx.project, ctx.task)
      unreadable = canvas!(canvas_space!())

      cases = [
        {:stack_not_found, %{"stack_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}},
        {:stack_not_found, %{"stack_id" => "not-a-uuid", "canvas_id" => ctx.canvas.id}},
        {:canvas_forbidden, %{"stack_id" => stack.id, "canvas_id" => unreadable.id}},
        {:canvas_not_found, %{"stack_id" => stack.id, "canvas_id" => Ecto.UUID.generate()}},
        {:canvas_not_found, %{"stack_id" => stack.id, "canvas_id" => "not-a-uuid"}}
      ]

      wire = drive(ctx.conn, ctx.token, "stack_attach_canvas", cases)

      fenced =
        drive(ctx.conn, ctx.fenced, "stack_attach_canvas", [
          {:stack_not_found, %{"stack_id" => stack.id, "canvas_id" => ctx.canvas.id}}
        ])

      forbidden =
        in_process_forbidden(
          "stack_attach_canvas",
          %{"stack_id" => stack.id, "canvas_id" => ctx.canvas.id},
          ctx.agent
        )

      observed = wire |> MapSet.union(fenced) |> MapSet.put(forbidden)
      assert observed == MapSet.new(declared), taxonomy_message(observed, declared)

      # PAIRED CONTROL.
      assert {:ok, %{"attached_count" => 1}} =
               ctx.conn
               |> call(ctx.token, "stack_attach_canvas", %{
                 "stack_id" => stack.id,
                 "canvas_id" => ctx.canvas.id
               })
               |> unwrap()
    end

    test "stack_detach_canvas emits exactly its declared set", ctx do
      declared = ToolSurface.canvas_attachment_error_codes()["stack_detach_canvas"]
      stack = stack_with!(ctx.project, ctx.task)

      wire =
        drive(ctx.conn, ctx.token, "stack_detach_canvas", [
          {:stack_not_found, %{"stack_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}}
        ])

      fenced =
        drive(ctx.conn, ctx.fenced, "stack_detach_canvas", [
          {:stack_not_found, %{"stack_id" => stack.id, "canvas_id" => ctx.canvas.id}}
        ])

      forbidden =
        in_process_forbidden(
          "stack_detach_canvas",
          %{"stack_id" => stack.id, "canvas_id" => ctx.canvas.id},
          ctx.agent
        )

      observed = wire |> MapSet.union(fenced) |> MapSet.put(forbidden)
      assert observed == MapSet.new(declared), taxonomy_message(observed, declared)

      # PAIRED CONTROL.
      assert {:ok, %{"detached_count" => 0, "skipped_count" => 1}} =
               ctx.conn
               |> call(ctx.token, "stack_detach_canvas", %{
                 "stack_id" => stack.id,
                 "canvas_id" => ctx.canvas.id
               })
               |> unwrap()
    end

    test "every declared code is named in the tool's limitations prose" do
      for {name, declared} <- ToolSurface.canvas_attachment_error_codes() do
        tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == name))
        assert tool, "#{name} is not in tool_definitions/0"

        documented =
          declared
          |> Enum.filter(&(tool.limitations =~ "`#{&1}`"))
          |> MapSet.new()

        assert documented == MapSet.new(declared),
               """
               #{name}: every code the clause can emit must be named in `limitations`.
               Missing: #{inspect(MapSet.difference(MapSet.new(declared), documented))}
               """
      end
    end

    # THE ASYMMETRY, PINNED. Only `:task_forbidden` and, since task 01a1559a
    # stage 2, the stack tools' `:stack_not_found` reach the caller as a
    # machine-readable `code`; the rest are prose in `error`.
    test "exactly the declared codes arrive as a machine-readable `code` key", ctx do
      coded = MapSet.new(ToolSurface.canvas_attachment_coded_errors())
      unreadable = canvas!(canvas_space!())

      probes = [
        {:task_forbidden, ctx.fenced, "task_list_canvases", %{"task_id" => ctx.task.id}},
        {:stack_not_found, ctx.token, "stack_attach_canvas",
         %{"stack_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}},
        {:task_not_found, ctx.token, "task_attach_canvas",
         %{"task_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}},
        {:canvas_forbidden, ctx.token, "task_attach_canvas",
         %{"task_id" => ctx.task.id, "canvas_id" => unreadable.id}},
        {:canvas_not_found, ctx.token, "task_attach_canvas",
         %{"task_id" => ctx.task.id, "canvas_id" => Ecto.UUID.generate()}},
        {:not_found, ctx.token, "task_detach_canvas",
         %{"task_id" => ctx.task.id, "canvas_id" => Ecto.UUID.generate()}}
      ]

      observed_coded =
        for {label, token, tool, args} <- probes,
            {:error, envelope} = ctx.conn |> call(token, tool, args) |> unwrap(),
            Map.has_key?(envelope, "code"),
            into: MapSet.new() do
          assert envelope["code"] == to_string(label),
                 "#{tool} #{label}: code was #{inspect(envelope["code"])}"

          label
        end

      assert observed_coded == coded,
             """
             The set of refusals carrying a machine-readable `code` changed.
             Now coded but undeclared: #{inspect(MapSet.difference(observed_coded, coded))}
             Declared but no longer coded: #{inspect(MapSet.difference(coded, observed_coded))}
             """
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 8b. The hosted transport carries the id keys — found by driving the wire
  # ══════════════════════════════════════════════════════════════════════════

  describe "the hosted transport carries the id keys" do
    # `MCPController.error_envelope/1` was once a fixed four-key allowlist that
    # dropped `task_id` and `canvas_id`; task 01a01b75 widened it. This test
    # keeps its shape: the exact key set, asserted both ways, on the two
    # refusals that still reach a hosted caller with an id key — the read's
    # `task_forbidden` and the attach's `canvas_forbidden`.
    test "task_id and canvas_id are set by the handler and survive /mcp",
         %{org_a: org_a, org_b: org_b, conn: conn} do
      project = project!(org_a)
      target = task!(project)
      space = canvas_space!()
      canvas = canvas!(space)

      agent = agent!()
      grant_canvas_read!(space, agent)
      {runtime, token} = runtime_with_token!(agent, ["task", "canvas"], [])
      fenced = fenced_token!(agent, org_b)

      # POSITIVE CONTROL: the handler DOES set both keys. Read directly off
      # `execute/3`, exactly as the unit tests read it.
      assert {:error, handler_task} =
               ToolSurface.execute(
                 "task_attach_canvas",
                 %{"task_id" => target.id, "canvas_id" => canvas.id},
                 %{agent_id: agent.id}
               )

      assert handler_task.task_id == target.id

      unreadable = canvas!(canvas_space!())

      assert {:error, handler_canvas} =
               ToolSurface.execute(
                 "task_attach_canvas",
                 %{"task_id" => target.id, "canvas_id" => unreadable.id},
                 %{runtime_id: runtime.runtime_id, agent_id: agent.id}
               )

      assert handler_canvas.canvas_id == unreadable.id

      # …and both survive the projection, carrying the id the CALLER
      # supplied — not one it could not already name.
      assert {:error, wire_task} = list(conn, fenced, target.id)
      assert wire_task["task_id"] == target.id

      assert {:error, wire_canvas} = attach(conn, token, target, unreadable)
      assert wire_canvas["canvas_id"] == unreadable.id

      assert Map.keys(wire_task) |> Enum.sort() ==
               ["code", "error", "recoverable", "suggestion", "task_id"]

      assert Map.keys(wire_canvas) |> Enum.sort() ==
               ["canvas_id", "error", "recoverable", "suggestion"]
    end

    # The ids are recoverable from the `error` sentence. If someone shortens
    # those strings, the id becomes unavailable by ANY route, and this goes red.
    test "the ids are recoverable from the error sentence on all three tools",
         %{org_a: org_a, org_b: org_b, conn: conn} do
      project = project!(org_a)
      target = task!(project)
      space = canvas_space!()
      canvas = canvas!(space)

      agent = agent!()
      grant_canvas_read!(space, agent)
      token = fenced_token!(agent, org_b)

      assert {:error, %{"error" => a}} = attach(conn, token, target, canvas)
      assert {:error, %{"error" => d}} = detach(conn, token, target, canvas)
      assert {:error, %{"error" => l}} = list(conn, token, target.id)

      for sentence <- [a, d, l], do: assert(sentence =~ target.id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 9. The transport gap, as an executable claim
  # ══════════════════════════════════════════════════════════════════════════

  describe "GUARD — limitations DOES reach a hosted runtime, folded into description" do
    # INVERTED by task 01a08a0c stage 1. Read the history, because the
    # inversion is the whole content of this block.
    #
    # Stage 4 of task 019fb581 found that the refusal taxonomy these tests pin
    # shipped only on the WebSocket capabilities push: an agent on `/mcp` got
    # `description` and `inputSchema` and nothing else, so it learned the gate
    # existed only by being refused by it. `canvas_create` worked around that
    # by hand-duplicating its boundary sentence into `description`. Stage 4
    # decided NOT to do the same for these three and wrote a guard recording
    # the decision — the version of this test that asserted the taxonomy did
    # NOT survive the projection.
    #
    # That decision has now been reversed, and by the general route rather than
    # by more hand-duplication: `PlatformWeb.MCPController.to_mcp_tool/1` runs
    # `Platform.Federation.ToolDoc.render_description/1`, which appends the
    # non-blank `returns` / `limitations` / `when_to_use` prose to
    # `description` under stable headings, original text first and unmodified.
    #
    # WHAT DID NOT CHANGE, and is still asserted below: the MCP tool object's
    # key set. The fix adds no sibling JSON keys, deliberately — the tool
    # object is a closed schema, so a client may drop keys it does not know and
    # sibling keys would have been a no-op that looked fixed in the diff.
    test "tools/list folds limitations into description and adds no new keys" do
      token = runtime_token!(agent!(), ["task"])

      %{"result" => %{"tools" => tools}} = rpc!(token, "tools/list", %{})

      for name <- ~w(task_attach_canvas task_detach_canvas task_list_canvases) do
        wire = Enum.find(tools, &(&1["name"] == name))
        assert wire, "#{name} missing from tools/list"

        # `_meta` joined this list in task 01a049de; it carries
        # `anthropic/maxResultSizeChars` and nothing else. The whitelist is
        # still exact — a new key has to be added here deliberately.
        assert Map.keys(wire) |> Enum.sort() == ["_meta", "description", "inputSchema", "name"]
        assert Map.keys(wire["_meta"]) == ["anthropic/maxResultSizeChars"]

        # The whitelist above is a proxy for the property this guard actually
        # exists to defend, so state the property outright as well: none of the
        # internal documentation keys reach a hosted runtime, whatever the
        # projection's key set happens to be. Key equality alone would have to
        # be re-reasoned about every time a legitimate key is added — this
        # assertion does not.
        for internal <- ~w(limitations returns when_to_use bundle parameters) do
          refute Map.has_key?(wire, internal),
                 "#{name} leaked #{internal} to a hosted runtime"
        end

        definition = Enum.find(ToolSurface.tool_definitions(), &(&1.name == name))

        # POSITIVE CONTROL for the absence probe, twice: the field EXISTS and
        # is non-trivial in the definition map, and a field that DOES survive
        # the projection is found by the same lookup. Without both halves this
        # test would pass against a tool with no `limitations` at all, or
        # against a `tools/list` that returned nothing useful.
        assert is_binary(definition.limitations) and byte_size(definition.limitations) > 200
        assert String.starts_with?(wire["description"], definition.description)

        # …and the taxonomy specifically DOES survive now, by riding in the
        # appended `Limitations:` block rather than as a key of its own.
        assert wire["description"] =~ "task_forbidden"
      end
    end
  end

  # ── taxonomy sweep helpers ────────────────────────────────────────────────

  # Drive each `{expected, args}` pair over the real transport and collect the
  # refusal atoms actually produced. Returns a `MapSet` for comparison against
  # the declared set.
  defp drive(conn, token, tool, cases) do
    for {expected, args} <- cases, into: MapSet.new() do
      assert {:error, envelope} = conn |> call(token, tool, args) |> unwrap(),
             "#{tool}: expected #{expected} for #{inspect(args)}, got a success"

      assert is_binary(envelope["error"]) and envelope["error"] != ""
      assert is_binary(envelope["suggestion"]) and envelope["suggestion"] != ""
      assert envelope["recoverable"] == false

      observed = classify(envelope)

      assert observed == expected,
             "#{tool} #{inspect(args)}: expected #{expected}, classified #{observed} " <>
               "from #{inspect(envelope)}"

      observed
    end
  end

  # Recover the `CanvasAttachments` refusal atom from the wire envelope.
  #
  # Only `:task_forbidden` carries a `code`, so the other four have to be read
  # off `error`. That is the asymmetry `@canvas_attachment_coded_errors` pins,
  # and writing this function is what makes the cost of it concrete: a REMOTE
  # RUNTIME has to do exactly this string-matching to tell four of the five
  # refusals apart.
  defp classify(%{"code" => code}), do: String.to_existing_atom(code)

  defp classify(%{"error" => error}) do
    cond do
      error =~ "Task not found" -> :task_not_found
      error =~ "Canvas not found" -> :canvas_not_found
      error =~ "because you cannot read it" -> :canvas_forbidden
      error =~ "No attachment found" -> :not_found
      true -> flunk("unclassifiable refusal: #{error}")
    end
  end

  defp taxonomy_message(observed, declared) do
    declared = MapSet.new(declared)

    """
    The emitted taxonomy and the declared one disagree.
    Emitted-but-undeclared: #{inspect(MapSet.difference(observed, declared))}
    Declared-but-unexercised: #{inspect(MapSet.difference(declared, observed))}
    """
  end

  # Task 01a008f6 stage 4: the task detail panel, inline editor and plan
  # approval UI are a LiveComponent. Their events carry `phx-target`, so
  # tests must address the component rather than the parent LiveView.
  defp detail(view), do: Phoenix.LiveViewTest.with_target(view, "#tasks-detail")
end
