defmodule Platform.Responsibilities.AgentsGoalHeartbeatTest do
  @moduledoc """
  Task `01a0b491` stage 3.

  The measurable case is the POSITIVE CONTROL for the `missing?: true`
  case: without it, a `gather_context/2` that marked every goal missing
  would satisfy the no-measurement assertion on its own. Both live in
  this module for that reason.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Cron
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: Handler
  alias Platform.Tasks

  import ExUnit.CaptureLog

  defp space_with_goal(goal) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agents #{System.unique_integer([:positive])}",
        slug: "agents-#{System.unique_integer([:positive])}",
        kind: "channel",
        goal: goal
      })

    space
  end

  describe "register/0" do
    test "declares a parseable daily cron expression and the leader role" do
      [spec] = Handler.register()

      assert spec.key == "agents.goal_heartbeat"
      assert spec.trigger_kind == "cron"
      assert spec.default_prompt_template == "agents.goal_heartbeat.v1"
      assert spec.metadata["role"] == "agents_leader"

      assert {:ok, _parsed} = Cron.parse(spec.trigger_config["expression"])
    end

    test "the handler is reachable from BuiltIns.providers/0" do
      assert Handler in BuiltIns.providers()
    end
  end

  describe "gather_context/2" do
    test "returns a populated count for the backlog goal" do
      _space = space_with_goal("Close backlog items in Suite")

      {:ok, context} = Handler.gather_context(nil, %{})

      assert context.goal == "Close backlog items in Suite"
      measurement = context.measurement

      refute measurement.missing?
      assert measurement.kind == :open_tasks
      assert is_integer(measurement.value)

      # First run: no delta, and it must SAY so rather than print 0.
      assert measurement.delta == nil
      assert Handler.format_measurement(measurement) =~ "first measurement"
      refute Handler.format_measurement(measurement) =~ "unchanged"
    end

    test "marks the measurement slot missing? for a goal with no derivable number" do
      _space = space_with_goal("Get SXI to a good state")

      {:ok, context} = Handler.gather_context(nil, %{})

      assert context.measurement.missing? == true
      assert context.measurement.reason =~ "names nothing this handler can count"

      # A goal that cannot name a number has no heartbeat.
      assert {:error, {:no_measurement, _reason}} = Handler.build_prompt(context)
    end

    test "build_prompt/1 succeeds on the measurable goal (control for the refusal above)" do
      _space = space_with_goal("Close backlog items in Suite")

      {:ok, context} = Handler.gather_context(nil, %{})
      assert {:ok, %{system: system, user: user}} = Handler.build_prompt(context)
      assert system =~ "goal heartbeat"
      assert user =~ "Close backlog items in Suite"
    end
  end

  describe "delta persistence" do
    test "the second run reports a delta where the first reported none" do
      space = space_with_goal("Close backlog items in Suite")

      first = Handler.measure(space, space.goal)
      assert first.delta == nil

      {:ok, space} =
        Chat.update_space(space, %{
          metadata: %{
            "goal_heartbeat" => %{
              "measurement" => first.value + 5,
              "measured_at" => DateTime.to_iso8601(DateTime.utc_now()),
              "goal" => space.goal
            }
          }
        })

      second = Handler.measure(space, space.goal)
      assert second.previous == first.value + 5
      assert second.delta == -5
      assert Handler.format_measurement(second) =~ "down 5"
    end

    test "a baseline taken for a DIFFERENT goal is not used as a delta" do
      space = space_with_goal("Close backlog items in Suite")

      {:ok, space} =
        Chat.update_space(space, %{
          metadata: %{
            "goal_heartbeat" => %{
              "measurement" => 999,
              "measured_at" => DateTime.to_iso8601(DateTime.utc_now()),
              "goal" => "some other goal entirely"
            }
          }
        })

      measured = Handler.measure(space, space.goal)
      assert measured.delta == nil
      assert measured.previous == nil
    end
  end

  describe "no space at all" do
    test "measure/2 refuses rather than inventing a zero" do
      assert %{missing?: true, reason: reason} = Handler.measure(nil, "Close backlog items")
      assert reason =~ "no chat space"
    end
  end

  # ── The write (task `01a0c332`) ──────────────────────────────────────────
  #
  # The pre-fix handler's only baseline write lived in `handle_output/3`,
  # which the Router reaches ONLY on the external dispatch path
  # (`run_external_dispatch/5`, router.ex ~1244) — never on
  # `dispatch_native/5` (~1657), the arm every cron→agent-turn fire takes.
  # The write was unreachable, so every real fire reported "first
  # measurement" forever. These tests exercise the gather, the point that
  # runs on every real fire, and assert the BASELINE PERSISTS — which is
  # why every test here gathers at least twice: a one-run test cannot
  # fail on this defect, the second run IS the test.

  describe "the write (gather persists the baseline)" do
    defp make_project do
      {:ok, project} =
        Tasks.create_project(%{
          name: "Heartbeat Project #{System.unique_integer([:positive])}"
        })

      project
    end

    defp open_task(project_id, title) do
      {:ok, task} =
        Tasks.create_task(%{
          project_id: project_id,
          title: title,
          status: "backlog"
        })

      task
    end

    # (a) TWO-RUN DISCRIMINATOR. Before the fix, run 2 reports
    # `delta == nil` because the fire's baseline was never written —
    # this test failed on the unfixed handler (recorded in the stage
    # evidence) and must stay green after it.
    test "run 1 has no delta and persists its baseline; run 2 reports the delta" do
      space = space_with_goal("Close backlog items in Suite")
      project = make_project()

      {:ok, first} = Handler.gather_context(nil, %{})
      assert first.measurement.missing? == false
      assert first.measurement.delta == nil
      run1 = first.measurement.value

      reloaded = Chat.get_space(space.id)
      persisted = reloaded.metadata["goal_heartbeat"]
      assert is_map(persisted)
      assert persisted["measurement"] == run1
      assert persisted["goal"] == "Close backlog items in Suite"
      assert is_binary(persisted["measured_at"])

      # One open task enters between the runs.
      open_task(project.id, "Heartbeat: opened in run 2")

      {:ok, second} = Handler.gather_context(nil, %{})

      # The exact integer: exactly one task entered, so exactly +1.
      assert second.measurement.value == run1 + 1
      assert second.measurement.previous == run1
      assert second.measurement.delta == 1

      # The baseline rolled forward to run 2's value.
      reloaded2 = Chat.get_space(space.id)
      assert reloaded2.metadata["goal_heartbeat"]["measurement"] == second.measurement.value
    end

    # (b) FLAT CONTROL. The delta:0 path has never executed in production
    # (nothing ever wrote a baseline), so this clause pins the "no change"
    # reading explicitly rather than letting it alias the first-run one.
    test "two gathers with nothing changed between report delta 0, not first-run" do
      _space = space_with_goal("Close backlog items in Suite")

      {:ok, _first} = Handler.gather_context(nil, %{})
      {:ok, second} = Handler.gather_context(nil, %{})

      assert second.measurement.delta == 0

      rendered = Handler.format_measurement(second.measurement)
      assert rendered =~ "unchanged since the previous run"
      refute rendered =~ "first measurement"
    end

    # (c) GOAL RESET. A baseline taken for a different goal is not a
    # comparable baseline: the delta resets to "first measurement for
    # this goal", and the persisted row must name the NEW goal so the
    # NEXT gather has one to compare against.
    test "a goal reset reads as first measurement again and re-baselines to the new goal" do
      space = space_with_goal("Close backlog items in Suite")

      {:ok, _first} = Handler.gather_context(nil, %{})

      new_goal = "Close the SXI backlog this sprint"
      {:ok, _} = Chat.update_space(space, %{goal: new_goal})

      {:ok, second} = Handler.gather_context(nil, %{})

      assert second.measurement.delta == nil
      assert Handler.format_measurement(second.measurement) =~ "first measurement"

      reloaded = Chat.get_space(space.id)
      assert reloaded.metadata["goal_heartbeat"]["goal"] == new_goal
    end

    # (d) ANTI-PATTERN GUARD. `measure/2` is ALSO the stage-4 header
    # re-derivation, called on every goal save. If the write is ever
    # moved into it, those renders advance the baseline without a fire
    # having consumed it, and the next fire reports "unchanged" instead
    # of the delta. Detonates exactly that: after the change, three
    # header-path reads must leave the baseline at the FIRST FIRE's
    # value, so the second gather still reports +1.
    #
    # Ordering note: the header reads are placed AFTER the count change
    # (three more before it, per the spec text, would read identically
    # under both implementations — the baseline and the count agree at
    # every read). Only reads that follow the change can distinguish a
    # persisting `measure/2` from a non-persisting one.
    test "the stage-4 header path (measure/2) never advances the baseline" do
      space = space_with_goal("Close backlog items in Suite")
      project = make_project()

      {:ok, first} = Handler.gather_context(nil, %{})
      baseline = first.measurement.value

      # Header path before anything changed — a no-op read under any
      # implementation.
      for _ <- 1..3, do: Handler.measure(space, space.goal)

      # One open task enters, THEN the header re-renders (a goal save
      # between the two fires).
      open_task(project.id, "Heartbeat: opened between fires")
      for _ <- 1..3, do: Handler.measure(space, space.goal)

      {:ok, second} = Handler.gather_context(nil, %{})

      assert second.measurement.previous == baseline
      assert second.measurement.delta == 1
      assert Handler.format_measurement(second.measurement) =~ "up 1"
    end

    # (e) TOLERANCE. The dispatch is never lost to a persist failure: the
    # warning logs, the gather still returns {:ok, context} with the
    # computed measurement.
    test "a failed persist logs a warning and the gather still returns the context" do
      space = space_with_goal("Close backlog items in Suite")

      # Force the row invalid past the changeset, so the metadata write
      # inside `record_measurement/2` fails. validate_required checks
      # DATA rather than changes (Ecto's validate_change skips unchanged
      # fields — a goal-length trick would NOT fail), so name/slug
      # nulled via a bare changeset makes every Chat.update_space on
      # this row return {:error, changeset}.
      space
      |> Ecto.Changeset.change(%{name: nil, slug: nil})
      |> Repo.update!()

      log =
        capture_log(fn ->
          {:ok, context} = Handler.gather_context(nil, %{})
          send(self(), {:gathered, context})
        end)

      assert log =~ "could not persist measurement"

      assert_received {:gathered, context}
      assert context.measurement.missing? == false
      assert is_integer(context.measurement.value)
      assert context.measurement.delta == nil

      # Nothing was persisted.
      reloaded = Chat.get_space(space.id)
      refute reloaded.metadata["goal_heartbeat"]
    end
  end
end
