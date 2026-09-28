defmodule Platform.Responsibilities.GoalHeartbeatNativeSkipTest do
  @moduledoc """
  Fire-level detector for task `01a0e881` stage 2, part 1: does the
  native hand-off `Router.dispatch_native/6` skips on
  `{:absent, {:refused, {:no_measurement, _}}}` (task `01a0e881` stage 1,
  commit `0f09ed60`) actually stop the broadcast a native runtime would
  otherwise receive, and does it leave the unrelated `@no_work_refusals`
  path alone?

  ## Why this drives `Router.fire/2`, not `Handler.measure/2` or
  `Handler.build_prompt/1` directly

  Stage 1's own fixed bug was a unit test asserting a map the Router had
  just built (see `agents_goal_heartbeat_uncounted_test.exs`, which
  proves `build_prompt/1`'s refusal shape but never calls the dispatcher
  the fix actually touches). Calling `measure/2` or `build_prompt/1`
  in isolation here would repeat exactly that mistake for the REGRESSION
  test — it would prove the classification, not the skip. Every
  assertion below goes through `Router.fire/2` (which resolves the row
  by key, mirroring `AgentsGoalHeartbeatFireTest`) so the thing measured
  is what `AgentResponder.maybe_dispatch/1` would actually have been
  called with — or, on the red-first case, that it is never called at
  all.

  ## The dispatcher seam

  `Router.call_agent_responder/1` (router.ex ~2390) is the ONE call site
  that would hand a signal to `Platform.Chat.AgentResponder.maybe_dispatch/1`,
  which is what ultimately broadcasts to a runtime's `runtime:<id>` topic.
  Swapping it for `CaptureDispatcher` below (same technique as
  `AgentsGoalHeartbeatFireTest`) does not simulate the skip — it sits at
  the exact boundary the fix changed, so "no message received by
  `CaptureDispatcher`" is equivalent evidence to "no broadcast fires":
  if `dispatch_native/6` had not skipped, this seam is unconditionally on
  the path that would reach the dispatcher.

  ## Fixture discipline

  The `agents.goal_heartbeat` row comes from `Handler.register/0` (never
  a hand-written spec map — see `AgentsGoalHeartbeatFireTest`'s
  moduledoc on why a hand-seeded row over a dispatch defect passes
  forever), and the assignee is a native agent wired to the real
  `agents_leader` role via `Role` + `RoleResponsibility`, exactly as
  `AgentsGoalHeartbeatFireTest.wire_leader!/0` does it — not a
  `ResponsibilityOverride`, so the same role-bundle resolution path
  production actually walks is exercised.
  """

  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: GoalHeartbeatHandler
  alias Platform.Responsibilities.Handlers.MeetingActionItems
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility

  @heartbeat_key "agents.goal_heartbeat"
  @role_key "agents_leader"
  @goal "Close backlog items in Suite"

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :goal_heartbeat_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
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

    :ok
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  # Same shape as `AgentsGoalHeartbeatFireTest.wire_leader!/0`: a `Role`
  # row on the closed roster, the role->responsibility link the bundle
  # resolver joins through, a native agent, and the role assignment
  # `Roles.assignee_for/1` resolves through. Deliberately NOT a
  # `ResponsibilityOverride` — the override short-circuits before the
  # role bundle is even consulted (see the handler's moduledoc), and
  # this stage is exercising the role path production actually uses.
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
    |> RoleResponsibility.changeset(%{role_key: @role_key, responsibility_key: @heartbeat_key})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:role_key, :responsibility_key])

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "goal-heartbeat-skip-leader-#{System.unique_integer([:positive])}",
        name: "Agents Leader Skip Test",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(@role_key, agent.id)

    agent
  end

  # The goal space the heartbeat measures against. `goal` is left unset
  # so the red-first case genuinely has no chat space carrying a goal —
  # `Handler.agents_space/0` filters on `not is_nil(goal) and goal != ""`,
  # so a goal-less space still exercises the real query rather than an
  # empty table standing in for "no goal anywhere".
  defp goalless_space! do
    {:ok, space} =
      Chat.create_space(%{
        name: "Goalless space #{System.unique_integer([:positive])}",
        slug: "goalless-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    space
  end

  defp goal_space!(agent) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Backlog goal space #{System.unique_integer([:positive])}",
        slug: "backlog-goal-#{System.unique_integer([:positive])}",
        kind: "channel",
        goal: @goal,
        leader_agent_id: agent.id
      })

    space
  end

  defp register_heartbeat_row! do
    [spec] = GoalHeartbeatHandler.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    row
  end

  # Same override-based wiring `NativeDispatchEnvelopeTest.federated_assignee/1`
  # uses for the meetings key: an override is sufficient for a
  # responsibility with no role-bundle requirement in this test, and using
  # it here (rather than re-deriving `meetings`' own role) keeps the
  # negative control scoped to what stage 1 could plausibly have broken —
  # the refusal-to-signal path, not role resolution.
  defp override_assignee!(responsibility_key) do
    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "meetings-action-items-skip-#{System.unique_integer([:positive])}",
        name: "Meetings Action Items Skip Test",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.set_override(responsibility_key, agent.id)

    agent
  end

  defp fire_heartbeat! do
    Router.fire(@heartbeat_key, %{kind: :cron, fired_at: DateTime.utc_now()})
  end

  # ── validation 01a0e893-c713-7006-bce9-f3515dacce76: red-first ────────

  describe "red-first: no goal on any space" do
    setup do
      register_heartbeat_row!()
      :ok
    end

    test "an empty spaces table produces no broadcast to a native runtime" do
      _agent = wire_leader!()

      # Genuinely zero spaces — hits `Handler.measure(nil, _)`.
      assert fire_heartbeat!() == {:ok, :no_measurement}
      assert Responsibilities.outcome({:ok, :no_measurement}) == :not_applicable

      # THE ASSERTION THE CASE EXISTS FOR: nothing ever reached the
      # dispatcher seam that would hand a signal to a native runtime.
      refute_receive {:captured_signal, _signal}, 300
    end

    test "a space with no goal set produces the same skip, not a different refusal" do
      _agent = wire_leader!()
      _space = goalless_space!()

      # Belt and suspenders against `Handler.agents_space/0` behaving
      # differently on a goal-less row than on an empty table (it does
      # not: both eventually hit `measure(nil, _)`, since
      # `agents_space/0` filters on `not is_nil(goal) and goal != ""`),
      # so the red-first case is not accidentally pinned to only one of
      # the two code paths that produce it.
      assert fire_heartbeat!() == {:ok, :no_measurement}
      refute_receive {:captured_signal, _signal}, 300
    end
  end

  # ── validation 01a0e893-c713-7007-acb6-fe52f27628f9: positive control ──

  describe "positive control: a goal is set" do
    test "still dispatches — the fix is not broad enough to suppress a real goal" do
      register_heartbeat_row!()
      agent = wire_leader!()
      _space = goal_space!(agent)

      assert fire_heartbeat!() == {:ok, :dispatched}
      assert Responsibilities.outcome({:ok, :dispatched}) == :complete

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == @heartbeat_key
      assert signal.metadata.agent_id == agent.id
      assert signal.metadata.prompt_status == :rendered
      refute Map.has_key?(signal.metadata, :prompt_absence_reason)
      assert signal.metadata.prompt =~ @goal
    end
  end

  # ── validation 01a0e893-c713-7008-81e8-bee3d09e528a: negative control ──

  describe "negative control: meetings.action_items still dispatches on its own no-work refusal" do
    test "unchanged after stage 1's fix — the skip must not widen to @no_work_refusals" do
      [spec] = MeetingActionItems.register()
      {:ok, _row} = Responsibilities.upsert_by_key(spec)
      agent = override_assignee!(MeetingActionItems.key())

      # Same trigger shape `NativeDispatchEnvelopeTest` already proves
      # reaches `{:error, :no_intent_text}` in `build_prompt/1`: a blank
      # chunk, via a nil `transcript_id`.
      assert Router.fire(MeetingActionItems.key(), %{
               kind: :event_topic,
               payload: %{transcript_id: nil}
             }) == {:ok, :dispatched}

      assert_receive {:captured_signal, signal}
      assert signal.metadata.responsibility_key == MeetingActionItems.key()
      assert signal.metadata.agent_id == agent.id

      # `:no_intent_text` is on `@no_work_refusals` — a native assignee
      # still gets a bare signal so it can wake and say there was
      # nothing to act on, unlike `:no_measurement`, which now skips the
      # hand-off entirely. This is the assertion that would go red if
      # stage 1's match arm were widened past `:no_measurement`.
      assert signal.metadata.prompt_status == :no_work
      assert signal.metadata.prompt_absence_reason == "no_intent_text"
      refute Map.has_key?(signal.metadata, :prompt)

      assert :no_intent_text in Router.no_work_refusals()
    end
  end
end
