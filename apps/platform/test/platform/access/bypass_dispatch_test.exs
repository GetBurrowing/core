defmodule Platform.Access.BypassDispatchTest do
  @moduledoc """
  An agent is not WOKEN onto a task or a space its owner, or its own grants,
  may not read (task 01a1386e-45a5 stage 2, RBAC stack member 7;
  `0058-rbac-v2-roles-scopes-and-agent-capping.md § Precedence`,
  "The grant-less short-circuit").

  Three wake paths, each conjunctive with its existing gate:

    * the TaskRouter's dispatch target, `PhaseRuntime.resolve/1`, now refuses
      with `{:error, :owner_denied}` and `TaskRouter.refresh_assignee/2`
      SUPPRESSES on it (the fail-open arm would otherwise dispatch to the
      held runtime);
    * the `@`-mention summon (`Chat.reinvite_and_pin_mentioned/1`);
    * `AttentionRouter` routing to an agent that is ALREADY a participant,
      including the execution-assignee fallback.

  Every absence assertion is preceded, in the same test and on the same
  fixture, by its POSITIVE CONTROL: the identical call wakes the agent
  before the deny row exists.

  ## Premises this suite records

    * **Until stack member 5 a runtime's Scope carries only the agent's OWN
      grants.** So a deny on the owner U refuses through the OWNER half of
      the decision (`Scope.for_user(U)`); the owner-deny tests assert that
      the runtime Scope holds no grant at all, which pins which half fired.
      The agent-principal deny is its own test.
    * **A grant or deny applies only to its own permission.** Dispatch reads
      `tasks.read` on `{:task, id}`; the summon and the attention router read
      `chat.read` on `{:space, id}`. The tests deny the permission each path
      reads.
    * **A runtime owned by an EXTERNAL user still dispatches with no
      grants.** That is today's behaviour, preserved by the no-grants rule;
      the zero-grant row pins it as a pre-existing exposure, not a fix.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.TenancyFixtures

  alias Platform.Access.{Grants, Scope}
  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Chat
  alias Platform.Chat.{ActiveAgentStore, AttentionRouter, Message, Participant}
  alias Platform.Federation
  alias Platform.Orchestration.{ExecutionSpace, LeaseManager, PhaseRuntime}
  alias Platform.Orchestration.{TaskRouter, TaskRouterWatcher}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema
  alias Platform.Tenancy
  alias Platform.Tenancy.OrgMembership

  # Fixed OBSERVATION window: "no dispatch arrived" is an absence claim, and
  # absence is only provable against a window (mirrors
  # task_router_phase_assignee_test.exs).
  @observe_ms 1_500

  defmodule StubAgentChat do
    @moduledoc false
    def chat(_agent, message, opts \\ []) do
      if pid = Application.get_env(:platform, :chat_agent_test_pid) do
        send(pid, {:agent_chat_called, message, opts})
      end

      {:ok, %{content: "stub reply", model: "stub", usage: %{}}}
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    _root = acme_org_id()
    org = tenant_org_id("bpd-#{System.unique_integer([:positive])}")

    p = project!(org, "bpd-p")
    q = project!(org, "bpd-q")
    u = member!(org)
    {agent_b, rt_b} = linked!(u, "b")

    %{org: org, p: p, q: q, u: u, agent_b: agent_b, rt_b: rt_b}
  end

  # ── TaskRouter dispatch ─────────────────────────────────────────────────

  describe "TaskRouter dispatch" do
    test "a deny on the OWNER refuses resolve and dispatch; P on the same runtime still dispatches",
         ctx do
      %{agent_b: b, rt_b: rt, u: u} = ctx
      tq = dispatchable_task!(ctx.q, b, "bpd q task")
      tp = dispatchable_task!(ctx.p, b, "bpd p task")
      subscribe(rt)

      # Positive control: same task, same runtime, before the deny.
      assert {:ok, %{type: :federated, id: rt_id}} = PhaseRuntime.resolve(tq)
      assert rt_id == rt.runtime_id
      start_router!(tq.id, rt)
      assert collect_attention_topics() == ["runtime:#{rt.runtime_id}"]
      assert %{stage_id: _} = LeaseManager.get(tq.id)
      stop_router(tq.id)
      assert LeaseManager.get(tq.id) == nil

      deny!({:user, u.id}, "tasks.read", {:project, ctx.q.id})

      # The OWNER half is the one that fires: the runtime's own Scope holds
      # no grant at all.
      refute Scope.has_grants?(Scope.for_runtime(rt))
      assert Scope.has_grants?(Scope.for_user(u))

      assert PhaseRuntime.resolve(tq) == {:error, :owner_denied}
      assert TaskRouterWatcher.resolve_runtime_for_task(tq) == {:error, :owner_denied}

      attach_suppression_telemetry()
      start_router!(tq.id, rt)

      assert collect_attention_topics() == [],
             "a refused runtime must not be dispatched to through the fail-open arm"

      assert LeaseManager.get(tq.id) == nil
      assert_received {:dispatch_suppressed, %{task_id: suppressed, reason: :owner_denied}}
      assert suppressed == tq.id
      assert TaskRouter.current_status(tq.id).status != :stalled

      log = execution_space_text(tq.id)
      assert log =~ "owner_denied"
      assert log =~ rt.runtime_id
      refute log =~ ctx.q.name

      # Same runtime, task in P: untouched by the deny on Q.
      assert {:ok, %{id: ^rt_id}} = PhaseRuntime.resolve(tp)
      start_router!(tp.id, rt)
      assert collect_attention_topics() == ["runtime:#{rt.runtime_id}"]
      assert %{stage_id: _} = LeaseManager.get(tp.id)
    end

    test "the watcher starts no router for a refused task", ctx do
      %{agent_b: b, u: u} = ctx
      start_supervised!(TaskRouterWatcher)
      tq = dispatchable_task!(ctx.q, b, "bpd watcher q")
      tp = dispatchable_task!(ctx.p, b, "bpd watcher p")
      on_exit(fn -> Enum.each([tq.id, tp.id], &stop_router/1) end)

      # Positive control: the watcher starts a router for TQ before the deny.
      watcher_evaluate([tq])
      assert TaskRouterWatcher.router_running?(tq.id)
      stop_router(tq.id)
      refute TaskRouterWatcher.router_running?(tq.id)

      deny!({:user, u.id}, "tasks.read", {:project, ctx.q.id})

      watcher_evaluate([tq, tp])

      refute TaskRouterWatcher.router_running?(tq.id),
             "an :owner_denied resolution is an error, so the watcher must start no router"

      assert TaskRouterWatcher.router_running?(tp.id)
    end

    test "a deny on the agent's OWN principal refuses while the owner is allowed", ctx do
      %{agent_b: b, rt_b: rt, u: u} = ctx
      tq = dispatchable_task!(ctx.q, b, "bpd agent-deny q")
      subscribe(rt)

      grant!({:user, u.id}, "tasks.read", {:project, ctx.q.id})
      assert {:ok, _} = PhaseRuntime.resolve(tq)

      deny!({:agent, b.id}, "tasks.read", {:project, ctx.q.id})

      assert PhaseRuntime.resolve(tq) == {:error, :owner_denied}
      start_router!(tq.id, rt)
      assert collect_attention_topics() == []
      assert LeaseManager.get(tq.id) == nil
    end

    test "after the deny is revoked the next :dispatch sends", ctx do
      %{agent_b: b, rt_b: rt, u: u} = ctx
      tq = dispatchable_task!(ctx.q, b, "bpd revoke q")
      subscribe(rt)

      {:ok, row} =
        Grants.deny(%{
          principal: {:user, u.id},
          permission: "tasks.read",
          resource: {:project, ctx.q.id}
        })

      pid = start_router!(tq.id, rt)
      assert collect_attention_topics() == []

      {:ok, _} = Grants.revoke(row)
      send(pid, :dispatch)

      assert collect_attention_topics() == ["runtime:#{rt.runtime_id}"],
             "the refusal must have been the deny: revoking it restores the dispatch"

      assert %{stage_id: _} = LeaseManager.get(tq.id)
    end

    test "zero grants: a runtime owned by an EXTERNAL user resolves exactly as on base", ctx do
      ext = guest!(ctx.org)
      {agent_e, rt_e} = linked!(ext, "ext")
      te = dispatchable_task!(ctx.q, agent_e, "bpd ext q")

      refute Scope.has_grants?(Scope.for_user(ext))
      refute Scope.has_grants?(Scope.for_runtime(rt_e))
      assert Tenancy.external_user?(%{id: ext.id})

      assert {:ok, %{type: :federated, id: id}} = PhaseRuntime.resolve(te)
      assert id == rt_e.runtime_id
    end
  end

  # ── @-mention summon ────────────────────────────────────────────────────

  describe "@-mention summon" do
    test "an admin's mention adds B before the deny and is refused after it", ctx do
      %{agent_b: b, u: u} = ctx
      tq = dispatchable_task!(ctx.q, b, "bpd mention q")
      {:ok, eq} = ExecutionSpace.find_or_create(tq.id)
      m = member!(ctx.org)
      pm = user_participant!(eq.id, m, "admin")

      # Positive control: the authorized mention adds B, nothing refused.
      post_from_self!(eq.id, pm.id, "please look @[" <> b.slug <> "]")
      refute_receive {:mention_summon_refused, _, _}, 200
      assert [_row] = agent_rows(eq.id, b.id)

      Repo.delete_all(
        from(pp in Participant,
          where:
            pp.space_id == ^eq.id and pp.participant_type == "agent" and
              pp.participant_id == ^b.id
        )
      )

      deny!({:user, u.id}, "chat.read", {:project, ctx.q.id})

      msg = post_from_self!(eq.id, pm.id, "again @[" <> b.slug <> "]")

      assert_receive {:mention_summon_refused, id, names}
      assert id == msg.id
      assert names == [b.name]
      assert agent_rows(eq.id, b.id) == []
    end

    test "zero grants: agent_may_read_space? is true for every agent", ctx do
      tq = dispatchable_task!(ctx.q, ctx.agent_b, "bpd zero mention")
      {:ok, eq} = ExecutionSpace.find_or_create(tq.id)
      ext = guest!(ctx.org)
      {agent_e, _rt_e} = linked!(ext, "ext-zero")
      unlinked = agent!("unlinked")

      for agent <- [ctx.agent_b, agent_e, unlinked] do
        assert Chat.agent_may_read_space?(agent, eq.id)
      end
    end
  end

  # ── AttentionRouter ─────────────────────────────────────────────────────

  describe "AttentionRouter" do
    setup :attention_router

    test "a participant agent is mention-routed before the deny and not after", ctx do
      %{agent_b: b, u: u} = ctx
      tq = dispatchable_task!(ctx.q, b, "bpd route q")
      {:ok, eq} = ExecutionSpace.find_or_create(tq.id)
      m = member!(ctx.org)
      pm = user_participant!(eq.id, m, "member")
      {:ok, pb} = Chat.add_agent_participant(eq.id, b)
      Chat.add_space_agent(eq.id, b.id, role: "member")
      pb_id = pb.id

      # Positive control: the mention routes to B.
      before = insert_message!(eq.id, pm.id, "hey @[" <> b.slug <> "] help")
      assert {:ok, decisions} = AttentionRouter.route(before)
      assert Enum.any?(decisions, &match?(%{participant_id: ^pb_id, reason: :mention}, &1))

      deny!({:user, u.id}, "chat.read", {:project, ctx.q.id})

      after_deny = insert_message!(eq.id, pm.id, "hey @[" <> b.slug <> "] help again")
      assert {:ok, decisions} = AttentionRouter.route(after_deny)

      refute Enum.any?(decisions, &(&1.participant_id == pb_id)),
             "a refused agent must get no decision at all, saw #{inspect(decisions)}"

      refute Enum.any?(decisions, &(&1.reason in [:mention, :multi_mention]))
    end

    test "the execution-assignee fallback does not wake a refused assignee", ctx do
      %{agent_b: b, u: u} = ctx
      tq = dispatchable_task!(ctx.q, b, "bpd fallback q")
      {:ok, eq} = ExecutionSpace.find_or_create(tq.id)
      m = member!(ctx.org)
      pm = user_participant!(eq.id, m, "member")

      # Positive control: an unmentioned message wakes the assignee and adds
      # it to the space.
      before = insert_message!(eq.id, pm.id, "status?")
      assert {:ok, [%{participant_id: pb_id}]} = AttentionRouter.route(before)
      assert [%Participant{id: ^pb_id}] = agent_rows(eq.id, b.id)

      deny!({:user, u.id}, "chat.read", {:project, ctx.q.id})
      ActiveAgentStore.clear_active(eq.id)

      after_deny = insert_message!(eq.id, pm.id, "status now?")
      assert {:ok, decisions} = AttentionRouter.route(after_deny)
      refute Enum.any?(decisions, &(&1.participant_id == pb_id))
    end

    test "zero grants: routing a message adds exactly one access_grants query", ctx do
      tq = dispatchable_task!(ctx.q, ctx.agent_b, "bpd count q")
      {:ok, eq} = ExecutionSpace.find_or_create(tq.id)
      m = member!(ctx.org)
      pm = user_participant!(eq.id, m, "member")
      {:ok, _pb} = Chat.add_agent_participant(eq.id, ctx.agent_b)
      Chat.add_space_agent(eq.id, ctx.agent_b.id, role: "member")

      {:ok, channel} =
        Chat.create_space(%{
          name: "bpd-human-only",
          slug: "bpd-h-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      ph = user_participant!(channel.id, m, "member")

      counter = count_grant_queries()

      for content <- ["hey @[" <> ctx.agent_b.slug <> "]", "plain message"] do
        msg = insert_message!(eq.id, pm.id, content)
        reset(counter)
        assert {:ok, _} = AttentionRouter.route(msg)
        assert read(counter) == 1, "#{inspect(content)}: #{read(counter)} access_grants queries"
      end

      # No agent participant: no query at all.
      msg = insert_message!(channel.id, ph.id, "only humans here")
      reset(counter)
      assert {:ok, _} = AttentionRouter.route(msg)
      assert read(counter) == 0
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "bpd-#{tag}-#{n}@example.com",
      name: "BPD #{tag} #{n}",
      oidc_sub: "bpd-#{tag}-#{n}"
    })
  end

  defp member!(org) do
    u = user!("member")

    %OrgMembership{}
    |> OrgMembership.changeset(%{user_id: u.id, org_id: org, role: "member"})
    |> Repo.insert!()

    u
  end

  defp guest!(org) do
    u = user!("guest")
    {:ok, _} = Tenancy.mark_membership_external(%{user_id: u.id, org_id: org})
    u
  end

  defp project!(org, name) do
    {:ok, p} =
      Tasks.create_project(%{name: "#{name}-#{System.unique_integer([:positive])}", org_id: org})

    p
  end

  defp agent!(label) do
    n = System.unique_integer([:positive])

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "bpd-#{label}-#{n}",
        name: "BPD #{label} #{n}",
        status: "active"
      })
      |> Repo.insert()

    agent
  end

  # A REAL agent -> runtime link (never the synthetic `%{type: :federated,
  # id: "runtime-test-..."}` map, which only dispatches through the fail-open
  # arm).
  defp linked!(owner, label) do
    agent = agent!(label)

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "bpd-#{label}-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw} = Federation.activate_runtime(runtime)
    {:ok, linked_agent} = Federation.link_agent(activated, agent)

    {linked_agent, Repo.get!(AgentRuntime, activated.id)}
  end

  # Active status, agent assignee in every phase, approved plan with a
  # RUNNING stage, so a dispatch records a LeaseManager row.
  defp dispatchable_task!(project, agent, title) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "#{title} #{System.unique_integer([:positive])}",
        description: "bypass dispatch",
        deploy_target: "production"
      })

    entry = %{"assignee_id" => agent.id, "assignee_type" => "agent"}

    task =
      task
      |> Ecto.Changeset.change(%{
        status: "in_progress",
        assignee_id: agent.id,
        assignee_type: "agent",
        phase_assignees: %{"planning" => entry, "execution" => entry}
      })
      |> Repo.update!()

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "coding", description: "code"})

    {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    stage
    |> Ecto.Changeset.change(%{status: "running", started_at: DateTime.utc_now()})
    |> Repo.update!()

    Repo.get!(TaskSchema, task.id)
  end

  defp deny!(principal, permission, resource),
    do:
      {:ok, _} = Grants.deny(%{principal: principal, permission: permission, resource: resource})

  defp grant!(principal, permission, resource),
    do:
      {:ok, _} = Grants.grant(%{principal: principal, permission: permission, resource: resource})

  defp user_participant!(space_id, user, role) do
    {:ok, p} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        role: role,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp agent_rows(space_id, agent_id) do
    Repo.all(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "agent" and
            p.participant_id == ^agent_id
      )
    )
  end

  defp post_from_self!(space_id, participant_id, content) do
    {:ok, msg} =
      Chat.post_message(
        %{
          space_id: space_id,
          participant_id: participant_id,
          content_type: "text",
          content: content
        },
        from_pid: self()
      )

    msg
  end

  defp insert_message!(space_id, participant_id, content) do
    %Message{}
    |> Message.changeset(%{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content
    })
    |> Repo.insert!()
  end

  defp execution_space_text(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)

    Repo.all(from(m in Message, where: m.space_id == ^space.id, select: m.content))
    |> Enum.join("\n")
  end

  # ── router harness (mirrors task_router_phase_assignee_test.exs) ────────

  defp subscribe(%AgentRuntime{runtime_id: id}),
    do: PlatformWeb.Endpoint.subscribe("runtime:#{id}")

  defp start_router!(task_id, %AgentRuntime{runtime_id: id}) do
    {:ok, pid} = TaskRouter.start_link(task_id: task_id, assignee: %{type: :federated, id: id})
    on_exit(fn -> stop_router(task_id) end)
    pid
  end

  defp stop_router(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end

    case :ets.info(:orchestration_lease_manager) do
      :undefined -> :ok
      _ -> LeaseManager.clear(task_id)
    end
  end

  defp watcher_evaluate(tasks) do
    watcher = Process.whereis(TaskRouterWatcher)
    Enum.each(tasks, &send(watcher, {:task_updated, Repo.get!(TaskSchema, &1.id)}))
    TaskRouterWatcher.sync()
  end

  defp collect_attention_topics(window_ms \\ @observe_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    drain_attention(deadline, [])
  end

  defp drain_attention(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        %Phoenix.Socket.Broadcast{event: "attention", topic: topic} ->
          drain_attention(deadline, [topic | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp attach_suppression_telemetry do
    test_pid = self()
    handler_id = "bpd-suppressed-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :orchestration, :dispatch_suppressed],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:dispatch_suppressed, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # ── AttentionRouter harness (mirrors attention_router_test.exs) ─────────

  defp attention_router(_ctx) do
    previous =
      for k <- [:chat_agent_module, :chat_agent_dispatch_mode, :chat_agent_test_pid],
          do: {k, Application.get_env(:platform, k)}

    Application.put_env(:platform, :chat_agent_module, StubAgentChat)
    Application.put_env(:platform, :chat_agent_dispatch_mode, :sync)
    Application.put_env(:platform, :chat_agent_test_pid, self())

    on_exit(fn -> Enum.each(previous, fn {k, v} -> Application.put_env(:platform, k, v) end) end)

    _router = Process.whereis(AttentionRouter) || start_supervised!({AttentionRouter, []})
    _store = Process.whereis(ActiveAgentStore) || start_supervised!({ActiveAgentStore, []})
    :ok
  end

  # Counts `access_grants` queries from ANY process (the AttentionRouter runs
  # them in its own GenServer).
  defp count_grant_queries do
    counter = :counters.new(1, [])
    handler_id = "bpd-grant-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:platform, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if metadata[:source] == "access_grants", do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    counter
  end

  # Drain the router's mailbox first, so telemetry-triggered routes of
  # messages posted by the fixture are not counted against the call.
  defp reset(counter) do
    :ok = GenServer.call(AttentionRouter, :__drain__)
    :counters.put(counter, 1, 0)
  end

  defp read(counter), do: :counters.get(counter, 1)
end
