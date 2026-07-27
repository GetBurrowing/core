defmodule Platform.Orchestration.DispatchE2eSpaceIdTest do
  @moduledoc """
  Stage 3 of task `019fa469` — DEFECT 2: the `dispatch.review_e2e` render emitted
  `Execution space:` with nothing after it, and later
  `...post that into the execution space ()`. Observed on task
  `019f9b29-251e-7ef4-a75d-acd42524687f` stage 5.

  ## Root — a plumbing gap, not a selection bug

  `e2e_review_assigns/2` resolved the assign with
  `task_field(task, :execution_space_id) || ""`. There is no `execution_space_id`
  FIELD on the task schema: it lives on the router's `%State{}`
  (`task_router.ex:89`) and never entered `dispatch_prompt/4`. So the accessor
  returned `nil` on every production call and the `|| ""` laundered a missing
  REQUIRED assign into an empty string. It only ever surfaced on this one
  template because `dispatch.review_e2e` is the only slug that interpolates
  `{{execution_space_id}}` (`prompt_templates.ex:745`, `:794`).

  It stayed invisible in tests because the existing unit tests
  (`heartbeat_scheduler_test.exs:918`, `:977`) hand `select_review_template/2` a
  plain MAP that happens to carry an `execution_space_id` key — a shape the real
  `%Task{}` never has. The accessor is correct for the fixture and wrong for
  production.

  Why it matters beyond tidiness: on a FAILED e2e verdict the reviewer's own
  observation IS the failure feedback, and the template instructs it to post that
  observation into a space it was never given. The one output that matters had
  nowhere to go.

  ## Loud, via telemetry — not `Logger`

  `config/test.exs` sets `config :logger, level: :warning`, so a `Logger.info`
  assertion goes silently vacuous under `CaptureLog` (documented at
  `task_router_dispatch_suppression_test.exs:22-24`). The unresolved-assign
  signal is therefore a telemetry event,
  `[:platform, :orchestration, :dispatch_assign_missing]`, which the test
  observes directly. The accompanying `Logger.error` is for the operator; it is
  not the pin.

  ## Anti-vacuity

  Every negative here is paired with a positive in the same test:

    * "the space id is present" is trivially satisfiable by a render that errored
      into an empty string, so each render assertion is pinned with the
      `Task is in behavioral review` anchor and a `String.length/1` floor.
    * the telemetry test has a NEGATIVE CONTROL — a resolvable dispatch must NOT
      emit the event — so a handler that fires unconditionally fails.

  ## What is NOT pinned, and why

  The router's `execution_space_id: state.execution_space_id` opt is the PRIMARY
  path (it saves a DB query per e2e dispatch), but the last-resort
  `ExecutionSpace.find_by_task_id/1` lookup resolves to the exact same row, so no
  router-level assertion can distinguish the two. The opt's precedence is pinned
  at the unit level instead ("opts win over a live execution-space row"); the
  router test pins the end-to-end symptom the incident actually showed.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks

  @forced_slugs ~w(dispatch.review_e2e)

  @e2e_anchor "Task is in behavioral review"
  @empty_parens_artifact "execution space ()"
  @missing_assign_event [:platform, :orchestration, :dispatch_assign_missing]

  @e2e_payload %{
    "setup" => "Boot a dev BEAM from the task worktree.",
    "actions" => "Render the dispatch and read the Execution space line.",
    "expected" => "The line carries a uuid."
  }

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    :ok = PromptTemplates.seed_defaults()

    # `seed_defaults/0` is skip-if-exists, so a stale row would make every
    # assertion below test yesterday's copy.
    for slug <- @forced_slugs do
      template = PromptTemplates.get_template_by_slug(slug)
      refute is_nil(template), "expected #{slug} to be seeded"

      {:ok, _} =
        PromptTemplates.update_template(template, %{
          content: PromptTemplates.default_content_for_slug(slug)
        })
    end

    {:ok, project} =
      Tasks.create_project(%{
        name: "E2E Space Id Project",
        repo_url: "https://github.com/test/e2e-space-id"
      })

    %{project: project}
  end

  describe "execution_space_id threading" do
    test "an execution_space_id passed in opts reaches the rendered review_e2e prompt" do
      space_id = "019fa469-0000-7000-8000-0000000005ce"

      output =
        HeartbeatScheduler.dispatch_prompt(bare_task(), plan(), e2e_stage(),
          execution_space_id: space_id
        )

      assert output =~ "Execution space: " <> space_id,
             "the router-supplied space id must reach the render"

      assert output =~ "execution space (#{space_id})",
             "the failure-feedback sentence must name the space the reviewer posts into"

      refute output =~ @empty_parens_artifact,
             "the empty-parens artifact from the incident must not appear"

      # Anti-vacuity: an errored/empty render would satisfy the refute above.
      assert output =~ @e2e_anchor
      assert String.length(output) > 200
    end

    test "with no opts and no execution space anywhere, the render still happens and the missing assign is loud" do
      handler = attach_missing_assign_handler!()

      log =
        capture_log(fn ->
          output = HeartbeatScheduler.dispatch_prompt(bare_task(), plan(), e2e_stage())

          # Degraded, not blocked — a prompt with a hole beats no dispatch.
          assert output =~ @e2e_anchor
          assert String.length(output) > 200
        end)

      assert_received {:dispatch_assign_missing, ^handler, measurements, metadata}

      assert measurements.count == 1
      assert metadata.slug == "dispatch.review_e2e"
      assert metadata.assign == :execution_space_id
      assert metadata.task_id == bare_task().id

      # Secondary, not the pin: `Logger.error` clears the :warning floor that
      # makes `Logger.info` assertions vacuous in this env.
      assert log =~ "execution_space_id"
    end

    test "NEGATIVE CONTROL — a resolvable dispatch emits no missing-assign event" do
      handler = attach_missing_assign_handler!()

      output =
        HeartbeatScheduler.dispatch_prompt(bare_task(), plan(), e2e_stage(),
          execution_space_id: "019fa469-0000-7000-8000-0000000005cf"
        )

      assert output =~ @e2e_anchor

      refute_received {:dispatch_assign_missing, ^handler, _measurements, _metadata}
    end

    test "an empty-string opt is treated as missing, not as a resolved value" do
      handler = attach_missing_assign_handler!()

      capture_log(fn ->
        HeartbeatScheduler.dispatch_prompt(bare_task(), plan(), e2e_stage(),
          execution_space_id: ""
        )
      end)

      assert_received {:dispatch_assign_missing, ^handler, _measurements, _metadata},
                      "`|| \"\"` is exactly how this defect hid — a blank must not count as resolved"
    end
  end

  describe "last-resort DB lookup for direct callers that never went through the router" do
    test "resolves the space from ExecutionSpace when opts and the task carry nothing", %{
      project: project
    } do
      task = persisted_task(project)
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      handler = attach_missing_assign_handler!()

      output = HeartbeatScheduler.dispatch_prompt(task, plan(), e2e_stage())

      assert output =~ "Execution space: " <> space.id
      refute output =~ @empty_parens_artifact
      assert output =~ @e2e_anchor
      assert String.length(output) > 200

      refute_received {:dispatch_assign_missing, ^handler, _m, _md}
    end

    test "opts win over a live execution-space row", %{project: project} do
      task = persisted_task(project)
      {:ok, space} = ExecutionSpace.find_or_create(task.id)
      override = "019fa469-0000-7000-8000-0000000005d0"

      output =
        HeartbeatScheduler.dispatch_prompt(task, plan(), e2e_stage(),
          execution_space_id: override
        )

      assert output =~ "Execution space: " <> override
      refute output =~ space.id
      assert output =~ @e2e_anchor
    end
  end

  describe "the router hands its own execution space to the dispatch" do
    test "the broadcast e2e prompt carries the router's execution space id", %{project: project} do
      %{task: task} = fixture = e2e_router_task(project)
      {:ok, space} = ExecutionSpace.find_or_create(task.id)

      %{pid: pid, runtime_id: runtime_id} = start_router!(fixture)
      :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
      on_exit(fn -> PlatformWeb.Endpoint.unsubscribe("runtime:#{runtime_id}") end)

      send(pid, :dispatch)
      barrier(task)

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "attention",
                       payload: %{message: %{content: prompt}}
                     },
                     2_000

      assert prompt =~ @e2e_anchor,
             "the running stage's pending e2e_behavior must select the behavioral template"

      assert prompt =~ "Execution space: " <> space.id
      refute prompt =~ @empty_parens_artifact
      assert String.length(prompt) > 200
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp project_attrs,
    do: %{repo_url: "https://github.com/test/e2e-space-id", default_branch: "main"}

  defp plan, do: %{version: 1, stages: [%{}, %{}]}

  # A plain-map task with NO execution_space_id key — the production shape.
  # `%Task{}` has no such field, which is the whole defect.
  defp bare_task do
    %{
      id: "019fa469-0000-7000-8000-0000000005c0",
      title: "Behavioral review dispatch",
      description: "Run the planner-authored e2e script.",
      status: "in_review",
      priority: "high",
      project: project_attrs()
    }
  end

  defp persisted_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Persisted behavioral review",
        status: "in_progress"
      })

    Tasks.get_task_detail(task.id)
  end

  defp e2e_stage do
    %{
      id: "019fa469-0000-7000-8000-0000000005c1",
      position: 2,
      name: "Task-level review",
      status: "running",
      validations: [
        %{
          id: "019fa469-0000-7000-8000-0000000005c2",
          kind: "e2e_behavior",
          status: "pending",
          evaluation_payload: @e2e_payload
        }
      ]
    }
  end

  defp e2e_router_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Router e2e dispatch",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Task-level review"})

    {:ok, stage} = Tasks.transition_stage(stage, "running")

    {:ok, _validation} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "e2e_behavior",
        status: "pending",
        evaluation_payload: @e2e_payload
      })

    {:ok, task} = Tasks.transition_task(task, "in_review")

    %{task: task, stage: stage}
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp attach_missing_assign_handler! do
    handler_id = "dispatch-assign-missing-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @missing_assign_event,
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:dispatch_assign_missing, handler_id, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  defp start_router!(%{task: task}) do
    runtime_id = "runtime-e2e-space-#{System.unique_integer([:positive])}"
    assignee = %{type: :federated, id: runtime_id}
    {:ok, pid} = TaskRouter.start_link(task_id: task.id, assignee: assignee)

    on_exit(fn ->
      case Registry.lookup(Platform.Orchestration.Registry, task.id) do
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
        _ -> LeaseManager.clear(task.id)
      end
    end)

    # Drain the boot dispatch so the assertion observes the one we inject.
    barrier(task)

    %{pid: pid, runtime_id: runtime_id}
  end

  # `current_status/1` is a plain `GenServer.call`, so it cannot be answered
  # until every message queued ahead of it has been handled. Not a sleep.
  defp barrier(task), do: TaskRouter.current_status(task.id)
end
