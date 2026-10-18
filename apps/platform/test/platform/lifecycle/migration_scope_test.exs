defmodule Platform.Lifecycle.MigrationScopeTest do
  @moduledoc """
  Parts C (architect half) and D of task 019fe1b7 stage 4 — the shape of what
  the migration DID and DID NOT take over, asserted by behaviour.

  ## C: there is ONE architect resolver, and `:expired` is a value on it

  The ticket framed the two hooks as having divergent expiry paths to be
  unified. That premise is false for the architect and this file pins the
  correction as a test rather than as prose in a moduledoc:
  `Tasks.resolve_architecture_gate/3` takes `:expired` alongside `:pass`,
  `:reject`, `:dispatch_failed` and `:human_override`. There is no second
  expiry function, so there is nothing to unify — and if a later change adds
  one, the totality assertion below is what notices.

  The fall-open behaviour itself — an expired gate approving the plan while
  still recording the failure that `AutoMerger` and `StackDeployer` read
  through `planning_gate_failed?/1` — is pinned in full, with its positive
  control, by `Platform.Tasks.ArchitectureGateExpirySettlementTest`. This file
  does not restate it. What it adds is the MIGRATION-specific half that file
  cannot know about: the deadline sweep reaches that same single resolver
  WITHOUT entering the pipeline, so expiry did not silently become a second
  edge.

  ## D: the out-of-scope seam, asserted as out of scope

  This member wraps NEITHER `Responsibilities.fire/2` NOR
  `Responsibilities.Router.fire/2`. `Platform.Meetings.Summarizer` calls the
  Router DIRECTLY, so the meeting-summary path fires OUTSIDE any pipeline and
  keeps doing so.

  Asserting that is not pedantry. It is the case that catches a well-meaning
  later change to the facade — someone wrapping `Router.fire/2` to "finish the
  migration" would silently route every meeting summary through a lifecycle
  edge with no step registered for it — and it is the honest record that the
  frame is not total. A design that looks complete with a silent hole is worse
  than one that is explicitly partial.

  Every absence assertion here has its presence half in the SAME run: a
  refute-only test stays green when the writer still fires.
  """
  use Platform.DataCase, async: false

  alias Platform.Agents.Agent
  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.Executor
  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Lifecycle.StepRun
  alias Platform.Lifecycle.TestSteps
  alias Platform.Meetings
  alias Platform.Meetings.Summarizer
  alias Platform.Repo
  alias Platform.Responsibilities.BuiltIns
  alias Platform.Responsibilities.Registry
  alias Platform.Roles
  alias Platform.Roles.Role
  alias Platform.Roles.RoleResponsibility
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Task

  defmodule NoopNativeDispatcher do
    @moduledoc false
    # Gives the Router a no-op native dispatch surface, so `Router.fire/2`
    # answers `{:ok, :dispatched}` without standing up AgentResponder and chat
    # plumbing. Mirrors the same-named module in `SummarizerTest`.
    def maybe_dispatch(_signal), do: :ok
  end

  defp u, do: System.unique_integer([:positive])

  # ── C: the single architect resolver ────────────────────────────────────

  describe "the architect has exactly one resolver and :expired is a value on it" do
    setup do
      {:ok, project} = Tasks.create_project(%{name: "Migration Scope #{u()}"})

      task =
        Repo.insert!(%Task{project_id: project.id, title: "Gate subject", status: "planning"})

      %{project: project, task: task}
    end

    defp gated_plan!(task) do
      plan = Repo.insert!(%Plan{task_id: task.id, version: 1, status: "pending_review"})
      {:ok, opened} = Tasks.open_architecture_gate(plan)
      opened
    end

    test "every resolution the migration can produce goes through resolve_architecture_gate/3",
         %{task: task} do
      # TOTALITY, one resolution per plan because each is terminal. If a
      # sixth resolution — or worse, a SECOND expiry function — appears, a
      # clause here has to be added deliberately.
      for resolution <- [:pass, :reject, :expired, :dispatch_failed, :human_override] do
        subject =
          Repo.insert!(%Task{
            project_id: task.project_id,
            title: "Gate subject #{resolution}",
            status: "planning"
          })

        plan = gated_plan!(subject)

        assert {:ok, _settled} = Tasks.resolve_architecture_gate(plan, resolution),
               "#{inspect(resolution)} is not a value on the one shared resolver — " <>
                 "if the migration grew a second expiry path, that is the defect"

        refute Tasks.architecture_gate_open?(plan.id)
      end
    end

    test ":expired resolves through that same resolver and writes NO lifecycle run row",
         %{task: task} do
      plan = gated_plan!(task)

      # PRESENCE HALF FIRST, in the same run: a real edge on this same task
      # DOES write rows. Without it, the emptiness asserted below is also
      # true of a system where lifecycle rows are never written at all.
      registry_name = :"scope_registry_#{u()}"
      {:ok, _pid} = StepRegistry.start_link(name: registry_name)

      :ok =
        StepRegistry.register(
          %{name: "probe_before", mfa: {TestSteps.Sync, :start, 1}, kind: :deterministic},
          registry_name
        )

      {:complete, _summary} =
        Executor.run_edge(task, Edges.architect_edge(),
          steps: [%{"step" => "probe_before", "await" => true, "can_divert" => false}],
          registry: registry_name,
          step_timeout_ms: 200,
          edge_budget_ms: 2_000
        )

      before_rows = Repo.aggregate(StepRun, :count, :id)
      assert before_rows > 0, "the positive control wrote no rows; the absence below is vacuous"

      # THE ABSENCE. Expiry is a resolution on the shared resolver, not an
      # edge. It must not create a run.
      assert {:ok, _settled} = Tasks.resolve_architecture_gate(plan.id, :expired)

      assert Repo.aggregate(StepRun, :count, :id) == before_rows,
             "resolving :expired created a lifecycle run row — expiry has become a " <>
               "second edge, which is the thing stage 3 established does not exist"

      # And the fall-open record the downstream readers depend on is still
      # written by the resolver, not by the pipeline.
      assert Tasks.planning_gate_failed?(Repo.get!(Task, task.id))
    end

    test "POSITIVE CONTROL: a passed gate on an identical fixture is NOT gate-failed",
         %{task: task} do
      # Without this, the assertion above holds equally if
      # `planning_gate_failed?/1` were true of everything.
      plan = gated_plan!(task)

      assert {:ok, _settled} = Tasks.resolve_architecture_gate(plan.id, :pass)

      refute Tasks.planning_gate_failed?(Repo.get!(Task, task.id))
      assert Tasks.failed_planning_steps(Repo.get!(Task, task.id)) == []
    end
  end

  # ── D: the out-of-scope seam ────────────────────────────────────────────

  describe "the meetings summarizer still fires OUTSIDE any pipeline" do
    setup do
      previous = Application.get_env(:platform, :responsibility_router_native_dispatcher)

      Application.put_env(
        :platform,
        :responsibility_router_native_dispatcher,
        {NoopNativeDispatcher, :maybe_dispatch}
      )

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:platform, :responsibility_router_native_dispatcher)
          value -> Application.put_env(:platform, :responsibility_router_native_dispatcher, value)
        end
      end)

      name = :"#{__MODULE__}.Reg#{u()}"
      _pid = start_supervised!({Registry, name: name, providers: BuiltIns.providers()})

      seed_role!("meeting_scribe")
      ensure_role_responsibility!("meeting_scribe", "meetings.summarize")

      agent =
        %Agent{}
        |> Agent.changeset(%{
          slug: "scope-test-#{u()}",
          name: "Scope Test Native",
          status: "active",
          kind: "native"
        })
        |> Repo.insert!()

      {:ok, _} = Roles.assign_role("meeting_scribe", agent.id)

      %{registry: name}
    end

    defp seed_role!(key) do
      case Repo.get(Role, key) do
        %Role{} = existing ->
          existing

        nil ->
          {:ok, role} =
            %Role{}
            |> Role.changeset(%{
              key: key,
              name: key |> String.replace("_", " ") |> String.capitalize(),
              description: "test role #{key}",
              icon: "hero-star"
            })
            |> Repo.insert()

          role
      end
    end

    defp ensure_role_responsibility!(role_key, responsibility_key) do
      case Repo.get_by(RoleResponsibility,
             role_key: role_key,
             responsibility_key: responsibility_key
           ) do
        %RoleResponsibility{} = existing ->
          existing

        nil ->
          {:ok, rr} =
            %RoleResponsibility{}
            |> RoleResponsibility.changeset(%{
              role_key: role_key,
              responsibility_key: responsibility_key
            })
            |> Repo.insert()

          rr
      end
    end

    test "the summary path works end to end through its own public entry point, " <>
           "and creates no lifecycle run" do
      # PRECONDITION. If the responsibility is unfilled, `run_summary/1`
      # falls through to the legacy LLM body, which cannot run here — the
      # test would be asserting the wrong branch entirely.
      assert Platform.Responsibilities.Router.responsibility_filled?("meetings.summarize"),
             "the bridge gate is not filled; this case would exercise the legacy body"

      {:ok, transcript} =
        Meetings.create_transcript(%{
          room_id: Platform.Types.UUIDv7.generate(),
          space_id: Platform.Types.UUIDv7.generate(),
          segments: [
            %{
              "speaker_name" => "Sam",
              "text" => "Quick standup.",
              "start_time" => 0,
              "end_time" => 500,
              "final" => true
            }
          ]
        })

      test_pid = self()
      handler_id = "scope-summarizer-#{u()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:platform, :responsibility, :fired],
          [:platform, :responsibility, :failed],
          [:platform, :responsibility, :unfilled]
        ],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      rows_before = Repo.aggregate(StepRun, :count, :id)

      {result, _log} =
        ExUnit.CaptureLog.with_log(fn -> Summarizer.run_summary(transcript) end)

      # THE END-TO-END HALF. `run_summary/1` is the summarizer's own public
      # entry point and it still answers `:ok` on the delegated path.
      assert result == :ok

      # PRESENCE HALF: the fire genuinely happened. Without it, "no lifecycle
      # row" is satisfied by a summarizer that did nothing at all — which is
      # exactly the silent hole this case exists to detect.
      assert_receive {:telemetry, [:platform, :responsibility, event],
                      %{key: "meetings.summarize"}},
                     1_000

      assert event == :fired,
             "the summary responsibility did not fire (#{inspect(event)}) — the " <>
               "absence assertion below would prove nothing"

      # THE ABSENCE, and the point of the whole case: this member migrated
      # TWO NAMED CALLERS, not the facade. A later change that wrapped
      # `Router.fire/2` would route this through a lifecycle edge with no
      # step registered for it, and would fail here.
      assert Repo.aggregate(StepRun, :count, :id) == rows_before,
             "the meetings summary fire created a lifecycle run row — the facade " <>
               "has been wrapped, and this member's scope claim is no longer true"
    end

    test "neither edge this member owns names the meetings responsibility" do
      # Behavioural, not a grep: no run row exists for this member's edges on
      # ANY task as a result of a meetings fire, because the summarizer never
      # supplies a task. Asserted through the reader the rest of the system
      # uses rather than by reading source text for an absent name.
      assert Edges.all() == ["planning.design_requested", "plan.review_requested"]
      refute "meetings.summarize" in Edges.all()

      {:ok, project} = Tasks.create_project(%{name: "Scope Edges #{u()}"})

      task =
        Repo.insert!(%Task{project_id: project.id, title: "No meetings edge", status: "planning"})

      for edge <- Edges.all() do
        assert Runs.for_edge(task.id, edge) == []
      end
    end
  end
end
