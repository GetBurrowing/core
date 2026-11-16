defmodule Platform.Responsibilities.AgentsGoalHeartbeatClaimedSpaceTest do
  @moduledoc """
  Task `01a1dfc1-dffb` stage 3: a build-time module may claim a chat space's
  goal through the optional `claims_space_goal?/1` callback, and core's
  `agents.goal_heartbeat` then stands down for that space.

  Every fixture extension is defined in this file. The "no extension", "does
  not implement", "answers false" and "raises" cases are the positive
  controls for the claimed case: each must still measure, write the baseline
  and fire, so a gather that skipped every space could not pass them.

  NOT async: every case writes `:platform, :extensions` (global app env) and
  restores it in `on_exit`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Extensions
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat, as: Handler
  alias Platform.Responsibilities.Router
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility

  @heartbeat_key "agents.goal_heartbeat"
  @role_key "agents_leader"
  @goal "Close backlog items in Suite"
  @claimed_env :claimed_space_test_space_id

  defmodule FixtureBase do
    @moduledoc false
    defmacro __using__(_opts) do
      quote do
        @behaviour Platform.Extension
        @impl true
        def canvas_kinds, do: []
        @impl true
        def mcp_tool_bundles, do: []
        @impl true
        def runtime_channel_events, do: []
        @impl true
        def handle_runtime_event(_event, _runtime_id, _payload), do: :ok
        @impl true
        def runtime_disconnected(_runtime_id), do: :ok
        @impl true
        def live_hooks, do: []
        @impl true
        def experiment_surfaces, do: []
        @impl true
        def experiment_metrics, do: %{}
        @impl true
        def migrations_path, do: nil
      end
    end
  end

  defmodule NoCallbackFixture do
    @moduledoc false
    use FixtureBase
  end

  defmodule FalseFixture do
    @moduledoc false
    use FixtureBase
    @impl true
    def claims_space_goal?(_space_id), do: false
  end

  defmodule TruthyFixture do
    @moduledoc false
    use FixtureBase
    # A truthy value that is not `true` must not count as a claim.
    @impl true
    def claims_space_goal?(_space_id), do: :yes
  end

  defmodule ClaimOneFixture do
    @moduledoc false
    use FixtureBase
    @impl true
    def claims_space_goal?(space_id),
      do: space_id == Application.get_env(:platform, :claimed_space_test_space_id)
  end

  defmodule RaisingFixture do
    @moduledoc false
    use FixtureBase
    @impl true
    def claims_space_goal?(_space_id), do: raise("fixture claim exploded")
  end

  defmodule CaptureDispatcher do
    @moduledoc false
    def maybe_dispatch(signal) do
      pid = Application.get_env(:platform, :claimed_space_capture_pid)
      if is_pid(pid), do: send(pid, {:captured_signal, signal})
      :ok
    end
  end

  setup do
    previous = Application.fetch_env(:platform, :extensions)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:platform, :extensions, value)
        :error -> Application.delete_env(:platform, :extensions)
      end

      Application.delete_env(:platform, @claimed_env)
      Application.delete_env(:platform, :claimed_space_capture_pid)
      Application.delete_env(:platform, :responsibility_router_native_dispatcher)
    end)

    Application.put_env(:platform, :claimed_space_capture_pid, self())

    Application.put_env(
      :platform,
      :responsibility_router_native_dispatcher,
      {CaptureDispatcher, :maybe_dispatch}
    )

    :ok
  end

  # ── fixtures ─────────────────────────────────────────────────────────

  defp use_extensions(list), do: Application.put_env(:platform, :extensions, list)

  defp space!(attrs) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "Claimed test #{n}", slug: "claimed-test-#{n}", kind: "channel"}, attrs)
      )

    space
  end

  # Same wiring as `GoalHeartbeatNativeSkipTest.wire_leader!/0`: the real
  # role path production walks, not an override.
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
        slug: "claimed-space-leader-#{System.unique_integer([:positive])}",
        name: "Agents Leader Claimed Test",
        status: "active",
        kind: "native",
        runtime_type: "external",
        workspace_id: nil
      })
      |> Repo.insert!()

    {:ok, _} = Roles.assign_role(@role_key, agent.id)
    agent
  end

  defp register_heartbeat_row! do
    [spec] = Handler.register()
    {:ok, row} = Responsibilities.upsert_by_key(spec)
    row
  end

  defp fire_heartbeat!(fired_at) do
    Router.fire(@heartbeat_key, %{kind: :cron, fired_at: fired_at})
  end

  defp fired_at, do: ~U[2026-11-16 12:00:00.000000Z]

  # Today's behaviour, asserted whole: a number, a baseline written, and a
  # full fire that reaches the dispatcher.
  defp assert_fires_normally do
    agent = wire_leader!()
    register_heartbeat_row!()
    space = space!(%{goal: @goal, leader_agent_id: agent.id})

    context = Handler.gather_context(%{})
    refute context.measurement.missing?
    assert is_integer(context.measurement.value)
    assert context.dispatch_space_id == space.id
    assert {:ok, _} = Handler.build_prompt(context)

    baseline = Chat.get_space(space.id).metadata["goal_heartbeat"]
    assert baseline["measurement"] == context.measurement.value
    assert baseline["goal"] == @goal

    assert fire_heartbeat!(fired_at()) == {:ok, :dispatched}
    assert_received {:captured_signal, signal}
    assert signal.metadata.responsibility_key == @heartbeat_key
    assert signal.metadata.agent_id == agent.id
  end

  # ── the reader ───────────────────────────────────────────────────────

  test "the callback is optional on the behaviour" do
    assert {:claims_space_goal?, 1} in Platform.Extension.behaviour_info(:optional_callbacks)
    assert {:claims_space_goal?, 1} in Platform.Extension.behaviour_info(:callbacks)
  end

  test "a non-binary id is never claimed, even by a module that claims everything" do
    Application.put_env(:platform, @claimed_env, nil)
    use_extensions([ClaimOneFixture])

    refute Extensions.space_goal_claimed?(nil)
    refute Extensions.space_goal_claimed?(:space)
    refute Extensions.space_goal_claimed?(123)
  end

  test "only an exact true counts as a claim" do
    use_extensions([TruthyFixture])
    refute Extensions.space_goal_claimed?(Ecto.UUID.generate())
  end

  # ── today's behaviour holds ──────────────────────────────────────────

  describe "no extension configured" do
    test "nothing is claimed and the heartbeat measures, writes its baseline and fires" do
      use_extensions([])
      refute Extensions.space_goal_claimed?(Ecto.UUID.generate())
      assert_fires_normally()
    end
  end

  describe "an extension that does not implement the callback" do
    test "claims nothing and the heartbeat fires" do
      use_extensions([NoCallbackFixture])
      refute Extensions.space_goal_claimed?(Ecto.UUID.generate())
      assert_fires_normally()
    end
  end

  describe "an extension answering false" do
    test "claims nothing and the heartbeat fires" do
      use_extensions([FalseFixture])
      refute Extensions.space_goal_claimed?(Ecto.UUID.generate())
      assert_fires_normally()
    end
  end

  describe "an extension that raises" do
    test "counts as false, is logged at warning, and the heartbeat fires" do
      use_extensions([RaisingFixture])

      log =
        capture_log([level: :warning], fn ->
          refute Extensions.space_goal_claimed?(Ecto.UUID.generate())
        end)

      assert log =~ "claims_space_goal?"
      assert log =~ "fixture claim exploded"

      capture_log(fn -> assert_fires_normally() end)
    end
  end

  # ── the claim ────────────────────────────────────────────────────────

  describe "an extension answering true for space A only" do
    setup do
      use_extensions([FalseFixture, ClaimOneFixture])
      :ok
    end

    test "with A as the agents space the beat stands down and writes nothing" do
      agent = wire_leader!()
      register_heartbeat_row!()

      prior = %{
        "measurement" => 7,
        "measured_at" => "2026-11-15T12:00:00Z",
        "goal" => @goal
      }

      space_a =
        space!(%{
          goal: @goal,
          leader_agent_id: agent.id,
          metadata: %{"goal_heartbeat" => prior}
        })

      Application.put_env(:platform, @claimed_env, space_a.id)
      assert Extensions.space_goal_claimed?(space_a.id)
      assert Handler.agents_space().id == space_a.id

      context = Handler.gather_context(%{})
      assert context.goal == @goal
      assert context.measurement.missing?
      refute Map.has_key?(context.measurement, :kind)
      refute Map.has_key?(context, :dispatch_space_id)
      assert {:error, {:no_measurement, _reason}} = Handler.build_prompt(context)

      assert Chat.get_space(space_a.id).metadata["goal_heartbeat"] == prior

      assert fire_heartbeat!(fired_at()) == {:ok, :no_measurement}
      refute_received {:captured_signal, _signal}
      assert Chat.get_space(space_a.id).metadata["goal_heartbeat"] == prior
    end

    test "with a different space B as the agents space the heartbeat fires" do
      space_a = space!(%{})
      Application.put_env(:platform, @claimed_env, space_a.id)
      assert Extensions.space_goal_claimed?(space_a.id)

      assert_fires_normally()
      refute Handler.agents_space().id == space_a.id
    end
  end
end
