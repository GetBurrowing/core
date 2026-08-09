defmodule Platform.Lifecycle.CompletionWebhookTest do
  @moduledoc """
  The completion-webhook NOTIFY, exercised through `Platform.Tasks.transition_task/2`
  (task 019fe1b7 stage 4).

  ## Two resolution paths, and both are exercised on purpose

  **A test that supplies its own configuration cannot test the shipped
  configuration.** So the declaration cases go through
  `Platform.Lifecycle.resolve_steps/2` against a project row with NO pipeline
  — the shipped `Edges.default_steps/1` path, exactly as production resolves
  it — and the posting cases configure a project pipeline, because the URL is
  per-project configuration and there is no shipped default for it.

  Both run against the SHIPPED registry (the one `test_helper.exs` starts):
  nothing here points `:lifecycle_step_registry` at a private instance, since
  the whole subject is a shipped allowlist entry.

  ## Public repo: `example.com` and nothing else

  Every URL in this file is on `example.com`, and the host allowlist is
  injected per case. No real hostname appears here, in the step, or in its
  configuration — the shipped `@allowed_webhook_hosts` is empty and
  fail-closed.
  """

  use Platform.DataCase, async: false

  alias Platform.Lifecycle
  alias Platform.Lifecycle.EdgeInventory
  alias Platform.Lifecycle.Edges
  alias Platform.Lifecycle.PipelineConfig
  alias Platform.Lifecycle.Runs
  alias Platform.Lifecycle.StepRegistry
  alias Platform.Lifecycle.Steps.CompletionWebhook
  alias Platform.Tasks

  @cleanup_step "worktree_cleanup"
  @webhook_step "completion_webhook"
  @endpoint_url "https://hooks.example.com/task-completed"

  setup do
    previous_hosts = Application.get_env(:platform, :lifecycle_allowed_webhook_hosts)
    previous_client = Application.get_env(:platform, :completion_webhook_req_client)

    Application.put_env(:platform, :lifecycle_allowed_webhook_hosts, ["hooks.example.com"])

    Application.put_env(
      :platform,
      :completion_webhook_req_client,
      Req.new(plug: {Req.Test, :completion_webhook_test})
    )

    # The notify is a `:sync` step: the POST happens INLINE in this process
    # during `transition_task/2`, so the stub's default owner is the right
    # one and no ownership handoff is needed.

    on_exit(fn ->
      restore(:lifecycle_allowed_webhook_hosts, previous_hosts)
      restore(:completion_webhook_req_client, previous_client)
    end)

    :ok
  end

  describe "the edge set: `->done` only, and NOT `->cancelled`" do
    test "completion edges are the inbound edges to done, derived and sorted" do
      # Explicit sorted list, not set membership. If the transition table
      # widens, this is what has to change — deliberately.
      assert EdgeInventory.completion_edges() == [
               "deploying->done",
               "in_progress->done",
               "in_review->done"
             ]
    end

    test "THE DECISION: the notify is NOT declared on the ->cancelled edges" do
      # Stage 3's effect hangs on the WIDER `terminal_edges/0`. Inheriting
      # that set here would announce completion for an abandoned task. This
      # asserts the divergence rather than the narrow set alone, because
      # asserting only "the ->done edges carry it" passes on an
      # implementation that reused `terminal_edges/0` and also fires on
      # cancellation.
      cancelled_edges = EdgeInventory.terminal_edges() -- EdgeInventory.completion_edges()

      assert cancelled_edges == [
               "backlog->cancelled",
               "blocked->cancelled",
               "in_progress->cancelled",
               "planning->cancelled",
               "stack_pending->cancelled"
             ]

      for edge <- cancelled_edges do
        steps = Edges.default_steps(edge)

        assert steps == [%{"step" => @cleanup_step, "await" => false, "can_divert" => false}],
               "cancellation edge #{edge} must carry the cleanup effect and NOT the notify"

        refute @webhook_step in Enum.map(steps, &Map.get(&1, "step"))
      end
    end

    test "each ->done edge declares [cleanup, webhook] in that ORDER" do
      for edge <- EdgeInventory.completion_edges() do
        # An explicit ordered list, never set membership: order is the
        # pipeline's semantics.
        assert Edges.default_steps(edge) == [
                 %{"step" => @cleanup_step, "await" => false, "can_divert" => false},
                 %{"step" => @webhook_step, "await" => false, "can_divert" => false}
               ],
               "completion edge #{edge} ships the wrong declaration"
      end
    end

    test "THE STACK-MEMBER PATH: in_review->done carries it without touching deploying" do
      assert "in_review->done" in EdgeInventory.completion_edges()
      assert "in_progress->done" in EdgeInventory.completion_edges()

      # CONTROL: a non-terminal edge ships nothing, so the declaration
      # discriminates by completion rather than applying everywhere.
      assert Edges.default_steps("in_progress->in_review") == []
    end

    test "an unconfigured project RESOLVES the notify through the shipped path" do
      # The resolver, not the declaration. `default_steps/1` was unreachable
      # from any shipped path before stage 3 wired this fallback, so the
      # declaration passing tells you nothing on its own.
      project = project_fixture()

      assert Lifecycle.resolve_steps(project, "in_review->done") == [
               %{"step" => @cleanup_step, "await" => false, "can_divert" => false},
               %{"step" => @webhook_step, "await" => false, "can_divert" => false}
             ]
    end
  end

  describe "a task reaching done WITH a webhook configured" do
    test "POSTs ONCE with the EXACT payload and records `completed`" do
      %{task: task} = fixture(pipeline: pipeline_for("in_review->done"))
      parent = self()

      Req.Test.stub(:completion_webhook_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:webhook, conn.method, conn.request_path, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      task = walk_to_in_review(task)
      assert {:ok, %{status: "done"} = done} = Tasks.transition_task(task, "done")

      assert_receive {:webhook, "POST", "/task-completed", body}

      # EXACT map comparison. A subset check cannot detect a field added
      # later — including one carrying a runtime id or a worktree path,
      # which is the failure mode this pin exists for.
      assert body == %{
               "task_id" => done.id,
               "project_id" => done.project_id,
               "status" => "done",
               "edge" => "in_review->done"
             }

      # ...and the shipped builder produces exactly that, so the pin is on
      # the code rather than on a copy of it written here.
      assert CompletionWebhook.payload(done, "in_review->done") == body

      # ONCE. A second delivery would show up as a second message.
      refute_receive {:webhook, _method, _path, _body}, 50

      assert step_runs(done.id, "in_review->done") == [
               {@cleanup_step, "completed"},
               {@webhook_step, "completed"}
             ]
    end

    test "the payload's `edge` DISCRIMINATES two paths that share `status: done`" do
      # The reason `edge` is in the payload at all. Both tasks below end
      # `status: "done"` and are otherwise indistinguishable to a consumer;
      # only `edge` says which terminal path was taken.
      #
      # `deploying->done` is deliberately NOT the contrast here:
      # `in_review -> deploying` fails with `:no_deploy_target_resolved`
      # unless a deploy target is resolvable, so a test reaching it would be
      # testing the deploy-target resolver. `in_progress->done` vs
      # `in_review->done` discriminates the same property with no such
      # entanglement — and `in_review->done` is the ADR-0041 stack-member
      # path, which is the one a deploy-edge-only implementation misses.
      %{task: via_review} = fixture(pipeline: pipeline_for("in_review->done"))
      %{task: via_progress} = fixture(pipeline: pipeline_for("in_progress->done"))
      parent = self()

      Req.Test.stub(:completion_webhook_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        send(parent, {:webhook_edge, decoded["task_id"], decoded["status"], decoded["edge"]})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      via_review = walk_to_in_review(via_review)
      assert {:ok, %{status: "done"}} = Tasks.transition_task(via_review, "done")
      assert_receive {:webhook_edge, review_id, "done", "in_review->done"}

      via_progress = walk_to_in_progress(via_progress)
      assert {:ok, %{status: "done"}} = Tasks.transition_task(via_progress, "done")
      assert_receive {:webhook_edge, progress_id, "done", "in_progress->done"}

      refute review_id == progress_id
    end
  end

  describe "a notify that fails does NOT block the transition" do
    test "a non-2xx response: task is still done AND a `failed` run row exists" do
      %{task: task} = fixture(pipeline: pipeline_for("in_review->done"))
      parent = self()

      Req.Test.stub(:completion_webhook_test, fn conn ->
        send(parent, :webhook_attempted)
        Plug.Conn.send_resp(conn, 500, "nope")
      end)

      task = walk_to_in_review(task)

      # BOTH HALVES. "the task reached done" alone passes against an
      # implementation that never fires the webhook at all.
      assert {:ok, %{status: "done"} = done} = Tasks.transition_task(task, "done")
      assert_receive :webhook_attempted

      assert step_runs(done.id, "in_review->done") == [
               {@cleanup_step, "completed"},
               {@webhook_step, "failed"}
             ]

      # Not rolled back: the row in the database says `done`, not just the
      # struct this process is holding.
      # `Repo.get!` deliberately: `Tasks.get_task/1` is the artifacts-summary
      # reader and returns a different shape entirely.
      assert Platform.Repo.get!(Platform.Tasks.Task, done.id).status == "done"

      assert failure_reason(done.id) =~ "webhook_rejected"
    end

    test "a transport error: task is still done AND a `failed` run row exists" do
      %{task: task} = fixture(pipeline: pipeline_for("in_review->done"))
      parent = self()

      Req.Test.stub(:completion_webhook_test, fn conn ->
        send(parent, :webhook_attempted)
        Req.Test.transport_error(conn, :econnrefused)
      end)

      task = walk_to_in_review(task)

      assert {:ok, %{status: "done"} = done} = Tasks.transition_task(task, "done")
      assert_receive :webhook_attempted

      assert step_runs(done.id, "in_review->done") == [
               {@cleanup_step, "completed"},
               {@webhook_step, "failed"}
             ]

      # `Repo.get!` deliberately: `Tasks.get_task/1` is the artifacts-summary
      # reader and returns a different shape entirely.
      assert Platform.Repo.get!(Platform.Tasks.Task, done.id).status == "done"
      assert failure_reason(done.id) =~ "webhook_transport_error"
    end
  end

  describe "no webhook configured" do
    test "NOTHING is posted — with a positive control in the same run" do
      # The negative alone is satisfied by an implementation that never
      # posts anything, so a configured task runs in the SAME test and must
      # post. One stub serves both.
      %{task: unconfigured} = fixture()
      %{task: configured} = fixture(pipeline: pipeline_for("in_review->done"))
      parent = self()

      Req.Test.stub(:completion_webhook_test, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:posted, Jason.decode!(body)["task_id"]})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      unconfigured = walk_to_in_review(unconfigured)
      assert {:ok, %{status: "done"} = unconfigured} = Tasks.transition_task(unconfigured, "done")

      refute_receive {:posted, _task_id}, 50

      # The step nonetheless RAN and completed — `completed`, not
      # `not_applicable`: the pipeline is not empty, there is simply no URL.
      assert step_runs(unconfigured.id, "in_review->done") == [
               {@cleanup_step, "completed"},
               {@webhook_step, "completed"}
             ]

      # POSITIVE CONTROL, same stub, same run.
      configured = walk_to_in_review(configured)
      assert {:ok, %{status: "done"} = configured} = Tasks.transition_task(configured, "done")

      assert_receive {:posted, posted_id}
      assert posted_id == configured.id
      refute posted_id == unconfigured.id
    end
  end

  describe "a notify CANNOT GATE — rejected at config load" do
    test "the hazard is real: the same flags on a non-notify step LOAD and gate" do
      # Anti-vacuity. Before asserting the refusal, prove the declaration
      # shape being refused is one the system otherwise HONOURS — otherwise
      # the rejection is true by construction and would pass against an
      # implementation that rejects `await: true` everywhere, or one where
      # the flags mean nothing at all.
      gate_shaped = %{"step" => @cleanup_step, "await" => true, "can_divert" => true}

      assert PipelineConfig.check(%{"in_review->done" => [gate_shaped]}) == :ok

      # And the flags are load-bearing, not decorative: the executor reads
      # divert authority from exactly this declaration.
      assert Platform.Lifecycle.Executor.run_edge(
               fixture().task,
               "in_review->done",
               steps: [%{"step" => "s_divert", "await" => true, "can_divert" => true}],
               registry: diverting_registry(),
               step_timeout_ms: 500,
               edge_budget_ms: 2_000
             )
             |> elem(0) == :diverted
    end

    test "the SAME flags on the notify are REJECTED, each flag independently" do
      for flags <- [
            %{"await" => true, "can_divert" => false},
            %{"await" => false, "can_divert" => true},
            %{"await" => true, "can_divert" => true}
          ] do
        step = Map.merge(%{"step" => @webhook_step, "url" => @endpoint_url}, flags)

        # STRUCTURED term, not a message substring: a substring assertion
        # cannot tell this rejection from the `backlog.created` gate
        # prohibition, whose message contains many of the same words.
        assert PipelineConfig.check(%{"in_review->done" => [step]}) ==
                 {:error, {:notify_cannot_gate, @webhook_step}},
               "notify accepted a gate-shaped declaration: #{inspect(flags)}"
      end
    end

    test "the notify LOADS when both flags are false — the rule is not a blanket ban" do
      assert PipelineConfig.check(%{"in_review->done" => [webhook_step()]}) == :ok
    end

    test "the SHIPPED declaration satisfies the rule rather than being exempt from it" do
      for edge <- EdgeInventory.completion_edges() do
        assert PipelineConfig.check(%{edge => Edges.default_steps(edge)}) == :ok
      end
    end

    test "notify-ness comes from the registry entry, not the name or the position" do
      assert StepRegistry.notify_step?(@webhook_step)
      refute StepRegistry.notify_step?(@cleanup_step)
      refute StepRegistry.notify_step?("no_such_step")

      # Position-independent: the same declaration at index 1 is refused too.
      gate_shaped = Map.put(webhook_step(), "await", true)

      assert PipelineConfig.check(%{
               "in_review->done" => [
                 %{"step" => @cleanup_step, "await" => false, "can_divert" => false},
                 gate_shaped
               ]
             }) == {:error, {:notify_cannot_gate, @webhook_step}}
    end
  end

  describe "the endpoint host is allowlisted, fail-closed" do
    test "a host outside the runtime allowlist is refused at config load" do
      # POSITIVE CONTROL first: the allowlisted host loads.
      assert PipelineConfig.check(%{"in_review->done" => [webhook_step()]}) == :ok

      other = Map.put(webhook_step(), "url", "https://elsewhere.example.com/hook")
      assert {:error, message} = PipelineConfig.check(%{"in_review->done" => [other]})
      assert message =~ "not allowlisted"
    end

    test "the SHIPPED allowlist is empty — no real host is compiled into this repo" do
      assert StepRegistry.default_allowed_webhook_hosts() == []
    end
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp webhook_step do
    %{"step" => @webhook_step, "await" => false, "can_divert" => false, "url" => @endpoint_url}
  end

  defp pipeline_for(edge) do
    # A configured project replaces the shipped default wholesale, so a
    # project that wants both must declare both. Declared in the shipped
    # order.
    %{
      edge => [
        %{"step" => @cleanup_step, "await" => false, "can_divert" => false},
        webhook_step()
      ]
    }
  end

  defp project_fixture(pipeline \\ nil) do
    config = if pipeline, do: %{Lifecycle.config_key() => pipeline}, else: %{}

    {:ok, project} =
      Tasks.create_project(%{
        name: "Completion Webhook Project #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/test/completion-webhook",
        tech_stack: %{"language" => "elixir"},
        deploy_config: %{"target" => "production"},
        config: config
      })

    project
  end

  defp fixture(opts \\ []) do
    project = project_fixture(Keyword.get(opts, :pipeline))

    {:ok, task} = Tasks.create_task(%{project_id: project.id, title: "Completion Webhook Task"})

    %{project: project, task: task}
  end

  # `in_progress` is behind the approved-plan gate; seed a plan rather than
  # route around it, so this walks the real path.
  defp walk_to_in_progress(task) do
    {:ok, _plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    {:ok, task} = Tasks.transition_task(task, "planning")
    {:ok, task} = Tasks.transition_task(task, "in_progress")
    task
  end

  defp walk_to_in_review(task) do
    {:ok, task} = task |> walk_to_in_progress() |> Tasks.transition_task("in_review")
    task
  end

  defp step_runs(task_id, edge) do
    task_id |> Runs.for_edge(edge) |> Enum.map(&{&1.step_name, &1.status})
  end

  defp failure_reason(task_id) do
    task_id
    |> Runs.for_edge("in_review->done")
    |> Enum.find(&(&1.step_name == @webhook_step))
    |> Map.get(:reason)
  end

  # A private registry holding ONE diverting step, used only by the
  # hazard-is-real control above. It never resolves the shipped names.
  defp diverting_registry do
    name = :"divert_registry_#{System.unique_integer([:positive])}"
    {:ok, _pid} = StepRegistry.start_link(name: name)

    :ok =
      StepRegistry.register(
        %{name: "s_divert", mfa: {__MODULE__, :divert_step, 1}, kind: :deterministic},
        name
      )

    name
  end

  @doc false
  def divert_step(_context), do: {:diverted, :control}

  defp restore(key, nil), do: Application.delete_env(:platform, key)
  defp restore(key, value), do: Application.put_env(:platform, key, value)
end
