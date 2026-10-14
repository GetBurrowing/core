defmodule Platform.Orchestration.TaskRouterDesignCanvasesTest do
  @moduledoc """
  Task 01a13ae7 stage 1 — the ROUTER hands the attached canvases to
  `HeartbeatScheduler.dispatch_prompt/4`.

  The plumbing-gap shape (precedent: `dispatch_e2e_space_id_test.exs`): a
  unit test with a hand-built opts list cannot catch a router that never
  passes them. `ContextAssembler` has carried the canvases in `context` since
  task_attach_canvas stage 4, and the Claude Code bridge drops `context`, so
  the only observation that matters is the broadcast's `message.content`.

  Paired: the same router path, for a task WITHOUT an attachment, carries no
  block — and that render is shown non-empty by the same anchor.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Orchestration.LeaseManager
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Orchestration.TaskRouter
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments

  # Plain substring. Stage 4 reworded the design fidelity sections so they
  # name the block without quoting this heading; the counts below are the
  # gate's own measurement (review gate 01a13af2) on the router path.
  @heading "## Attached design canvases — the design spec"
  @ui_sentence "Before writing any code for this stage, open every canvas above with canvas_get"
  @task_anchor "Router design canvases fixture"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})
    :ok = PromptTemplates.seed_defaults()

    {:ok, project} =
      Tasks.create_project(%{
        name: "Design Canvases Router Project",
        repo_url: "https://github.com/test/design-canvases-router"
      })

    %{project: project}
  end

  test "the broadcast execution prompt carries an attached canvas", %{project: project} do
    %{task: task} = fixture = router_task(project)
    canvas = attach_canvas!(task)

    prompt = dispatch_and_capture(fixture)

    assert prompt =~ @task_anchor
    assert prompt =~ canvas.id
    assert prompt =~ @heading
    assert prompt =~ @ui_sentence
    assert prompt =~ "/canvases/" <> canvas.id
    assert length(:binary.matches(prompt, @heading)) == 1
  end

  test "without an attachment the same router path carries no block", %{project: project} do
    fixture = router_task(project)

    prompt = dispatch_and_capture(fixture)

    assert prompt =~ @task_anchor
    assert String.length(prompt) > 500
    refute prompt =~ @heading
    refute prompt =~ @ui_sentence
    # The design fidelity section that used to quote the heading is present,
    # so the zero above is measured on the text that produced the stray hit.
    assert prompt =~ "If this dispatch carries an Attached design canvases block"
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp router_task(project) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: @task_anchor,
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Build the badge",
        description: "Edit apps/platform/lib/platform_web/live/tasks_live.ex."
      })

    {:ok, stage} = Tasks.transition_stage(stage, "running")

    {:ok, _validation} =
      Tasks.create_validation(%{stage_id: stage.id, kind: "test_pass", status: "pending"})

    %{task: task, stage: stage}
  end

  defp attach_canvas!(task) do
    {:ok, space} =
      Chat.create_space(%{
        name: "Design Canvases Router Space",
        slug: "design-canvases-router-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => "Quiet reconnect"
      })

    {:ok, _} =
      CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
        attached_by: %{kind: "user", id: participant.id}
      )

    canvas
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp dispatch_and_capture(%{task: task}) do
    runtime_id = "runtime-design-canvases-#{System.unique_integer([:positive])}"
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

    :ok = PlatformWeb.Endpoint.subscribe("runtime:#{runtime_id}")
    on_exit(fn -> PlatformWeb.Endpoint.unsubscribe("runtime:#{runtime_id}") end)

    send(pid, :dispatch)
    barrier(task)

    assert_receive %Phoenix.Socket.Broadcast{
                     event: "attention",
                     payload: %{message: %{content: prompt}}
                   },
                   2_000

    prompt
  end

  # `current_status/1` is a plain `GenServer.call`, so it cannot be answered
  # until every message queued ahead of it has been handled. Not a sleep.
  defp barrier(task), do: TaskRouter.current_status(task.id)
end
