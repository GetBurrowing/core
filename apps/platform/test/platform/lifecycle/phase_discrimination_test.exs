defmodule Platform.Lifecycle.PhaseDiscriminationTest do
  @moduledoc """
  THE ANTI-VACUITY MODULE for the task-status half of the lifecycle frame
  (task 019fe1b7 stage 5).

  ADR-0046 exists to kill one conflation: a hook framework that cannot tell
  **"this phase never happened"** from **"this phase happened and nothing was
  configured"**. Both produce zero `lifecycle_step_runs` rows, so a test that
  reads rows alone CANNOT discriminate them — and neither could any shipped
  caller until this stage, because `Platform.Tasks` discarded
  `Platform.Lifecycle.Executor.run_edge/3`'s outcome. The
  `[:platform, :lifecycle, :edge]` telemetry event added in this stage is the
  seam that makes the difference readable, and every assertion below reads
  BOTH channels (rows and events) because either alone is blind to one of the
  three states:

      state                    rows     event
      never traversed          none     NONE
      traversed, empty         none     outcome: :not_applicable
      traversed, populated     one/step outcome: :complete

  All three live in ONE test so the discrimination is visible to a reader
  rather than spread across three files that each look green in isolation.

  ## Every "did NOT fire" here has a positive control in the SAME run

  An implementation whose pipeline never runs at all passes every "fired
  nothing" assertion in this file. So each negative is paired with a positive
  on the same configuration, in the same test, and — for the skipped-phase
  case — on the same edge, so the absence cannot be explained by an empty
  pipeline, a typo'd edge key, an unsaved project config or a dead registry.
  """

  # `async: false`: these cases point the VM-global
  # `:lifecycle_step_registry` at a per-case registry, because the fire point
  # inside `Platform.Tasks` has nowhere to thread a server argument — that is
  # the whole point of going through it.
  use Platform.DataCase, async: false

  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Lifecycle.TestSteps
  alias Platform.Tasks
  alias Platform.Tasks.Stacks

  @edge_event [:platform, :lifecycle, :edge]

  setup do
    registry_name = :"phase_discrimination_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = StepRegistry.start_link(name: registry_name)

    for name <- ~w(s_deploy_done s_review_done s_bounce s_drop) do
      :ok =
        StepRegistry.register(
          %{name: name, mfa: {TestSteps.Sync, :start, 1}, kind: :deterministic},
          registry_name
        )
    end

    before = Application.fetch_env(:platform, :lifecycle_step_registry)
    Application.put_env(:platform, :lifecycle_step_registry, registry_name)

    # The observability seam. Attached per-case with a unique handler id so a
    # leaked handler from another case cannot answer for this one.
    handler_id = "phase-discrimination-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @edge_event,
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:lifecycle_edge_event, metadata})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      case before do
        :error -> Application.delete_env(:platform, :lifecycle_step_registry)
        {:ok, value} -> Application.put_env(:platform, :lifecycle_step_registry, value)
      end
    end)

    %{registry: registry_name}
  end

  # Drain every edge event delivered so far. Returns `{edge, outcome}` pairs
  # for one task, in emission order — an explicit ORDERED list, never set
  # membership, because the order edges fire in IS the lifecycle.
  defp edge_events(task_id) do
    receive_all([])
    |> Enum.filter(&(&1.task_id == task_id))
    |> Enum.map(&{&1.edge, &1.outcome})
  end

  defp receive_all(acc) do
    receive do
      {:lifecycle_edge_event, metadata} -> receive_all([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sync(name, opts \\ []) do
    %{
      "step" => name,
      "await" => Keyword.get(opts, :await, false),
      "can_divert" => Keyword.get(opts, :can_divert, false)
    }
  end

  # `default_deploy_target`, NOT `%{"target" => ...}`.
  #
  # PREMISE CORRECTION (task 019fe1b7 stage 5). Stage 4 recorded
  # `in_review -> deploying` as "not reachable from a bare fixture" because
  # every attempt answered `{:error, :no_deploy_target_resolved}`, and it
  # picked a different contrast rather than traverse `deploying`. The edge is
  # reachable. `Platform.Tasks.resolve_deploy_target/1` reads
  # `deploy_config["default_deploy_target"]`, a sole-entry
  # `deploy_config["deploy_targets"]`, or `task.deploy_target` — and the
  # inherited fixture in this suite sets `deploy_config: %{"target" => ...}`,
  # a key that function does not consult. The gate was never the obstacle;
  # the fixture was. `deploying` is a genuinely traversable phase here, which
  # is what lets the skipped-phase test below have a real positive control
  # instead of a vacuous one.
  defp project_with(pipeline) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Phase Discrimination Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/phase-discrimination",
        tech_stack: %{"language" => "elixir"},
        deploy_config: %{"default_deploy_target" => "production"},
        config: %{"lifecycle_pipeline" => pipeline}
      })

    project
  end

  defp task_in(project, attrs) do
    {:ok, task} =
      Tasks.create_task(
        Map.merge(%{project_id: project.id, title: "Phase Discrimination Task"}, attrs)
      )

    {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    task
  end

  defp advance(task, statuses) do
    Enum.reduce(statuses, task, fn status, acc ->
      {:ok, next} = Tasks.transition_task(acc, status)
      next
    end)
  end

  describe "skipped phase vs traversed-empty vs traversed-populated" do
    test "all three states are distinguishable, and none is confused for another" do
      # ONE project, so all three tasks below resolve against the SAME
      # configuration. If the deploy pipeline were misconfigured, the
      # positive control would fail and the negative would not be credited.
      #
      # Sized to the WRONG answers: the deploy edges carry TWO steps and the
      # review edge ONE, so an implementation that fires a fixed pipeline, or
      # that fires the wrong edge's pipeline, cannot pass by coincidence.
      project =
        project_with(%{
          "in_progress->deploying" => [sync("s_deploy_done"), sync("s_review_done")],
          "deploying->done" => [sync("s_deploy_done"), sync("s_review_done")],
          "in_review->done" => [sync("s_review_done")]
        })

      # ── (1) THE SKIPPED PHASE ──────────────────────────────────────────
      # An ADR-0041 stack member rides the rollup-PR merge fan-out, owns no
      # per-task deploy stage, and reaches `done` from `in_review` without
      # ever entering `deploying`.
      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "phase-discrimination-#{System.unique_integer([:positive])}",
          name: "Phase discrimination stack",
          rollup_branch: "stack/phase-discrimination",
          # The ADR-0042 commencement gate refuses `-> in_progress` for a
          # member whose STACK is not itself `in_progress`, independently of
          # whether every sibling has an approved plan (`waiting_on: []` with
          # the gate still shut is the "forming lockout" signature). Seeded
          # open here so this test exercises the lifecycle edges rather than
          # the commencement gate.
          status: "in_progress"
        })

      member = task_in(project, %{stack_id: stack.id, title: "Stack member"})
      member = advance(member, ~w(planning in_progress in_review done))
      assert member.status == "done"

      member_events = edge_events(member.id)

      # The member's actual path, as an explicit ordered list. `deploying`
      # appears NOWHERE in it — that is the fact the assertions below rest
      # on, asserted rather than assumed.
      assert member_events == [
               {"backlog->planning", :not_applicable},
               {"planning->in_progress", :not_applicable},
               {"in_progress->in_review", :not_applicable},
               {"in_review->done", :complete}
             ]

      # THE SKIPPED-PHASE ASSERTION. No rows AND no event of any kind for
      # either deploy edge — specifically NOT `:not_applicable`, which would
      # claim the edge ran.
      for edge <- ~w(in_progress->deploying in_review->deploying deploying->done) do
        assert Runs.for_edge(member.id, edge) == [],
               "skipped phase #{edge} recorded step runs for a member that never deployed"

        refute Enum.any?(member_events, fn {e, _outcome} -> e == edge end),
               "skipped phase #{edge} produced a recorded outcome; a phase that never " <>
                 "happened must be distinguishable from one that ran with nothing configured"
      end

      # ── (2) THE POSITIVE CONTROL, SAME RUN, SAME EDGES ─────────────────
      # Without this the block above is worthless: a pipeline that never runs
      # at all satisfies every assertion in it. A SOLO task on the same
      # project genuinely traverses `deploying`, so the deploy edges are
      # proved capable of recording — the member's silence is about the
      # member's path, not about the configuration.
      solo = task_in(project, %{title: "Solo task"})
      solo = advance(solo, ~w(planning in_progress deploying done))
      assert solo.status == "done"

      solo_events = edge_events(solo.id)

      assert solo_events == [
               {"backlog->planning", :not_applicable},
               {"planning->in_progress", :not_applicable},
               {"in_progress->deploying", :complete},
               {"deploying->done", :complete}
             ]

      assert Enum.map(
               Runs.for_edge(solo.id, "deploying->done"),
               &{&1.position, &1.step_name, &1.status}
             ) ==
               [
                 {0, "s_deploy_done", "completed"},
                 {1, "s_review_done", "completed"}
               ]

      assert Enum.map(Runs.for_edge(solo.id, "in_progress->deploying"), & &1.step_name) ==
               ["s_deploy_done", "s_review_done"]

      # ── (3) TRAVERSED WITH AN EMPTY CONFIGURED PIPELINE ────────────────
      # `backlog->planning` and `planning->in_progress` are configured on
      # NOBODY and carry no shipped default. Both tasks traversed them. The
      # discriminating fact: zero rows — the SAME row-level evidence the
      # skipped deploy edges produced — but an outcome IS recorded, and it is
      # `:not_applicable`. Rows alone cannot tell (1) from (3); this is why
      # the outcome had to become observable.
      for {task, edge} <- [
            {member, "backlog->planning"},
            {member, "planning->in_progress"},
            {solo, "backlog->planning"},
            {solo, "planning->in_progress"}
          ] do
        assert Runs.for_edge(task.id, edge) == [],
               "an empty pipeline must write no rows — `not_applicable` is an outcome, not a row"
      end

      assert {"planning->in_progress", :not_applicable} in member_events
      assert {"planning->in_progress", :not_applicable} in solo_events

      # And the three states are pairwise distinct on the pair of channels,
      # stated once so a reader does not have to reassemble it:
      #
      #   skipped   → {rows: [], event: absent}
      #   empty     → {rows: [], event: :not_applicable}
      #   populated → {rows: [_|_], event: :complete}
      refute Enum.any?(member_events, fn {e, _} -> e == "deploying->done" end)
      assert {"deploying->done", :complete} in solo_events
      assert Runs.for_edge(solo.id, "deploying->done") != []
    end
  end

  describe "the re-entry bound on a REAL firing edge" do
    # ══════════════════════════════════════════════════════════════════════
    # SUBSTITUTION, DOCUMENTED. DO NOT RE-LITIGATE.
    #
    # The ticket for this stack asked for the framework re-entry bound to be
    # asserted on the `done -> planning` REOPEN edge. **That edge fires
    # nothing today**, so the assertion would have been vacuous in exactly
    # the way this module exists to prevent: `done -> planning` is real and
    # legal in `@valid_task_transitions`, but BOTH writers that produce it
    # bypass `Platform.Tasks.maybe_finalize_transition/3`, the only choke
    # point a task-status hook can hang on. Each writes
    # `Task.changeset(%{status: "planning"}) |> Repo.update()` directly:
    #
    #   * `Platform.Tasks.reopen_with_feedback/3` (apps/platform/lib/
    #     platform/tasks.ex) — the reopen writer, inside its transaction
    #     after rejecting the active plan.
    #   * `Platform.Tasks.supersede_current_plan/3` (apps/platform/lib/
    #     platform/tasks.ex) — the plan-supersession writer, after marking
    #     the plan `superseded`.
    #
    # Routing either through the choke point would change the behaviour of
    # plan approval and supersession, which is NOT this stack's scope. See
    # `Platform.Lifecycle.EdgeInventory`'s "What this frame DOES NOT
    # OBSERVE" section for the full list of five bypassing writers.
    #
    # SUBSTITUTED EDGE: `backlog -> blocked`. Chosen because `blocked` is
    # enterable from SIX states, the `backlog <-> blocked` cycle genuinely
    # repeats without any gate to route around, and both halves go through
    # `transition_task/3` and therefore through the choke point — which is
    # the property `done -> planning` lacks and the reason for the swap.
    # ══════════════════════════════════════════════════════════════════════
    test "an edge that repeats fires at most the bound, and the FIRST firing did run" do
      limit = Platform.Lifecycle.edge_run_limit()

      project = project_with(%{"backlog->blocked" => [sync("s_bounce")]})
      task = task_in(project, %{})

      # Traverse the edge strictly MORE times than the bound, so "at most the
      # bound" is a real ceiling rather than a count the fixture never reached.
      traversals = limit + 2

      task =
        Enum.reduce(1..traversals, task, fn _i, acc ->
          {:ok, blocked} = Tasks.transition_task(acc, "blocked")
          {:ok, back} = Tasks.transition_task(blocked, "backlog")
          back
        end)

      assert task.status == "backlog"

      # POSITIVE CONTROL: the edge FIRED. "Did not re-fire" is trivially
      # satisfied by never firing at all, so the bound means nothing without
      # this. The step ran exactly `limit` times — no more, and not zero.
      assert TestSteps.Sync.ran() == List.duplicate("s_bounce", limit)

      rows = Runs.for_edge(task.id, "backlog->blocked")

      # THE BOUND, on rows: exactly `limit` firings ran the step, and every
      # firing past it is a `suppressed` row with NO step name. Suppressed is
      # emphatically not `not_applicable` — a refusal to run and an empty
      # pipeline are different facts.
      assert Enum.map(rows, &{&1.run_seq, &1.step_name, &1.status}) ==
               Enum.map(1..limit, &{&1, "s_bounce", "completed"}) ++
                 Enum.map((limit + 1)..traversals, &{&1, nil, "suppressed"})

      # THE BOUND, on outcomes, as an explicit ordered list.
      blocked_events =
        task.id
        |> edge_events()
        |> Enum.filter(fn {edge, _outcome} -> edge == "backlog->blocked" end)

      assert blocked_events ==
               List.duplicate({"backlog->blocked", :complete}, limit) ++
                 List.duplicate({"backlog->blocked", :suppressed}, traversals - limit)
    end
  end

  describe "the SECOND transition table — manual board drops" do
    test "a drop across a terminal edge fires nothing; the programmatic one fires" do
      # SCOPE BOUNDARY, PINNED AS A DECISION. `Platform.Tasks` holds TWO
      # transition tables: `@valid_task_transitions` (the pipeline path) and
      # `@valid_drop_transitions` (the permissive human drag-and-drop path).
      # `drop_task_to_column/3` writes `Task.changeset(%{status: target})
      # |> Repo.update()` directly, per its own in-code comment, so manual
      # board drops fire NO hooks at all. That is deliberate — a human
      # dragging a card is not a lifecycle event the pipeline claims to
      # observe — and this test exists so a later reader does not "fix" it by
      # accident, or discover it by shipping a hook that silently never runs
      # for board users.
      project = project_with(%{"in_progress->done" => [sync("s_drop")]})

      dropped = task_in(project, %{title: "Dropped by hand"})
      dropped = advance(dropped, ~w(planning in_progress))

      assert {:ok, %{status: "done"}} = Tasks.drop_task_to_column(dropped, "done")

      assert Runs.for_edge(dropped.id, "in_progress->done") == []

      # SECOND CONTROL, on the SAME TASK: the two transitions that reached
      # `in_progress` went through the choke point and ARE recorded. So the
      # frame was demonstrably watching this task right up to the drop — the
      # silence on `in_progress->done` is the drop path bypassing it, not the
      # test failing to wire the task up.
      assert edge_events(dropped.id) == [
               {"backlog->planning", :not_applicable},
               {"planning->in_progress", :not_applicable}
             ]

      # CONTROL, SAME RUN, SAME PROJECT, SAME EDGE: the equivalent
      # PROGRAMMATIC transition DOES fire. Without it the absence above is
      # equally explained by an unsaved pipeline or a dead registry, and the
      # test would pin nothing.
      programmatic = task_in(project, %{title: "Moved programmatically"})
      programmatic = advance(programmatic, ~w(planning in_progress done))

      assert programmatic.status == "done"

      assert Enum.map(
               Runs.for_edge(programmatic.id, "in_progress->done"),
               &{&1.step_name, &1.status}
             ) ==
               [{"s_drop", "completed"}]

      assert {"in_progress->done", :complete} in edge_events(programmatic.id)

      # The hazard is real in the fixture: the drop path DID move the task,
      # so the silence above is the hook frame not observing a write that
      # genuinely happened — not a refused transition that never wrote.
      # `get_task_record/1`, not `get_task/1` — the latter name is taken by
      # the artifacts-summary reader and returns a different shape entirely.
      assert Tasks.get_task_record(dropped.id).status == "done"
    end
  end
end
