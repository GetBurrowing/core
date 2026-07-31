defmodule Platform.Design.TaskDirectionUnansweredGuardTest do
  @moduledoc """
  A standing guard that `design.task_direction` keeps recording a
  DISTINGUISHABLE outcome for a fire nobody answered (task `019fa61c`
  stage 5).

  ## Why this guard exists on a responsibility this task does not change

  Stage 5's reader — `Platform.Architecture.StageAudit.coverage/1` — was
  built because `architecture.audit_diff` fired 28 times in a 3.3-hour
  window and left no durable evidence anywhere. The obvious question is
  why `design.task_direction`, which runs through the same
  `Platform.Responsibilities.fire/2` seam, never had that problem. The
  answer is not that it was written more carefully. It is that the design
  step HOLDS THE PLANNER: its silence had a cost, so the system was
  forced to model it, and it therefore already has all four pieces
  `audit_diff` lacked —

    * a ROW: `Tasks.record_planning_step/3` writes
      `planning_step_outcomes["design"]`,
    * a DEADLINE: `PreplanStep.expire/2`, driven from the router,
    * a TOOL: `task_design_decline` (task `019fa504`),
    * a READER: `Tasks.failed_planning_steps/1` ->
      `Tasks.planning_gate_failed?/1`, which gates the merge.

  `audit_diff` holds nothing up, so its silence was free and was never
  modelled. That asymmetry is the whole finding, and it means
  `019fa504` did not close a gap for `task_direction` — it added a third
  EXIT for a designer who had only two.

  So there is nothing to change here, and this file changes nothing. It
  PINS the property, because a future refactor of the shared fire path
  could quietly delete it and every existing assertion would still pass:
  the closest existing cover
  (`preplan_step_test.exs`, "GUARD — expire/2") sets `planning_step:
  "designing"` on a hand-built task rather than firing, so a fire path
  that stopped opening the step at all would not fail it.

  ## The vacuity this file is written against

  "A fired-and-unanswered step records `failed`" passes on its own
  against a module that records `failed` for EVERYTHING, and equally
  against one that never fired in the first place. Three things are
  therefore asserted together, in one test, over one fixture:

    * a POSITIVE CONTROL that the fire actually went out — the dispatcher
      stub reports it, so "unanswered" means unanswered and not
      undispatched;
    * that the ACCEPTED DISPATCH records NOTHING and leaves the step
      open, so a handoff is never laundered into a win (the whole reason
      `StageAudit.open_from_fire/2` writes `"pending"` and not
      `"noted"`);
    * that the three terminal situations — unanswered, answered, never
      applicable — are PAIRWISE DISTINCT in the persisted row, and that
      only the unanswered one reaches the merge gate.

  Not `async: true`: the dispatcher seam is module-level `Application`
  env, which is global.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Design.PreplanStep
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.DesignTaskDirection
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema

  @key "design.task_direction"

  # Stage 1's own doctest example, so the classifier's verdict is not in
  # doubt in either direction.
  @ui_title "Add an epic-create FAB above the board"
  @non_ui_title "Add Providers.Architecture shim"

  defmodule ReportingDispatcher do
    @moduledoc false
    def maybe_dispatch(_signal) do
      case Application.get_env(:platform, :task_direction_guard_pid) do
        pid when is_pid(pid) -> send(pid, :design_fired)
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    # The Registry's boot walk is off in the test env, so the row stage 3
    # of `019f9b29-5ecd` registers has to be installed per sandbox.
    [spec] = DesignTaskDirection.register()
    {:ok, _row} = Responsibilities.upsert_by_key(spec)

    previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {ReportingDispatcher, :maybe_dispatch}
    )

    Application.put_env(:platform, :task_direction_guard_pid, self())

    on_exit(fn ->
      Application.delete_env(:platform, :task_direction_guard_pid)

      if previous do
        Application.put_env(:platform, :responsibility_router_native_dispatcher, previous)
      else
        Application.delete_env(:platform, :responsibility_router_native_dispatcher)
      end
    end)

    {:ok, project} = Tasks.create_project(%{name: "Task Direction Guard #{unique()}"})

    %{project: project}
  end

  defp unique, do: System.unique_integer([:positive])

  defp quietly(fun), do: capture_log([level: :debug], fun)

  defp task!(project, title) do
    now = DateTime.utc_now()

    %TaskSchema{}
    |> Ecto.Changeset.change(%{
      project_id: project.id,
      title: title,
      status: "planning",
      inserted_at: now,
      updated_at: now
    })
    |> Repo.insert!()
  end

  defp reload(%TaskSchema{id: id}), do: Repo.get!(TaskSchema, id)

  defp design_entry(task), do: (reload(task).planning_step_outcomes || %{})["design"]

  # Hand-built rather than `ExecutionSpace.find_or_create/1`: that helper
  # derives its slug from the task UUID's millisecond field, so two tasks
  # created inside one millisecond collide on the space slug index. Same
  # reason `Platform.Design.BrandTest` builds its own.
  defp execution_space!(task) do
    n = unique()

    {:ok, space} =
      Chat.create_space(%{
        name: "td-guard-exec-#{n}",
        slug: "td-guard-exec-#{n}",
        kind: "execution",
        metadata: %{"task_id" => task.id}
      })

    space
  end

  # `historian` as the carrier role, the same substitution the architect
  # hook test uses: it keeps this off the seeded `designer` bundle the
  # closed-roster coverage suite already exercises.
  defp wire_designer! do
    role_key = "historian"

    Repo.insert!(
      %Role{key: role_key, name: "Historian", description: "test", icon: "hero-star"},
      on_conflict: :nothing,
      conflict_target: :key
    )

    %RoleResponsibility{}
    |> RoleResponsibility.changeset(%{role_key: role_key, responsibility_key: @key})
    |> Repo.insert!()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "td-guard-designer-#{unique()}",
        name: "Guard Designer",
        status: "active",
        kind: "native",
        workspace_id: nil
      })
      |> Repo.insert()

    {:ok, _} = Roles.assign_role(role_key, agent.id)

    agent
  end

  describe "GUARD — a fired-and-unanswered design.task_direction stays distinguishable" do
    test "the fire goes out, records nothing, and its silence lands as failed at the deadline",
         %{project: project} do
      _agent = wire_designer!()

      unanswered = task!(project, @ui_title)
      _ = execution_space!(unanswered)

      quietly(fn -> assert {:ok, :open} = PreplanStep.start(unanswered) end)

      # POSITIVE CONTROL. Without it "unanswered" is satisfied by a step
      # that was never dispatched, which is the exact conflation
      # `019fa61c` exists to remove one responsibility over.
      assert_receive :design_fired, 500

      # An ACCEPTED HANDOFF IS NOT AN ANSWER. Nothing is recorded and the
      # step stays open — the same rule `StageAudit.open_from_fire/2`
      # follows when it writes `"pending"` rather than `"noted"`. If this
      # ever recorded `complete`, every later silence would be
      # indistinguishable from a win and the deadline below would be
      # unreachable.
      assert design_entry(unanswered) == nil
      assert PreplanStep.open?(reload(unanswered))

      quietly(fn -> assert {:ok, :failed} = PreplanStep.expire(unanswered, 1_800_000) end)

      unanswered_entry = design_entry(unanswered)
      assert unanswered_entry["outcome"] == "failed"

      # The row says WHY, so a merge-time reader can act on it rather
      # than rediscovering the timeout.
      assert unanswered_entry["reason"] == "design_timeout"
      assert is_binary(unanswered_entry["detail"])

      # ── the two counterfactuals, same fixture, same fire path ───────

      # (a) ANSWERED: a canvas landed.
      answered = task!(project, @ui_title)
      _ = execution_space!(answered)
      quietly(fn -> assert {:ok, :open} = PreplanStep.start(answered) end)
      assert_receive :design_fired, 500

      quietly(fn ->
        assert {:ok, :complete} = PreplanStep.settle(answered, Ecto.UUID.generate())
      end)

      # (b) NEVER APPLICABLE: not a UI task, so nothing is fired at all.
      inapplicable = task!(project, @non_ui_title)
      quietly(fn -> assert {:ok, :not_applicable} = PreplanStep.start(inapplicable) end)
      refute_receive :design_fired, 200

      answered_entry = design_entry(answered)
      inapplicable_entry = design_entry(inapplicable)

      assert answered_entry["outcome"] == "complete"
      assert inapplicable_entry["outcome"] == "not_applicable"

      # PAIRWISE DISTINCT, written as direct inequalities. A refactor that
      # collapsed any two of these would restore the invisibility this
      # whole task is about, on the one responsibility that never had it.
      assert unanswered_entry["outcome"] != answered_entry["outcome"]
      assert unanswered_entry["outcome"] != inapplicable_entry["outcome"]
      assert answered_entry["outcome"] != inapplicable_entry["outcome"]

      # And the READER — the fourth piece `audit_diff` lacked. Only the
      # unanswered fire reaches the merge gate; an answered one and an
      # inapplicable one are silent there, so the gate is a signal rather
      # than a constant.
      assert Tasks.planning_gate_failed?(reload(unanswered))
      refute Tasks.planning_gate_failed?(reload(answered))
      refute Tasks.planning_gate_failed?(reload(inapplicable))
    end
  end
end
