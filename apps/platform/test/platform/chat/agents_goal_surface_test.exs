defmodule Platform.Chat.AgentsGoalSurfaceTest do
  @moduledoc """
  The context layer behind the stage-4 agents surface (task
  `01a0b491-0718-7001-8bba-bf50f119bb13`).

  Every assertion about an ABSENCE here is paired with the flag-on or
  goal-present case that produces the presence, because "renders nothing"
  is indistinguishable from "is broken" without it. That pairing is the
  point of the module: with `AGENTS_GOAL_SURFACE` unset the stage-1
  columns may hold values and the surface still resolves to nil, and only
  the paired case shows the nil was the flag.

  `async: false` — the feature flag is application env, which is global to
  the node.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Chat.Space
  alias Platform.Repo
  alias Platform.Roles

  @flag_key :agents_goal_surface

  setup do
    previous = Application.get_env(:platform, @flag_key)
    on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
    :ok
  end

  defp enable_flag, do: Application.put_env(:platform, @flag_key, true)
  defp disable_flag, do: Application.put_env(:platform, @flag_key, false)

  defp insert_agent(name) do
    Repo.insert!(%Platform.Agents.Agent{
      name: name,
      slug: "#{String.downcase(name)}-#{System.unique_integer([:positive])}",
      status: "active"
    })
  end

  defp insert_space(attrs) do
    slug = "agents-surface-#{System.unique_integer([:positive])}"

    %Space{}
    |> Space.changeset(Map.merge(%{kind: "channel", name: "Agents", slug: slug}, Map.new(attrs)))
    |> Repo.insert!()
  end

  describe "the feature flag gates the whole surface" do
    test "with the flag off both entry points return nil even though the columns hold values" do
      agent = insert_agent("Dalton")
      space = insert_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)

      disable_flag()

      refute Sidebar.agents_surface_enabled?()
      assert Sidebar.agents_rail_block() == nil
      assert Sidebar.goal_panel(space) == nil
    end

    test "with the flag on the SAME row produces both — this is the control for the case above" do
      agent = insert_agent("Dalton")
      space = insert_space(goal: "Close backlog items in Suite", leader_agent_id: agent.id)

      enable_flag()

      assert Sidebar.agents_surface_enabled?()
      assert %{space: %Space{}} = Sidebar.agents_rail_block()
      assert %{goal: "Close backlog items in Suite"} = Sidebar.goal_panel(space)
    end
  end

  describe "goal_panel/1 is conditional on the space, not painted unconditionally" do
    setup do
      enable_flag()
      :ok
    end

    test "a space with no goal yields nil while a space with one yields a panel" do
      plain = insert_space(name: "control")
      goal_space = insert_space(goal: "Close backlog items in Suite")

      assert Sidebar.goal_panel(plain) == nil
      assert %{goal: "Close backlog items in Suite"} = Sidebar.goal_panel(goal_space)
    end

    test "nil and a blank goal are both nil" do
      assert Sidebar.goal_panel(nil) == nil
      assert Sidebar.goal_panel(insert_space(goal: "")) == nil
    end
  end

  describe "the measurement re-derives on save and never carries forward" do
    setup do
      enable_flag()
      :ok
    end

    test "a goal that stops being measurable shows the missing state immediately, not the old number" do
      space = insert_space(goal: "Close backlog items in Suite")

      measurable = Sidebar.goal_panel(space)
      assert measurable.measurement.missing? == false
      assert is_integer(measurable.measurement.value)

      # The same single operation the LiveView's `save_goal` runs — no
      # insert-vs-update split, no first-time path.
      {:ok, updated} = Chat.update_space(space, %{goal: "Get Globex to a good state"})

      unmeasurable = Sidebar.goal_panel(updated)
      assert unmeasurable.measurement.missing? == true
      assert is_binary(unmeasurable.measurement.reason)
      refute Map.has_key?(unmeasurable.measurement, :value)

      # Round trip back: the warning state is driven by measurability, not
      # by the act of saving.
      {:ok, back} = Chat.update_space(updated, %{goal: "Close backlog items in Suite"})
      assert Sidebar.goal_panel(back).measurement.missing? == false
    end
  end

  describe "agents_leader/1 resolves the role first" do
    setup do
      enable_flag()
      :ok
    end

    test "the role assignee wins over the space column, so a swap repaints" do
      column_agent = insert_agent("Columnagent")
      role_agent = insert_agent("Roleagent")
      space = insert_space(goal: "Close backlog items in Suite", leader_agent_id: column_agent.id)

      # No role pinned: the column is the fallback and answers.
      assert Sidebar.agents_leader(space).id == column_agent.id

      {:ok, _} = Roles.assign_role(Sidebar.agents_leader_role(), role_agent.id)

      assert Sidebar.agents_leader(space).id == role_agent.id
      assert Sidebar.agents_rail_block().leader.id == role_agent.id
      assert Sidebar.goal_panel(space).leader.id == role_agent.id
    end

    test "no role and no column yields nil rather than a placeholder face" do
      space = insert_space(goal: "Close backlog items in Suite")
      assert Sidebar.agents_leader(space) == nil
      assert Sidebar.agents_rail_block().leader == nil
    end
  end

  describe "first_goal_offered?/1 scopes the first goal to the install (task 01a0ca99)" do
    # ONE fixture — a goal-less channel, flag on, no goal anywhere — is the
    # positive control for every false below. Each false case changes exactly
    # one condition from it, so a false cannot be a broken fixture.
    setup do
      enable_flag()
      %{space: insert_space(name: "agents")}
    end

    defp archive!(space),
      do: space |> Ecto.Changeset.change(archived_at: DateTime.utc_now()) |> Repo.update!()

    test "true for a goal-less channel with the flag on and no goal anywhere", %{space: space} do
      assert Sidebar.first_goal_offered?(space) == true
    end

    test "false with the flag off", %{space: space} do
      assert Sidebar.first_goal_offered?(space)
      disable_flag()
      assert Sidebar.first_goal_offered?(space) == false
    end

    test "false when another non-archived space already carries a goal", %{space: space} do
      assert Sidebar.first_goal_offered?(space)
      insert_space(name: "other", goal: "Close backlog items in Suite")
      assert Sidebar.first_goal_offered?(space) == false
    end

    test "true again when the only other goal-carrying space is archived", %{space: space} do
      other = insert_space(name: "other", goal: "Close backlog items in Suite")
      refute Sidebar.first_goal_offered?(space)

      archive!(other)
      assert Sidebar.first_goal_offered?(space) == true
    end

    test "false for a dm", %{space: space} do
      assert Sidebar.first_goal_offered?(space)
      dm = space |> Ecto.Changeset.change(kind: "dm") |> Repo.update!()
      assert Sidebar.first_goal_offered?(dm) == false
    end

    test "false for an archived channel", %{space: space} do
      assert Sidebar.first_goal_offered?(space)
      assert Sidebar.first_goal_offered?(archive!(space)) == false
    end

    test "false for a space that already has a goal, and for a blank goal it is true", %{
      space: space
    } do
      assert Sidebar.first_goal_offered?(%{space | goal: ""})
      {:ok, goaled} = Chat.update_space(space, %{goal: "Close backlog items in Suite"})
      assert Sidebar.first_goal_offered?(goaled) == false
    end

    test "false for nil and non-space input" do
      assert Sidebar.first_goal_offered?(nil) == false
      assert Sidebar.first_goal_offered?(%{kind: "channel", goal: nil}) == false
    end
  end

  describe "format_measurement_tail/1 splits the sentence at the numeral" do
    alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat

    test "the tail is the full clause minus its leading number" do
      slot = %{missing?: false, kind: :open_tasks, unit: "open tasks", value: 279, delta: -3}

      assert AgentsGoalHeartbeat.format_measurement(slot) =~ "279"
      tail = AgentsGoalHeartbeat.format_measurement_tail(slot)

      refute String.starts_with?(tail, "279")
      assert "279" <> tail == AgentsGoalHeartbeat.format_measurement(slot)
    end

    test "a missing slot returns its whole reason unchanged" do
      slot = %{missing?: true, reason: "the space has no goal set"}

      assert AgentsGoalHeartbeat.format_measurement_tail(slot) ==
               AgentsGoalHeartbeat.format_measurement(slot)
    end
  end
end
