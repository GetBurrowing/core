defmodule Platform.Orchestration.TaskRouterBootDispatchFlagTest do
  @moduledoc """
  Task 01a03ed3 stage 2 — the router can say whether the dispatch it is about
  to run was scheduled by its own `init/1` or by something that actually
  happened.

  ## Nothing is suppressed in this stage

  The flag is recorded and observable; no code path reads it to withhold a
  prompt. So the first test here is a NO-CHANGE test: exactly one attention
  broadcast and exactly one engagement message, same as before. If this stage
  altered what is sent or how often, that test is the one that says so.

  ## Why the drop-branch test asserts positively that it entered the window

  `boot_dispatch?` defaults to `false`. A test that merely asserts "the flag is
  false after sending `:dispatch`" therefore passes trivially on a tree where
  the flag was never set at all, and passes just as happily if the `:dispatch`
  raced past the 50 ms debounce window and never reached the drop branch. Green
  for the wrong reason, indistinguishable from green for the right one.

  So this file does two things instead of trusting the race:

    * It widens the debounce window via
      `:task_router_dispatch_debounce_ms` (the knob
      `TaskRouter.dispatch_debounce_ms/0` reads), so landing inside the window
      is deterministic rather than lucky.
    * Before sending `:dispatch` it asserts the router IS in the boot window —
      `dispatch_timer` armed and `boot_dispatch?` true — and after sending it
      asserts the timer ref is the SAME ref. An unchanged ref is what proves
      the message took the DROP branch rather than re-arming. A missed race is
      then visibly red, not silently green.

  MEASURED (mutation probe, this stage): deleting `boot_dispatch?: false` from
  the drop branch of `handle_info(:dispatch, …)` turns
  "a `:dispatch` dropped inside the boot window clears the flag" red. The clear
  is load-bearing and the scenario is genuinely reached.

  ## `:sys.get_state/1` and `current_status/1` answer different questions

  The pre-fire assertions read `:sys.get_state/1` because `dispatch_timer` is
  deliberately NOT surfaced through `current_status/1` — nothing outside the
  router should key off whether a reconcile is in flight, and this test is
  inside the router's own contract. The post-fire assertion uses
  `current_status/1`, which is the observable step 6 added.

  Synchronisation is `sync_router/2` + `current_status/1`, never
  `Process.sleep/1`. A bare `current_status/1` is answered before the timer
  fires, so an assertion placed after it would observe pre-dispatch state and go
  vacuously green.

  ## `async: false`

  The router is a real GenServer reading `Repo` from its own process, so the
  sandbox has to be in shared mode. Same reason as `task_router_test.exs`.
  """

  use Platform.DataCase, async: false

  import Ecto.Query
  import Platform.AsyncAssertions, only: [sync_router: 1]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Chat.Message
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks

  # Wide enough that a test process can observe the armed timer and deliver a
  # message inside it without racing. The production value is 50 ms; the knob
  # exists precisely so a test injects a window instead of sleeping on one.
  @wide_debounce_ms 2_000

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Boot Re-engagement Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/boot-re-engagement"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Boot Re-engagement Task",
        description: "Marks whether a dispatch came from init/1 or from an event",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write code"
      })

    {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
        [{pid, _}] ->
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end

        [] ->
          :ok
      end

      case :ets.info(:orchestration_lease_manager) do
        :undefined -> :ok
        _ -> LeaseManager.clear(task.id)
      end
    end)

    %{project: project, task: task, plan: plan, stage: stage}
  end

  # ── Fixtures ───────────────────────────────────────────────────────────────

  # An agent linked to an AgentRuntime, addressed by the runtime's EXTERNAL
  # `runtime_id` string. The link is BIDIRECTIONAL and both halves are
  # load-bearing: the router resolves through `runtime.agent_id`, so a fixture
  # setting only `agent.runtime_id` would report `:no_agent_named` and quietly
  # test nothing.
  defp federated_agent do
    n = System.unique_integer([:positive])

    owner =
      Repo.insert!(%User{
        email: "boot-dispatch-#{n}@example.com",
        name: "Boot Dispatch Owner #{n}",
        oidc_sub: "oidc-boot-dispatch-#{n}"
      })

    runtime =
      Repo.insert!(%AgentRuntime{
        owner_user_id: owner.id,
        status: "active",
        runtime_id: "runtime-test-#{n}",
        display_name: "boot-dispatch-#{n}"
      })

    agent =
      %Agent{}
      |> Agent.changeset(%{
        slug: "boot-dispatch-agent-#{n}",
        name: "Boot Dispatch Agent #{n}",
        status: "active",
        runtime_type: "external",
        runtime_id: runtime.id
      })
      |> Repo.insert!()

    runtime =
      runtime
      |> Ecto.Changeset.change(%{agent_id: agent.id})
      |> Repo.update!()

    %{agent: agent, runtime: runtime, assignee: %{type: :federated, id: runtime.runtime_id}}
  end

  defp widen_debounce_window do
    previous = Application.get_env(:platform, :task_router_dispatch_debounce_ms)
    Application.put_env(:platform, :task_router_dispatch_debounce_ms, @wide_debounce_ms)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :task_router_dispatch_debounce_ms)
        value -> Application.put_env(:platform, :task_router_dispatch_debounce_ms, value)
      end
    end)
  end

  defp engagement_count(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      nil ->
        0

      space ->
        Repo.aggregate(
          from(m in Message,
            where:
              m.space_id == ^space.id and
                fragment("?->>'kind' = ?", m.metadata, "engagement")
          ),
          :count
        )
    end
  end

  describe "boot dispatch provenance" do
    test "a boot dispatch still sends exactly one attention and one engagement", %{task: task} do
      %{assignee: assignee} = federated_agent()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000

      # The barrier is what makes the NEGATIVE half meaningful: without it a
      # second broadcast still in flight would be missed and the test would
      # report "exactly one" about a moment that had not finished happening.
      :ok = sync_router(task.id)
      _ = TaskRouter.current_status(task.id)

      refute_receive %Phoenix.Socket.Broadcast{event: "attention"}, 300

      assert engagement_count(task.id) == 1
    end

    test "a :dispatch dropped inside the boot window clears the flag", %{task: task} do
      widen_debounce_window()

      %{assignee: assignee} = federated_agent()

      {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # POSITIVE assertion that we are inside the window at all. `boot_dispatch?`
      # defaults to false, so without this the next assertion could pass on a
      # router that never set it.
      %{dispatch_timer: armed_ref, boot_dispatch?: true} = boot_state(pid)
      assert is_reference(armed_ref)

      send(pid, :dispatch)

      state = boot_state(pid)

      # Same ref => the message hit the DROP branch rather than re-arming. If
      # the race were missed and the timer had already fired, this would be a
      # different ref (or nil) and the test would be red rather than green for
      # the wrong reason.
      assert state.dispatch_timer == armed_ref

      # The clear under test. Omitting `boot_dispatch?: false` from the drop
      # branch leaves this true.
      refute state.boot_dispatch?
    end

    test "after a dispatch has fired, current_status reports boot_dispatch? false", %{task: task} do
      %{assignee: assignee} = federated_agent()

      Phoenix.PubSub.subscribe(Platform.PubSub, "runtime:#{assignee.id}")
      {:ok, _pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

      # Wait for the dispatch to have actually happened. A bare
      # `current_status/1` is answered before the debounce timer fires, so
      # asserting on it alone would observe pre-dispatch state.
      assert_receive %Phoenix.Socket.Broadcast{event: "attention"}, 2_000
      :ok = sync_router(task.id)

      status = TaskRouter.current_status(task.id)

      assert Map.has_key?(status, :boot_dispatch?)
      refute status.boot_dispatch?
    end
  end

  # `dispatch_timer` is deliberately not on `current_status/1` — nothing outside
  # the router should key off an in-flight reconcile. This test is inside the
  # router's own contract, so it reads process state directly.
  defp boot_state(pid), do: :sys.get_state(pid)
end
