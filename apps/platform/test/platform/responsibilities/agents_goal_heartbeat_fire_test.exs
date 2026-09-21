defmodule Platform.Responsibilities.AgentsGoalHeartbeatFireTest do
  @moduledoc """
  FIRE DETECTOR for task `01a0c332` stage 2: drives the FULL
  `Router.fire/2` path for `agents.goal_heartbeat` — the path the
  production defect actually lived on, which nothing had ever exercised.

  `agents_goal_heartbeat_test.exs` hand-seeds the baseline with
  `Chat.update_space` and proves only the READ (`previous_measurement/2`
  and the rendered clauses). Production never WROTE a baseline: the only
  code that wrote one, `AgentsGoalHeartbeat.handle_output/3`, is invoked
  by the Router on the external path alone (`run_external_dispatch/5`,
  router.ex ~1244) and never on `dispatch_native/5` (~1657) — the arm
  every cron→native-agent fire takes. A read-only test over a write
  defect passes forever; that is exactly how this bug survived. So the
  exclusion runs BOTH ways, the way `architecture_dispatch_test.exs`
  (external wiring only) and
  `architecture_audit_diff_native_artefact_test.exs` (the native fire
  detector that complements it) document theirs: the unit file proves
  everything but the write, and this file proves ONLY the write, end to
  end through a real fire. Only this file is new in stage 2 — no
  handler change, no router change, no migration.

  The detector shape follows
  `architecture_audit_diff_native_artefact_test.exs`: the row comes from
  the handler's OWN `register/0` (never a hand-written spec map, which
  would keep passing against a row nobody dispatches), the assignee is a
  native agent on the closed roster (`kind: "native"`,
  `runtime_type: "external"` — there is no `"federated"` agent kind,
  see that file's moduledoc) holding `agents_leader`, and the native
  dispatcher is stubbed with a capture module. `Router.fire/2` is the
  production entry point; calling `gather_context/2` or `measure/2`
  directly would exercise a path production does not take to the write,
  which is the shape of mistake that let the defect survive.

  ## Why every clause assertion matches the FULL clause

  `metadata.prompt` is the system message and the rendered user body
  joined with "\\n\\n" (`classify_prompt_outcome/1` over `{:messages, _}`),
  and the system message ITSELF contains the phrase "first measurement"
  ("If the delta is absent, say this is the first measurement…"). A bare
  `refute prompt =~ "first measurement"` would fail even against a
  correct handler. Every assertion here therefore matches the full
  rendered clause (`first measurement — no prior run to compare
  against`), which exists only in `Handler.format_measurement/1` output.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: Handler
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks

  @key "agents.goal_heartbeat"
  @role_key "agents_leader"
  @goal "Close backlog items in Suite"

  # The FULL first-run clause. Matching the bare phrase would collide
  # with the system message — see the moduledoc.
  @first_clause "first measurement — no prior run to compare against"

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :goal_heartbeat_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    Logger.put_module_level(Platform.Responsibilities.Router, :info)
    on_exit(fn -> Logger.delete_module_level(Platform.Responsibilities.Router) end)

    # The stubbed dispatcher sends every accepted signal here. Deleting
    # BOTH env keys on exit — the dispatcher stub and the capture pid —
    # or a later test file could inherit a live capture target.
    Application.put_env(:platform, :goal_heartbeat_capture_pid, self())
    on_exit(fn -> Application.delete_env(:platform, :goal_heartbeat_capture_pid) end)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    on_exit(fn ->
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
    end)

    # The row under test comes from the handler's OWN `register/0`, never
    # a hand-written map (same reasoning as the artefact detector). The
    # provider boot walk is disabled in the test env, so each case
    # installs the row explicitly.
    [spec] = Handler.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Goal Heartbeat Fire #{System.unique_integer([:positive])}"
      })

    agent = wire_leader!()
    space = backlog_space!(agent)

    %{row: row, project: project, agent: agent, space: space}
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  # Same shape as `wire_federated_architect!/0` in the artefact detector,
  # retargeted at this responsibility's role bundle: a Role row (the
  # `agents_leader` key is on the closed roster, `Role.valid_keys()`),
  # the role→responsibility link the bundle resolver joins through, a
  # native agent, and the role assignment the Router resolves through
  # `Roles.assignee_for/1`.
  defp wire_leader! do
    Repo.insert!(
      %Role{
        key: @role_key,
        name: "Agents Leader",
        description: "test fixture",
        icon: "hero-bolt"
      },
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{role_key: @role_key, responsibility_key: @key})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:role_key, :responsibility_key])

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "goal-heartbeat-leader-#{System.unique_integer([:positive])}",
        name: "Agents Leader Fire Test",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(@role_key, agent.id)

    agent
  end

  # The backlog space the heartbeat speaks for. `leader_agent_id` is
  # casted on the Space changeset; setting it pins
  # `Handler.agents_space/0`'s ordering (`desc: not is_nil(leader),
  # asc: inserted_at`) to THIS space deterministically. The
  # `prompt =~ @goal` asserts are the attribution control if anything
  # else ever shadows it.
  defp backlog_space!(agent) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agents fire-test #{System.unique_integer([:positive])}",
        slug: "agents-fire-#{System.unique_integer([:positive])}",
        kind: "channel",
        goal: @goal,
        leader_agent_id: agent.id
      })

    space
  end

  # The production entry point, not a provider-level shortcut. The
  # returned outcome is asserted at every call site as the second
  # positive control: a fire that resolved no assignee returns
  # `{:ok, :unfilled}` and would otherwise leave the absence assertions
  # passing vacuously.
  defp fire! do
    {result, _log} =
      with_log([level: :info], fn ->
        Router.fire(@key, %{kind: :cron, fired_at: DateTime.utc_now()})
      end)

    result
  end

  defp add_open_tasks!(%{project: project}, n) do
    for i <- 1..n do
      {:ok, _} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "fire-test open task #{i}",
          status: "in_progress"
        })
    end
  end

  # `measure/2` and the persisted baseline both live on the space's
  # `metadata` field — a struct held across a fire is STALE. Reload
  # before every read that must see the persisted row.
  defp reload!(space), do: Repo.get!(Space, space.id)

  # ── the detector ─────────────────────────────────────────────────────

  test "fire 1 is a first measurement; fire 2 after two new open tasks carries the delta", ctx do
    assert {:ok, :dispatched} = fire!()

    # POSITIVE CONTROLS, both needed. Without assert_receive the absence
    # of a delta would pass on a fire that never happened — and the
    # capture dispatcher returns :ok even when nobody is listening, so
    # the Router itself reports `:dispatched` either way. The agent_id
    # assert pins the assignee to THIS fixture, not some override or
    # leftover row.
    assert_receive {:captured_signal, signal}
    assert signal.metadata.responsibility_key == @key
    assert signal.metadata.agent_id == ctx.agent.id
    assert signal.metadata.prompt =~ @goal
    assert signal.metadata.prompt =~ @first_clause

    first_row = reload!(ctx.space).metadata["goal_heartbeat"]
    assert is_map(first_row), "fire 1 persisted no baseline"

    add_open_tasks!(ctx, 2)

    # THE DISCRIMINATING CASE. The second dispatch must carry the delta:
    # the pre-fix handler rendered "first measurement" on every fire
    # because nothing reachable ever wrote the baseline.
    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, signal2}
    assert signal2.metadata.prompt =~ "up 2 since the previous run"
    refute signal2.metadata.prompt =~ @first_clause

    second_row = reload!(ctx.space).metadata["goal_heartbeat"]
    assert second_row["measurement"] == first_row["measurement"] + 2
    assert second_row["goal"] == @goal
  end

  test "two fires with no task change render unchanged on the second", ctx do
    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, _signal}
    first_row = reload!(ctx.space).metadata["goal_heartbeat"]
    assert is_map(first_row), "fire 1 persisted no baseline"

    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, signal2}

    # The delta:0 clause has never executed in production (every run
    # before the fix re-read a nil baseline), so this pins a branch the
    # unit file's hand-seeded baseline exercises but the fire path had
    # never reached.
    assert signal2.metadata.prompt =~ "unchanged since the previous run"
    refute signal2.metadata.prompt =~ @first_clause

    second_row = reload!(ctx.space).metadata["goal_heartbeat"]
    assert second_row["measurement"] == first_row["measurement"]
  end

  test "changing the goal between fires resets to a first measurement", ctx do
    new_goal = "Ship 3 backlog items this week"

    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, _signal}
    assert is_map(reload!(ctx.space).metadata["goal_heartbeat"])

    {:ok, _} = Chat.update_space(reload!(ctx.space), %{goal: new_goal})

    # The old number was taken for a different question, so the delta
    # resets to a first measurement rather than reporting a difference
    # between two different goals — and the row now carries the NEW
    # goal, not merely a reset number.
    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, signal2}
    assert signal2.metadata.prompt =~ new_goal
    assert signal2.metadata.prompt =~ @first_clause
    refute signal2.metadata.prompt =~ "unchanged since the previous run"

    row = reload!(ctx.space).metadata["goal_heartbeat"]
    assert row["goal"] == new_goal
  end

  test "the stage-4 header path cannot advance the baseline: fire 2 deltas against fire 1",
       ctx do
    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, _signal}

    space = reload!(ctx.space)
    assert is_map(space.metadata["goal_heartbeat"]), "fire 1 persisted no baseline"

    # THREE direct `measure/2` calls — the stage-4 header path — before
    # the count changes. Stage 1's design note, measured there: these
    # reads CANNOT detonate a write that had been moved into `measure/2`,
    # because baseline and count agree at every direct read, so a moved
    # write re-persists the same number and leaves every read here
    # indistinguishable. Included anyway (the spec asks for both blocks);
    # the reads AFTER the change are the ones that detonate.
    directs_before = for _ <- 1..3, do: Handler.measure(space, space.goal)

    first_value = hd(directs_before).value
    assert Enum.all?(directs_before, &(&1.value == first_value and &1.delta == 0))

    add_open_tasks!(ctx, 2)

    # The reads that CAN detonate. `measure/2` is pure, so in the fixed
    # world both reads still compare against fire 1's baseline. Reload
    # between the reads so a hypothetical persisting `measure/2` is
    # caught here too — its first call would advance the persisted row,
    # and the second read (fresh struct) would then show `delta == 0`.
    directs_after =
      Enum.map(1..2, fn _ ->
        current = reload!(space)
        Handler.measure(current, current.goal)
      end)

    assert Enum.all?(directs_after, &(&1.previous == first_value and &1.delta == 2))

    # The main detonation: the gather re-reads the space fresh, so a
    # baseline advanced by any direct call above shows up here as
    # "unchanged since the previous run" instead of "up 2".
    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, signal2}
    assert signal2.metadata.prompt =~ "up 2 since the previous run"
    refute signal2.metadata.prompt =~ @first_clause
  end
end
