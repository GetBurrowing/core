defmodule Platform.Orchestration.TaskRouterWithheldDispatchIdentityTest do
  @moduledoc """
  Ticket `01a08e86` stage 2 — the withheld-dispatch notice must carry the
  ack's IDENTITY, not just the claim that one exists.

  ## The single claim this file pins

  `suppress_live_acked_executor/3` asserts a state: "stage N already has an
  acked executor inside its safety net". On the 2026-09-11 incident that
  executor had returned twenty minutes earlier, and the notice named only the
  stage POSITION — so a reader had no way to tell a live executor from a dead
  one without querying `runtime_events` by hand. Saru caught it only by
  happening to know no stage 4 had ever been acked.

  The claim: the posted notice names the ack's ISO8601 instant, its elapsed
  age in whole minutes, and the `subagent_id` from the `execution.acked`
  payload.

  ## What would falsify it

  Deleting any one of those three facts from the message. Each is asserted
  separately, against the value read back from the durable row rather than a
  hand-written string, so a renderer that prints a DIFFERENT instant (the
  payload's `"acked_at"` rather than the `occurred_at` column the guard
  actually measures) fails here too.

  The age assertion is the reason the ack is aged to a fixed 25 minutes: a
  fresh ack renders `0m`, which a broken renderer could produce by accident
  from a zeroed default. 25 is inside `coding`'s 90-minute safety net, so the
  suppression under test still fires.

  ## The nil-subagent case is the FAILURE PATH, and it is a real value

  Ack rows written before task `019f6c73` made the spawn handle mandatory
  carry no `subagent_id`. Rendering that must say `unknown` and must not
  crash the router — a notice is never worth taking the router down for. The
  second test strips the key from a real ack row and asserts the notice still
  posts.

  ## What is NOT asserted here

  Not a Logger capture. The operator reads the execution space, so the
  assertions are on the posted MESSAGE BODY — the same durable row
  `task_router_withheld_dispatch_copy_test.exs` reads, and for the same
  reason: a suppression that silently stopped posting must fail loudly rather
  than make a string assertion pass against nothing.

  Not the guard's control flow. Stage 1 of this task fixed the BEHAVIOUR
  (`stage_restarted_since?/2`); this stage fixes only what the operator is
  told when the behaviour is correct. Both tests below assert the dispatch is
  still WITHHELD, which is what stops a copy change from quietly disarming the
  guard.

  ## `async: false`

  The router is a real GenServer reading `Repo` from its own process, so the
  sandbox runs in shared mode.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Chat.Message
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Withheld Identity Project #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Withheld dispatch identity #{n}",
        description: "Pin the ack identity carried by the withheld-dispatch notice",
        status: "in_progress",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    # "Build the feature" infers `stage_kind: "coding"`, whose `safety_net_ms`
    # is non-nil — without a suppression window there is no notice to read.
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the feature",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    # A pending non-manual gate, so the suppression that fires is the live-ack
    # guard and not the unmet-gate branch.
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-withheld-identity-#{n}"}
    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{assignee.id}")

    on_exit(fn ->
      PlatformWeb.Endpoint.unsubscribe("runtime:#{assignee.id}")
      stop_router(task.id)

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{task: task, plan: plan, stage: stage, validation: validation, assignee: assignee}
  end

  describe "the withheld-dispatch notice" do
    test "names the ack's ISO8601 instant, its age in minutes, and the acking subagent", ctx do
      pid = start_router(ctx.task.id, ctx.assignee)

      # ANTI-VACUITY: the fixture must dispatch once, or nothing can be
      # withheld and every assertion below reads an absent row.
      assert_dispatched!("the fixture must dispatch once before anything can be withheld")

      subagent_id = ack!(ctx.task, ctx.stage, ctx.assignee)

      # 25 minutes: inside `coding`'s 90-minute net (so the guard still
      # suppresses), and far enough from zero that a renderer emitting a
      # constant `0m` cannot pass by accident.
      age_ack!(ctx.task, ctx.stage, 25 * 60_000)

      {acked_at, read_back_subagent} =
        Orchestration.last_stage_ack(ctx.task.id, ctx.stage.id, ctx.assignee.id)

      assert read_back_subagent == subagent_id,
             "the helper must hand back the subagent id the ack actually recorded, " <>
               "or the assertion below is comparing the notice against a value the " <>
               "router never saw"

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)

      # The guard's job is UNCHANGED by this stage. If the copy change had
      # disarmed it, this refutation fails before any string is read.
      refute_dispatched!("an acked, live stage must still not be re-dispatched")

      posted = withheld_message!(ctx.task.id)

      assert posted =~ DateTime.to_iso8601(acked_at),
             """
             The notice does not name the ack instant the guard measured.

             Expected to find: #{DateTime.to_iso8601(acked_at)}
             Posted message was:
             #{posted}
             """

      assert posted =~ subagent_id,
             """
             The notice does not name the subagent that acked, so a reader still \
             cannot tell a live executor from a returned one.

             Expected to find: #{subagent_id}
             Posted message was:
             #{posted}
             """

      # Task 01a0c762 stage 2: the runtime is the AUTHENTICATED half of the
      # identity (the subagent id is caller-asserted), and the guard now
      # counts only this runtime's acks, so the notice names it.
      assert posted =~ "by runtime #{ctx.assignee.id} / subagent #{subagent_id}",
             """
             The notice does not name the acking runtime next to the subagent.

             Posted message was:
             #{posted}
             """

      assert posted =~ ~r/\b25m ago\b/,
             """
             The notice does not name the ack's elapsed age. The ack was aged to \
             exactly 25 minutes before the suppression ran.

             Posted message was:
             #{posted}
             """

      # The correction shipped by task 01a0a5b7 must survive this one: the
      # recovery paragraph is still there and still does not promise a
      # re-dispatch.
      assert posted =~ ~r/task_ack/,
             "the manual-recovery sequence must survive the identity prefix"

      assert posted =~ ~r/\b(not|never|no)\b[^.!?]{0,40}re-?dispatch/i,
             "the safety-net correction from task 01a0a5b7 must survive this change"
    end

    test "renders an ack with no subagent_id as unknown, and the router survives", ctx do
      pid = start_router(ctx.task.id, ctx.assignee)
      assert_dispatched!("the fixture must dispatch once before anything can be withheld")

      ack!(ctx.task, ctx.stage, ctx.assignee)
      strip_subagent_id!(ctx.task.id, ctx.stage.id)

      {acked_at, read_back_subagent} =
        Orchestration.last_stage_ack(ctx.task.id, ctx.stage.id, ctx.assignee.id)

      assert is_nil(read_back_subagent),
             "the legacy shape must actually be in place, or this test is the " <>
               "previous one in disguise"

      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_dispatched!("an acked, live stage must still not be re-dispatched")

      assert Process.alive?(pid),
             "a nil subagent id must not take the router down — the notice is the " <>
               "failure path, not a place to crash"

      posted = withheld_message!(ctx.task.id)

      assert posted =~ "unknown",
             """
             A legacy ack with no subagent_id must render as `unknown`.

             Posted message was:
             #{posted}
             """

      # The instant is still known even when the handle is not, so the notice
      # must not degrade both facts together.
      assert posted =~ DateTime.to_iso8601(acked_at),
             "a missing subagent id must not cost the reader the ack instant too"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Reads the message the router actually posted. Same `ilike` anchor as
  # `task_router_withheld_dispatch_copy_test.exs` so the two cannot drift.
  defp withheld_message!(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    row =
      from(m in Message,
        where: m.space_id == ^space.id and is_nil(m.deleted_at),
        where: ilike(m.content, "Dispatch withheld:%"),
        order_by: [desc: m.inserted_at, desc: m.id],
        limit: 1
      )
      |> Repo.one()

    assert row, "no withheld-dispatch message was posted — every assertion would be vacuous"

    refute String.trim(row.content) == "",
           "the withheld-dispatch message is blank — every assertion would be vacuous"

    row.content
  end

  defp latest_ack_row!(task_id, stage_id) do
    Repo.one!(
      from(e in RuntimeEvent,
        where:
          e.task_id == ^task_id and e.event_type == "execution.acked" and
            fragment("?->>'stage_id' = ?", e.payload, ^stage_id),
        order_by: [desc: e.occurred_at, desc: e.id],
        limit: 1
      )
    )
  end

  # Moves the durable ack back in time. `occurred_at` is the column the guard
  # compares against `safety_net_ms`, so this is the same field the notice
  # must quote.
  #
  # THE STAGE'S `started_at` MOVES WITH IT, and it is not optional. Stage 1 of
  # this task added `stage_restarted_since?/2`: a stage whose `started_at` is
  # newer than the ack is a stage that RESTARTED after it, and the guard then
  # correctly declines to suppress. The fixture's stage starts at
  # `DateTime.utc_now()`, so aging the ack alone manufactures exactly that
  # shape — measured, first run of this file: the dispatch was delivered and
  # the notice under test was never posted. Backdating the start to before the
  # ack restores the ORDINARY sequence (stage starts, then the executor acks),
  # which is the state whose notice this file is about.
  defp age_ack!(task, stage, ms_ago) do
    aged = DateTime.add(DateTime.utc_now(), -ms_ago, :millisecond)

    stage
    |> Ecto.Changeset.change(%{started_at: DateTime.add(aged, -60, :second)})
    |> Repo.update!()

    row = latest_ack_row!(task.id, stage.id)

    row
    |> Ecto.Changeset.change(%{occurred_at: aged})
    |> Repo.update!()

    {read_back, _subagent} = Orchestration.last_stage_ack(task.id, stage.id, row.runtime_id)

    assert DateTime.compare(read_back, aged) == :eq,
           "the lookup must see the aged timestamp, or the age assertion varies nothing"

    :ok
  end

  # The legacy shape: an `execution.acked` row written before task 019f6c73
  # made `subagent_id` mandatory. Produced by removing the key from a REAL ack
  # row rather than by inserting a hand-built one, so the rest of the payload
  # is whatever the live tool writes today.
  defp strip_subagent_id!(task_id, stage_id) do
    row = latest_ack_row!(task_id, stage_id)

    assert Map.has_key?(row.payload, "subagent_id"),
           "the ack path stopped writing subagent_id — stripping it proves nothing"

    row
    |> Ecto.Changeset.change(%{payload: Map.delete(row.payload, "subagent_id")})
    |> Repo.update!()

    :ok
  end

  # The REAL ack path — the same tool call an executor makes first. Returns the
  # handle it recorded so the notice can be checked against it.
  defp ack!(task, stage, assignee) do
    subagent_id = "subagent-withheld-identity-#{System.unique_integer([:positive])}"

    {:ok, _envelope} =
      ToolSurface.execute(
        "task_ack",
        %{"task_id" => task.id, "stage_id" => stage.id, "subagent_id" => subagent_id},
        # Task 01a0c762 stage 2: ack as the DISPATCHED runtime. The router's
        # durable-ack readers now count only the lease owner's rows; an empty
        # context wrote `runtime_id: "tool-surface"`, which no owner matches.
        %{runtime_id: assignee.id}
      )

    :ok = sync_router(task.id)

    assert %DateTime{} = Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id),
           "the ack must leave a durable per-stage row written by the dispatched " <>
             "runtime, or the suppression under test never triggers and there is " <>
             "no notice to read"

    subagent_id
  end

  defp assert_dispatched!(context) do
    assert_receive %Phoenix.Socket.Broadcast{
                     event: "attention",
                     payload: %{message: %{content: prompt}}
                   },
                   2_000,
                   context

    assert String.length(prompt) > 200,
           "a dispatch prompt this short is not a real stage dispatch"

    prompt
  end

  defp refute_dispatched!(context) do
    refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 1_500, context
  end

  defp start_router(task_id, assignee) do
    {:ok, pid} = TaskRouter.start_link(task_id: task_id, assignee: assignee)
    :ok = sync_router(task_id)
    pid
  end

  defp stop_router(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 2_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end
end
