defmodule Platform.Orchestration.TaskRouterBranchProvisioningTest do
  @moduledoc """
  Pins WHERE Suite creates `task/<uuid>` (task 01a001ac, stage 2).

  ## The claim

  `TaskRouter.do_dispatch_resolved/5` calls
  `Platform.Tasks.BranchProvisioner.ensure_branches/2` BEFORE
  `HeartbeatScheduler.dispatch_prompt/4` renders, and only for an
  execution-phase dispatch on a non-stack task.

  The alternative site — `PlanEngine.build_deploy_plan/1` — was rejected
  deliberately: it runs after every implementation stage is done and the
  executor has already pushed somewhere, so a branch created there cannot
  constrain anything the executor did. It would be detection dressed as
  prevention.

  ## Why the negative cases live in the SAME file as the positive one

  "A planning dispatch provisions nothing" is satisfied by a provisioner
  that never fires at all. It only carries information when it runs next
  to a case that DOES provision, against the same stub, in the same run.
  That pairing is the whole design of this file; do not split it.

  ## The fail-soft case is the one most easily written vacuously

  Asserting "the router did not crash" would pass against a version that
  swallowed the dispatch entirely — which is the failure mode fail-soft
  exists to prevent. So the error case asserts the two POSITIVE
  consequences: the attention broadcast still fires, and the warning
  naming the branch is logged.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.BranchProvisioner
  alias Platform.Tasks.Stacks
  alias Platform.Tasks.Task, as: TaskSchema

  @observe_ms 1_500

  # ── Stub runner ─────────────────────────────────────────────────────────
  #
  # `BranchProvisionerTest`'s stub threads its agent pid through the process
  # dictionary, which cannot work here: the calls happen inside the ROUTER
  # process, not the test process. This one reads the test pid out of
  # application env — the same keyword list `BranchProvisioner.runner/0`
  # reads — and reports by message, so the assertions are ordinary
  # `assert_received` absence/presence claims.
  defmodule StubRunner do
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @sha "0f1e2d3c4b5a69788796a5b4c3d2e1f001122334"

    @impl true
    def default_branch_sha(%{repo: repo}) do
      report({:default_branch_sha, repo}, {:ok, @sha})
    end

    @impl true
    def list_matching_refs(%{repo: repo, ref: ref}) do
      report({:list_matching_refs, repo, ref}, {:ok, []})
    end

    @impl true
    def create_ref(%{repo: repo, ref: ref, sha: sha}) do
      report({:create_ref, repo, ref, sha}, {:ok, ref})
    end

    defp report(call, ok_result) do
      config = Application.get_env(:platform, :branch_provisioner, [])

      case Keyword.get(config, :test_pid) do
        pid when is_pid(pid) -> send(pid, {:provisioner, call})
        _ -> :ok
      end

      case Keyword.get(config, :mode, :ok) do
        :ok -> ok_result
        :error -> {:error, :gh_unavailable, "gh CLI not found on PATH"}
      end
    end
  end

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    {:ok, project} =
      Tasks.create_project(%{
        name: "Branch Provisioning Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/branch-provisioning"
      })

    {agent, runtime} = create_linked_agent_runtime()

    %{project: project, agent: agent, runtime: runtime}
  end

  defp pin_runner(mode) do
    previous = Application.get_env(:platform, :branch_provisioner)

    Application.put_env(:platform, :branch_provisioner,
      runner: StubRunner,
      test_pid: self(),
      mode: mode
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :branch_provisioner, previous)
      else
        Application.delete_env(:platform, :branch_provisioner)
      end
    end)

    :ok
  end

  # ── Case 0: THE PROVISIONING CONTROL ──────────────────────────────────
  #
  # Every negative case below is an absence claim, and an absence claim is
  # worth nothing unless the observer has been shown to see a presence. This
  # is that demonstration: the stub IS reachable from the router process, and
  # the branch it is asked for carries the FULL uuid.
  describe "execution-phase dispatch" do
    test "provisions task/<full-uuid> exactly once, before the prompt", %{
      project: project,
      agent: agent,
      runtime: runtime
    } do
      pin_runner(:ok)
      subscribe(runtime)

      task = dispatchable_task(project, agent, "in_progress")
      branch = BranchProvisioner.branch_for(Repo.get!(TaskSchema, task.id))

      assert branch == "task/#{task.id}",
             "fixture precondition: the derived branch must carry the full uuid"

      start_router!(task.id, runtime)

      topics = collect_attention_topics()

      assert topics == ["runtime:#{runtime}"],
             "harness failure: the execution dispatch itself never fired; saw #{inspect(topics)}"

      calls = drain_provisioner_calls()

      creates = for {:create_ref, _repo, ref, _sha} <- calls, do: ref

      assert creates == ["refs/heads/" <> branch],
             "expected exactly one create_ref for the derived branch; saw #{inspect(calls)}"
    end

    # ── Case 0b: THE FIRST EXECUTION DISPATCH ───────────────────────────
    #
    # `do_dispatch/2` resolves stages with `current_running_stage/1`, so an
    # `in_progress` task whose next stage is still `pending` resolves NO stage
    # and renders `dispatch.fallback`. That is the dispatch which "is the only
    # thing that will ever get an agent to call `stage_start`"
    # (`unresolved_stage_dispatch?/3`), i.e. the FIRST one the executor runs
    # `git worktree add` from — so it is the one that most needs the branch to
    # exist. A gate keyed on `dispatch.in_progress` alone leaves this red.
    test "provisions on the pending-stage first dispatch too", %{
      project: project,
      agent: agent,
      runtime: runtime
    } do
      pin_runner(:ok)
      subscribe(runtime)

      task = dispatchable_task(project, agent, "in_progress", "pending")

      start_router!(task.id, runtime)

      assert collect_attention_topics() == ["runtime:#{runtime}"],
             "harness failure: the pending-stage dispatch never fired"

      creates = for {:create_ref, _repo, ref, _sha} <- drain_provisioner_calls(), do: ref

      assert creates == ["refs/heads/task/#{task.id}"]
    end
  end

  # ── Case 1: PLANNING DISPATCHES PROVISION NOTHING ─────────────────────
  #
  # Paired with case 0 by construction: same stub, same run, same observer.
  describe "non-execution dispatch" do
    test "a planning dispatch provisions nothing", %{
      project: project,
      agent: agent,
      runtime: runtime
    } do
      pin_runner(:ok)
      subscribe(runtime)

      task =
        project
        |> create_task!()
        |> put_task_fields(%{
          status: "planning",
          assignee_id: agent.id,
          assignee_type: "agent",
          phase_assignees: %{"planning" => phase_entry(agent), "execution" => phase_entry(agent)}
        })

      start_router!(task.id, runtime)

      topics = collect_attention_topics()

      refute topics == [],
             "harness failure: no planning dispatch observed at all, so 'provisioned nothing' " <>
               "is vacuous here"

      assert drain_provisioner_calls() == [],
             "a planning dispatch has no executor to constrain and must not touch GitHub"
    end

    test "a stack member's execution dispatch provisions nothing", %{
      project: project,
      agent: agent,
      runtime: runtime
    } do
      pin_runner(:ok)
      subscribe(runtime)

      {:ok, stack} =
        Stacks.create_stack(%{
          project_id: project.id,
          slug: "stack-#{System.unique_integer([:positive])}",
          name: "Rollup Stack",
          rollup_branch: "stack/rollup-#{System.unique_integer([:positive])}"
        })

      task = dispatchable_task(project, agent, "in_progress")
      task = put_task_fields(task, %{stack_id: stack.id})

      start_router!(task.id, runtime)

      topics = collect_attention_topics()

      refute topics == [],
             "harness failure: the stack member never dispatched, so 'provisioned nothing' " <>
               "is vacuous here"

      assert drain_provisioner_calls() == [],
             "a stack member ships through the rollup branch; StackDeployer owns its refs"
    end
  end

  # ── Case 2: FAIL SOFT, LOG LOUD ───────────────────────────────────────
  describe "provisioner failure" do
    test "still dispatches, and logs a warning naming the task and branch", %{
      project: project,
      agent: agent,
      runtime: runtime
    } do
      pin_runner(:error)
      subscribe(runtime)

      task = dispatchable_task(project, agent, "in_progress")
      branch = "task/#{task.id}"

      log =
        capture_log(fn ->
          start_router!(task.id, runtime)

          # Held inside the capture window so the router's warning — emitted
          # from its own process, before the broadcast — is inside it too.
          topics = collect_attention_topics()

          assert topics == ["runtime:#{runtime}"],
                 "a provisioner failure must NOT suppress the dispatch: a task that cannot " <>
                   "reach GitHub still needs its executor prompted; saw #{inspect(topics)}"
        end)

      assert log =~ "could not pre-create branch #{branch}",
             "the failure must be named in the log, or the drift is invisible; log was:\n#{log}"

      assert log =~ task.id
      assert log =~ "gh_unavailable"

      # The provisioner was actually reached — otherwise this test would pass
      # against a build that never calls it and never fails.
      assert Enum.any?(drain_provisioner_calls(), &match?({:list_matching_refs, _, _}, &1)),
             "the stub was never called, so the 'failure' path was never exercised"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────

  defp subscribe(runtime), do: PlatformWeb.Endpoint.subscribe("runtime:#{runtime}")

  defp collect_attention_topics(window_ms \\ @observe_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    drain_attention(deadline, [])
  end

  defp drain_attention(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        %Phoenix.Socket.Broadcast{event: "attention", topic: topic} ->
          drain_attention(deadline, [topic | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  defp drain_provisioner_calls(acc \\ []) do
    receive do
      {:provisioner, call} -> drain_provisioner_calls([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp create_user do
    Repo.insert!(%User{
      email: "branch_prov_#{System.unique_integer([:positive])}@example.com",
      name: "Branch Provisioning Test User",
      oidc_sub: "oidc-branch-prov-#{System.unique_integer([:positive])}"
    })
  end

  defp create_linked_agent_runtime do
    user = create_user()

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "branch-prov-agent-#{System.unique_integer([:positive])}",
        name: "Branch Provisioning Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "branch-prov-runtime-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end

  defp create_task!(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Branch Provisioning Task #{System.unique_integer([:positive])}",
        description: "Pins where Suite creates task/<uuid>",
        deploy_target: "production"
      })

    task
  end

  defp put_task_fields(%TaskSchema{} = task, fields) do
    task
    |> Ecto.Changeset.change(fields)
    |> Repo.update!()
  end

  defp phase_entry(%Agent{} = agent) do
    %{"assignee_id" => agent.id, "assignee_type" => "agent"}
  end

  defp dispatchable_task(project, agent, status, stage_status \\ "running") do
    task =
      project
      |> create_task!()
      |> put_task_fields(%{
        status: status,
        assignee_id: agent.id,
        assignee_type: "agent",
        phase_assignees: %{"planning" => phase_entry(agent), "execution" => phase_entry(agent)}
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "coding",
        description: "Write code",
        status: stage_status
      })

    {:ok, _validation} = Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass"})

    task
  end

  defp start_router!(task_id, runtime_id) do
    {:ok, pid} =
      TaskRouter.start_link(task_id: task_id, assignee: %{type: :federated, id: runtime_id})

    on_exit(fn -> stop_router(task_id) end)

    pid
  end

  defp stop_router(task_id) do
    case Registry.lookup(Platform.Orchestration.Registry, task_id) do
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
      _ -> LeaseManager.clear(task_id)
    end
  end
end
