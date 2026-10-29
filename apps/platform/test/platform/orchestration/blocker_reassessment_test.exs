defmodule Platform.Orchestration.BlockerReassessmentTest do
  use Platform.DataCase, async: false
  alias Platform.Orchestration.{BlockerReassessment, ExecutionLease, RuntimeSupervision}
  alias Platform.Tasks

  setup do
    {:ok, project} =
      Tasks.create_project(%{name: "Verification #{System.unique_integer([:positive])}"})

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Episode"})
    {:ok, dependency} = Tasks.create_task(%{project_id: project.id, title: "Headline capability"})
    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build", status: "running"})

    context = %{runtime_id: "verified-runtime", agent_id: Ecto.UUID.generate()}

    :ok =
      Platform.Orchestration.LeaseManager.record_dispatch(
        task.id,
        stage.id,
        "execution",
        DateTime.utc_now(),
        context.runtime_id
      )

    on_exit(fn -> Platform.Orchestration.LeaseManager.clear(task.id) end)

    spec = %{
      "dependencies" => [%{"kind" => "task", "task_id" => dependency.id}],
      "required_capability" => "headline_review:1",
      "verifier" => "owning_runtime"
    }

    %{task: task, dependency: dependency, stage: stage, context: context, spec: spec}
  end

  defp block(ctx, kind \\ "dependency") do
    RuntimeSupervision.record_event(%{
      task_id: ctx.task.id,
      stage_id: ctx.stage.id,
      runtime_id: ctx.context.runtime_id,
      event_type: "execution.blocked",
      payload:
        Map.merge(ctx.spec, %{
          "stage_id" => ctx.stage.id,
          "wait_kind" => kind,
          "needs_human" => true,
          "description" => "Missing installed capability"
        })
    })
  end

  defp hold(ctx),
    do: RuntimeSupervision.needs_human_hold(ctx.task.id, ctx.stage.id, ctx.context.runtime_id)

  defp complete(ctx), do: Tasks.update_task(ctx.dependency, %{status: "done"})

  defp request(ctx) do
    assert {:ok, [{:requested, req}]} = BlockerReassessment.reassess(ctx.task.id)
    req
  end

  defp evidence(req),
    do: %{
      "request_token" => req.request_token,
      "hold_revision" => req.hold_revision,
      "required_capability" => req.required_capability,
      "verified" => true,
      "evidence_refs" => ["fixture://installed-headline-overlay"]
    }

  test "block -> ack -> completion remains parked until real owning-runtime evidence", ctx do
    assert {:ok, _} = block(ctx)

    assert {:ok, _} =
             RuntimeSupervision.record_event(%{
               task_id: ctx.task.id,
               stage_id: ctx.stage.id,
               runtime_id: ctx.context.runtime_id,
               event_type: "execution.acked"
             })

    complete(ctx)
    req = request(ctx)
    assert hold(ctx).status == "blocked"

    assert {:error, :dependency_verification_required} =
             RuntimeSupervision.record_event(%{
               task_id: ctx.task.id,
               stage_id: ctx.stage.id,
               runtime_id: ctx.context.runtime_id,
               event_type: "execution.unblocked"
             })

    assert {:ok, %{released: true, event_id: id}} =
             BlockerReassessment.verify(
               ctx.task.id,
               ctx.stage.id,
               evidence(req),
               ctx.context
             )

    assert is_binary(id)
    assert hold(ctx) == nil

    assert {:error, :not_owner_or_hold_closed} =
             BlockerReassessment.verify(
               ctx.task.id,
               ctx.stage.id,
               evidence(req),
               ctx.context
             )
  end

  test "human and untyped holds never auto-convert, even with dependency prose", ctx do
    assert {:ok, event} = block(ctx, "human")
    complete(ctx)
    assert {:ok, [:human_hold]} = BlockerReassessment.reassess(ctx.task.id)
    assert hold(ctx).id == event.lease_id
    assert ExecutionLease.wait_kind(hold(ctx)) == "human"

    assert {:error, :invalid_verification} =
             BlockerReassessment.verify(
               ctx.task.id,
               ctx.stage.id,
               %{},
               ctx.context
             )
  end

  test "explicit owning recheck of legacy human hold requires valid typed references", ctx do
    block(ctx, nil)
    complete(ctx)

    assert {:error, _} =
             BlockerReassessment.recheck(ctx.task.id, ctx.stage.id, ctx.spec, %{
               ctx.context
               | runtime_id: "stranger"
             })

    assert {:ok, [{:requested, req}]} =
             BlockerReassessment.recheck(ctx.task.id, ctx.stage.id, ctx.spec, ctx.context)

    assert {:ok, %{released: true}} =
             BlockerReassessment.verify(ctx.task.id, ctx.stage.id, evidence(req), ctx.context)
  end

  test "negative verification, retry budget and restart reconciliation keep wait durable", ctx do
    block(ctx)
    complete(ctx)
    req = request(ctx)

    assert {:ok, %{released: false}} =
             BlockerReassessment.verify(
               ctx.task.id,
               ctx.stage.id,
               Map.put(evidence(req), "verified", false),
               ctx.context
             )

    failed_wait = hold(ctx).metadata["dependency_wait"]
    assert failed_wait["last_verification_by"] == ctx.context.agent_id
    assert failed_wait["last_verification_runtime"] == ctx.context.runtime_id
    assert {:ok, _, _} = DateTime.from_iso8601(failed_wait["last_verification_at"])
    assert failed_wait["evidence_refs"] == ["fixture://installed-headline-overlay"]
    now = DateTime.add(DateTime.utc_now(), 301, :second)
    assert {:ok, [{:requested, req2}]} = BlockerReassessment.reassess(ctx.task.id, now)
    assert req2.request_token != req.request_token

    assert {:error, :stale_verification} =
             BlockerReassessment.verify(ctx.task.id, ctx.stage.id, evidence(req), ctx.context)

    assert {:ok, [{:requested, _}]} =
             BlockerReassessment.reassess(ctx.task.id, DateTime.add(now, 301, :second))

    assert {:ok, [{:waiting, "verification_budget_exhausted"}]} =
             BlockerReassessment.reassess(ctx.task.id, DateTime.add(now, 602, :second))

    assert hold(ctx).metadata["dependency_wait"]["state"] == "exhausted"

    assert {:ok, [:exhausted]} =
             BlockerReassessment.reassess(ctx.task.id, DateTime.add(now, 903, :second))
  end

  test "another runtime, wrong capability and changed dependency edges fail closed", ctx do
    block(ctx)
    complete(ctx)
    req = request(ctx)

    assert {:error, _} =
             BlockerReassessment.verify(ctx.task.id, ctx.stage.id, evidence(req), %{
               ctx.context
               | runtime_id: "stranger"
             })

    assert {:error, :stale_verification} =
             BlockerReassessment.verify(
               ctx.task.id,
               ctx.stage.id,
               Map.put(evidence(req), "required_capability", "old:0"),
               ctx.context
             )

    {:ok, other} = Tasks.create_task(%{project_id: ctx.task.project_id, title: "Other"})
    Tasks.add_dependency(ctx.task, other.id)

    assert {:error, :dependency_or_stage_changed} =
             BlockerReassessment.verify(ctx.task.id, ctx.stage.id, evidence(req), ctx.context)

    assert hold(ctx).status == "blocked"
  end

  test "deleted references and stale stages cannot release", ctx do
    block(ctx)
    complete(ctx)
    req = request(ctx)
    Repo.update!(Ecto.Changeset.change(ctx.stage, status: "completed"))

    assert {:error, :dependency_or_stage_changed} =
             BlockerReassessment.verify(ctx.task.id, ctx.stage.id, evidence(req), ctx.context)

    assert hold(ctx).status == "blocked"
  end

  test "completion wakes only matching waits and duplicate signals preserve the token", ctx do
    block(ctx)

    assert {:ok, [{:waiting, "dependency_or_stage_changed"}]} =
             BlockerReassessment.reassess(ctx.task.id)

    assert {:ok, [:not_due]} =
             BlockerReassessment.dependency_completed(ctx.task.id, Ecto.UUID.generate())

    complete(ctx)

    assert {:ok, [{:requested, req}]} =
             BlockerReassessment.dependency_completed(ctx.task.id, ctx.dependency.id)

    assert {:ok, [:not_due]} =
             BlockerReassessment.dependency_completed(ctx.task.id, ctx.dependency.id)

    assert hold(ctx).metadata["dependency_wait"]["request_token"] == req.request_token

    assert {:ok, [:not_due]} =
             BlockerReassessment.recheck(ctx.task.id, ctx.stage.id, ctx.spec, ctx.context)

    assert hold(ctx).metadata["dependency_wait"]["revision"] == req.hold_revision
  end

  test "a new hold fences evidence from an earlier revision", ctx do
    block(ctx)
    complete(ctx)
    req = request(ctx)
    block(ctx)
    req2 = request(ctx)
    assert req2.hold_revision != req.hold_revision

    assert {:error, :stale_verification} =
             BlockerReassessment.verify(ctx.task.id, ctx.stage.id, evidence(req), ctx.context)

    assert {:ok, %{released: true}} =
             BlockerReassessment.verify(ctx.task.id, ctx.stage.id, evidence(req2), ctx.context)
  end

  test "expired request cannot release even with positive evidence", ctx do
    block(ctx)
    complete(ctx)
    req = request(ctx)
    lease = hold(ctx)

    wait =
      Map.put(
        lease.metadata["dependency_wait"],
        "next_due_at",
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1))
      )

    Repo.update!(
      Ecto.Changeset.change(lease, metadata: Map.put(lease.metadata, "dependency_wait", wait))
    )

    assert {:error, :stale_verification} =
             BlockerReassessment.verify(ctx.task.id, ctx.stage.id, evidence(req), ctx.context)

    assert hold(ctx).status == "blocked"
  end

  test "dependency waits do not expire or clear on heartbeat, started or progress", ctx do
    block(ctx)
    lease = hold(ctx)

    Repo.update!(
      Ecto.Changeset.change(lease, expires_at: DateTime.add(DateTime.utc_now(), -50_000))
    )

    for event <- ["execution.started", "execution.heartbeat", "execution.progress"] do
      assert {:error, :dependency_verification_required} =
               RuntimeSupervision.record_event(%{
                 task_id: ctx.task.id,
                 stage_id: ctx.stage.id,
                 runtime_id: ctx.context.runtime_id,
                 event_type: event
               })
    end

    assert hold(ctx).id == lease.id
  end

  test "empty evidence is a failed verification and never a release", ctx do
    block(ctx)
    complete(ctx)
    req = request(ctx)

    assert {:ok, %{released: false}} =
             BlockerReassessment.verify(
               ctx.task.id,
               ctx.stage.id,
               Map.put(evidence(req), "evidence_refs", []),
               ctx.context
             )

    assert hold(ctx).metadata["dependency_wait"]["verification_result"] == "failed"
  end

  test "malformed, cross-org and deleted dependency references are refused", ctx do
    bad = Map.put(ctx.spec, "dependencies", [%{"kind" => "shell", "command" => "echo unsafe"}])

    assert {:error, :invalid_dependency_wait} =
             BlockerReassessment.validate_spec(
               ctx.task.id,
               ctx.stage.id,
               ctx.context.runtime_id,
               bad
             )

    project = Repo.get!(Platform.Tasks.Project, ctx.task.project_id)

    org =
      Repo.insert!(
        Platform.Tenancy.Org.changeset(%Platform.Tenancy.Org{}, %{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}",
          parent_org_id: project.org_id
        })
      )

    {:ok, other_project} = Tasks.create_project(%{name: "Other", org_id: org.id})
    {:ok, other_task} = Tasks.create_task(%{title: "Foreign", project_id: other_project.id})
    foreign = Map.put(ctx.spec, "dependencies", [%{"kind" => "task", "task_id" => other_task.id}])

    assert {:error, :invalid_dependency_wait} =
             BlockerReassessment.validate_spec(
               ctx.task.id,
               ctx.stage.id,
               ctx.context.runtime_id,
               foreign
             )

    Repo.update!(Ecto.Changeset.change(ctx.dependency, deleted_at: DateTime.utc_now()))

    assert {:error, :invalid_dependency_wait} =
             BlockerReassessment.validate_spec(
               ctx.task.id,
               ctx.stage.id,
               ctx.context.runtime_id,
               ctx.spec
             )
  end

  test "running tool surface returns JSON-safe requests and binds release identity to context",
       ctx do
    block(ctx, nil)
    complete(ctx)
    args = Map.merge(ctx.spec, %{"task_id" => ctx.task.id, "stage_id" => ctx.stage.id})

    assert {:error, _} =
             Platform.Federation.ToolSurface.execute("blocker_recheck", args, ctx.context)

    context = Map.put(ctx.context, :access_scope, Platform.Access.Scope.system())

    assert {:ok, %{results: [%{request: req}]}} =
             Platform.Federation.ToolSurface.execute("blocker_recheck", args, context)

    assert {:ok, _json} = Jason.encode(req)

    result =
      Map.merge(evidence(req), %{
        "task_id" => ctx.task.id,
        "stage_id" => ctx.stage.id,
        "runtime_id" => "forged"
      })

    assert {:ok, %{released: true, event_id: event_id}} =
             Platform.Federation.ToolSurface.execute("blocker_verify", result, context)

    event = Repo.get!(Platform.Orchestration.RuntimeEvent, event_id)
    assert event.runtime_id == ctx.context.runtime_id
    assert event.payload["reported_by"] == ctx.context.agent_id
  end

  test "router restart restores a pending wait and delivers a scoped probe without a stage dispatch",
       ctx do
    block(ctx)
    complete(ctx)
    PlatformWeb.Endpoint.subscribe("runtime:#{ctx.context.runtime_id}")

    pid =
      start_supervised!(
        {Platform.Orchestration.TaskRouter,
         [task_id: ctx.task.id, assignee: %{type: :federated, id: ctx.context.runtime_id}]}
      )

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "blocker_verification_requested",
                     payload: req
                   },
                   1500

    assert req.task_id == ctx.task.id
    assert req.stage_id == ctx.stage.id
    assert hold(ctx).status == "blocked"
    refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 50
    monitor = Process.monitor(pid)
    stop_supervised!(Platform.Orchestration.TaskRouter)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}

    pid2 =
      start_supervised!(
        {Platform.Orchestration.TaskRouter,
         [task_id: ctx.task.id, assignee: %{type: :federated, id: ctx.context.runtime_id}]},
        id: :restarted_router
      )

    :sys.get_state(pid2)
    assert hold(ctx).metadata["dependency_wait"]["request_token"] == req.request_token
    refute_receive %Phoenix.Socket.Broadcast{event: "blocker_verification_requested"}, 50
  end

  test "live dependency completion requests verification promptly without duplicate probes",
       ctx do
    block(ctx)
    PlatformWeb.Endpoint.subscribe("runtime:#{ctx.context.runtime_id}")

    pid =
      start_supervised!(
        {Platform.Orchestration.TaskRouter,
         [task_id: ctx.task.id, assignee: %{type: :federated, id: ctx.context.runtime_id}]}
      )

    :sys.get_state(pid)
    complete(ctx)

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "blocker_verification_requested",
                     payload: req
                   },
                   1500

    Tasks.broadcast_board({:dependency_completed, ctx.dependency.id})
    :sys.get_state(pid)
    assert hold(ctx).metadata["dependency_wait"]["request_token"] == req.request_token
    refute_receive %Phoenix.Socket.Broadcast{event: "blocker_verification_requested"}, 50
    assert hold(ctx).status == "blocked"
  end

  test "a runtime ownership change fences an already issued verification", ctx do
    block(ctx)
    complete(ctx)
    req = request(ctx)

    :ok =
      Platform.Orchestration.LeaseManager.record_dispatch(
        ctx.task.id,
        ctx.stage.id,
        "execution",
        DateTime.utc_now(),
        "replacement-runtime"
      )

    assert {:error, :dependency_or_stage_changed} =
             BlockerReassessment.verify(
               ctx.task.id,
               ctx.stage.id,
               evidence(req),
               ctx.context
             )

    assert hold(ctx).status == "blocked"
  end

  test "only an explicit attributed recheck restarts an exhausted verification budget", ctx do
    block(ctx)
    complete(ctx)
    req = request(ctx)
    lease = hold(ctx)

    wait =
      Map.merge(lease.metadata["dependency_wait"], %{
        "state" => "exhausted",
        "attempts" => 3,
        "next_due_at" => nil
      })

    Repo.update!(
      Ecto.Changeset.change(lease, metadata: Map.put(lease.metadata, "dependency_wait", wait))
    )

    assert {:ok, [:exhausted]} =
             BlockerReassessment.dependency_completed(ctx.task.id, ctx.dependency.id)

    assert {:ok, [{:requested, new_req}]} =
             BlockerReassessment.recheck(ctx.task.id, ctx.stage.id, ctx.spec, ctx.context)

    assert new_req.hold_revision != req.hold_revision
    assert hold(ctx).metadata["dependency_wait"]["attempts"] == 1

    assert {:ok, [:not_due]} =
             BlockerReassessment.recheck(ctx.task.id, ctx.stage.id, ctx.spec, ctx.context)
  end

  test "explicitly classified human action cannot be demoted through dependency recheck", ctx do
    block(ctx, "human")
    complete(ctx)

    assert {:error, :not_owner_or_invalid_wait} =
             BlockerReassessment.recheck(ctx.task.id, ctx.stage.id, ctx.spec, ctx.context)

    assert {:ok, [:human_hold]} = BlockerReassessment.reassess(ctx.task.id)
    assert hold(ctx).metadata["wait_kind"] == "human"
  end

  test "a capped scope cannot classify or release even its own live runtime hold", ctx do
    block(ctx, nil)
    complete(ctx)
    args = Map.merge(ctx.spec, %{"task_id" => ctx.task.id, "stage_id" => ctx.stage.id})
    capped = Map.put(ctx.context, :access_scope, %Platform.Access.Scope{})
    permitted = Map.put(ctx.context, :access_scope, Platform.Access.Scope.system())
    before = hold(ctx).metadata
    assert {:error, _} = Platform.Federation.ToolSurface.execute("blocker_recheck", args, capped)
    assert hold(ctx).metadata == before

    assert {:ok, %{results: [%{request: req}]}} =
             Platform.Federation.ToolSurface.execute("blocker_recheck", args, permitted)

    result = Map.merge(evidence(req), %{"task_id" => ctx.task.id, "stage_id" => ctx.stage.id})
    assert {:error, _} = Platform.Federation.ToolSurface.execute("blocker_verify", result, capped)
    assert hold(ctx).status == "blocked"

    assert {:ok, %{released: true}} =
             Platform.Federation.ToolSurface.execute("blocker_verify", result, permitted)
  end

  test "user recheck is authorized, revision fenced and duplicate safe", ctx do
    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "recheck#{System.unique_integer([:positive])}@example.com",
        name: "Rechecker",
        oidc_sub: Ecto.UUID.generate()
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    scope = Platform.Access.Scope.for_user(user)
    assert {:ok, _} = block(ctx)
    complete(ctx)
    l = hold(ctx)
    revision = RuntimeSupervision.hold_revision(l)

    assert {:error, _} =
             BlockerReassessment.request_from_user(
               ctx.task.id,
               ctx.stage.id,
               l.id,
               revision,
               %Platform.Access.Scope{},
               user.id
             )

    assert {:error, _} =
             BlockerReassessment.request_from_user(
               ctx.task.id,
               ctx.stage.id,
               l.id,
               "stale",
               scope,
               user.id
             )

    assert {:ok, _} =
             BlockerReassessment.request_from_user(
               ctx.task.id,
               ctx.stage.id,
               l.id,
               revision,
               scope,
               user.id
             )

    first = hold(ctx).metadata["dependency_wait"]
    assert first["state"] == "verifying"
    assert first["requested_by_user"] == user.id

    assert {:ok, _} =
             BlockerReassessment.request_from_user(
               ctx.task.id,
               ctx.stage.id,
               l.id,
               revision,
               scope,
               user.id
             )

    assert hold(ctx).metadata["dependency_wait"] == first
    assert hold(ctx).status == "blocked"
  end

  test "UI recheck never reclassifies an explicit human hold", ctx do
    user =
      Repo.insert!(%Platform.Accounts.User{
        email: "humanrecheck#{System.unique_integer([:positive])}@example.com",
        name: "Rechecker",
        oidc_sub: Ecto.UUID.generate()
      })
      |> Platform.TenancyFixtures.member_of_all_orgs!()

    assert {:ok, _} = block(ctx, "human")
    l = hold(ctx)

    assert {:error, _} =
             BlockerReassessment.request_from_user(
               ctx.task.id,
               ctx.stage.id,
               l.id,
               RuntimeSupervision.hold_revision(l),
               Platform.Access.Scope.for_user(user),
               user.id
             )

    assert hold(ctx).status == "blocked"
  end
end
