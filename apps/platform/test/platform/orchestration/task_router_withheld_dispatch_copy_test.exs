defmodule Platform.Orchestration.TaskRouterWithheldDispatchCopyTest do
  @moduledoc """
  Task 01a0a5b7 stage 2 — the withheld-dispatch message must describe what
  `handle_info(:check_safety_net, ...)` actually does when the net lapses.

  ## The single claim this file pins

  IF the safety-net lapse produces a `needs_human` blocker and dispatches
  NOTHING, THEN the withheld-dispatch message must not tell an operator the
  net will re-dispatch the stage. Both halves are measured in ONE test body
  against ONE fixture, and asserted as an implication in both directions:

    * if the behavioural probe ever OBSERVES a dispatch out of the lapse, the
      test fails demanding the copy be updated to promise it again;
    * if the copy ever promises a re-dispatch while the probe observed none,
      the test fails demanding the copy be corrected.

  ## What would falsify it

  Any ONE of three observations out of the expired `:check_safety_net` pass:

    1. a new engagement row stamped with a `dispatch_runtime_id`;
    2. a new `attention` broadcast;
    3. a new "Dispatch withheld:" log row.

  That is the measurement. If any appears, the claim in the message ("does
  NOT re-dispatch") is false and this test says so — it does not quietly
  pass.

  ## DELIVERED versus ATTEMPTED — which this file measures

  It measures BOTH, and the distinction is load-bearing. Observations 1 and 2
  see a dispatch that was DELIVERED: a prompt actually reached a runtime.
  They are blind to a dispatch that was ATTEMPTED and then withheld, and the
  thing that withholds it is `suppress_live_acked_executor/3` — the very
  guard whose message this file is pinning. Measured (task 01a0a5b7 stage 2
  review): a lapse that re-enters `:dispatch` via `send(self(), :dispatch)`
  produces NO delivered dispatch, because the ack is seconds old and
  `coding`'s safety-net window is 90 minutes, so the guard suppresses it. On
  a delivered-only probe that mutant survives.

  Observation 3 closes that: a withheld dispatch is not silent, it writes a
  SECOND "Dispatch withheld:" row through `ExecutionSpace.post_log/2`. The
  count of those rows written AFTER the lapse is therefore the ATTEMPTED
  probe, and it is what makes the implication below hold for an attempt the
  guard swallowed as well as for one that got through.

  The stamp is the discriminator for observation 1, not `kind: "engagement"`
  alone — the blocker the lapse DOES post is an engagement row too, and
  counting those would have read the fix as the defect.

  ## Why the halves are PAIRED, not split

  Asserting only the copy is vacuous: it stays green when someone re-adds a
  re-dispatch promise in different words (hence the regex over the ACTUAL
  posted text rather than a hand-written expected string), and it stays green
  when the handler's behaviour changes underneath. Asserting only the
  behaviour proves nothing about what operators are told. Split into two
  tests, nothing forces both facts to hold of the same code in the same run.

  ## Why row counts, not `refute_received` alone

  The mailbox is read at one instant and a dispatch is broadcast before its
  engagement row settles, so a mailbox refute can pass while a dispatch is in
  flight. The durable engagement ROW count is the primary no-dispatch
  evidence here; the `attention` broadcast refute is layered on top of a
  settle window, never used alone.

  ## Behaviour first

  There is no source-text scan of the handler in this file. A guard keyed on
  the handler's spelling stops asserting when the code changes shape, in the
  passing direction and silently. The behavioural half boots a real router
  and measures the outcome.

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
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    n = System.unique_integer([:positive])

    {:ok, project} = Tasks.create_project(%{name: "Withheld Dispatch Copy Project #{n}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Withheld dispatch copy #{n}",
        description: "Pin the withheld-dispatch copy to the safety net's behaviour",
        status: "in_progress",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    # "Build the feature" infers `stage_kind: "coding"`, which is what gives
    # the stage a non-nil `safety_net_ms` — and therefore both a suppression
    # window (the copy half) and an armed deadline (the behavioural half).
    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the feature",
        description: "coding — stage 1",
        status: "running",
        started_at: DateTime.utc_now()
      })

    # A pending non-manual gate: without open work the lapse takes the
    # settled-plan suppression branch and the behavioural half would be
    # measuring the wrong handler path.
    {:ok, validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    assignee = %{type: :federated, id: "runtime-withheld-copy-#{n}"}
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

  describe "the withheld-dispatch message and the safety-net lapse" do
    test "the lapse blocks and dispatches nothing, and the message says exactly that", ctx do
      Phoenix.PubSub.subscribe(Platform.PubSub, "tasks:board")

      pid = start_router(ctx.task.id, ctx.assignee)

      # ANTI-VACUITY: the fixture must dispatch once, or "no dispatch" below
      # would be free and the copy half would never be reached.
      assert_dispatched!("the fixture must dispatch once before anything can be withheld")

      ack!(ctx.task, ctx.stage, ctx.assignee)

      # ── COPY HALF: drive the real suppression so the real `post_log/2` row
      # is written. Nothing here hand-writes the expected sentence.
      send(pid, :dispatch)
      :ok = sync_router(ctx.task.id)
      refute_dispatched!("an acked, live stage must not be re-dispatched by a reconcile")

      posted = withheld_message!(ctx.task.id)

      # ── BEHAVIOURAL HALF: measured, not read from source.
      before_blockers = blocker_count(ctx.task.id)
      before_engagements = dispatch_engagement_count(ctx.task.id)
      before_withheld = withheld_count(ctx.task.id)

      # ANTI-VACUITY: the dispatch-row query must MATCH the dispatch that
      # already happened, or "no new row" below would be the query failing to
      # see dispatches rather than the handler declining to make one.
      assert before_engagements >= 1,
             "the dispatch-engagement query matched nothing after a dispatch was " <>
               "observed on the runtime topic — it cannot detect a re-dispatch either"

      # ANTI-VACUITY for the ATTEMPTED probe: the withheld-row query must
      # MATCH the suppression that already happened above, or "no new
      # withheld row" below would be the query seeing nothing rather than
      # the handler attempting nothing.
      assert before_withheld >= 1,
             "the withheld-row query matched nothing after a suppression was " <>
               "already driven and its message read — it cannot detect a " <>
               "withheld re-dispatch either"

      expire_safety_net_deadline!(ctx.task.id)

      send(pid, :check_safety_net)
      :ok = sync_router(ctx.task.id)

      assert_received {:runtime_event,
                       %{event_type: "execution.safety_net_fired", stage_id: fired_stage_id}}

      assert fired_stage_id == ctx.stage.id,
             "the lapse fired for a different stage — the no-dispatch count below " <>
               "would be measuring an unrelated stage"

      assert blocker_count(ctx.task.id) == before_blockers + 1,
             "the lapse must post a needs_human blocker, or the implication under " <>
               "test has no antecedent"

      # Primary, durable no-dispatch evidence.
      dispatched_rows? = dispatch_engagement_count(ctx.task.id) > before_engagements

      # Layered on top of a settle window, never used alone.
      dispatched_broadcast? =
        receive do
          %Phoenix.Socket.Broadcast{event: "attention"} -> true
        after
          1_500 -> false
        end

      # ATTEMPTED, not merely delivered: a dispatch the live-ack guard swallows
      # still writes a "Dispatch withheld:" row. Settle first — `:dispatch`
      # only ARMS the debounce timer, so the suppression runs one
      # `:dispatch_now` later.
      :ok = sync_router(ctx.task.id)
      withheld_more? = withheld_count(ctx.task.id) > before_withheld

      dispatched? = dispatched_rows? or dispatched_broadcast? or withheld_more?

      # ── THE TIE: one implication, both directions, same run.
      promises = redispatch_promises(posted)

      if dispatched? do
        flunk("""
        The safety-net lapse DISPATCHED (engagement row: #{dispatched_rows?}, \
        attention broadcast: #{dispatched_broadcast?}, withheld-dispatch row: \
        #{withheld_more?}).

        A withheld-dispatch row counts: the dispatch was ATTEMPTED, and only \
        the live-ack guard stopped it reaching a runtime.

        That is the observation this file names as its falsifier. The copy in \
        `suppress_live_acked_executor/3` now understates the handler: update the \
        message to say the net re-dispatches, then update this test.

        Posted message was:
        #{posted}
        """)
      end

      assert promises == [],
             """
             The withheld-dispatch message promises a re-dispatch, but the \
             safety-net lapse was measured above to post a blocker and dispatch \
             nothing (no new engagement row, no attention broadcast).

             Correct the copy in `suppress_live_acked_executor/3`. Offending \
             sentence(s):

             #{Enum.join(promises, "\n")}
             """

      # The positive half of the copy claim: the message must name the manual
      # recovery sequence, since that is what an operator has instead.
      assert posted =~ ~r/task_ack/,
             "the message must name the ack step of the manual recovery sequence"

      assert posted =~ ~r/task_update\s+status:\s*in_progress/,
             "the message must name the unblock step of the manual recovery sequence"

      assert posted =~ ~r/spawn a replacement/i,
             "the message must name the replacement-executor step"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  # Sentences of the ACTUAL posted text that assert a re-dispatch. A sentence
  # that explicitly negates it ("does NOT re-dispatch", "is not re-dispatched")
  # is not a promise; anything else mentioning re-dispatch is, whatever its
  # wording — which is what stops a promise re-added in new words from
  # slipping past a fixed-string check.
  defp redispatch_promises(text) do
    text
    |> String.split(~r/(?<=[.!?])\s+/, trim: true)
    |> Enum.filter(&Regex.match?(~r/re-?dispatch/i, &1))
    |> Enum.reject(&Regex.match?(~r/\b(not|never|no)\b[^.!?]{0,40}re-?dispatch/i, &1))
  end

  # The ATTEMPTED-dispatch probe. `suppress_live_acked_executor/3` posts one
  # of these rows every time a dispatch reaches it and is withheld, so the
  # COUNT (not the presence) separates "no dispatch was attempted" from "a
  # dispatch was attempted and swallowed by the guard". Same `ilike` anchor as
  # `withheld_message!/1`, so the two cannot drift apart.
  defp withheld_count(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    from(m in Message,
      where: m.space_id == ^space.id and is_nil(m.deleted_at),
      where: ilike(m.content, "Dispatch withheld:%")
    )
    |> Repo.aggregate(:count)
  end

  # Reads the message the router actually posted. Asserting on the row means a
  # suppression that silently stopped posting fails here rather than making
  # the copy assertions pass against an empty string.
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

    assert row,
           "no withheld-dispatch message was posted — the copy half would be vacuous"

    refute String.trim(row.content) == "",
           "the withheld-dispatch message is blank — every copy assertion would be vacuous"

    row.content
  end

  # Engagement rows that are DISPATCHES, not just engagements. The router's
  # blocker and notice paths also go through `post_engagement/3` (measured:
  # the first run of this test counted the safety-net blocker as a dispatch),
  # so `kind: "engagement"` alone over-matches. Only `dispatch_attention/5`'s
  # companion row stamps `dispatch_runtime_id` — the runtime the prompt was
  # addressed to — which is exactly the trace a re-dispatch would leave.
  defp dispatch_engagement_count(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    from(m in Message,
      where: m.space_id == ^space.id and is_nil(m.deleted_at),
      where: fragment("?->>'kind' = ?", m.metadata, "engagement"),
      where: fragment("?->>'source' = ?", m.metadata, "task_router"),
      where: not is_nil(fragment("?->>'dispatch_runtime_id'", m.metadata))
    )
    |> Repo.aggregate(:count)
  end

  defp blocker_count(task_id) do
    space = ExecutionSpace.find_by_task_id(task_id)
    assert space, "expected an execution space for the task"

    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.count(&String.contains?(&1.content, "Stage safety-net exceeded"))
  end

  # The ONE field that separates "the window has not elapsed" from "the window
  # has elapsed".
  defp expire_safety_net_deadline!(task_id) do
    lease = LeaseManager.get(task_id)
    assert lease, "expected a LeaseManager row — the probe would be vacuous without one"
    assert lease.safety_net_at, "expected an armed safety-net deadline"
    refute lease.safety_net_fired?, "expected the one-shot to be unconsumed"

    past = DateTime.add(DateTime.utc_now(), -1_000, :millisecond)
    :ets.insert(:orchestration_lease_manager, {task_id, %{lease | safety_net_at: past}})
    :ok
  end

  # The REAL ack path — the same tool call an executor makes first.
  defp ack!(task, stage, assignee) do
    {:ok, _envelope} =
      ToolSurface.execute(
        "task_ack",
        %{
          "task_id" => task.id,
          "stage_id" => stage.id,
          "subagent_id" => "subagent-withheld-copy-#{System.unique_integer([:positive])}"
        },
        # Task 01a0c762 stage 2: ack as the DISPATCHED runtime. The router's
        # durable-ack readers now count only the lease owner's rows; an empty
        # context wrote `runtime_id: "tool-surface"`, which no owner matches.
        %{runtime_id: Platform.RuntimeProfileFixtures.ensure_task_runtime!(assignee.id)}
      )

    :ok = sync_router(task.id)

    assert %DateTime{} = Orchestration.last_stage_ack_at(task.id, stage.id, assignee.id),
           "the ack must leave a durable per-stage row written by the dispatched " <>
             "runtime, or the suppression under test never triggers and the copy " <>
             "half reads nothing"

    :ok
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
