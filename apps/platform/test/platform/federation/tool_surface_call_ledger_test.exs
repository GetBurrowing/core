defmodule Platform.Federation.ToolSurfaceCallLedgerTest do
  @moduledoc """
  Task 01a006c2 stage 5, PART B — CALL THROUGH THE SURFACE.

  Every capability this task shipped is exercised by an ACTUAL
  `ToolSurface.execute/3` invocation whose returned body is printed to the test
  log, and every new read tool is additionally called from a tenant-pinned
  agent in a sibling org so the DENIAL body can be printed and scanned.

  Reading `tool_definitions()` is not evidence: the 01a00570 lesson is that a
  registration which looks correct while the call itself fails is the entire
  failure mode. So there is no registration assertion in this file at all —
  those live in the per-capability stage tests. This file only calls.

  The denial assertions scan the WHOLE envelope with `inspect/1`, not the
  `error` string, because an authorize-AFTER-serialize regression leaks prose
  into sibling fields that an `error =~` assertion walks straight past.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.{ExecutionLease, RuntimeEvent}
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tenancy

  # Prose that must NEVER appear in a denial body. One string per class of
  # secret the five capabilities can serialize.
  @secrets [
    # execution_lease block_reason
    "waiting on a human decision",
    # lease metadata
    "operator prose",
    # runtime_event payload fragment
    "subagent_id",
    # runtime id / actor label
    "runtime-ledger-alpha",
    # plan rejection_reason
    "rollback is missing",
    # message content
    "Rowan asked about the deployment pipeline"
  ]

  setup do
    fabrikam = ensure_root_org()
    sxi = ensure_tenant_org("sxi-ledger-#{u()}", fabrikam)
    wayne_tech = ensure_tenant_org("wayne-tech-ledger-#{u()}", fabrikam)

    {:ok, project} = Tasks.create_project(%{name: "Ledger Proj #{u()}", org_id: sxi.id})
    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Ledger Task"})
    # A real status change through the real changeset writes the transition row.
    {:ok, task} = Tasks.update_task(task, %{status: "planning"})

    stage_id = Ecto.UUID.generate()
    lease = insert_lease(task, stage_id)

    insert_event(task, "execution.acked", %{"stage_id" => stage_id, "subagent_id" => "sub-1"})

    insert_event(
      task,
      "execution.blocked",
      %{"stage_id" => stage_id, "reason" => "needs input"},
      lease.id
    )

    Repo.insert!(%Plan{task_id: task.id, version: 1, status: "approved"})

    Repo.insert!(%Plan{
      task_id: task.id,
      version: 2,
      status: "rejected",
      rejection_reason: "rollback is missing",
      architecture_verdict: %{"state" => "rejected", "source" => "mcp"}
    })

    agent_sxi = create_agent("sxi-ledger", %{"org_id" => sxi.id})
    agent_pt = create_agent("pt-ledger", %{"org_id" => wayne_tech.id})

    {:ok, space} =
      Chat.create_space(%{
        name: "Ledger Space",
        slug: "ledger-#{u()}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent_sxi.id,
        display_name: agent_sxi.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, _} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: "Rowan asked about the deployment pipeline"
      })

    %{
      task: task,
      stage_id: stage_id,
      lease: lease,
      space: space,
      participant: participant,
      agent_sxi: agent_sxi,
      agent_pt: agent_pt
    }
  end

  describe "PART B — permitted calls, bodies recorded" do
    test "every capability answers a real execute/3 call", ctx do
      permitted = %{agent_id: ctx.agent_sxi.id, agent_participant_id: ctx.participant.id}

      banner("PART B — PERMITTED CALLS")

      {:ok, transitions} =
        record(
          "task_transition_list",
          %{"task_id" => ctx.task.id},
          ToolSurface.execute("task_transition_list", %{"task_id" => ctx.task.id}, permitted)
        )

      assert transitions.count == 1
      assert [%{from_status: "backlog", to_status: "planning"} = t] = transitions.transitions
      assert t.actor_kind
      assert transitions.note =~ "recorded transition"

      {:ok, events} =
        record(
          "runtime_event_list",
          %{"task_id" => ctx.task.id},
          ToolSurface.execute("runtime_event_list", %{"task_id" => ctx.task.id}, permitted)
        )

      assert events.count == 2
      assert Enum.all?(events.events, &(&1.payload["stage_id"] == ctx.stage_id))

      {:ok, leases} =
        record(
          "execution_lease_list",
          %{"task_id" => ctx.task.id},
          ToolSurface.execute("execution_lease_list", %{"task_id" => ctx.task.id}, permitted)
        )

      assert leases.count == 1
      assert [%{block_reason: "waiting on a human decision"}] = leases.leases

      {:ok, approved} =
        record(
          "plan_get (default)",
          %{"task_id" => ctx.task.id},
          ToolSurface.execute("plan_get", %{"task_id" => ctx.task.id}, permitted)
        )

      assert approved.version == 1
      assert approved.status == "approved"
      assert approved.is_current

      {:ok, rejected} =
        record(
          "plan_get (status: rejected)",
          %{"task_id" => ctx.task.id, "status" => "rejected"},
          ToolSurface.execute(
            "plan_get",
            %{"task_id" => ctx.task.id, "status" => "rejected"},
            permitted
          )
        )

      assert rejected.rejection_reason == "rollback is missing"
      refute rejected.is_current

      {:ok, hits} =
        record(
          "space_search_messages (ordinary word)",
          %{"space_id" => ctx.space.id, "query" => "deployment"},
          ToolSurface.execute(
            "space_search_messages",
            %{"space_id" => ctx.space.id, "query" => "deployment"},
            permitted
          )
        )

      assert [hit] = hits
      assert hit.content =~ "deployment pipeline"

      {:ok, envelope} =
        record(
          "space_search_messages (punctuation only)",
          %{"space_id" => ctx.space.id, "query" => "--- ??? !!!"},
          ToolSurface.execute(
            "space_search_messages",
            %{"space_id" => ctx.space.id, "query" => "--- ??? !!!"},
            permitted
          )
        )

      assert envelope.no_searchable_terms == true
      assert envelope.results == []
    end
  end

  describe "PART B — denied calls, bodies recorded and scanned" do
    test "a sibling-org tenant-pinned agent is denied on every new read tool and learns nothing",
         ctx do
      denied_ctx = %{agent_id: ctx.agent_pt.id, agent_participant_id: Ecto.UUID.generate()}

      banner("PART B — DENIED CALLS (sibling-org tenant-pinned agent)")

      for tool <- ~w(task_transition_list runtime_event_list execution_lease_list) do
        assert {:error, envelope} =
                 record(
                   tool <> " [DENIED]",
                   %{"task_id" => ctx.task.id},
                   ToolSurface.execute(tool, %{"task_id" => ctx.task.id}, denied_ctx)
                 )

        assert envelope.recoverable == false
        assert_no_secret_prose(envelope, tool)
      end
    end

    test "a non-participant is denied on space_search_messages and the guard does not answer first",
         ctx do
      denied_ctx = %{agent_id: ctx.agent_pt.id, agent_participant_id: Ecto.UUID.generate()}

      for query <- ["deployment", "--- ??? !!!"] do
        assert {:error, envelope} =
                 record(
                   "space_search_messages [DENIED] #{inspect(query)}",
                   %{"space_id" => ctx.space.id, "query" => query},
                   ToolSurface.execute(
                     "space_search_messages",
                     %{"space_id" => ctx.space.id, "query" => query},
                     denied_ctx
                   )
                 )

        assert envelope.error =~ "Access denied"
        # The punctuation query must NOT come back as the no_searchable_terms
        # envelope: an unauthorized caller may not learn how their query parsed.
        refute Map.has_key?(envelope, :no_searchable_terms)
        assert_no_secret_prose(envelope, "space_search_messages")
      end
    end

    # RESOLVED (was: "FINDING: plan_get answers a sibling-org agent"). Stage 5
    # recorded that `plan_get` took `_context` and ran no per-task check, and
    # that stage 3 had widened the OUTPUT CLASS to include a rejected plan's
    # rejection_reason / architecture_verdict prose. The e2e review failed on
    # it and the check was added, so this test is inverted: the sibling-org
    # agent is now DENIED, and the denial body is scanned whole for every
    # seeded secret rather than only for the `error` string.
    #
    # Both call shapes are asserted because they are different code paths at
    # the point of the check: the DEFAULT (no `status`) is what every existing
    # caller sends, and `status: "rejected"` is the widened one. Authorization
    # precedes the status parse, so neither can be the unguarded one.
    test "plan_get DENIES a sibling-org agent for both the default and the widened status call",
         ctx do
      denied_ctx = %{agent_id: ctx.agent_pt.id, agent_participant_id: Ecto.UUID.generate()}

      for args <- [
            %{"task_id" => ctx.task.id},
            %{"task_id" => ctx.task.id, "status" => "rejected"}
          ] do
        assert {:error, envelope} =
                 record(
                   "plan_get [sibling-org agent — DENIED]",
                   args,
                   ToolSurface.execute("plan_get", args, denied_ctx)
                 )

        assert envelope.error =~ "unauthorized"
        refute envelope.recoverable
        assert_no_secret_prose(envelope, "plan_get")

        # The denial must not leak the plan's existence or shape either.
        blob = inspect(envelope)
        refute blob =~ "rejection_reason"
        refute blob =~ "architecture_verdict"
        refute blob =~ ctx.task.id
      end
    end

    # The same-org agent still reads the widened plan: the check denies a
    # sibling, it does not break the capability stage 3 shipped.
    test "plan_get still answers the own-org agent with the rejected plan's prose", ctx do
      permitted = %{agent_id: ctx.agent_sxi.id, agent_participant_id: ctx.participant.id}

      assert {:ok, result} =
               record(
                 "plan_get [own-org agent — permitted]",
                 %{"task_id" => ctx.task.id, "status" => "rejected"},
                 ToolSurface.execute(
                   "plan_get",
                   %{"task_id" => ctx.task.id, "status" => "rejected"},
                   permitted
                 )
               )

      assert result.rejection_reason == "rollback is missing"
    end

    # A denial and a not-found must not be the same answer. If they collapsed,
    # a caller could not tell "you may not read this" from "there is nothing
    # to read", and the second reading is the one that invites a retry loop.
    test "plan_get's authorization refusal is distinguishable from its not-found envelope", ctx do
      # Same project (so the same org permits the reader) but no plan at all.
      {:ok, planless} =
        Tasks.create_task(%{project_id: ctx.task.project_id, title: "No Plan #{u()}"})

      permitted = %{agent_id: ctx.agent_sxi.id, agent_participant_id: ctx.participant.id}
      denied_ctx = %{agent_id: ctx.agent_pt.id, agent_participant_id: Ecto.UUID.generate()}

      assert {:error, not_found} =
               record(
                 "plan_get [no approved plan]",
                 %{"task_id" => planless.id},
                 ToolSurface.execute("plan_get", %{"task_id" => planless.id}, permitted)
               )

      # Verbatim, unchanged by this fix.
      assert not_found.error == "No approved plan for task"
      assert not_found.suggestion == "Create a plan with plan_create and approve it first"

      assert {:error, unauthorized} =
               ToolSurface.execute("plan_get", %{"task_id" => ctx.task.id}, denied_ctx)

      assert unauthorized.error =~ "unauthorized"
      refute unauthorized.error == not_found.error
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp assert_no_secret_prose(envelope, tool) do
    blob = inspect(envelope)

    for secret <- @secrets do
      refute blob =~ secret, "#{tool} denial leaked #{inspect(secret)}"
    end
  end

  defp record(label, args, result) do
    IO.puts("\n--- CALL #{label}")
    IO.puts("    args: #{inspect(args)}")
    IO.puts("    body: #{inspect(result, limit: 12, printable_limit: 900)}")
    result
  end

  defp banner(text), do: IO.puts("\n=== #{text} ===")

  defp u, do: System.unique_integer([:positive])

  defp minutes_ago(n), do: DateTime.add(DateTime.utc_now(), -60 * n, :second)

  defp insert_event(task, event_type, payload, lease_id \\ nil) do
    Repo.insert!(
      RuntimeEvent.changeset(%RuntimeEvent{}, %{
        task_id: task.id,
        lease_id: lease_id,
        phase: "execution",
        runtime_id: "runtime-ledger-alpha",
        event_type: event_type,
        occurred_at: minutes_ago(10),
        idempotency_key: "idem-#{u()}",
        payload: payload
      })
    )
  end

  defp insert_lease(task, stage_id) do
    Repo.insert!(
      ExecutionLease.changeset(%ExecutionLease{}, %{
        task_id: task.id,
        stage_id: stage_id,
        phase: "execution",
        runtime_id: "runtime-ledger-alpha",
        status: "blocked",
        started_at: minutes_ago(30),
        last_heartbeat_at: minutes_ago(12),
        last_progress_at: minutes_ago(12),
        expires_at: DateTime.add(DateTime.utc_now(), 1800, :second),
        block_reason: "waiting on a human decision",
        metadata: %{"note" => "operator prose"}
      })
    )
  end

  defp ensure_root_org do
    case Repo.get_by(Tenancy.Org, slug: "fabrikam") do
      nil ->
        Repo.insert!(
          Tenancy.Org.changeset(%Tenancy.Org{}, %{
            slug: "fabrikam",
            name: "Fabrikam",
            parent_org_id: nil
          })
        )

      org ->
        org
    end
  end

  defp ensure_tenant_org(slug, root) do
    Repo.insert!(
      Tenancy.Org.changeset(%Tenancy.Org{}, %{
        slug: slug,
        name: slug,
        parent_org_id: root.id
      })
    )
  end

  defp create_agent(slug_prefix, metadata) do
    Repo.insert!(
      Agent.changeset(%Agent{}, %{
        slug: "#{slug_prefix}-#{System.unique_integer([:positive, :monotonic])}",
        name: String.capitalize(slug_prefix),
        status: "active",
        metadata: metadata
      })
    )
  end
end
