defmodule Platform.Security.TaskCanvasAttachmentAuthorizationTest do
  @moduledoc """
  Stage 5 of task 019fb581 — the adversarial suite for the canvas-attachment
  task gate.

  Stages 3 and 4 put `Platform.Tasks.TaskAccess` in front of
  `task_attach_canvas`, `task_detach_canvas` and `task_list_canvases`, and
  tested it by calling `ToolSurface.execute/3` with a hand-written context map.
  This file exists because that is exactly the shape of test that can pass
  while the shipped system is wrong: the context is BUILT by the transport
  (`PlatformWeb.MCPController.build_context/2`), so a test that writes its own
  cannot see a context that stops carrying `agent_id` — or one that never
  carried the key the gate reads in the first place.

  Every authorization assertion below therefore drives `POST /mcp` with a real
  runtime bearer token. The unit tests keep the `CanvasAttachments` boundary
  honest; this file keeps the WIRE honest.

  ## What driving the real transport caught that the unit tests could not

  Three things, all live on `main` after stage 4 and none visible from
  `execute/3`:

    0. **The `task_id` key stage 3 added to every denial never reaches an HTTP
       caller.** `MCPController.error_envelope/1` is a fixed four-key allowlist
       (`error`, `code`, `recoverable`, `suggestion`) and discards the rest, so
       `task_id` — and `canvas_id` on the older canvas refusal — are dropped on
       `/mcp` while the WebSocket runtime channel pushes the map intact.
       `tool_surface_test.exs` asserts `error.task_id == ctx.task.id` and
       passes, because it reads the handler's return value rather than the
       wire. Pinned by the `"the hosted transport drops the id keys"` block,
       and NOT fixed here: widening that allowlist changes the refusal envelope
       of every tool in the surface.

    1. **Two of the six advertised grant paths are unreachable over federation.**
       `build_context/2` (`mcp_controller.ex:116-126`) and
       `RuntimeChannel.execute_tool_call/4` (`runtime_channel.ex:566-571`) both
       build a context carrying `agent_id` and never `user_id`, so
       `ToolSurface.canvas_authorization_actor/1` can only ever produce
       `{:agent, _}` or `nil` on a federated call. `TaskAccess` short-circuits
       `{:agent, _}` after path 4 BY DESIGN (agents have no org membership), so
       `:sponsor` and `:project_member` are dead over both transports — while
       all three tools' `limitations` prose advertises them to the agent
       reading it. Pinned by `"the sponsor and project-member grant paths are
       unreachable over federation"` below.

       `tool_surface_test.exs`'s `"authorizes a participating user via
       :user_id"` passes against a context shape no transport produces. It is
       not wrong — the `:user_id` branch is real for in-process callers — but
       it is not evidence about the hosted surface, and stage 3 read it as if
       it were.

    2. **A runtime with no `agent_id` is denied on all three tools.**
       `agent_runtimes.agent_id` is nullable and unset by default
       (`agent_runtime.ex:24`, absent from `validate_required/2`), and such a
       runtime authenticates fine and passes `ToolAuthorization`. Before stage
       3 it could detach and list freely because those clauses ignored their
       context. It now has no principal at all. Pinned below.

  ## Verification labels

  DETECTOR where the assertion detonates against pre-stage-3 behaviour (every
  denial test: the gates did not exist). GUARD where it pins behaviour that is
  new in this stack and has no prior state to be wrong (the taxonomy contract).

  ## Positive controls

  This file's own instruction, and the one most easily skipped. An absence
  assertion with nothing proving the probe could have fired passes vacuously.
  Every `refute` / `== 0` / `== nil` below is paired, in the same test, with a
  positive control that fires the same probe against a granted call:

    * no attachment row → the granted attach writes one, counted the same way
    * no denial telemetry on success → the denied call emits exactly one,
      through the same handler
    * the settler did not run → the granted attach runs it, through the same
      injected stub
    * the design step stayed open → the granted attach closes it
    * `limitations` is absent from the wire → `description` is present on the
      same payload, and `limitations` is present in `tool_definitions/0`

  ## Two corrections to the stage-5 brief, recorded rather than silently applied

    * The brief asks for the designer's participant row to be asserted with
      `attention_mode == "mention"`. It is `"all"`:
      `DispatchMembership.attention_mode/1` (`dispatch_membership.ex:355-356`)
      returns `"all"` for `kind == "execution"`, and an execution space is
      exactly what the pre-plan designer is bound to. The value is also moot
      post-ADR-0027, which is why the assertion below pins the row's EXISTENCE
      and its EFFECT (it grants the attach) and records the string only as
      current data.
    * The brief justifies the taxonomy contract with "remote runtimes branch
      on it". They cannot: `MCPController.to_mcp_tool/1` forwards only `name`,
      `description` and `inputSchema`, so `limitations` reaches nobody over
      `/mcp`. Stage 4 found this and recorded it in a comment; this file makes
      it an executable claim instead, so the day someone widens the forwarder
      the decision gets re-read rather than silently reversed.

  ## Scope fence, demonstrated and NOT papered over

  `architecture.review_plan` and `architecture.audit_diff` fire against a task
  they have no binding to. Neither handler sets `:dispatch_space_id`, so
  `Router.put_dispatch_space/2` writes no `metadata.space_id`,
  `AgentResponder.dispatch_space_id/1` reads nil and no participant row is ever
  minted for them. That is the opt-in design working as intended — granting one
  would hand them the execution space's whole message history — and they are
  therefore denied by this gate. It is a known open decision owned by Marlowe,
  not a bug for this stage to fix by widening grants. The test named for it
  below asserts the denial as the CURRENT contract so the decision stays
  visible; it does not assert that the denial is correct.
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

    %{org_a: Tenancy.get_org_by_slug!("sxi"), org_b: Tenancy.get_org_by_slug!("soylent")}
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

  defp canvas_space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "TCAA canvas #{n()}",
        slug: "tcaa-canvas-#{n()}",
        kind: "channel"
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

  # An MCP runtime bound to `agent`. `allowed_bundles` is a LITERAL list rather
  # than `AgentRuntime.valid_bundles()`: this file is about authorization, and
  # a capability refusal (`-32001`) would be a different failure wearing the
  # same red.
  defp runtime_token!(agent, bundles \\ ["task", "canvas"]) do
    raw = AgentRuntime.generate_token()

    {:ok, _runtime} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "tcaa-rt-#{n()}",
        owner_user_id: user!().id,
        agent_id: agent && agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw),
        status: "active",
        allowed_bundles: bundles
      })
      |> Repo.insert()

    raw
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

  # `:space_member`, via the task's execution space. This is the shape stage 2
  # mints for a dispatched pre-plan designer, and it is minted WITHOUT touching
  # the assignee columns: `Tasks.set_phase_assignees/2` re-derives the
  # top-level assignee from the current phase and would strip a grant set that
  # way.
  defp grant_space_member!(task, agent) do
    {:ok, space} = ExecutionSpace.find_or_create(task.id)
    {:ok, participant} = Chat.add_agent_participant(space.id, agent)
    {space, participant}
  end

  # The canvas conjunct, which `task_attach_canvas` needs on top of the task
  # one. Kept separate from `grant_space_member!/2` because the whole point of
  # the attach gate is that the two are independent.
  defp grant_canvas_read!(space, agent) do
    {:ok, participant} = Chat.add_agent_participant(space.id, agent)
    participant
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
  # of `fun`. The RAW event rather than the audit row: `TaskAccess`'s moduledoc
  # records that a denial naming an agent by slug fails the audit changeset and
  # is logged instead of persisted, so counting rows would make the cardinality
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

  # ══════════════════════════════════════════════════════════════════════════
  # 1. What the real transport caught and `execute/3` could not
  # ══════════════════════════════════════════════════════════════════════════

  describe "the federated context is the gate's only input" do
    # DETECTOR against the stage-3/4 test strategy rather than against its
    # code: `tool_surface_test.exs` proves the `:user_id` branch works by
    # writing `%{user_id: ...}` itself. No transport does.
    test "the sponsor and project-member grant paths are unreachable over federation",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      sponsor = user!()

      # A user who holds BOTH user-only grants: sponsor of the task, and a
      # member of its project's org.
      Platform.ExternalUserFixtures.plain_member!(sponsor, org_a)
      task = task!(project, %{sponsor_user_id: sponsor.id})

      space = canvas_space!()
      canvas = canvas!(space)

      # In-process, that user is authorized — twice over. This is the POSITIVE
      # CONTROL for the refutation below: it proves the grants are real and the
      # probe is capable of resolving them.
      assert {:ok, _task, :sponsor} =
               Platform.Tasks.TaskAccess.fetch_for_actor(task.id, {:user, sponsor.id})

      other_member = user!()
      Platform.ExternalUserFixtures.plain_member!(other_member, org_a)

      assert {:ok, _task, :project_member} =
               Platform.Tasks.TaskAccess.fetch_for_actor(task.id, {:user, other_member.id})

      # Over the wire, the SAME human cannot exercise either. A runtime is
      # owned by a user, and that ownership is what makes this sharp: the
      # runtime below is owned by the sponsor, and `build_context/2` still
      # never puts `owner_user_id` in the context.
      agent = agent!()
      grant_canvas_read!(space, agent)
      raw = AgentRuntime.generate_token()

      {:ok, _rt} =
        %AgentRuntime{}
        |> AgentRuntime.changeset(%{
          runtime_id: "tcaa-rt-#{n()}",
          owner_user_id: sponsor.id,
          agent_id: agent.id,
          auth_token_hash: AgentRuntime.hash_token(raw),
          status: "active",
          allowed_bundles: ["task", "canvas"]
        })
        |> Repo.insert()

      assert {:error, envelope} = attach(conn, raw, task, canvas)
      assert envelope["code"] == "task_forbidden"

      # …and the tools tell the agent otherwise, in all three `limitations`.
      # Pinned so that closing the gap (either by carrying the owner into the
      # context, or by deleting the claim) has to touch this test.
      for name <- ~w(task_attach_canvas task_detach_canvas task_list_canvases) do
        tool = Enum.find(ToolSurface.tool_definitions(), &(&1.name == name))
        assert tool.limitations =~ "sponsor"
        assert tool.limitations =~ "org"
      end
    end

    # DETECTOR. Before stage 3 this runtime could detach and list freely,
    # because both clauses ignored their context entirely.
    test "a runtime with no agent_id has no principal on any of the three tools",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      task = task!(project)
      space = canvas_space!()
      canvas = canvas!(space)

      # `agent_id` is nullable and unset by default — this is a legal, active,
      # authenticating runtime, not a malformed fixture.
      token = runtime_token!(nil)

      assert {:error, %{"code" => "task_forbidden"}} = attach(conn, token, task, canvas)
      assert {:error, %{"code" => "task_forbidden"}} = detach(conn, token, task, canvas)
      assert {:error, %{"code" => "task_forbidden"}} = list(conn, token, task.id)

      # POSITIVE CONTROL: the same runtime authenticates and is capability-
      # authorized, so the three refusals above are authorization decisions
      # rather than a 401 or a `-32001` wearing the same red.
      %{"result" => %{"isError" => false}} =
        call(conn, token, "task_get", %{"task_id" => task.id})
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 2. Cross-org and cross-project, and the three refusals kept distinct
  # ══════════════════════════════════════════════════════════════════════════

  describe "cross-boundary attach" do
    setup %{org_a: org_a, org_b: org_b} do
      target = task!(project!(org_a))

      # The caller is a fully legitimate agent — assignee of its OWN task in
      # another org, and a reader of the canvas. The only thing it lacks is a
      # binding to `target`.
      agent = agent!()
      own_task = task!(project!(org_b), %{assignee_type: "agent", assignee_id: agent.id})

      space = canvas_space!()
      canvas = canvas!(space)
      grant_canvas_read!(space, agent)

      %{target: target, own_task: own_task, agent: agent, canvas: canvas, space: space}
    end

    # DETECTOR: pre-stage-3 this attach succeeded.
    test "an agent bound to a task in another org cannot attach to this one", ctx do
      token = runtime_token!(ctx.agent)

      assert {:error, envelope} = attach(ctx.conn, token, ctx.target, ctx.canvas)
      assert envelope["code"] == "task_forbidden"
      assert envelope["recoverable"] == false
      assert envelope["error"] =~ "Access denied"
      assert envelope["suggestion"] =~ "task_design_decline"

      # The task id is NOT in the envelope, even though stage 3 put it there.
      # See `"the hosted transport drops the id keys"` below — the id survives
      # in the sentence, which is the only reason this refusal is still
      # actionable.
      refute Map.has_key?(envelope, "task_id")
      assert envelope["error"] =~ ctx.target.id

      # POSITIVE CONTROL: the same agent, same token, same canvas, against the
      # task it IS bound to. Without this the denial could be a broken caller.
      assert {:ok, ok} = attach(ctx.conn, token, ctx.own_task, ctx.canvas)
      assert ok["task_id"] == ctx.own_task.id
    end

    test "an agent bound to a task in another project of the SAME org is still denied",
         %{org_a: org_a, conn: conn} do
      agent = agent!()
      target = task!(project!(org_a))
      own = task!(project!(org_a), %{assignee_type: "agent", assignee_id: agent.id})

      space = canvas_space!()
      canvas = canvas!(space)
      grant_canvas_read!(space, agent)
      token = runtime_token!(agent)

      assert {:error, %{"code" => "task_forbidden"}} = attach(conn, token, target, canvas)

      # POSITIVE CONTROL, and the sharper half of the claim: same org, same
      # canvas, same agent — only the task differs.
      assert {:ok, _} = attach(conn, token, own, canvas)
    end

    # The brief's requirement, asserted as MUTUAL distinguishability rather
    # than as three separate shapes: an agent has to be able to tell which of
    # the three happened from the payload alone.
    test "task_forbidden, canvas_forbidden and Task not found are three distinct answers", ctx do
      token = runtime_token!(ctx.agent)

      # (a) task denied, canvas readable
      assert {:error, task_denied} = attach(ctx.conn, token, ctx.target, ctx.canvas)

      # (b) task allowed, canvas unreadable — a canvas in a space this agent
      # was never in.
      unreadable = canvas!(canvas_space!())
      assert {:error, canvas_denied} = attach(ctx.conn, token, ctx.own_task, unreadable)

      # (c) no such task
      assert {:error, absent} =
               ctx.conn
               |> call(token, "task_attach_canvas", %{
                 "task_id" => Ecto.UUID.generate(),
                 "canvas_id" => ctx.canvas.id
               })
               |> unwrap()

      assert task_denied["code"] == "task_forbidden"
      assert task_denied["error"] =~ ctx.target.id

      refute Map.has_key?(canvas_denied, "code")
      assert canvas_denied["error"] =~ unreadable.id
      assert canvas_denied["error"] =~ "cannot read it"

      refute Map.has_key?(absent, "code")
      assert absent["error"] =~ "Task not found"

      # No two of the three are confusable on `error` either, which is what a
      # caller with no `code` key has to fall back on.
      errors = Enum.map([task_denied, canvas_denied, absent], & &1["error"])
      assert length(Enum.uniq(errors)) == 3
    end

    # THE ORDER IS PART OF THE CONTRACT. `CanvasAttachments.attach_canvas/4`
    # runs the task door FIRST so the attach surface is not an existence oracle
    # for canvases in spaces the caller is nowhere near.
    test "the task door answers before the canvas door", ctx do
      token = runtime_token!(ctx.agent)
      unreadable = canvas!(canvas_space!())

      # Both conjuncts fail. The caller must learn about the TASK.
      assert {:error, envelope} = attach(ctx.conn, token, ctx.target, unreadable)
      assert envelope["code"] == "task_forbidden"
      refute envelope["error"] =~ unreadable.id

      # POSITIVE CONTROL: the canvas half really is unsatisfiable, so the
      # assertion above is about ORDER and not about the canvas being fine.
      assert {:error, %{"error" => canvas_error}} =
               attach(ctx.conn, token, ctx.own_task, unreadable)

      assert canvas_error =~ "cannot read it"
    end

    # The scope fence, as the CURRENT contract. Not an endorsement — see the
    # moduledoc. `architecture.review_plan` and `architecture.audit_diff` fire
    # with a task_id and no space binding, which is exactly this shape.
    test "a responsibility holder with a task_id but no space binding is denied", ctx do
      token = runtime_token!(ctx.agent)

      # Neither producer's handler sets `:dispatch_space_id`, so
      # `AgentResponder.dispatch_space_id/1` reads nil and no participant row is
      # ever minted. Assert that the space exists and the agent is NOT in it,
      # rather than assuming absence.
      {:ok, space} = ExecutionSpace.find_or_create(ctx.target.id)
      assert is_nil(Chat.get_agent_participant(space.id, ctx.agent.id))

      assert {:error, %{"code" => "task_forbidden"}} =
               attach(ctx.conn, token, ctx.target, ctx.canvas)

      # POSITIVE CONTROL, and the thing that makes this a fence rather than a
      # bug report: the SAME agent, once given the participant row the design
      # step gets and the architecture fires deliberately do not, attaches.
      # Widening the grant is a one-line change; the decision is Marlowe's.
      {:ok, _} = Chat.add_agent_participant(space.id, ctx.agent)
      assert {:ok, _} = attach(ctx.conn, token, ctx.target, ctx.canvas)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 3. Every grant path that can legitimately attach, still attaching
  # ══════════════════════════════════════════════════════════════════════════

  describe "grant paths reachable over federation" do
    setup %{org_a: org_a} do
      space = canvas_space!()
      %{project: project!(org_a), space: space, canvas: canvas!(space)}
    end

    test ":assignee attaches", ctx do
      agent = agent!()
      task = task!(ctx.project, %{assignee_type: "agent", assignee_id: agent.id})
      grant_canvas_read!(ctx.space, agent)

      assert {:ok, result} = attach(ctx.conn, runtime_token!(agent), task, ctx.canvas)
      assert result["canvas_id"] == ctx.canvas.id
      assert [_row] = attachment_rows(task.id)
    end

    test ":phase_assignee attaches", ctx do
      agent = agent!()
      task = task!(ctx.project)

      {:ok, task} =
        Tasks.set_phase_assignees(task, %{
          "execution" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
        })

      # The task is in `backlog`, whose phase is `planning`, so the top-level
      # assignee was re-derived away. `:assignee` cannot be what fires here.
      assert is_nil(task.assignee_id)

      grant_canvas_read!(ctx.space, agent)

      assert {:ok, _} = attach(ctx.conn, runtime_token!(agent), task, ctx.canvas)
      assert [_row] = attachment_rows(task.id)
    end

    test ":space_member attaches", ctx do
      agent = agent!()
      task = task!(ctx.project)
      grant_space_member!(task, agent)
      grant_canvas_read!(ctx.space, agent)

      assert {:ok, _} = attach(ctx.conn, runtime_token!(agent), task, ctx.canvas)
      assert [_row] = attachment_rows(task.id)
    end

    test "all three grant paths also open detach and list", ctx do
      for {label, mint} <- [
            {:assignee,
             fn agent -> task!(ctx.project, %{assignee_type: "agent", assignee_id: agent.id}) end},
            {:phase_assignee,
             fn agent ->
               {:ok, t} =
                 Tasks.set_phase_assignees(task!(ctx.project), %{
                   "review" => %{"assignee_id" => agent.id, "assignee_type" => "agent"}
                 })

               t
             end},
            {:space_member,
             fn agent ->
               task = task!(ctx.project)
               grant_space_member!(task, agent)
               task
             end}
          ] do
        agent = agent!()
        task = mint.(agent)
        grant_canvas_read!(ctx.space, agent)
        token = runtime_token!(agent)

        assert {:ok, _} = attach(ctx.conn, token, task, ctx.canvas), "#{label} could not attach"

        assert {:ok, %{"canvases" => [row]}} = list(ctx.conn, token, task.id),
               "#{label} could not list"

        assert row["canvas_id"] == ctx.canvas.id

        assert {:ok, %{"detached" => true}} = detach(ctx.conn, token, task, ctx.canvas),
               "#{label} could not detach"

        assert attachment_rows(task.id) == []
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 4. Side effects of a denial, each paired with a positive control
  # ══════════════════════════════════════════════════════════════════════════

  describe "a denied attach leaves nothing behind" do
    setup %{org_a: org_a} do
      project = project!(org_a)
      space = canvas_space!()
      canvas = canvas!(space)

      stranger = agent!()
      grant_canvas_read!(space, stranger)

      %{project: project, space: space, canvas: canvas, stranger: stranger}
    end

    test "no attachment row is written, and the same probe sees one when granted", ctx do
      denied_task = task!(ctx.project)
      token = runtime_token!(ctx.stranger)

      assert {:error, %{"code" => "task_forbidden"}} =
               attach(ctx.conn, token, denied_task, ctx.canvas)

      assert attachment_rows(denied_task.id) == []

      # POSITIVE CONTROL for the counting probe itself.
      granted_task = task!(ctx.project)
      grant_space_member!(granted_task, ctx.stranger)

      assert {:ok, _} = attach(ctx.conn, token, granted_task, ctx.canvas)
      assert [_row] = attachment_rows(granted_task.id)
    end

    test "exactly one denial event fires, and a granted attach fires none", ctx do
      denied_task = task!(ctx.project)
      token = runtime_token!(ctx.stranger)

      {result, denials} =
        count_denials(fn -> attach(ctx.conn, token, denied_task, ctx.canvas) end)

      assert {:error, %{"code" => "task_forbidden"}} = result

      assert length(denials) == 1,
             "expected exactly one #{inspect(@denial_event)}, got #{length(denials)}"

      [meta] = denials
      assert meta.resource_type == "task"
      assert meta.resource_id == denied_task.id
      assert meta.actor_type == "agent"
      assert meta.actor_id == ctx.stranger.id
      assert meta.tool == "task_attach_canvas"
      assert meta.project_id == ctx.project.id

      # POSITIVE CONTROL, both halves: the handler is proven to be attached and
      # firing (it caught one above), and proven SELECTIVE (a granted call
      # through the same code path emits nothing). Without the second half
      # "exactly one" would also hold for a gate that denied everything.
      granted_task = task!(ctx.project)
      grant_space_member!(granted_task, ctx.stranger)

      {ok_result, none} =
        count_denials(fn -> attach(ctx.conn, token, granted_task, ctx.canvas) end)

      assert {:ok, _} = ok_result
      assert none == []
    end

    test "the design settler does not run, and runs for a granted attach", ctx do
      denied_task = ctx.project |> task!() |> open_design_step!()
      token = runtime_token!(ctx.stranger)

      {result, settles} =
        record_settles(fn -> attach(ctx.conn, token, denied_task, ctx.canvas) end)

      assert {:error, %{"code" => "task_forbidden"}} = result
      assert settles == []

      # POSITIVE CONTROL: the stub is wired to the REAL seam and does fire —
      # so the empty list above is an absence rather than a broken injection.
      granted_task = ctx.project |> task!() |> open_design_step!()
      grant_space_member!(granted_task, ctx.stranger)

      {ok_result, fired} =
        record_settles(fn -> attach(ctx.conn, token, granted_task, ctx.canvas) end)

      assert {:ok, _} = ok_result
      assert [{task_id, %CanvasAttachment{}}] = fired
      assert task_id == granted_task.id
    end

    test "a denied detach leaves the attachment row in place", ctx do
      task = task!(ctx.project)
      owner = agent!()
      grant_space_member!(task, owner)
      grant_canvas_read!(ctx.space, owner)

      assert {:ok, _} = attach(ctx.conn, runtime_token!(owner), task, ctx.canvas)
      assert [_row] = attachment_rows(task.id)

      # DETECTOR: pre-stage-3, any runtime knowing two ids could delete this.
      assert {:error, %{"code" => "task_forbidden"}} =
               detach(ctx.conn, runtime_token!(ctx.stranger), task, ctx.canvas)

      assert [_still_there] = attachment_rows(task.id)

      # POSITIVE CONTROL for the deletion probe: the row IS deletable, by the
      # actor who may.
      assert {:ok, %{"detached" => true}} =
               detach(ctx.conn, runtime_token!(owner), task, ctx.canvas)

      assert attachment_rows(task.id) == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 5. The design step: denied, still open, still closable
  # ══════════════════════════════════════════════════════════════════════════

  describe "a denied designer can still close her own step" do
    # This is the failure mode stage 3's suggestion string exists for. ADR-0046
    # fires the design step ONCE, holds 30 minutes and never redelivers, so a
    # designer who cannot attach and cannot decline burns the hold and the task
    # records `failed`.
    test "a denied attach leaves the step open, and task_design_decline closes it",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      task = project |> task!() |> open_design_step!()

      space = canvas_space!()
      canvas = canvas!(space)
      designer = agent!()
      grant_canvas_read!(space, designer)
      token = runtime_token!(designer)

      assert {:error, envelope} = attach(conn, token, task, canvas)
      assert envelope["code"] == "task_forbidden"

      # STILL OPEN, both halves of "open": the cursor is unmoved and nothing
      # was recorded under `"design"`.
      assert reload(task).planning_step == "designing"
      assert design_entry(task) == nil

      # And the exit the denial names is reachable BY THE SAME TOKEN. The
      # suggestion is only worth its bytes if this holds — `task_design_decline`
      # is deliberately not gated on `TaskAccess`.
      assert {:ok, declined} =
               conn
               |> call(token, "task_design_decline", %{
                 "task_id" => task.id,
                 "reason" => @decline_reason
               })
               |> unwrap()

      assert declined["outcome"] == "not_applicable"

      entry = design_entry(task)
      assert entry["outcome"] == "not_applicable"
      assert entry["reason"] == "designer_declined"

      # POSITIVE CONTROL for the "still open" assertion: the probe can see a
      # CLOSED step. Without it, `design_entry(task) == nil` would also pass
      # against a task whose step never opened, or a probe reading the wrong key.
      assert design_entry(project |> task!() |> open_design_step!()) == nil
    end

    test "a granted attach closes the step, which is what the denial withheld",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      task = project |> task!() |> open_design_step!()

      space = canvas_space!()
      canvas = canvas!(space)
      designer = agent!()
      grant_space_member!(task, designer)
      grant_canvas_read!(space, designer)

      assert {:ok, _} = attach(conn, runtime_token!(designer), task, canvas)

      entry = design_entry(task)
      assert entry["outcome"] == "complete"
      refute reload(task).planning_step == "designing"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 6. The pre-plan designer's binding, asserted by its EFFECT
  # ══════════════════════════════════════════════════════════════════════════

  describe "the pre-plan designer's participant row" do
    test "the row the dispatch invite mints turns the denial above into an attach",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      task = project |> task!() |> open_design_step!()
      space = canvas_space!()
      canvas = canvas!(space)
      designer = agent!()
      grant_canvas_read!(space, designer)
      token = runtime_token!(designer)

      {:ok, exec_space} = ExecutionSpace.find_or_create(task.id)

      # BEFORE: no row, and the attach is denied. This is the positive control
      # for the assertion that follows — it proves the row is what changes the
      # answer, rather than something else in the setup.
      assert is_nil(Chat.get_agent_participant(exec_space.id, designer.id))
      assert {:error, %{"code" => "task_forbidden"}} = attach(conn, token, task, canvas)

      # The binding, minted the way `DispatchMembership.ensure_writable/3`
      # mints it on the dispatch path once `DesignTaskDirection.gather_context/2`
      # has opted in with `:dispatch_space_id`.
      assert {:ok, :invited} =
               Platform.Chat.DispatchMembership.ensure_writable(
                 exec_space.id,
                 designer.id,
                 source: :agent_responder
               )

      # AFTER: same token, same task, same canvas.
      assert {:ok, _} = attach(conn, token, task, canvas)

      row = Chat.get_agent_participant(exec_space.id, designer.id)
      assert %Participant{} = row
      assert row.participant_id == designer.id

      # PINNING CURRENT DATA, NOT BEHAVIOUR. The stage-5 brief predicted
      # `"mention"`; `DispatchMembership.attention_mode/1` returns `"all"` for
      # an execution space, and post-ADR-0027 `resolve_attention_mode/2`
      # discards the participant anyway, so this value routes nothing. Asserted
      # only so a change to it is deliberate.
      assert row.attention_mode == "all"
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 7. The two non-MCP paths, unaffected
  # ══════════════════════════════════════════════════════════════════════════

  describe "the :system responsibility path" do
    # `DesignTaskDirection` authorizes as `:system` because it creates the
    # canvas itself and the agent it attributes the work to is frequently not a
    # participant of the execution space. Stage 3 put a task gate in front of
    # the same function; `:system` must still pass it.
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

      # POSITIVE CONTROL that the gate is genuinely being crossed rather than
      # skipped: the attributed agent is NOT a participant of that space, so an
      # implementation that authorized as `{:agent, attributed.id}` instead of
      # `:system` would have been denied here.
      assert is_nil(Chat.get_agent_participant(space.id, attributed.id))
    end

    test ":system attaches to a task nobody is bound to", %{org_a: org_a} do
      task = task!(project!(org_a))
      space = canvas_space!()
      canvas = canvas!(space)

      assert {:ok, _} =
               Platform.Tasks.CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
                 attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
               )

      # POSITIVE CONTROL: the same call with no principal is refused, so the
      # success above is `:system` doing work rather than the gate being absent.
      other = task!(project!(org_a))

      assert {:error, :task_forbidden} =
               Platform.Tasks.CanvasAttachments.attach_canvas(nil, other.id, canvas.id,
                 attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
               )
    end
  end

  describe "the human LiveView detach path" do
    # `tasks_live.ex:1380` builds `{:user, socket.assigns[:current_user_id]}`.
    # Driven through the real LiveView rather than by calling
    # `detach_canvas/3` with a hand-made actor, because the assign wiring is
    # the half that a context-map test cannot see — a missing assign yields
    # `{:user, nil}`, which `TaskAccess.normalize_actor/1` reads as NO
    # PRINCIPAL and denies, silently, for every human.
    test "a project-org member can still detach a chip from the board",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      task = task!(project, %{status: "in_progress"})
      space = canvas_space!()
      canvas = canvas!(space)

      {:ok, _} =
        Platform.Tasks.CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
          attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
        )

      assert [_row] = attachment_rows(task.id)

      human = user!()
      Platform.ExternalUserFixtures.plain_member!(human, org_a)

      {:ok, view, _html} =
        conn
        |> init_test_session(current_user_id: human.id)
        |> live(~p"/tasks?task_id=#{task.id}")

      render_hook(view, "detach_canvas", %{"canvas-id" => canvas.id})

      assert attachment_rows(task.id) == []
    end

    # The absence half, and the reason the assign matters. A logged-in human
    # with no standing on the task's project is now refused — the handler
    # ignores the result, so the chip simply comes back.
    test "a logged-in human with no standing on the task does not detach it",
         %{org_a: org_a, org_b: org_b, conn: conn} do
      project = project!(org_a)
      task = task!(project, %{status: "in_progress"})
      space = canvas_space!()
      canvas = canvas!(space)

      {:ok, _} =
        Platform.Tasks.CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
          attached_by: %{kind: "agent", id: Ecto.UUID.generate()}
        )

      outsider = user!()
      Platform.ExternalUserFixtures.plain_member!(outsider, org_b)

      {:ok, view, _html} =
        conn
        |> init_test_session(current_user_id: outsider.id)
        |> live(~p"/tasks?task_id=#{task.id}")

      render_hook(view, "detach_canvas", %{"canvas-id" => canvas.id})

      # POSITIVE CONTROL is the test above: the identical hook, driven the
      # identical way, DOES delete the row for a member. So this is a refusal
      # rather than a hook that never fired.
      assert [_still_there] = attachment_rows(task.id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 8. The error-taxonomy contract
  # ══════════════════════════════════════════════════════════════════════════

  describe "GUARD — the closed refusal taxonomy" do
    setup %{org_a: org_a} do
      project = project!(org_a)
      space = canvas_space!()
      canvas = canvas!(space)

      # An agent that holds the task grant and the canvas grant, so every
      # refusal below is reached deliberately rather than by tripping the first
      # door every time.
      agent = agent!()
      task = task!(project, %{assignee_type: "agent", assignee_id: agent.id})
      grant_canvas_read!(space, agent)

      %{
        project: project,
        space: space,
        canvas: canvas,
        agent: agent,
        task: task,
        token: runtime_token!(agent)
      }
    end

    # The `@design_decline_error_codes` pattern, applied to the three tools:
    # the DECLARED set compared against the set actually driven out of the
    # clause, rather than either one restated in the test.
    test "task_attach_canvas emits exactly its declared set", ctx do
      declared = ToolSurface.canvas_attachment_error_codes()["task_attach_canvas"]

      stranger_task = task!(ctx.project)
      unreadable = canvas!(canvas_space!())

      cases = [
        {:task_forbidden, %{"task_id" => stranger_task.id, "canvas_id" => ctx.canvas.id}},
        {:task_not_found, %{"task_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}},
        {:task_not_found, %{"task_id" => "not-a-uuid", "canvas_id" => ctx.canvas.id}},
        {:canvas_forbidden, %{"task_id" => ctx.task.id, "canvas_id" => unreadable.id}},
        {:canvas_not_found, %{"task_id" => ctx.task.id, "canvas_id" => Ecto.UUID.generate()}},
        {:canvas_not_found, %{"task_id" => ctx.task.id, "canvas_id" => "not-a-uuid"}}
      ]

      observed = drive(ctx.conn, ctx.token, "task_attach_canvas", cases)

      assert observed == MapSet.new(declared), taxonomy_message(observed, declared)

      # PAIRED CONTROL for the whole sweep: a clause that refused EVERYTHING
      # would satisfy every assertion above.
      assert {:ok, _} = attach(ctx.conn, ctx.token, ctx.task, ctx.canvas)
    end

    test "task_detach_canvas emits exactly its declared set", ctx do
      declared = ToolSurface.canvas_attachment_error_codes()["task_detach_canvas"]
      stranger_task = task!(ctx.project)

      cases = [
        {:task_forbidden, %{"task_id" => stranger_task.id, "canvas_id" => ctx.canvas.id}},
        {:task_not_found, %{"task_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}},
        # Task reachable, no such attachment pair.
        {:not_found, %{"task_id" => ctx.task.id, "canvas_id" => Ecto.UUID.generate()}}
      ]

      observed = drive(ctx.conn, ctx.token, "task_detach_canvas", cases)

      assert observed == MapSet.new(declared), taxonomy_message(observed, declared)

      # PAIRED CONTROL.
      assert {:ok, _} = attach(ctx.conn, ctx.token, ctx.task, ctx.canvas)
      assert {:ok, %{"detached" => true}} = detach(ctx.conn, ctx.token, ctx.task, ctx.canvas)
    end

    test "task_list_canvases emits exactly its declared set", ctx do
      declared = ToolSurface.canvas_attachment_error_codes()["task_list_canvases"]
      stranger_task = task!(ctx.project)

      cases = [
        {:task_forbidden, %{"task_id" => stranger_task.id}},
        {:task_not_found, %{"task_id" => Ecto.UUID.generate()}},
        {:task_not_found, %{"task_id" => "not-a-uuid"}}
      ]

      observed = drive(ctx.conn, ctx.token, "task_list_canvases", cases)

      assert observed == MapSet.new(declared), taxonomy_message(observed, declared)

      # PAIRED CONTROL, and the decision stage 4 recorded: a REFUSAL, never an
      # empty list. If the clause returned `[]` for a denial the sweep above
      # would go red on `:task_forbidden`, and this proves `[]` is still the
      # honest answer for a task with nothing attached.
      assert {:ok, %{"canvases" => []}} = list(ctx.conn, ctx.token, ctx.task.id)
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

    # THE ASYMMETRY, PINNED. Only `:task_forbidden` reaches the caller as a
    # machine-readable `code`; the rest are prose in `error`. Stage 5 did not
    # widen this (see `@canvas_attachment_coded_errors`), so the point of this
    # test is that the next person changes it deliberately.
    test "exactly one declared code arrives as a machine-readable `code` key", ctx do
      coded = MapSet.new(ToolSurface.canvas_attachment_coded_errors())
      stranger_task = task!(ctx.project)
      unreadable = canvas!(canvas_space!())

      probes = [
        {:task_forbidden, "task_attach_canvas",
         %{"task_id" => stranger_task.id, "canvas_id" => ctx.canvas.id}},
        {:task_not_found, "task_attach_canvas",
         %{"task_id" => Ecto.UUID.generate(), "canvas_id" => ctx.canvas.id}},
        {:canvas_forbidden, "task_attach_canvas",
         %{"task_id" => ctx.task.id, "canvas_id" => unreadable.id}},
        {:canvas_not_found, "task_attach_canvas",
         %{"task_id" => ctx.task.id, "canvas_id" => Ecto.UUID.generate()}},
        {:not_found, "task_detach_canvas",
         %{"task_id" => ctx.task.id, "canvas_id" => Ecto.UUID.generate()}}
      ]

      observed_coded =
        for {label, tool, args} <- probes,
            {:error, envelope} = ctx.conn |> call(ctx.token, tool, args) |> unwrap(),
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
  # 8b. The hosted transport drops the id keys — found by driving the wire
  # ══════════════════════════════════════════════════════════════════════════

  describe "the hosted transport drops the id keys" do
    # THE FINDING THIS FILE EXISTS FOR, and the one no `execute/3` test can
    # see. `MCPController.error_envelope/1` (`mcp_controller.ex:221-230`) is a
    # FIXED FOUR-KEY ALLOWLIST — `error`, `code`, `recoverable`, `suggestion`
    # — and rejects everything else.
    #
    # So `task_id`, which task 019fb581 stage 3 added to all three denial
    # envelopes, and `canvas_id`, which task 019e2c4b added to the canvas
    # denial, reach no HTTP caller. `tool_surface_test.exs` asserts
    # `error.task_id == ctx.task.id` and passes, because it reads the map
    # BEFORE the transport touches it.
    #
    # The WebSocket runtime channel pushes the same map intact
    # (`runtime_channel.ex:589-594`, `error: error`), so the two federation
    # transports still disagree about this payload — a narrower version of the
    # split `mcp_controller_test.exs`'s "tools/call error envelope" block was
    # written to close.
    #
    # NOT FIXED HERE. Widening the allowlist changes the refusal envelope of
    # every tool in the surface, which is a wire change with a blast radius
    # well outside an adversarial test stage. Pinned as the current contract
    # and raised to the review stage.
    test "task_id and canvas_id are set by the handler and discarded by /mcp",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      target = task!(project)
      space = canvas_space!()
      canvas = canvas!(space)

      agent = agent!()
      grant_canvas_read!(space, agent)
      token = runtime_token!(agent)

      # POSITIVE CONTROL, and the whole point of the pairing: the handler DOES
      # set both keys. Read directly off `execute/3`, exactly as the stage-3
      # unit tests read it.
      assert {:error, handler_task} =
               ToolSurface.execute(
                 "task_attach_canvas",
                 %{"task_id" => target.id, "canvas_id" => canvas.id},
                 %{agent_id: agent.id}
               )

      assert handler_task.task_id == target.id

      own = task!(project, %{assignee_type: "agent", assignee_id: agent.id})
      unreadable = canvas!(canvas_space!())

      assert {:error, handler_canvas} =
               ToolSurface.execute(
                 "task_attach_canvas",
                 %{"task_id" => own.id, "canvas_id" => unreadable.id},
                 %{agent_id: agent.id}
               )

      assert handler_canvas.canvas_id == unreadable.id

      # …and neither survives the projection.
      assert {:error, wire_task} = attach(conn, token, target, canvas)
      refute Map.has_key?(wire_task, "task_id")

      assert {:error, wire_canvas} = attach(conn, token, own, unreadable)
      refute Map.has_key?(wire_canvas, "canvas_id")

      # The four keys that DO survive, asserted positively so "the key is
      # missing" cannot be satisfied by an empty or malformed envelope.
      assert Map.keys(wire_task) |> Enum.sort() ==
               ["code", "error", "recoverable", "suggestion"]

      assert Map.keys(wire_canvas) |> Enum.sort() == ["error", "recoverable", "suggestion"]
    end

    # The consequence, stated as the thing that keeps the denial usable: the
    # ids are recoverable from the `error` sentence. If someone shortens those
    # strings, the id becomes unavailable to an HTTP caller by ANY route, and
    # this goes red.
    test "the ids are recoverable from the error sentence on all three tools",
         %{org_a: org_a, conn: conn} do
      project = project!(org_a)
      target = task!(project)
      space = canvas_space!()
      canvas = canvas!(space)

      agent = agent!()
      grant_canvas_read!(space, agent)
      token = runtime_token!(agent)

      assert {:error, %{"error" => a}} = attach(conn, token, target, canvas)
      assert {:error, %{"error" => d}} = detach(conn, token, target, canvas)
      assert {:error, %{"error" => l}} = list(conn, token, target.id)

      for sentence <- [a, d, l], do: assert(sentence =~ target.id)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # 9. The transport gap, as an executable claim
  # ══════════════════════════════════════════════════════════════════════════

  describe "GUARD — limitations does not reach a hosted runtime" do
    # Stage 4 found this and wrote it in a comment. A comment is what drifts.
    #
    # The consequence is real: the refusal taxonomy the tests above pin ships
    # only on the capabilities push. An agent on `/mcp` gets `description` and
    # `inputSchema` and nothing else, so it learns the gate exists only by
    # being refused by it. `canvas.create` works around this by duplicating its
    # boundary into `description`; stage 4 decided NOT to for these three,
    # because it would have to be done for all three and the whole definition
    # map is the attention-broadcast payload.
    #
    # This test does not argue either way. It makes the fact go red when it
    # stops being a fact.
    test "tools/list forwards only name, description and inputSchema" do
      token = runtime_token!(agent!(), ["task"])

      %{"result" => %{"tools" => tools}} = rpc!(token, "tools/list", %{})

      for name <- ~w(task_attach_canvas task_detach_canvas task_list_canvases) do
        wire = Enum.find(tools, &(&1["name"] == name))
        assert wire, "#{name} missing from tools/list"

        assert Map.keys(wire) |> Enum.sort() == ["description", "inputSchema", "name"]

        definition = Enum.find(ToolSurface.tool_definitions(), &(&1.name == name))

        # POSITIVE CONTROL for the absence probe, twice: the field EXISTS and
        # is non-trivial in the definition map, and a field that DOES survive
        # the projection is found by the same lookup. Without both halves this
        # test would pass against a tool with no `limitations` at all, or
        # against a `tools/list` that returned nothing useful.
        assert is_binary(definition.limitations) and byte_size(definition.limitations) > 200
        assert wire["description"] == definition.description

        # …and the taxonomy specifically does not survive.
        refute wire["description"] =~ "task_forbidden"
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
end
