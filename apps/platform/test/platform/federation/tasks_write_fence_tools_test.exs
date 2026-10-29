defmodule Platform.Federation.TasksWriteFenceToolsTest do
  @moduledoc """
  The Tasks, Stacks and Plans MCP write tools re-check their targets against
  the calling runtime's capped Scope (task 01a1472d stage 2), through stage
  1's `Platform.Access.task_target/3`.

  The world is stage 1's R/S fixture (`PlatformWeb.TasksWriteFenceTest`): the
  root org R and a sub-org S, each with a project, an epic, a stack with one
  member task, a task with a `pending_review` plan, a stage, a validation and
  a pending review request with one item. Actors:

    * M_rt, a runtime owned by M, an internal member of S only (fenced to S
      through the runtime's `owner_cap`);
    * RM_rt and RA_rt, runtimes owned by a root member and a root admin
      (unfenced);
    * an in-process caller with no `:runtime_id`.

  For EVERY tool `Platform.Access.ToolPermissions` maps to `tasks.write` or
  `tasks.manage`, M_rt calls it with the R-side ids and the test asserts:

    * the answer equals the answer to the same call with fresh random UUIDs,
      once each random id is read as the R id it stands in for (an envelope
      that echoes the id it was given cannot be `==` across two different
      ids; every other byte must be);
    * a full snapshot of every row the tool could write, and the row counts
      of every table a create path could grow, is identical before and after.

  Beside each refusal sit its POSITIVE CONTROLS on the same fixture shape:
  M_rt on the S-side ids, RM_rt and RA_rt on R and S, and the in-process
  caller on R all reach the row, which is measured as
  "the answer is NOT the random-UUID answer". The tools for which that
  measurement cannot discriminate in this fixture are named in
  `@unobservable` with the reason, and the set is pinned, so a tool that
  stops being observable fails rather than going quietly vacuous.
  """

  use PlatformWeb.ConnCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope, ToolPermissions}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{Message, Participant, Space}
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.{ExecutionLease, RuntimeEvent}
  alias Platform.Repo

  alias Platform.Tasks.{
    CanvasAttachment,
    Epic,
    PhaseTransition,
    Plan,
    Project,
    ReviewItem,
    ReviewRequest,
    Stack,
    Stage,
    Task,
    Validation
  }

  alias Platform.Tenancy.OrgMembership

  # ── the classification (static guard below) ─────────────────────────────

  @mcp_guarded ~w(
    alarm_silence
    blocker_recheck
    blocker_verify
    design_critique_request
    epic_create
    epic_update
    janitor_hand_back
    plan_approve
    plan_architecture_verdict
    plan_create
    plan_reject
    plan_submit
    plan_update
    project_update
    report_blocker
    review_request_create
    stack_abandon
    stack_add
    stack_add_dependency
    stack_assign_agents
    stack_attach_canvas
    stack_complete
    stack_create
    stack_detach_canvas
    stack_eject
    stack_remove_dependency
    stack_retry_member_merge
    stack_start
    stack_start_planning
    stack_update
    stage_architecture_audit
    stage_complete
    stage_start
    task_ack
    task_attach_canvas
    task_close_as_delivered
    task_complete
    task_create
    task_design_decline
    task_detach_canvas
    task_start
    task_update
    validation_evaluate
    validation_pass
    validation_payload_amend
  )

  # Every tasks.write / tasks.manage tool is guarded; none is exempt.
  @mcp_exempt []

  # Tools whose "reaches the row" control cannot discriminate in this
  # fixture, by actor class, with the reason. Pinned below.
  #
  #   * design_critique_request: the test install registers no
  #     `design.critique` responsibility, so every call (real row, random
  #     row, refused row) stops at `:responsibility_not_registered` before
  #     an id is read. Its observable target is the transport `space_id`,
  #     covered by its own describe block.
  #   * task_close_as_delivered: callable only through a runtime owned by a
  #     root-org admin, so every other caller stops at the principal check
  #     before an id is read. The root admin's refusal is observable through
  #     a tasks.write deny, covered by its own describe block.
  #   * blocker_recheck/blocker_verify: this fixture has neither a running
  #     stage nor an owning-runtime hold/request. Both must refuse before
  #     that row is actionable. BlockerReassessmentTest supplies those real
  #     states and checks permitted versus capped-scope writes explicitly.
  @unobservable %{
    non_root_admin:
      ~w(blocker_recheck blocker_verify design_critique_request task_close_as_delivered),
    root_admin: ~w(blocker_recheck blocker_verify design_critique_request)
  }

  @canvas_id "0190f0c3-0000-7000-8000-00000000c0de"

  @stages [
    %{
      "name" => "Fence probe stage",
      "position" => 1,
      "description" => "fence probe",
      "validations" => [%{"kind" => "test_pass"}]
    }
  ]

  # ── fixtures (stage 1's R/S world) ──────────────────────────────────────

  defp n, do: System.unique_integer([:positive])

  defp user!(tag) do
    i = n()

    Repo.insert!(%User{
      email: "wfence-mcp-#{tag}-#{i}@example.com",
      name: "Write fence MCP #{tag} #{i}",
      oidc_sub: "wfence-mcp-#{tag}-#{i}"
    })
  end

  defp membership!(user, org, role \\ "member") do
    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: user.id, org_id: org, role: role})
    |> Repo.insert!()
  end

  defp world!(org, tag) do
    i = n()

    {:ok, project} =
      Platform.Tasks.create_project(%{name: "wfence-mcp-#{tag}-#{i}", org_id: org})

    epic = Repo.insert!(%Epic{project_id: project.id, name: "#{tag} epic #{i}"})

    stack =
      Repo.insert!(%Stack{
        project_id: project.id,
        slug: "wfence-mcp-#{String.downcase(tag)}-#{i}",
        name: "#{tag} stack #{i}",
        rollup_branch: "stack/wfence-mcp-#{i}"
      })

    task =
      Repo.insert!(%Task{
        project_id: project.id,
        title: "#{tag} task #{i}",
        status: "planning",
        priority: "high"
      })

    member =
      Repo.insert!(%Task{
        project_id: project.id,
        stack_id: stack.id,
        stack_position: 1,
        title: "#{tag} member #{i}",
        status: "backlog"
      })

    plan = Repo.insert!(%Plan{task_id: task.id, status: "pending_review", version: 1})
    stage = Repo.insert!(%Stage{plan_id: plan.id, position: 1, name: "#{tag} stage"})
    validation = Repo.insert!(%Validation{stage_id: stage.id, kind: "manual_approval"})

    request =
      Repo.insert!(%ReviewRequest{
        validation_id: validation.id,
        task_id: task.id,
        status: "pending",
        submitted_by: "wfence-mcp"
      })

    item = Repo.insert!(%ReviewItem{review_request_id: request.id, label: "#{tag} item #{i}"})

    %{
      org: org,
      project: project,
      epic: epic,
      stack: stack,
      task: task,
      member: member,
      plan: plan,
      stage: stage,
      validation: validation,
      request: request,
      item: item
    }
  end

  @id_keys ~w(project epic stack task member plan stage validation request item)a

  defp ids(w), do: Map.new(@id_keys, &{&1, Map.fetch!(w, &1).id})
  defp random_ids, do: Map.new(@id_keys, &{&1, Ecto.UUID.generate()})

  defp agent! do
    i = n()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "wfence-mcp-agent-#{i}",
        name: "Fence MCP #{i}",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  # The default tool profile carries no `task`, `plan` or `review` bundle,
  # so a default runtime holds no `tasks.write` and every one of these tools
  # is refused at the tool gate (-32001) before its handler runs: a fixture
  # that cannot tell the fence from the gate. The runtime under test carries
  # the three bundles that map to `tasks.write` / `tasks.manage`, so the
  # only thing left to refuse it is its owner's fence.
  @profile AgentRuntime.default_tool_profile() ++ ~w(task plan review)

  # A runtime owned by `owner`. Returns `{runtime, raw_token}`.
  defp runtime!(owner) do
    agent = agent!()
    raw = AgentRuntime.generate_token()

    {:ok, rt} =
      %AgentRuntime{}
      |> AgentRuntime.changeset(%{
        runtime_id: "wfence-mcp-rt-#{n()}",
        owner_user_id: owner.id,
        agent_id: agent.id,
        auth_token_hash: AgentRuntime.hash_token(raw),
        status: "active"
      })
      |> Repo.insert()

    {:ok, _profile} =
      Platform.Access.RuntimeProfiles.create_for_runtime(
        rt,
        @profile,
        Platform.Access.RuntimeProfiles.translated_permissions(@profile)
      )

    {rt, raw}
  end

  defp context(%AgentRuntime{} = rt), do: %{runtime_id: rt.runtime_id, agent_id: rt.agent_id}
  defp context(:in_process), do: %{agent_id: agent!().id}

  # The tool's answer, with a raise read as a value so two raising calls
  # compare like any other two answers.
  defp call(ctx, tool, args) do
    ToolSurface.execute(tool, args, ctx)
  rescue
    e -> {:raised, e.__struct__}
  end

  # `term` with every id of `from` read as the id of `to` at the same key.
  defp swap(term, from, to) do
    pairs = for k <- @id_keys, do: {Map.fetch!(from, k), Map.fetch!(to, k)}
    replace(term, pairs)
  end

  defp replace(term, pairs) when is_binary(term),
    do: Enum.reduce(pairs, term, fn {a, b}, acc -> String.replace(acc, a, b) end)

  defp replace(term, pairs) when is_list(term), do: Enum.map(term, &replace(&1, pairs))

  defp replace(term, pairs) when is_tuple(term),
    do: term |> Tuple.to_list() |> replace(pairs) |> List.to_tuple()

  defp replace(%_{} = struct, _pairs), do: struct

  defp replace(term, pairs) when is_map(term),
    do: Map.new(term, fn {k, v} -> {replace(k, pairs), replace(v, pairs)} end)

  defp replace(term, _pairs), do: term

  # ── snapshots ───────────────────────────────────────────────────────────

  @counted [
    Task,
    Epic,
    Project,
    Plan,
    Stage,
    Validation,
    Stack,
    ReviewRequest,
    ReviewItem,
    CanvasAttachment,
    RuntimeEvent,
    ExecutionLease,
    PhaseTransition,
    Message,
    Space,
    Participant
  ]

  defp row(schema, id) do
    case Repo.get(schema, id) do
      nil ->
        nil

      row ->
        row
        |> Map.from_struct()
        |> Map.drop([:__meta__])
        |> Map.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
    end
  end

  defp snapshot(worlds) do
    %{
      rows:
        for w <- worlds do
          [
            row(Project, w.project.id),
            row(Epic, w.epic.id),
            row(Stack, w.stack.id),
            row(Task, w.task.id),
            row(Task, w.member.id),
            row(Plan, w.plan.id),
            row(Stage, w.stage.id),
            row(Validation, w.validation.id),
            row(ReviewRequest, w.request.id),
            row(ReviewItem, w.item.id)
          ]
        end,
      counts: Enum.map(@counted, &{&1, Repo.aggregate(&1, :count)})
    }
  end

  # ── the arguments each tool is called with ──────────────────────────────

  defp args_for("alarm_silence", i),
    do: %{
      "task_id" => i.task,
      "stage_id" => i.stage,
      "until_seconds" => 600,
      "reason" => "fence probe silence"
    }

  defp args_for("blocker_recheck", i),
    do: %{
      "task_id" => i.task,
      "stage_id" => i.stage,
      "dependencies" => [],
      "required_capability" => "headline_review:1",
      "verifier" => "owning_runtime"
    }

  defp args_for("blocker_verify", i),
    do: %{
      "task_id" => i.task,
      "stage_id" => i.stage,
      "request_token" => "probe",
      "hold_revision" => "probe",
      "required_capability" => "headline_review:1",
      "verified" => false,
      "evidence_refs" => []
    }

  defp args_for("design_critique_request", i),
    do: %{"task_id" => i.task, "review_request_id" => i.request, "note" => "fence probe"}

  defp args_for("epic_create", i), do: %{"project_id" => i.project, "name" => "fence epic"}
  defp args_for("epic_update", i), do: %{"epic_id" => i.epic, "name" => "fence renamed epic"}

  defp args_for("janitor_hand_back", i), do: %{"task_id" => i.task, "reason" => "not_small"}
  defp args_for("plan_approve", i), do: %{"plan_id" => i.plan}

  defp args_for("plan_architecture_verdict", i),
    do: %{"plan_id" => i.plan, "verdict" => "pass", "summary" => "fence probe verdict"}

  defp args_for("plan_create", i), do: %{"task_id" => i.task, "stages" => @stages}

  defp args_for("plan_reject", i),
    do: %{"plan_id" => i.plan, "rejection_reason" => "fence probe rejection"}

  defp args_for("plan_submit", i), do: %{"plan_id" => i.plan}
  defp args_for("plan_update", i), do: %{"plan_id" => i.plan, "stages" => @stages}

  defp args_for("project_update", i),
    do: %{"project_id" => i.project, "name" => "fence renamed project"}

  defp args_for("report_blocker", i),
    do: %{
      "task_id" => i.task,
      "stage_id" => i.stage,
      "description" => "fence probe blocker",
      "attempts" => ["first attempt", "second attempt", "third attempt"],
      "memory_ref" => "org/page/identity.md",
      "unblock_action" => "a human picks option A",
      "category" => "product"
    }

  defp args_for("review_request_create", i),
    do: %{
      "validation_id" => i.validation,
      "items" => [%{"label" => "fence probe item", "content" => "fence probe"}]
    }

  defp args_for("stack_abandon", i), do: %{"stack_id" => i.stack, "reason" => "fence probe"}
  defp args_for("stack_add", i), do: %{"stack_id" => i.stack, "task_id" => i.task}

  defp args_for("stack_add_dependency", i),
    do: %{"stack_id" => i.stack, "from_task_id" => i.member, "to_task_id" => i.task}

  defp args_for("stack_assign_agents", i), do: %{"stack_id" => i.stack}

  defp args_for("stack_attach_canvas", i),
    do: %{"stack_id" => i.stack, "canvas_id" => @canvas_id}

  defp args_for("stack_detach_canvas", i),
    do: %{"stack_id" => i.stack, "canvas_id" => @canvas_id}

  defp args_for("stack_complete", i), do: %{"stack_id" => i.stack}

  defp args_for("stack_create", i),
    do: %{"project_id" => i.project, "slug" => "fence-probe-stack", "name" => "Fence stack"}

  defp args_for("stack_eject", i), do: %{"stack_id" => i.stack, "task_id" => i.member}

  defp args_for("stack_remove_dependency", i),
    do: %{"stack_id" => i.stack, "from_task_id" => i.member, "to_task_id" => i.task}

  defp args_for("stack_retry_member_merge", i), do: %{"task_id" => i.member}
  defp args_for("stack_start", i), do: %{"stack_id" => i.stack}
  defp args_for("stack_start_planning", i), do: %{"stack_id" => i.stack}

  defp args_for("stack_update", i),
    do: %{"stack_id" => i.stack, "name" => "fence renamed stack"}

  defp args_for("stage_architecture_audit", i),
    do: %{"stage_id" => i.stage, "summary" => "fence probe audit"}

  defp args_for("stage_complete", i), do: %{"stage_id" => i.stage}
  defp args_for("stage_start", i), do: %{"stage_id" => i.stage}

  defp args_for("task_ack", i),
    do: %{"task_id" => i.task, "stage_id" => i.stage, "subagent_id" => "fence-probe-subagent"}

  defp args_for("task_attach_canvas", i), do: %{"task_id" => i.task, "canvas_id" => @canvas_id}

  defp args_for("task_close_as_delivered", i),
    do: %{"task_id" => i.task, "delivery_reference" => "#1018"}

  defp args_for("task_complete", i), do: %{"task_id" => i.task}

  defp args_for("task_create", i),
    do: %{"project_id" => i.project, "title" => "fence probe task"}

  defp args_for("task_design_decline", i),
    do: %{"task_id" => i.task, "reason" => "cannot deliver this design direction"}

  defp args_for("task_detach_canvas", i), do: %{"task_id" => i.task, "canvas_id" => @canvas_id}
  defp args_for("task_start", i), do: %{"task_id" => i.task}

  defp args_for("task_update", i), do: %{"task_id" => i.task, "title" => "fence renamed task"}

  defp args_for("validation_evaluate", i),
    do: %{"validation_id" => i.validation, "status" => "passed"}

  defp args_for("validation_pass", i), do: %{"validation_id" => i.validation}

  defp args_for("validation_payload_amend", i),
    do: %{
      "validation_id" => i.validation,
      "reason" => "fence probe amend",
      "evaluation_payload" => %{
        "setup" => "fence probe setup",
        "actions" => "fence probe actions",
        "expected" => "fence probe expected"
      }
    }

  # ── setup ───────────────────────────────────────────────────────────────

  setup do
    root = acme_org_id()
    s = tenant_org_id("wfence_mcp_s_#{n()}")

    m = user!("m")
    membership!(m, s)
    rm = user!("rm")
    membership!(rm, root)
    ra = user!("ra")
    membership!(ra, root, "admin")

    %{root: root, s: s, m: m, rm: rm, ra: ra}
  end

  # `answer` is the random-UUID answer, read as the ids of `w`.
  defp random_answer(ctx, tool, w) do
    rand = random_ids()
    ctx |> call(tool, args_for(tool, rand)) |> swap(rand, ids(w))
  end

  defp reaches_row?(ctx, tool, w),
    do: call(ctx, tool, args_for(tool, ids(w))) != random_answer(ctx, tool, w)

  # ── every tool: M_rt is refused on R, and every control reaches the row ─

  describe "M's runtime on R ids gets the random-UUID answer and writes nothing" do
    for tool <- @mcp_guarded do
      test tool, ctx do
        tool = unquote(tool)
        r = world!(ctx.root, "R")
        {m_rt, _} = runtime!(ctx.m)
        m_ctx = context(m_rt)

        before = snapshot([r])
        refused = call(m_ctx, tool, args_for(tool, ids(r)))
        assert snapshot([r]) == before, "#{tool} wrote on a refused R target"
        assert refused == random_answer(m_ctx, tool, r)
      end
    end
  end

  describe "positive controls reach the row" do
    for tool <- @mcp_guarded do
      test tool, ctx do
        tool = unquote(tool)
        non_admin_blind? = tool in @unobservable.non_root_admin
        admin_blind? = tool in @unobservable.root_admin

        {m_rt, _} = runtime!(ctx.m)
        {rm_rt, _} = runtime!(ctx.rm)
        {ra_rt, _} = runtime!(ctx.ra)

        cases = [
          {"M on S", context(m_rt), ctx.s, non_admin_blind?},
          {"RM on R", context(rm_rt), ctx.root, non_admin_blind?},
          {"RM on S", context(rm_rt), ctx.s, non_admin_blind?},
          {"RA on R", context(ra_rt), ctx.root, admin_blind?},
          {"RA on S", context(ra_rt), ctx.s, admin_blind?},
          {"in-process on R", context(:in_process), ctx.root, non_admin_blind?}
        ]

        for {label, caller, org, blind?} <- cases do
          w = world!(org, "C")

          assert reaches_row?(caller, tool, w) == not blind?,
                 "#{tool}, #{label}: reaches_row? should be #{not blind?}"
        end
      end
    end
  end

  # ── a permitted primary target with a refused secondary one ─────────────

  describe "a refused secondary target on a permitted call" do
    # {tool, args from (S ids, the secondary id), the secondary key}
    @secondary [
      {"task_create", :project, :epic, "epic_id"},
      {"task_create", :project, :stack, "stack_id"},
      {"task_update", :task, :project, "project_id"},
      {"task_update", :task, :epic, "epic_id"},
      {"stack_add", :stack, :task, "task_id"},
      {"stack_add_dependency", :stack, :task, "to_task_id"},
      {"stack_create", :project, :epic, "epic_id"},
      {"task_ack", :task, :stage, "stage_id"},
      {"alarm_silence", :task, :stage, "stage_id"}
    ]

    for {tool, _primary, kind, key} <- @secondary do
      test "#{tool} with an R #{key}", ctx do
        {tool, kind, key} = {unquote(tool), unquote(kind), unquote(key)}
        r = world!(ctx.root, "R")
        s = world!(ctx.s, "S")
        {m_rt, _} = runtime!(ctx.m)
        m_ctx = context(m_rt)

        args = fn secondary -> Map.put(args_for(tool, ids(s)), key, secondary) end
        r_id = Map.fetch!(ids(r), kind)
        random = Ecto.UUID.generate()

        before = snapshot([r, s])
        refused = call(m_ctx, tool, args.(r_id))
        assert snapshot([r, s]) == before, "#{tool} wrote with a refused #{key}"

        expected =
          m_ctx |> call(tool, args.(random)) |> replace([{random, r_id}])

        # For `stack_id` the random-UUID call is the one whose not-found
        # path writes (the task is created before the stack lookup fails);
        # the refused call answers the same and, above, writes nothing.
        assert refused == expected

        # Control: the same call with the S-side secondary is not refused.
        s_answer = call(m_ctx, tool, args.(Map.fetch!(ids(s), kind)))
        refute s_answer == replace(expected, [{r_id, Map.fetch!(ids(s), kind)}])
      end
    end
  end

  # ── design_critique_request: the transport space ────────────────────────

  describe "design_critique_request on a space the runtime sits in" do
    defp channel_with!(org, agent_id) do
      i = n()

      {:ok, space} =
        Chat.create_channel(%{
          name: "wfence-mcp-#{i}",
          slug: "wfence-mcp-#{i}",
          kind: "channel",
          org_id: org
        })

      {:ok, _} = Chat.add_agent_participant(space.id, agent_id, attention_mode: "mention")
      space
    end

    test "an R space is the random-space answer for M; an S space is not", ctx do
      {m_rt, _} = runtime!(ctx.m)
      r_space = channel_with!(ctx.root, m_rt.agent_id)
      s_space = channel_with!(ctx.s, m_rt.agent_id)
      random = Ecto.UUID.generate()
      args = %{"note" => "fence probe"}
      at = fn space_id -> Map.put(context(m_rt), :space_id, space_id) end

      before = snapshot([])
      refused = call(at.(r_space.id), "design_critique_request", args)
      assert snapshot([]) == before

      expected =
        at.(random)
        |> call("design_critique_request", args)
        |> replace([{random, r_space.id}])

      assert refused == expected

      assert {:error, %{error: "Access denied: agent is not a participant in space " <> _}} =
               refused

      s_answer = call(at.(s_space.id), "design_critique_request", args)
      refute s_answer == replace(expected, [{r_space.id, s_space.id}])

      # Control: a root member's runtime in the same R space is not refused.
      {rm_rt, _} = runtime!(ctx.rm)
      {:ok, _} = Chat.add_agent_participant(r_space.id, rm_rt.agent_id, attention_mode: "mention")

      rm_answer =
        call(Map.put(context(rm_rt), :space_id, r_space.id), "design_critique_request", args)

      refute rm_answer == expected
    end
  end

  # ── task_close_as_delivered: the root admin's own deny ──────────────────

  describe "a root admin holding a tasks.write deny" do
    test "task_close_as_delivered and task_update are refused on the denied project only",
         ctx do
      r = world!(ctx.root, "R")
      other = world!(ctx.root, "R2")
      {ra_rt, _} = runtime!(ctx.ra)
      ra_ctx = context(ra_rt)

      {:ok, _} = Grants.deny(%{principal: ctx.ra, permission: "tasks.write", resource: r.project})

      for tool <- ~w(task_close_as_delivered task_update) do
        before = snapshot([r])
        refused = call(ra_ctx, tool, args_for(tool, ids(r)))
        assert snapshot([r]) == before
        assert refused == random_answer(ra_ctx, tool, r), tool

        assert reaches_row?(ra_ctx, tool, other), "#{tool} on the undenied project"
      end
    end
  end

  # ── the caller-resolution rules ─────────────────────────────────────────

  describe "caller resolution" do
    test "an in-process caller carrying M's Scope is fenced like M's runtime", ctx do
      r = world!(ctx.root, "R")
      s = world!(ctx.s, "S")
      m_ctx = %{access_scope: Scope.for_user(ctx.m), agent_id: agent!().id}

      before = snapshot([r])
      refused = call(m_ctx, "task_update", args_for("task_update", ids(r)))
      assert snapshot([r]) == before
      assert refused == random_answer(m_ctx, "task_update", r)

      assert {:ok, %{title: "fence renamed task"}} =
               call(m_ctx, "task_update", args_for("task_update", ids(s)))
    end

    test "a runtime_id that resolves to no runtime is refused on R and S alike", ctx do
      unknown = %{runtime_id: "wfence-mcp-unknown-#{n()}", agent_id: agent!().id}

      for org <- [ctx.root, ctx.s] do
        w = world!(org, "U")
        before = snapshot([w])
        refused = call(unknown, "task_update", args_for("task_update", ids(w)))
        assert snapshot([w]) == before
        assert refused == random_answer(unknown, "task_update", w)
      end
    end

    # The stage asked for an ownerless runtime as a control. There is none
    # to call through: `agent_runtimes.owner_user_id` is NOT NULL and the
    # changeset requires it, so every `:runtime_id` an MCP context carries
    # resolves to an OWNED runtime or to nothing. `Scope.ownerless_member_scope/0`
    # is reached only by a synthetic, row-less runtime built in-process
    # (`space_read_scope/1`), which no write tool is handed.
    test "no runtime row can be ownerless" do
      changeset =
        AgentRuntime.changeset(%AgentRuntime{}, %{runtime_id: "wfence-mcp-ownerless-#{n()}"})

      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:owner_user_id]
    end

    test "no runtime_id and no Scope is today's in-process call", ctx do
      w = world!(ctx.root, "I")

      assert {:ok, %{title: "fence renamed task"}} =
               call(context(:in_process), "task_update", args_for("task_update", ids(w)))
    end

    test "an id that is not a canonical UUID is never swapped", ctx do
      {m_rt, _} = runtime!(ctx.m)

      assert call(context(m_rt), "task_update", %{"task_id" => "not-a-uuid", "title" => "x"}) ==
               call(context(:in_process), "task_update", %{
                 "task_id" => "not-a-uuid",
                 "title" => "x"
               })
    end

    test "an uppercase R id is answered as an uppercase random id", ctx do
      r = world!(ctx.root, "R")
      {m_rt, _} = runtime!(ctx.m)
      up = String.upcase(r.task.id)
      random = String.upcase(Ecto.UUID.generate())

      refused = call(context(m_rt), "task_update", %{"task_id" => up, "title" => "x"})

      expected =
        context(m_rt)
        |> call("task_update", %{"task_id" => random, "title" => "x"})
        |> replace([{random, up}])

      assert refused == expected
      assert row(Task, r.task.id).title == r.task.title
    end
  end

  # ── over the real MCP endpoint ──────────────────────────────────────────

  describe "over HTTP" do
    defp rpc!(token, tool, args) do
      body = %{
        "jsonrpc" => "2.0",
        "id" => n(),
        "method" => "tools/call",
        "params" => %{"name" => tool, "arguments" => args}
      }

      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", body)
      |> json_response(200)
    end

    test "task_update from M's token on an R task is the random-UUID answer", ctx do
      r = world!(ctx.root, "R")
      s = world!(ctx.s, "S")
      {_m_rt, token} = runtime!(ctx.m)
      random = Ecto.UUID.generate()

      before = row(Task, r.task.id)
      refused = rpc!(token, "task_update", %{"task_id" => r.task.id, "title" => "x"})
      assert row(Task, r.task.id) == before

      expected =
        token
        |> rpc!("task_update", %{"task_id" => random, "title" => "x"})
        |> Map.delete("id")
        |> replace([{random, r.task.id}])

      assert Map.delete(refused, "id") == expected
      assert %{"result" => %{"isError" => true}} = refused

      # Control: the same token renames its own org's task.
      assert %{"result" => %{"isError" => false}} =
               rpc!(token, "task_update", %{"task_id" => s.task.id, "title" => "renamed"})

      assert row(Task, s.task.id).title == "renamed"
    end
  end

  # ── STATIC GUARD ────────────────────────────────────────────────────────

  describe "STATIC GUARD: every tasks.write / tasks.manage tool is classified" do
    # The raw (permission, tool) pairs as written in ToolPermissions' source,
    # so a tool hidden from tools/list by a runtime flag is still counted.
    defp permission_source_names(permissions) do
      path = Path.expand("../../../lib/platform/access/tool_permissions.ex", __DIR__)
      {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

      {_, acc} =
        Macro.prewalk(ast, [], fn
          {perm, {:sigil_w, _, [{:<<>>, _, [words]}, _]}} = node, acc
          when is_binary(perm) ->
            if perm in permissions,
              do: {node, acc ++ String.split(words)},
              else: {node, acc}

          node, acc ->
            {node, acc}
        end)

      acc
    end

    test "the raw ToolPermissions list equals @mcp_guarded ++ @mcp_exempt" do
      raw = permission_source_names(["tasks.write", "tasks.manage"])

      assert length(raw) == 45
      assert Enum.sort(raw) == Enum.sort(@mcp_guarded ++ @mcp_exempt)

      for name <- raw,
          do: assert(ToolPermissions.for_tool(name) in ["tasks.write", "tasks.manage"], name)
    end

    test "the intercept's target table names exactly @mcp_guarded" do
      assert ToolSurface.task_write_targets() |> Map.keys() |> Enum.sort() ==
               Enum.sort(@mcp_guarded)
    end

    # A target keyed on an argument the handler never reads would fence
    # nothing and pass every list check above. Each key must appear in the
    # tool's own clause, or in the code the clause hands its args to.
    @task_attrs "../../../lib/platform/federation/task_attrs.ex"
    @read_in %{
      "design_critique_request" => [defp: "request_design_critique"],
      "report_blocker" => [defp: "record_blocker"],
      "task_create" => [file: @task_attrs],
      "task_update" => [defp: "task_update_with_base", file: @task_attrs]
    }

    test "every target key is read by its handler" do
      source =
        File.read!(Path.expand("../../../lib/platform/federation/tool_surface.ex", __DIR__))

      for {tool, targets} <- ToolSurface.task_write_targets(),
          {_type, key} <- targets,
          is_binary(key) do
        body =
          Enum.map_join([{:def, tool} | Map.get(@read_in, tool, [])], "\n", &code(source, &1))

        assert body =~ ~r/(?<![a-z_])#{key}(?![a-z_])/, "#{tool} never reads #{key}"
      end
    end

    defp code(source, {:def, tool}), do: clause(source, "  def execute(\"#{tool}\"")
    defp code(source, {:defp, name}), do: clause(source, "  defp #{name}(")
    defp code(_source, {:file, path}), do: File.read!(Path.expand(path, __DIR__))

    defp clause(source, head) do
      [_, rest] = String.split(source, head, parts: 2)
      rest |> String.split(~r/\n  defp? /, parts: 2) |> hd()
    end
  end
end
