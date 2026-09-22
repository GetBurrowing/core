defmodule Platform.Responsibilities.AgentsGoalHeartbeatUncountedTest do
  @moduledoc """
  Task `01a0ca9f` stage 1: a goal this handler cannot count still fires
  the heartbeat, and the prompt says there is no count instead of
  inventing a number.

  Every case drives the production entry point, `Router.fire/2`, with the
  native dispatcher stubbed by a capture module (the shape of
  `agents_goal_heartbeat_fire_test.exs`). None calls `handle_output/3`:
  the Router's native arm never reaches it, so a test through it would
  pass against a handler production never runs.

  ## The measured control is a LITERAL

  "measured goal prompt is byte-identical" asserts the WHOLE captured
  prompt against a hard-coded string, written and seen passing against
  the unmodified handler (origin/main `baf0bc6c`) before the uncounted
  change. The expected value is never rebuilt from `format_measurement/1`,
  `prompt_measurement/1` or the template: a control derived from the code
  under test moves with it and cannot fail. Stage 2 (project scope) must
  keep this test passing unedited.
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

  @uncounted_goal "Keep the job board populated with new opportunities that match " <>
                    "the expected criteria defined in the project org memory."

  @uncounted_line "Measurement: no count for this goal. There is no number the system " <>
                    "can count for this goal, so do not supply one: report concretely " <>
                    "what changed since the last beat."

  @solo_sentence "You are the only agent working this goal. There is no one to delegate to; " <>
                   "this is yours."

  @first_clause "first measurement — no prior run to compare against"

  # The whole prompt for: goal "Close backlog items in Suite", exactly 3
  # open tasks in the install, first beat, solo roster. System message and
  # the rendered `agents.goal_heartbeat.v1` row joined by "\n\n"
  # (`Router.classify_prompt_outcome/1`). Hand-written; see the moduledoc.
  @measured_literal """
  You are the agents leader. This hourly heartbeat is a prod to drive the goal, not a status report. Never invent a number: use only the figures given. If the delta is absent, say this is the first measurement rather than reporting no change.

  You are the agents leader. This is the hourly goal heartbeat for the agents space: a prod to move the goal, not a status report.

  Goal: Close backlog items in Suite
  Measurement: 3 open tasks (first measurement — no prior run to compare against)

  This is the first beat; there is no prior claim to check.

  You are the only agent working this goal. There is no one to delegate to; this is yours. Pick the single open item that most moves the measurement and work it this turn. Report what you picked and what changed.

  Lead with the measurement and its movement exactly as given above. Do not recompute it, do not round it, and do not invent a number that is not there. If the measurement says this is the first run, say so rather than reporting no change.

  Post your reply in this space. End it with one line that starts "Next:" naming the single action you will have done before the next beat.
  """

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

    [spec] = Handler.register()
    {:ok, _row} = Responsibilities.upsert_by_key(spec)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Goal Heartbeat Uncounted #{System.unique_integer([:positive])}"
      })

    %{project: project, agent: wire_leader!()}
  end

  # ── fixtures ─────────────────────────────────────────────────────────

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
        slug: "goal-heartbeat-uncounted-#{System.unique_integer([:positive])}",
        name: "Agents Leader Uncounted Test",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(@role_key, agent.id)

    agent
  end

  defp goal_space!(agent, goal) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agents uncounted #{System.unique_integer([:positive])}",
        slug: "agents-uncounted-#{System.unique_integer([:positive])}",
        kind: "channel",
        goal: goal,
        leader_agent_id: agent.id
      })

    space
  end

  defp add_open_tasks!(project, n) do
    for i <- 1..n do
      {:ok, _} =
        Tasks.create_task(%{project_id: project.id, title: "open #{i}", status: "in_progress"})
    end
  end

  defp fire! do
    {result, _log} =
      with_log([level: :info], fn ->
        Router.fire(@key, %{kind: :cron, fired_at: DateTime.utc_now()})
      end)

    result
  end

  # Fires once and returns the captured signal's prompt, asserting the
  # dispatch happened and went to THIS fixture's leader.
  defp fire_prompt!(agent) do
    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, signal}
    assert signal.metadata.agent_id == agent.id
    signal.metadata.prompt
  end

  defp measurement_line(prompt) do
    prompt |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Measurement: "))
  end

  defp reload!(space), do: Repo.get!(Space, space.id)

  # ── the measured control ─────────────────────────────────────────────

  test "measured goal prompt is byte-identical to the literal", ctx do
    _space = goal_space!(ctx.agent, "Close backlog items in Suite")
    add_open_tasks!(ctx.project, 3)

    assert fire_prompt!(ctx.agent) == @measured_literal
  end

  # ── the uncounted goal ───────────────────────────────────────────────

  test "(a) an uncounted goal dispatches with a no-count measurement line and no digit", ctx do
    _space = goal_space!(ctx.agent, @uncounted_goal)
    add_open_tasks!(ctx.project, 3)

    prompt = fire_prompt!(ctx.agent)
    line = measurement_line(prompt)

    assert line == @uncounted_line
    refute line =~ ~r/\d/
    assert prompt =~ @uncounted_goal
    assert prompt =~ @solo_sentence
    refute prompt =~ "first measurement"
  end

  test "(b) a goal carrying a digit leaks no digit into the measurement line", ctx do
    _space = goal_space!(ctx.agent, "Ship 3 demos")

    prompt = fire_prompt!(ctx.agent)
    line = measurement_line(prompt)

    # Attribution control: the digit IS in the prompt (the Goal line), so
    # its absence below is about the measurement line alone.
    assert prompt =~ "Goal: Ship 3 demos"
    assert line == @uncounted_line
    refute line =~ ~r/\d/
  end

  test "(c) the second uncounted beat is not a first beat, and no baseline is written", ctx do
    space = goal_space!(ctx.agent, @uncounted_goal)

    first = fire_prompt!(ctx.agent)
    assert first =~ "This is the first beat; there is no prior claim to check."

    row = reload!(space).metadata["goal_heartbeat"]
    assert row["goal"] == @uncounted_goal
    assert is_binary(row["beat_at"])
    refute Map.has_key?(row, "measurement")
    refute Map.has_key?(row, "measured_at")

    second = fire_prompt!(ctx.agent)
    assert second =~ "Last beat got no reply from you in this space."
    refute second =~ "This is the first beat"

    row2 = reload!(space).metadata["goal_heartbeat"]
    refute Map.has_key?(row2, "measurement")
    refute Map.has_key?(row2, "measured_at")
  end

  test "(d) switching an uncounted goal to a backlog goal renders a first measurement", ctx do
    space = goal_space!(ctx.agent, @uncounted_goal)
    add_open_tasks!(ctx.project, 2)

    _ = fire_prompt!(ctx.agent)

    {:ok, _} = Chat.update_space(reload!(space), %{goal: "Close backlog items in Suite"})

    prompt = fire_prompt!(ctx.agent)
    assert measurement_line(prompt) =~ @first_clause
    refute prompt =~ "no count for this goal"
  end

  # The refusal as the NATIVE path actually carries it. The plan said "no
  # signal is captured"; measured against unmodified `baf0bc6c`, that is
  # false: `Router.dispatch_native/6` classifies a `build_prompt/1` error
  # as `{:absent, {:refused, _}}` and still hands the leader a signal,
  # with NO `:prompt` key and `prompt_status: :render_gap`. What survives
  # is the refusal to render a prompt, and that is what is asserted.
  test "(e) no space carries a goal: build_prompt still refuses, so no prompt is dispatched",
       ctx do
    assert Handler.agents_space() == nil

    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, signal}
    assert signal.metadata.agent_id == ctx.agent.id

    refute Map.has_key?(signal.metadata, :prompt)
    assert signal.metadata.prompt_status == :render_gap
    assert signal.metadata.prompt_absence_reason =~ "no_measurement"
    assert signal.metadata.prompt_absence_reason =~ "no chat space carries a goal"
  end
end
