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
end
