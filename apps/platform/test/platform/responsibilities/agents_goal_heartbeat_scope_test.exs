defmodule Platform.Responsibilities.AgentsGoalHeartbeatScopeTest do
  @moduledoc """
  Task `01a0ca9f` stage 2: the open-task count is scoped to one project
  via the goal space's `metadata["goal_project_id"]`.

  Every fire goes through the production entry point, `Router.fire/2`,
  with the native dispatcher stubbed by a capture module (the shape of
  `agents_goal_heartbeat_fire_test.exs`); none calls `handle_output/3`,
  which the Router's native arm never reaches.

  Fixture: project A has 3 open tasks plus one done, one cancelled and
  one soft-deleted; project B has 2 open. The unscoped (install) prompt's
  byte-identity is held by stage 1's literal control in
  `agents_goal_heartbeat_uncounted_test.exs`; this file does not restate
  it.
  """

  use Platform.DataCase, async: false

  import Ecto.Query, only: [from: 2]
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
  alias Platform.Tasks.Task, as: TaskSchema

  @key "agents.goal_heartbeat"
  @role_key "agents_leader"

  @goal "Grow the job-board backlog: keep it populated with new opportunities"

  @first_clause "(first measurement — no prior run to compare against)"

  @unknown_line "Measurement: no count for this goal. Its project scope names no project " <>
                  "that exists, so nothing was counted: report concretely what changed " <>
                  "since the last beat."

  @count_failed_line "Measurement: no count for this goal. The open-task count could not " <>
                       "be read this hour, so nothing was counted: report concretely what " <>
                       "changed since the last beat."

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :goal_heartbeat_scope_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    Application.put_env(:platform, :goal_heartbeat_scope_capture_pid, self())
    on_exit(fn -> Application.delete_env(:platform, :goal_heartbeat_scope_capture_pid) end)

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

    %{agent: wire_leader!()}
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
        slug: "goal-heartbeat-scope-#{System.unique_integer([:positive])}",
        name: "Agents Leader Scope Test",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(@role_key, agent.id)

    agent
  end

  defp goal_space!(agent, metadata \\ %{}) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Agents scope #{System.unique_integer([:positive])}",
        slug: "agents-scope-#{System.unique_integer([:positive])}",
        kind: "channel",
        goal: @goal,
        leader_agent_id: agent.id,
        metadata: metadata
      })

    space
  end

  defp project!(label) do
    {:ok, project} =
      Tasks.create_project(%{name: "Scope #{label} #{System.unique_integer([:positive])}"})

    project
  end

  defp task!(project, status) do
    {:ok, task} =
      Tasks.create_task(%{project_id: project.id, title: "t #{status}", status: status})

    task
  end

  # A: 3 open + done + cancelled + soft-deleted. B: 2 open.
  defp projects! do
    a = project!("Alpha")
    b = project!("Bravo")

    for _ <- 1..3, do: task!(a, "in_progress")
    task!(a, "done")
    task!(a, "cancelled")

    deleted = task!(a, "in_progress")

    deleted
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update!()

    for _ <- 1..2, do: task!(b, "backlog")

    {a, b}
  end

  defp set_scope!(space, value) do
    space = reload!(space)
    metadata = Map.put(space.metadata || %{}, "goal_project_id", value)
    {:ok, space} = Chat.update_space(space, %{metadata: metadata})
    space
  end

  defp unset_scope!(space) do
    space = reload!(space)

    {:ok, space} =
      Chat.update_space(space, %{metadata: Map.delete(space.metadata, "goal_project_id")})

    space
  end

  defp fire! do
    {result, _log} =
      with_log([level: :info], fn ->
        Router.fire(@key, %{kind: :cron, fired_at: DateTime.utc_now()})
      end)

    result
  end

  defp fire_prompt!(agent) do
    assert {:ok, :dispatched} = fire!()
    assert_receive {:captured_signal, signal}
    assert signal.metadata.agent_id == agent.id
    assert is_binary(signal.metadata.prompt)
    signal.metadata.prompt
  end

  defp measurement_line(prompt) do
    prompt |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "Measurement: "))
  end

  defp reload!(space), do: Repo.get!(Space, space.id)

  defp open_count_in(project) do
    from(t in TaskSchema,
      where:
        t.project_id == ^project.id and t.status not in ["done", "cancelled"] and
          is_nil(t.deleted_at),
      select: count(t.id)
    )
    |> Repo.one()
  end

  # ── (i) scoped to A ──────────────────────────────────────────────────

  test "(i) scoped to A counts A's open tasks only", ctx do
    space = goal_space!(ctx.agent)
    %{missing?: false, value: pre_unscoped} = Handler.measure(space, @goal)

    {a, b} = projects!()
    space = set_scope!(space, a.id)

    line = fire_prompt!(ctx.agent) |> measurement_line()
    assert String.starts_with?(line, "Measurement: 3 open tasks in #{a.name} (first measurement")

    row = reload!(space).metadata["goal_heartbeat"]
    assert row["measurement"] == 3
    assert row["project_id"] == a.id

    # Positive control, same data: B's tasks exist and an unscoped fire
    # sees them, so the 3 above is the filter, not an empty install.
    assert open_count_in(b) == 2
    _space = unset_scope!(space)

    unscoped_line = fire_prompt!(ctx.agent) |> measurement_line()
    [_, n] = Regex.run(~r/^Measurement: (\d+) open tasks \(/, unscoped_line)
    assert String.to_integer(n) >= pre_unscoped + 5
  end

  # ── (ii) unset scope ─────────────────────────────────────────────────

  test "(ii) no scope key and a nil scope both measure install-wide with today's slot", ctx do
    space = goal_space!(ctx.agent)
    {_a, _b} = projects!()

    slot = Handler.measure(space, @goal)
    assert Handler.goal_scope(space) == :install
    assert slot.unit == "open tasks"
    refute Map.has_key?(slot, :project_id)

    nil_space = set_scope!(space, nil)
    assert Handler.goal_scope(nil_space) == :install
    assert Handler.measure(nil_space, @goal) == slot

    line = fire_prompt!(ctx.agent) |> measurement_line()
    assert line == "Measurement: #{slot.value} open tasks #{@first_clause}"

    row = reload!(space).metadata["goal_heartbeat"]
    assert Map.keys(row) |> Enum.sort() == ["goal", "measured_at", "measurement"]
  end

  test "(ii) an existing unscoped baseline (no project_id key) still yields its delta", ctx do
    {_a, _b} = projects!()

    space =
      goal_space!(ctx.agent, %{
        "goal_heartbeat" => %{
          "measurement" => 1,
          "measured_at" => "2026-09-22T10:00:00Z",
          "goal" => @goal
        }
      })

    line = fire_prompt!(ctx.agent) |> measurement_line()
    assert line == "Measurement: 5 open tasks (up 4 since the previous run)"

    row = reload!(space).metadata["goal_heartbeat"]
    refute Map.has_key?(row, "project_id")
  end

  # ── (iii) a scope that names no project ──────────────────────────────

  for {label, kind} <- [
        {"a random UUID", :random},
        {"an archived project", :archived},
        {"a project scheduled for deletion", :deletion_scheduled},
        {"the non-UUID string job-hunt", :slug}
      ] do
    test "(iii) #{label} dispatches with no number and no install-wide fallback", ctx do
      {a, _b} = projects!()
      space = goal_space!(ctx.agent)
      %{value: install_count} = Handler.measure(space, @goal)
      assert install_count >= 5

      value =
        case unquote(kind) do
          :random ->
            Ecto.UUID.generate()

          :archived ->
            {:ok, _} = Tasks.update_project(a, %{archived_at: DateTime.utc_now()})
            a.id

          :deletion_scheduled ->
            {:ok, _} = Tasks.update_project(a, %{deletion_scheduled_at: DateTime.utc_now()})
            a.id

          :slug ->
            "job-hunt"
        end

      space = set_scope!(space, value)
      assert Handler.goal_scope(space) == :unknown

      line = fire_prompt!(ctx.agent) |> measurement_line()
      assert line == @unknown_line
      assert line =~ "names no project that exists"
      refute line =~ ~r/\d/
      refute line =~ "#{install_count} open tasks"

      row = reload!(space).metadata["goal_heartbeat"]
      assert is_binary(row["beat_at"])
      refute Map.has_key?(row, "measurement")
      assert reload!(space).metadata["goal_project_id"] == value

      assert Handler.format_measurement(Handler.measure(space, @goal)) ==
               "no count: the goal's project scope names no project that exists"
    end
  end

  # ── (iv) scope change resets the baseline ────────────────────────────

  test "(iv) a scope change reads as a first measurement, never a delta", ctx do
    {a, b} = projects!()
    space = goal_space!(ctx.agent) |> set_scope!(a.id)

    first = fire_prompt!(ctx.agent) |> measurement_line()
    assert first == "Measurement: 3 open tasks in #{a.name} #{@first_clause}"

    space = set_scope!(space, b.id)
    second = fire_prompt!(ctx.agent) |> measurement_line()
    assert second == "Measurement: 2 open tasks in #{b.name} #{@first_clause}"

    for word <- ["up", "down", "unchanged"], do: refute(second =~ ~r/\b#{word}\b/)

    _space = unset_scope!(space)
    third = fire_prompt!(ctx.agent) |> measurement_line()
    assert third =~ ~r/^Measurement: \d+ open tasks \(first measurement/
    for word <- ["up", "down", "unchanged"], do: refute(third =~ ~r/\b#{word}\b/)

    # Control: the same scope twice DOES produce a delta, so the resets
    # above are the scope comparison and not a baseline that never lands.
    fourth = fire_prompt!(ctx.agent) |> measurement_line()
    assert fourth =~ "(unchanged since the previous run)"
  end

  # ── (v) the goal save leaves the scope alone ─────────────────────────

  test "(v) updating the goal text leaves goal_project_id intact", ctx do
    {a, _b} = projects!()
    space = goal_space!(ctx.agent) |> set_scope!(a.id)

    _ = fire_prompt!(ctx.agent)
    assert reload!(space).metadata["goal_project_id"] == a.id

    {:ok, _} = Chat.update_space(reload!(space), %{goal: "Close backlog items in Suite"})
    assert reload!(space).metadata["goal_project_id"] == a.id

    line = fire_prompt!(ctx.agent) |> measurement_line()
    assert line == "Measurement: 3 open tasks in #{a.name} #{@first_clause}"
  end

  # ── a count that raised is not zero ──────────────────────────────────

  test "a raised count query renders no number, and keeps the prior baseline", ctx do
    {_a, _b} = projects!()

    baseline = %{
      "measurement" => 4,
      "measured_at" => "2026-09-22T10:00:00Z",
      "goal" => @goal
    }

    space = goal_space!(ctx.agent, %{"goal_heartbeat" => baseline})

    # Transactional DDL inside the sandbox: rolled back with the test. The
    # sandbox runs each query in a savepoint, so the failed count does not
    # abort the rest of the gather.
    Repo.query!("ALTER TABLE tasks RENAME COLUMN deleted_at TO deleted_at_scope_test")

    {result, log} =
      with_log([level: :warning], fn ->
        Router.fire(@key, %{kind: :cron, fired_at: DateTime.utc_now()})
      end)

    assert {:ok, :dispatched} = result
    assert log =~ "open task count raised"
    assert_receive {:captured_signal, signal}

    line = measurement_line(signal.metadata.prompt)
    assert line == @count_failed_line
    refute line =~ ~r/\d/

    assert reload!(space).metadata["goal_heartbeat"] == baseline
  end
end
