defmodule Platform.Orchestration.TaskRouterRemediationDispatchTest do
  @moduledoc """
  Task `01a006e7` remediation, defect 2 — ONE execution dispatch per
  remediation open.

  ## What the reviewer reported, and what is actually there

  The e2e reviewer reported that every remediation-stage open delivered the
  execution dispatch payload TWICE. It does not, and this file is the
  measurement that says so — plus the regression guard that keeps it true.

  Instrumenting every `send(self(), :dispatch)` site and every
  `AttentionDispatch.broadcast/3` on the exact scenario below (long-lived
  router, gate started, one behavioural failure) gives, at the commit the
  reviewer ran:

      SRC 409   -> dispatch_now -> attention status=in_progress   (router boot)
      SRC 1152  -> dispatch_now -> attention status=in_review     (gate running)
      SRC 1118 + SRC 1152 -> ONE dispatch_now -> attention status=in_progress

  The remediation open really does ask for a dispatch twice — the failure arm's
  unconditional `send(self(), :dispatch)` and the `{:stage_transitioned,
  running}` arm for the stage it just started — but `handle_info(:dispatch, _)`
  is a DROP-IF-SCHEDULED debounce (task 01a00587): the second request lands
  while the first `:dispatch_now` is still armed and is discarded. Both
  requests are in the mailbox before `:dispatch_now` is handled, so the
  collapse is an ordering property, not a race — it survives even with the
  debounce window set to zero, which is how this file runs.

  The two payloads the reviewer saw are the FIRST TWO lines above: the
  router-boot dispatch and the gate's `in_review` dispatch. That pair is an
  artifact of a harness that starts a router and then immediately starts the
  gate stage (the reviewer's `case1.exs` does exactly this, and `server.log`
  shows exactly two dispatch log lines for its task). A production router is
  long-lived, so the boot dispatch does not recur; and neither of those two
  is the remediation dispatch. Nothing about the duplicate is introduced by
  this task, and nothing in the router is changed for it.

  ## Why the file exists anyway

  "One dispatch per remediation open" was, until now, an unasserted property
  resting on a debounce in a different module. This pins it.

  ## ANTI-VACUITY

  The assertion is a COUNT — "a dispatch happened" is true on the broken shape
  too. Two things make the count mean something:

    * case 0 shows the collector can see TWO broadcasts, so a count of 1 is not
      a count of what the collector is capable of seeing; and
    * the real case asserts the collector saw the router's OWN earlier
      dispatches before the window it measures, so a count of 1 is not the
      silence of a subscription pointed at the wrong topic.
  """
  use Platform.DataCase, async: false

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Federation
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.TaskRouter
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine

  # Fixed OBSERVATION window. "No second dispatch arrived" is an absence claim,
  # and absence is only provable against a window — there is no observable to
  # barrier on for a message that must never be sent.
  @observe_ms 1_500

  @e2e_payload %{
    "setup" => "A task sits at its task-level review gate.",
    "actions" => "Fail one behavioural check.",
    "expected" => "The task bounces to in_progress with ONE dispatch."
  }

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    # THE DEBOUNCE IS TURNED OFF, deliberately. `:dispatch` is coalesced over a
    # 50 ms window, and in-VM that window happens to be wide enough to swallow
    # the second request — so with it on, this test measures the WINDOW rather
    # than the number of things that asked for a dispatch. Two independent
    # requests separated by more than one window (a loaded box, a slow PubSub
    # hop, a longer window in config) are two dispatches; setting the window to
    # zero makes that latent second request observable instead of timing-
    # dependent.
    previous = Application.get_env(:platform, :task_router_dispatch_debounce_ms)
    Application.put_env(:platform, :task_router_dispatch_debounce_ms, 0)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:platform, :task_router_dispatch_debounce_ms)
        ms -> Application.put_env(:platform, :task_router_dispatch_debounce_ms, ms)
      end
    end)

    {:ok, project} =
      Tasks.create_project(%{
        name: "Remediation Dispatch Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/remediation-dispatch"
      })

    {agent, runtime_id} = create_linked_agent_runtime()

    %{project: project, agent: agent, runtime_id: runtime_id}
  end

  # ── Case 0: THE COUNTING CONTROL ──────────────────────────────────────

  describe "observer control" do
    test "the collector can see TWO attention broadcasts on the runtime topic", %{
      runtime_id: runtime_id
    } do
      PlatformWeb.Endpoint.subscribe(Federation.AttentionDispatch.topic(runtime_id))

      for n <- 1..2 do
        PlatformWeb.Endpoint.broadcast(
          Federation.AttentionDispatch.topic(runtime_id),
          "attention",
          %{signal: %{reason: "control-#{n}"}}
        )
      end

      assert length(collect_attention(200)) == 2,
             "observer control failed: the collector cannot see two broadcasts, " <>
               "so a count of 1 in the real case would prove nothing"
    end
  end

  # ── Case 1: THE REAL CASE ─────────────────────────────────────────────

  describe "a failed behavioural gate" do
    test "delivers EXACTLY ONE execution dispatch for the remediation stage", %{
      project: project,
      agent: agent,
      runtime_id: runtime_id
    } do
      %{task: task, gate_stage: gate_stage} = gated_task(project, agent)

      _pid = start_router!(task.id, runtime_id)

      {:ok, _running} = PlanEngine.start_stage(gate_stage.id)
      barrier(task)
      assert Tasks.get_task_record(task.id).status == "in_review"

      # Subscribe only now, then FLUSH: the `in_review` dispatch for the gate
      # stage is debounced and can land after the barrier, and counting it as
      # a remediation dispatch would make this test report a duplicate that is
      # not there. Everything counted below is filtered to `in_progress`
      # anyway — the flush just keeps the failure message honest.
      PlatformWeb.Endpoint.subscribe(Federation.AttentionDispatch.topic(runtime_id))
      flushed = collect_attention(400)

      [failing | _rest] = Tasks.list_validations(gate_stage.id)

      {:ok, _failed} =
        PlanEngine.evaluate_validation(failing.id, %{
          status: "failed",
          evaluated_by: "test",
          evidence: %{"summary" => "the behaviour did not hold"}
        })

      barrier(task)

      # EXECUTION dispatches only. The gate's own `in_review` dispatch is a
      # different signal for a different phase; folding it in would count a
      # legitimate message as a duplicate.
      dispatches =
        collect_attention()
        |> Enum.filter(&(&1.signal[:task_status] == "in_progress"))

      # GUARD, and it must fire before the count below means anything: the
      # collector is pointed at a topic the ROUTER actually broadcasts on. A
      # subscription to the wrong topic would report zero dispatches forever,
      # and `length(dispatches) == 1` would then be failing to observe rather
      # than observing one.
      refute flushed == [],
             "the collector saw no router dispatch at all before the window — " <>
               "it is not observing the runtime topic, so the count below proves nothing"

      # Guard: the remediation stage really was opened and started, so the
      # count below is a count of the dispatch for THAT stage rather than the
      # silence of a bounce that never happened.
      plan = Tasks.get_plan(Tasks.current_plan(task.id).id)

      remediation =
        Enum.filter(plan.stages, &(&1.name == PlanEngine.remediation_stage_name()))

      assert [%{status: "running"}] = remediation

      assert length(dispatches) == 1,
             "the remediation open dispatched #{length(dispatches)} times — " <>
               "each one spawns an executor on the same stage. Reasons: " <>
               inspect(Enum.map(dispatches, & &1.signal[:reason]))

      [only] = dispatches
      assert only.signal[:task_id] == task.id
      assert only.signal[:task_status] == "in_progress"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp gated_task(project, agent) do
    phase = %{"assignee_id" => agent.id, "assignee_type" => "agent"}

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Remediation dispatch task",
        status: "in_progress",
        assignee_id: agent.id,
        assignee_type: "agent",
        phase_assignees: %{"execution" => phase, "review" => phase},
        deploy_strategy: %{"type" => "manual"},
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    for {name, position} <- [{"Schema", 1}, {"Context", 2}, {"LiveView", 3}] do
      {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: position, name: name})
      {:ok, running} = Tasks.transition_stage(stage, "running")
      {:ok, _passed} = Tasks.transition_stage(running, "passed")
    end

    {:ok, gate_stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 4, name: "Task-level review"})

    {:ok, _validation} =
      Tasks.create_validation(%{
        stage_id: gate_stage.id,
        kind: "e2e_behavior",
        evaluation_payload: @e2e_payload
      })

    %{task: task, plan: plan, gate_stage: gate_stage}
  end

  defp create_linked_agent_runtime do
    user =
      Repo.insert!(%User{
        email: "remediation_dispatch_#{System.unique_integer([:positive])}@example.com",
        name: "Remediation Dispatch User",
        oidc_sub: "oidc-remediation-dispatch-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      %Agent{}
      |> Agent.changeset(%{
        slug: "remediation-dispatch-agent-#{System.unique_integer([:positive])}",
        name: "Remediation Dispatch Agent",
        status: "active"
      })
      |> Repo.insert()

    {:ok, runtime} =
      Federation.register_runtime(user.id, %{
        runtime_id: "remediation-dispatch-runtime-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, _linked} = Federation.link_agent(activated, agent)

    {agent, activated.runtime_id}
  end

  defp start_router!(task_id, runtime_id) do
    {:ok, pid} =
      TaskRouter.start_link(task_id: task_id, assignee: %{type: :federated, id: runtime_id})

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task_id) do
        [{p, _}] ->
          try do
            GenServer.stop(p, :normal, 1_000)
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
    end)

    TaskRouter.current_status(task_id)

    pid
  end

  defp barrier(task), do: TaskRouter.current_status(task.id)

  defp collect_attention(window_ms \\ @observe_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    drain(deadline, [])
  end

  # Selective receive: anything that is not an attention broadcast stays in the
  # mailbox rather than being eaten by this collector.
  defp drain(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        %Phoenix.Socket.Broadcast{event: "attention", payload: payload} ->
          drain(deadline, [payload | acc])
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end
end
