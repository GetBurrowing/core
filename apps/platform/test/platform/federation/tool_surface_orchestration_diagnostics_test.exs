defmodule Platform.Federation.ToolSurfaceOrchestrationDiagnosticsTest do
  @moduledoc """
  Tests for `runtime_event_list` and `execution_lease_list` — the read-back MCP
  surface over `runtime_events` and `execution_leases`.

  Both are READ ONLY. The rows already exist and are already written by
  `Platform.Orchestration.RuntimeSupervision` inside the transaction that
  records the event; no writer and no migration is added, which is why nothing
  here asserts that calling a tool records something. It must not.

  ## The fact these tools exist to make findable

  A task can carry a full runtime-event stream and ZERO execution leases, and
  that is normal. `RuntimeSupervision`'s `@event_statuses` maps
  `"execution.acked" => nil`, and `upsert_lease/2` short-circuits on a nil
  status — returning any existing lease and inserting nothing. So a plain
  dispatch-ack never creates a lease. Before these tools, confirming that
  required SSH plus a hand-written SQL query, which is precisely what a
  federated agent diagnosing a watchdog false-alarm does not have. The
  `empty lease list is normal` case is pinned as a test below rather than left
  to the docstring.

  ## What these tests actually exercise

  Every assertion is on `ToolSurface.execute/3` OUTPUT, never on the
  registration map alone. A registration that reads correctly while the call
  itself fails is the failure mode a registration-only test walks straight
  through.
  """

  use Platform.DataCase, async: false

  import Platform.TenancyFixtures

  alias Platform.Agents.Agent
  alias Platform.Federation.{ToolAuthorization, ToolSurface}
  alias Platform.Orchestration.{Diagnostics, ExecutionLease, RuntimeEvent}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy

  setup do
    acme = ensure_root_org()
    globex = ensure_tenant_org("globex-diag-#{u()}", acme)
    vandelay_ind = ensure_tenant_org("vandelay-ind-diag-#{u()}", acme)

    {:ok, project} = Tasks.create_project(%{name: "Diag Proj #{u()}", org_id: globex.id})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Watched Task"})
    {:ok, quiet_task} = Tasks.create_task(%{project_id: project.id, title: "Untouched Task"})

    stage_id = Ecto.UUID.generate()

    lease = insert_lease(task, stage_id, "blocked", "runtime-alpha")

    insert_event(task, "execution.acked", %{"stage_id" => stage_id, "subagent_id" => "sub-1"},
      runtime_id: "runtime-alpha",
      occurred_at: minutes_ago(30)
    )

    insert_event(task, "execution.blocked", %{"stage_id" => stage_id, "reason" => "needs input"},
      runtime_id: "runtime-alpha",
      lease_id: lease.id,
      occurred_at: minutes_ago(10)
    )

    %{
      task: task,
      quiet_task: quiet_task,
      stage_id: stage_id,
      lease: lease,
      agent_globex: create_agent("globex-agent", %{"org_id" => globex.id}),
      agent_pt: create_agent("pt-agent", %{"org_id" => vandelay_ind.id})
    }
  end

  describe "registration" do
    test "both live in the task bundle and nowhere else" do
      names = ToolSurface.list_tools(["task"]) |> MapSet.new(& &1.name)
      assert "runtime_event_list" in names
      assert "execution_lease_list" in names

      others = ~w(canvas messaging plan review space context_read federation memory
                  skill attachment files)

      for bundle <- others, tool <- ~w(runtime_event_list execution_lease_list) do
        bundle_names = ToolSurface.list_tools([bundle]) |> MapSet.new(& &1.name)
        refute tool in bundle_names, "#{tool} leaked into the #{bundle} bundle"
      end
    end

    # The empty-lease-list fact is the whole reason a caller can trust a zero
    # result. If it drops out of the description, the tool silently regresses
    # to the state that forced a human to run SQL.
    test "each tool's limitations string states that zero leases is normal" do
      tools = ToolSurface.list_tools(["task"])

      for name <- ~w(runtime_event_list execution_lease_list) do
        tool = Enum.find(tools, &(&1.name == name))
        assert tool, "#{name} not registered"
        assert tool.limitations =~ "execution.acked"
        assert tool.limitations =~ ~r/zero (execution )?leases|EMPTY LIST/i
      end
    end

    test "a runtime holding the task bundle may call them; one without may not" do
      for tool <- ~w(runtime_event_list execution_lease_list) do
        assert ToolAuthorization.authorize(
                 tool,
                 Platform.RuntimeProfileFixtures.runtime!(root_admin!().id, ["task"])
               ) == :ok

        assert ToolAuthorization.authorize(
                 tool,
                 Platform.RuntimeProfileFixtures.runtime!(root_admin!().id, ["plan", "review"])
               ) == {:error, :forbidden}
      end
    end
  end

  describe "runtime_event_list execute/3" do
    # (a) payload["stage_id"] survives the round trip. There is no top-level
    # stage_id column, so a serializer that plucked a curated subset would
    # destroy the only stage attribution these rows carry.
    test "events come back newest first with payload[\"stage_id\"] intact", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "runtime_event_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_globex)
               )

      assert result.task_id == ctx.task.id
      assert result.count == 2
      assert [newest, older] = result.events

      assert newest.event_type == "execution.blocked"
      assert older.event_type == "execution.acked"

      assert newest.payload["stage_id"] == ctx.stage_id
      assert older.payload["stage_id"] == ctx.stage_id
      assert older.payload["subagent_id"] == "sub-1"

      assert newest.runtime_id == "runtime-alpha"
      assert newest.lease_id == ctx.lease.id
      assert %DateTime{} = newest.occurred_at
      assert newest.phase == "execution"
    end

    test "event_type filters to that type only", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "runtime_event_list",
                 %{"task_id" => ctx.task.id, "event_type" => "execution.acked"},
                 context_for(ctx.agent_globex)
               )

      assert result.count == 1
      assert [%{event_type: "execution.acked"}] = result.events
    end

    # (b) The cap is a clamp, not a rejection — and the reported `limit` must
    # be the value actually applied, or the response lies about truncation.
    test "limit is clamped at 200 rather than honoured or rejected", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "runtime_event_list",
                 %{"task_id" => ctx.task.id, "limit" => 5000},
                 context_for(ctx.agent_globex)
               )

      assert result.limit == 200
    end

    test "limit is honoured below the cap and truncates the result", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "runtime_event_list",
                 %{"task_id" => ctx.task.id, "limit" => 1},
                 context_for(ctx.agent_globex)
               )

      assert result.limit == 1
      assert result.count == 1
      # Newest-first ordering means truncation drops the OLDEST, not the newest.
      assert [%{event_type: "execution.blocked"}] = result.events
    end

    test "an absent task_id is refused, not answered with a zero-row shape", ctx do
      assert {:error, envelope} =
               ToolSurface.execute("runtime_event_list", %{}, context_for(ctx.agent_globex))

      assert envelope.error =~ "task_id"
      refute Map.has_key?(envelope, :count)
      refute Map.has_key?(envelope, :events)
    end

    test "no `id` alias is accepted in place of task_id", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "runtime_event_list",
                 %{"id" => ctx.task.id},
                 context_for(ctx.agent_globex)
               )

      assert envelope.error =~ "task_id"
    end
  end

  describe "execution_lease_list execute/3" do
    test "leases come back with lifecycle timestamps and block_reason", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_globex)
               )

      assert result.count == 1
      assert [lease] = result.leases

      assert lease.id == ctx.lease.id
      assert lease.stage_id == ctx.stage_id
      assert lease.phase == "execution"
      assert lease.runtime_id == "runtime-alpha"
      assert lease.status == "blocked"
      assert lease.block_reason == "waiting on a human decision"
      assert lease.metadata == %{"note" => "operator prose"}
      assert %DateTime{} = lease.started_at
      assert %DateTime{} = lease.expires_at
      assert Map.has_key?(lease, :last_heartbeat_at)
      assert Map.has_key?(lease, :last_progress_at)
    end

    test "status filter narrows to that status", ctx do
      assert {:ok, blocked} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id, "status" => "blocked"},
                 context_for(ctx.agent_globex)
               )

      assert blocked.count == 1

      assert {:ok, active} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id, "status" => "active"},
                 context_for(ctx.agent_globex)
               )

      assert active.count == 0
    end

    # (c) A typo'd status must REFUSE. Returning everything would hand back a
    # list the caller believes is filtered; returning [] would be
    # indistinguishable from the genuinely-empty case below — the exact
    # ambiguity this tool exists to remove.
    test "an unknown status is rejected rather than silently returning everything", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id, "status" => "blokced"},
                 context_for(ctx.agent_globex)
               )

      assert envelope.error =~ "status"
      refute Map.has_key?(envelope, :leases)
      refute Map.has_key?(envelope, :count)

      # And the suggestion must name the real vocabulary, so the caller can fix
      # it without reading source.
      for status <- ExecutionLease.statuses() do
        assert envelope.suggestion =~ status
      end
    end

    # THE load-bearing case. A task can have events and no leases and be
    # perfectly healthy.
    test "a task with runtime events but no lease returns an empty list, not an error", ctx do
      insert_event(ctx.quiet_task, "execution.acked", %{"stage_id" => Ecto.UUID.generate()},
        runtime_id: "runtime-beta"
      )

      assert {:ok, events} =
               ToolSurface.execute(
                 "runtime_event_list",
                 %{"task_id" => ctx.quiet_task.id},
                 context_for(ctx.agent_globex)
               )

      assert events.count == 1

      assert {:ok, leases} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.quiet_task.id},
                 context_for(ctx.agent_globex)
               )

      assert leases.count == 0
      assert leases.leases == []
    end

    test "an absent task_id is refused", ctx do
      assert {:error, envelope} =
               ToolSurface.execute("execution_lease_list", %{}, context_for(ctx.agent_globex))

      assert envelope.error =~ "task_id"
      refute Map.has_key?(envelope, :leases)
    end
  end

  describe "authorization" do
    # (d) Denial on BOTH tools, and the envelope must carry no prose. The
    # refutes scan the WHOLE envelope rather than the `error` string — that is
    # the only thing that catches an authorize-after-serialize mutation.
    test "a sibling-org agent is denied on both tools and sees no prose", ctx do
      assert {:error, ev_envelope} =
               ToolSurface.execute(
                 "runtime_event_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_pt)
               )

      assert ev_envelope.recoverable == false
      assert_no_leakage(ev_envelope)

      assert {:error, lease_envelope} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_pt)
               )

      assert lease_envelope.recoverable == false
      assert_no_leakage(lease_envelope)
    end

    test "denial survives a status filter — the filter is not evaluated first", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id, "status" => "blocked"},
                 context_for(ctx.agent_pt)
               )

      assert envelope.recoverable == false
      assert_no_leakage(envelope)
    end

    test "a malformed task id is refused rather than raising", ctx do
      for tool <- ~w(runtime_event_list execution_lease_list) do
        assert {:error, envelope} =
                 ToolSurface.execute(
                   tool,
                   %{"task_id" => "not-a-uuid"},
                   context_for(ctx.agent_globex)
                 )

        assert envelope.recoverable == false
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp assert_no_leakage(envelope) do
    blob = inspect(envelope)

    refute blob =~ "waiting on a human decision", "block_reason prose leaked into a denial"
    refute blob =~ "runtime-alpha", "runtime_id leaked into a denial"
    refute blob =~ "operator prose", "lease metadata leaked into a denial"
    refute blob =~ "subagent_id", "payload fragment leaked into a denial"
  end

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -60 * n, :second)

  defp insert_event(task, event_type, payload, opts) do
    {:ok, event} =
      %RuntimeEvent{}
      |> RuntimeEvent.changeset(%{
        task_id: task.id,
        lease_id: Keyword.get(opts, :lease_id),
        phase: "execution",
        runtime_id: Keyword.get(opts, :runtime_id, "runtime-alpha"),
        event_type: event_type,
        occurred_at: Keyword.get(opts, :occurred_at, DateTime.utc_now()),
        idempotency_key: "idem-#{u()}",
        payload: payload
      })
      |> Repo.insert()

    event
  end

  # ── task 01a0a5ed stage 2 ─────────────────────────────────────────────────
  #
  # ANTI-VACUITY. "passing `limit` does not error" is what an IGNORED option
  # also does. Every test here seeds MORE rows than the bound it asserts and
  # pins the returned length, the reported `count` AND the echoed `limit`
  # together: the echoed limit is what lets a caller tell truncation from
  # exhaustion, so a response that ran with 200 and reported 500 would be the
  # defect even with a correctly-sized list.
  describe "execution_lease_list limit" do
    setup ctx do
      # 210 > @max_limit (200) > @default_limit (50), so all three bounds are
      # observable in one seeded task. Newest first == largest started_at.
      seed_leases(ctx.task, 210)
      :ok
    end

    test "with no limit returns exactly the module default", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id},
                 context_for(ctx.agent_globex)
               )

      assert result.count == Diagnostics.default_limit()
      assert result.limit == Diagnostics.default_limit()
      assert length(result.leases) == Diagnostics.default_limit()
    end

    test "an over-cap request is CLAMPED to the cap, not rejected and not honoured", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id, "limit" => 500},
                 context_for(ctx.agent_globex)
               )

      assert result.count == Diagnostics.max_limit()
      assert length(result.leases) == Diagnostics.max_limit()

      # The EFFECTIVE limit, not the asked-for one. Echoing 500 here while the
      # query ran with 200 is the lie this assertion exists to catch.
      assert result.limit == Diagnostics.max_limit()
      refute result.limit == 500
    end

    test "an under-cap limit is honoured and keeps the NEWEST rows", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id, "limit" => 5},
                 context_for(ctx.agent_globex)
               )

      assert result.count == 5
      assert result.limit == 5
      assert length(result.leases) == 5

      started = Enum.map(result.leases, & &1.started_at)
      assert started == Enum.sort(started, {:desc, DateTime})

      newest_five =
        ExecutionLease
        |> where(task_id: ^ctx.task.id)
        |> order_by(desc: :started_at, desc: :inserted_at)
        |> limit(5)
        |> Repo.all()
        |> Enum.map(& &1.id)

      assert Enum.map(result.leases, & &1.id) == newest_five
    end

    test "limit composes with status — both applied, neither dropped", ctx do
      assert {:ok, result} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id, "status" => "blocked", "limit" => 2},
                 context_for(ctx.agent_globex)
               )

      assert result.count == 2
      assert result.limit == 2
      assert result.status_filter == "blocked"
      assert length(result.leases) == 2

      # `status` was not silently dropped by the limit: there are more than two
      # non-blocked leases seeded, so an unfiltered limit-2 read would return
      # something else.
      assert Enum.all?(result.leases, &(&1.status == "blocked"))

      blocked_total =
        ExecutionLease
        |> where(task_id: ^ctx.task.id, status: "blocked")
        |> Repo.aggregate(:count)

      assert blocked_total > 2, "the limit must be the thing truncating, not the row count"
    end

    test "the invalid-status refusal still fires when limit is present", ctx do
      assert {:error, envelope} =
               ToolSurface.execute(
                 "execution_lease_list",
                 %{"task_id" => ctx.task.id, "status" => "blokced", "limit" => 2},
                 context_for(ctx.agent_globex)
               )

      assert envelope.error =~ "status"
      refute Map.has_key?(envelope, :leases)
      refute Map.has_key?(envelope, :limit)
    end
  end

  # Bulk seed: `insert_all` rather than 210 changesets, with strictly
  # increasing `started_at` so newest-first is observable. Every third row is
  # "blocked" so the status-composition test has more blocked rows than its
  # limit.
  defp seed_leases(task, n) do
    now = DateTime.utc_now()

    rows =
      for i <- 1..n do
        %{
          id: Platform.Types.UUIDv7.generate(),
          task_id: task.id,
          stage_id: Ecto.UUID.generate(),
          phase: "execution",
          runtime_id: "runtime-bulk-#{i}",
          status: if(rem(i, 3) == 0, do: "blocked", else: "active"),
          started_at: DateTime.add(now, i, :second),
          expires_at: DateTime.add(now, 1800, :second),
          metadata: %{},
          owner_attribution_status: "legacy_pre_migration",
          inserted_at: now,
          updated_at: now
        }
      end

    {^n, _} = Repo.insert_all(ExecutionLease, rows)
    :ok
  end

  defp insert_lease(task, stage_id, status, runtime_id) do
    {:ok, lease} =
      %ExecutionLease{}
      |> ExecutionLease.changeset(%{
        task_id: task.id,
        stage_id: stage_id,
        phase: "execution",
        runtime_id: runtime_id,
        status: status,
        started_at: minutes_ago(30),
        last_heartbeat_at: minutes_ago(12),
        last_progress_at: minutes_ago(12),
        expires_at: DateTime.add(DateTime.utc_now(), 1800, :second),
        block_reason: "waiting on a human decision",
        metadata: %{"note" => "operator prose"}
      })
      |> Repo.insert()

    lease
  end

  defp u, do: System.unique_integer([:positive])

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "acme") do
      nil ->
        {:ok, org} =
          %Tenancy.Org{}
          |> Tenancy.Org.changeset(%{slug: "acme", name: "Acme", parent_org_id: nil})
          |> Repo.insert()

        org

      org ->
        org
    end
  end

  defp ensure_tenant_org(slug, root) do
    {:ok, org} =
      %Tenancy.Org{}
      |> Tenancy.Org.changeset(%{slug: slug, name: slug, parent_org_id: root.id})
      |> Repo.insert()

    org
  end

  defp create_agent(slug_prefix, metadata) do
    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(slug_prefix),
        status: "active",
        metadata: metadata
      })
      |> Repo.insert()

    agent
  end

  defp context_for(%Agent{id: id}), do: %{agent_id: id}
end
